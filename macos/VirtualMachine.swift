import Foundation
import Darwin
import AppKit

enum MachineRuntimeState:Equatable,Sendable {
    case stopped,running(Int32),unreachable(Int32?)
    var pid:Int32? {
        switch self {case .stopped:return nil;case .running(let pid):return pid;case .unreachable(let pid):return pid}
    }
}

struct MachineConfiguration: Codable {
    let id: String
    let name: String
    let cpus: Int
    let memoryMiB: Int
    let disk: String
    let firmware: String
    let variables: String
    let mac: String
    let guestPort: UInt16
    let token: String
    let graphics:String?
    let recoveryDisplay:Bool?
    let keyboardLayout:String?
    let tpmStateFile:String?
    let dynamicMemory:DynamicMemoryConfiguration?
    let sharedDownloads:SharedDownloadsConfiguration?
    let sharedFolders:SharedFoldersConfiguration?
    var folderExports:[SharedFolderExport] {
        if let sharedFolders {return sharedFolders.folders}
        return sharedDownloads.map{[SharedFolderExport(kind:.downloads,hostPath:$0.hostPath)]} ?? []
    }
    /// Experimental protected layout: one accelerated desktop plus one DOD
    /// adapter per Mac display. Enabled only after installing the signed pair.
    let mixedDisplays:Bool?
    var settings:MachineSettings {
        var result=MachineSettings(cpus:cpus,initialMemoryMiB:memoryMiB,automaticMemory:dynamicMemory != nil,
              maximumMemoryMiB:memoryMiB+(dynamicMemory?.hotplugMiB ?? 0),
              backgroundMemoryMiB:dynamicMemory?.backgroundMiB ?? min(memoryMiB,1536),
              reserveMemoryMiB:dynamicMemory?.reserveMiB ?? 512)
        result.sharedFolderSelection=Dictionary(uniqueKeysWithValues:SharedFolderKind.allCases.map{kind in
            (kind.rawValue,folderExports.contains{$0.kind == kind})
        })
        return result
    }
}

@MainActor
final class VirtualMachineController {
    let directory: URL
    let runtime: URL
    let configuration: MachineConfiguration
    private var machine: Process?
    private var tpm: Process?
    var onDesktopSize:((NSSize)->Void)?
    var desktopClipboardBridge:GuestBridge?
    var onDesktopInput:(()->Void)?
    var desktopState:[String:Any] {desktop?.state ?? ["visible":false]}
    private var desktop:DesktopWindow?
    private var displayControl:DesktopConnection?
    private var displayRequest:UUID?
    private(set) var desktopResolutionPending=false
    let controlSocket: String

    init(directory: URL, runtime: URL) throws {
        self.directory = directory
        self.runtime = runtime
        configuration = try JSONDecoder().decode(MachineConfiguration.self,
            from: Data(contentsOf: directory.appendingPathComponent("machine.json")))
        try configuration.dynamicMemory?.validate(baseMiB:configuration.memoryMiB)
        if configuration.sharedFolders != nil {try configuration.sharedFolders?.validate()}
        else {try configuration.sharedDownloads?.validate()}
        guard configuration.graphics == nil || ["standard","virtio2D","native3D"].contains(configuration.graphics!) else{
            throw CocoaError(.coderReadCorrupt,userInfo:[NSLocalizedDescriptionKey:"Unknown Windows graphics configuration."])
        }
        if let layout=configuration.keyboardLayout {
            guard !layout.isEmpty,layout.utf8.count<=32,layout.utf8.allSatisfy({(97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95}),
                  FileManager.default.fileExists(atPath:runtime.deletingLastPathComponent().appendingPathComponent("share/qemu/keymaps/\(layout)").path) else {
                throw CocoaError(.coderReadCorrupt,userInfo:[NSLocalizedDescriptionKey:"Unsupported Windows console keyboard layout."])
            }
        }
        if let file=configuration.tpmStateFile {
            let state=URL(fileURLWithPath:file).standardizedFileURL
            let allowed=directory.appendingPathComponent("Windows/tpm").standardizedFileURL.path+"/"
            guard state.path.hasPrefix(allowed),FileManager.default.fileExists(atPath:state.path),
                  !file.contains(",") else {
                throw CocoaError(.coderReadCorrupt,userInfo:[NSLocalizedDescriptionKey:"Invalid imported Windows TPM state."])
            }
        }
        controlSocket = "/tmp/perpendicular-\(getuid())-\(configuration.id.prefix(8)).sock"
    }

    var isRunning: Bool {
        if machine?.isRunning == true { return true }
        return (try? MachineControl.execute(socket:controlSocket,operation:"query-uuid")["UUID"] as? String) == configuration.id
    }
    /// QMP runs away from AppKit. A live recorded process with an unavailable
    /// control channel is unknown, never permission to start a second VM.
    func observedState() async -> MachineRuntimeState {
        let directory=directory,id=configuration.id,socket=controlSocket
        return await Task.detached {
            let pidFile=directory.appendingPathComponent("qemu-system-aarch64.pid")
            let saved=(try? String(contentsOf:pidFile,encoding:.utf8)).flatMap{Int32($0.trimmingCharacters(in:.whitespacesAndNewlines))}
            let live=saved.flatMap{pid -> Int32? in
                guard pid>1 else{return nil}
                return kill(pid,0)==0 || errno != ESRCH ? pid:nil
            }
            do {
                let reply=try MachineControl.execute(socket:socket,operation:"query-uuid",expectedPID:live)
                guard (reply["UUID"] as? String)?.lowercased()==id.lowercased(),let live else{return .unreachable(live)}
                return .running(live)
            }catch {return live.map{.unreachable($0)} ?? .stopped}
        }.value
    }
    func forceStop(expectedPID:Int32) async throws {
        let socket=controlSocket,id=configuration.id
        // Authenticate both this VM and this process generation on the same
        // connection that receives quit. Never kill a PID from a stale file.
        try await Task.detached {
            _=try MachineControl.execute(socket:socket,operation:"quit",expectedUUID:id,expectedPID:expectedPID)
        }.value
    }
    var nativeGraphicsEnabled:Bool {configuration.graphics == "native3D" && configuration.recoveryDisplay != true}
    var mixedDisplaysEnabled:Bool {nativeGraphicsEnabled && configuration.mixedDisplays == true}
    var virtualDisplayEnabled:Bool {nativeGraphicsEnabled}
    var desktopIsKey:Bool {desktop?.window.isKeyWindow == true}
    var appDisplayBindings:AppDisplayBindings? {
        guard mixedDisplaysEnabled,let launch=desktopLaunch(),
              let data=try? Data(contentsOf:directory.appendingPathComponent("app-displays.json")),data.count<8192,
              let value=try? JSONDecoder().decode(AppDisplayBindings.self,from:data),
              value.machineID==configuration.id,value.pid==launch.pid else{return nil}
        return value
    }

    func applyingPendingSettings()async throws->VirtualMachineController {
        guard await observedState() == .stopped else{return self}
        guard let settings=try MachineSettingsStore.pending(in:directory,machineID:configuration.id) else{return self}
        let file=directory.appendingPathComponent("machine.json")
        let bytes=try MachineSettingsStore.merged(settings,with:Data(contentsOf:file),machineID:configuration.id)
        // Preserve disk, firmware, TPM, token and unknown fields. Validate the
        // complete result before writing, and never edit live QEMU arguments.
        let next=try JSONDecoder().decode(MachineConfiguration.self,from:bytes)
        try next.dynamicMemory?.validate(baseMiB:next.memoryMiB)
        for folder in next.folderExports {try folder.validate(createIfMissing:true)}
        try bytes.write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        let controller=try VirtualMachineController(directory:directory,runtime:runtime)
        try MachineSettingsStore.clear(in:directory)
        return controller
    }

    func withRecoveryDisplay(_ enabled:Bool)throws->VirtualMachineController {
        try withDisplay(graphics:nil,recovery:enabled)
    }
    func withDisplay(graphics:String?,recovery:Bool)throws->VirtualMachineController {
        guard !isRunning else {throw CocoaError(.executableRuntimeMismatch,userInfo:[NSLocalizedDescriptionKey:"Windows must finish shutting down before its display can change."])}
        let file=directory.appendingPathComponent("machine.json")
        guard var value=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any],value["id"] as? String == configuration.id else {
            throw CocoaError(.coderReadCorrupt)
        }
        if let graphics {
            guard ["standard","native3D"].contains(graphics) else{throw CocoaError(.coderReadCorrupt)}
            value["graphics"]=graphics
        }
        value["recoveryDisplay"]=recovery
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        return try VirtualMachineController(directory:directory,runtime:runtime)
    }

    func shutdown() async throws {
        let state=await observedState()
        if state == .stopped{return}
        guard let pid=state.pid else{throw CocoaError(.executableRuntimeMismatch)}
        let socket=controlSocket,id=configuration.id
        try await Task.detached {
            _=try MachineControl.execute(socket:socket,operation:"system_powerdown",expectedUUID:id,expectedPID:pid)
        }.value
    }

    func showDesktop() async throws {
        try await start()
        if let launch=desktopLaunch() {
            if desktop == nil {desktop=try DesktopWindow(socket:launch.socket,endpoint:{[weak self] in self?.desktopLaunch()?.native},resized:{[weak self] size in self?.onDesktopSize?(size)},input:{[weak self] in self?.onDesktopInput?()})}
            desktop?.configureClipboard(desktopClipboardBridge);desktop?.show();return
        }
        let path=directory.appendingPathComponent("qemu-system-aarch64.pid")
        guard let text=try? String(contentsOf:path,encoding:.utf8),let pid=Int32(text),
              let application=NSRunningApplication(processIdentifier:pid) else {return}
        application.unhide();application.activate(options:[])
    }
    /// Publish exact modes to the dedicated app consoles. The primary VNC
    /// connection and its input stay bound to the reserved Windows desktop.
    func prepareAppMonitorModes(_ modes:[AppMonitorMode]) async throws {
        let changed=modes.filter(\.changed)
        guard !changed.isEmpty else{return}
        guard case .running(let pid)=await observedState() else {throw CocoaError(.executableRuntimeMismatch)}
        let socket=controlSocket,id=configuration.id
        try await Task.detached {
            func value(_ operation:String,_ arguments:[String:Any]) throws -> Any {
                try MachineControl.value(socket:socket,operation:operation,arguments:arguments,expectedUUID:id,expectedPID:pid)
            }
            let consoles=try value("qom-list",["path":"/backend"]) as? [[String:Any]] ?? []
            for mode in changed {
                guard (9...23).contains(mode.slot),(640...4096).contains(mode.width),(480...4096).contains(mode.height) else {
                    throw CocoaError(.coderInvalidValue)
                }
                let device="/machine/peripheral/appdisplay\(mode.slot-9)"
                var selected:String?
                for console in consoles {
                    guard let name=console["name"] as? String,name.hasPrefix("console[") else {continue}
                    let path="/backend/"+name
                    if try value("qom-get",["path":path,"property":"device"]) as? String == device {selected=path;break}
                }
                guard let path=selected else {throw CocoaError(.coderReadCorrupt)}
                let target="\(mode.width)x\(mode.height)"
                _=try value("qom-get",["path":path,"property":"perpendicular-mode"])
                func publish(_ size:String) throws { _=try value("qom-set",["path":path,"property":"perpendicular-mode","value":size]) }
                do {
                    try publish(target);try await Task.sleep(for:.seconds(1))
                    try publish("0x0");try await Task.sleep(for:.seconds(1))
                    try publish(target);try await Task.sleep(for:.seconds(1))
                }catch {
                    // Reconnect before reporting a failed update; never leave
                    // an admitted app display intentionally disconnected.
                    try? publish(target);throw error
                }
            }
        }.value
    }
    func requestDesktopResolution(_ size:NSSize){
        guard let launch=desktopLaunch() else{return}
        displayControl?.stop()
        let request=UUID();displayRequest=request;desktopResolutionPending=true
        // This publishes the custom mode to virtio-gpu. The guest's driver
        // helper applies it; RFB's framebuffer acknowledgement is not proof
        // of the Windows mode, which ApplicationModel reads back separately.
        let client=DesktopConnection(path:launch.socket,receive:{_,_,_ in},layout:{_ in},failed:{[weak self] _ in
            guard let self,self.displayRequest == request else{return};self.desktopResolutionPending=false
        })
        displayControl=client;client.requestPixels(false)
        client.setScreens([DesktopScreen(id:0,x:0,y:0,width:Int(size.width),height:Int(size.height))],reconnectMonitor:nativeGraphicsEnabled,submitted:{[weak self] in
            guard let self,self.displayRequest == request else{return};self.desktopResolutionPending=false
        });client.start()
    }
    func finishDesktopResolution(){displayRequest=nil;desktopResolutionPending=false;displayControl?.stop();displayControl=nil}
    func closeDesktop(){finishDesktopResolution();desktop?.stop();desktop?.window.close();desktop=nil}
    func closeForegroundApplication(notAfter:Double) async throws {
        try await sendApplicationChord(["alt","f4"],notAfter:notAfter)
    }
    func cycleApplicationFocus(notAfter:Double) async throws {
        try await sendApplicationChord(["alt","esc"],notAfter:notAfter)
    }
    func moveApplicationToNextDisplay(notAfter:Double) async throws {
        try await sendApplicationChord(["meta_l","shift","right"],notAfter:notAfter)
    }
    func restoreDesktopApplication(notAfter:Double) async throws {
        try await sendApplicationChord(["meta_l","down"],notAfter:notAfter)
    }
    func nudgeApplication(moveKey:String,direction:String,notAfter:Double) async throws {
        guard moveKey.utf8.count==1,let key=moveKey.utf8.first,(97...122).contains(key),
              ["up","down","left","right"].contains(direction) else{throw CocoaError(.coderInvalidValue)}
        // Read the system-menu accelerator from this exact target's Windows
        // menu instead of assuming an English installation. Each key has a
        // bounded release; cancellation stops the sequence at a key boundary.
        for keys in [["alt","spc"],[moveKey],[direction],["ret"]] {
            try Task.checkCancellation()
            try await sendApplicationChord(keys,notAfter:notAfter)
            try await Task.sleep(for:.milliseconds(130))
        }
    }
    func fitDesktopApplication(notAfter:Double) async throws {
        try await sendApplicationChord(["meta_l","up"],notAfter:notAfter)
    }
    private func sendApplicationChord(_ keys:[String],notAfter:Double) async throws {
        guard let launch=desktopLaunch() else{throw CocoaError(.executableRuntimeMismatch)}
        let socket=controlSocket,id=configuration.id,pid=launch.pid
        try await Task.detached {
            // QEMU releases both device keys after the bounded hold, even if
            // the frontend disappears. No process termination or token change.
            _=try MachineControl.execute(socket:socket,operation:"send-key",
                arguments:["keys":keys.map{["type":"qcode","data":$0]},"hold-time":100],
                expectedUUID:id,expectedPID:pid,notAfter:notAfter)
        }.value
    }
    func synchronizePrimaryDisplay(){
        // The v0.4 native driver keeps the modes advertised at boot. Sending
        // a new RFB preferred size while connected can select a smaller default
        // instead of adding that mode. The native boot already seeds the raster.
        guard !nativeGraphicsEnabled else{return}
        guard virtualDisplayEnabled,let launch=desktopLaunch(),let host=HostDisplay.current().first else{return}
        let size=host.guestPixelSize
        let width=Int(size.width),height=Int(size.height)
        let request=UUID();displayRequest=request;displayControl?.stop()
        let client=DesktopConnection(path:launch.socket,receive:{_,_,_ in},layout:{[weak self] screen in
            guard let self,self.displayRequest == request,screen.width == width,screen.height == height else{return}
            self.displayRequest=nil;self.displayControl?.stop();self.displayControl=nil
        },failed:{[weak self] _ in
            guard let self,self.displayRequest == request else{return}
            self.displayRequest=nil;self.displayControl?.stop();self.displayControl=nil
        })
        // Configure the monitor after the interactive guest is connected, not
        // while firmware is choosing its boot framebuffer. Closing the recovery
        // console must not control the Windows monitor geometry.
        displayControl=client;client.requestPixels(false)
        client.setScreens([DesktopScreen(id:0,x:0,y:0,width:width,height:height)]);client.start()
        Task{@MainActor [weak self] in
            try? await Task.sleep(for:.seconds(5))
            guard let self,self.displayRequest == request else{return}
            self.displayRequest=nil;self.displayControl?.stop();self.displayControl=nil
        }
    }
    var usesSMBFolders:Bool {desktopLaunch()?.fileSharing == "smb"}
    private func desktopLaunch()->DesktopLaunch?{
        guard let bytes=try? Data(contentsOf:directory.appendingPathComponent("desktop-launch.json")),bytes.count<8192,
              let launch=try? JSONDecoder().decode(DesktopLaunch.self,from:bytes),launch.machineID == configuration.id,
              let text=try? String(contentsOf:directory.appendingPathComponent("qemu-system-aarch64.pid"),encoding:.utf8),
              Int32(text) == launch.pid,kill(launch.pid,0) == 0 else{return nil}
        return launch
    }

    func start() async throws {
        switch await observedState() {
        case .running:return
        case .unreachable:throw CocoaError(.executableRuntimeMismatch,userInfo:[NSLocalizedDescriptionKey:"Lo stato della VM non è verificabile. Non avvio una seconda istanza."])
        case .stopped:break
        }
        closeDesktop()
        let vm = directory.appendingPathComponent("Windows")
        guard configuration.graphics != "virtio2D" || configuration.recoveryDisplay == true else {
            throw CocoaError(.executableRuntimeMismatch,userInfo:[NSLocalizedDescriptionKey:"The reference 2D experiment is not an available display backend. Choose Standard or Recovery Display."])
        }
        let resources=runtime.deletingLastPathComponent().deletingLastPathComponent()
        let native=nativeGraphicsEnabled ? try NativeGraphics(root:resources.appendingPathComponent("Native3D")):nil
        let hostDisplays=HostDisplay.current()
        if let native,configuration.dynamicMemory != nil,!native.supportsDynamicMemory {
            throw CocoaError(.executableRuntimeMismatch,userInfo:[NSLocalizedDescriptionKey:"This graphics runtime has not been qualified for dynamic RAM. Use the qualified Windows IoT memory runtime."])
        }
        if mixedDisplaysEnabled && (!nativeGraphicsEnabled || native?.supportsMixedDisplays != true) {
            throw CocoaError(.executableRuntimeMismatch,userInfo:[NSLocalizedDescriptionKey:"Il runtime non supporta la configurazione multischermo protetta."])
        }
        if mixedDisplaysEnabled && !(1...15).contains(hostDisplays.count) {
            throw CocoaError(.executableRuntimeMismatch,userInfo:[NSLocalizedDescriptionKey:"La configurazione multischermo richiede da uno a quindici schermi Mac rilevati."])
        }
        if mixedDisplaysEnabled && !MixedDisplayPlan.supported(hostDisplays) {
            throw CocoaError(.executableRuntimeMismatch,userInfo:[NSLocalizedDescriptionKey:"Gli schermi collegati non sono supportati dalla configurazione multischermo corrente."])
        }
        let session=UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        let displayDirectory=URL(fileURLWithPath:"/tmp/perpendicular-display-\(getuid())-\(session.prefix(8))")
        try FileManager.default.createDirectory(at:displayDirectory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let desktopSocket=displayDirectory.appendingPathComponent("desktop.sock").path
        let tpmSocket = "/tmp/perpendicular-tpm-\(getuid())-\(configuration.id.prefix(8)).sock"
        try await stopPreviousTPM(socket:tpmSocket,vm:vm)
        try? FileManager.default.removeItem(atPath: controlSocket)
        try? FileManager.default.removeItem(atPath: tpmSocket)
        let tpmState=configuration.tpmStateFile.map{"backend-uri=file://\($0),lock"} ?? "dir=\(vm.path)/tpm"
        tpm = try launch("swtpm", ["socket", "--tpm2", "--tpmstate", tpmState,
            "--ctrl", "type=unixio,path=\(tpmSocket)", "--flags", "not-need-init"], log: "tpm.log")
        // The TPM creates its socket before the VM can attach to it.
        let deadline = Date().addingTimeInterval(10)
        while tpm?.isRunning == true, !FileManager.default.fileExists(atPath: tpmSocket), Date() < deadline {
            try await Task.sleep(for:.milliseconds(20))
        }
        guard FileManager.default.fileExists(atPath: tpmSocket) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The virtual TPM did not start."])
        }
        func block(_ object: [String: Any]) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        }
        let c = configuration
        // The default 512 GiB PCI window can exceed the HVF guest PA range.
        // A 1 GiB aligned window fits this single GPU's 512 MiB BAR and keeps
        // PCI enumeration available alongside the bounded hotplug region.
        let pciWindow=native != nil ? ",highmem-mmio-size=1G":""
        let sharing=try await SambaServer.ensure(directory:directory,exports:c.folderExports,runtime:runtime)
        var arguments = [
            "-name", "Perpendicular Windows", "-uuid", c.id,
            "-L",runtime.deletingLastPathComponent().appendingPathComponent("share/qemu").path,
            "-k",c.keyboardLayout ?? "en-us",
            "-machine", "virt,gic-version=3,highmem=on,pflash0=code,pflash1=vars\(pciWindow)",
            "-accel", native == nil ? "hvf":"hvf,ipa-granule-size=4096", "-cpu", "host", "-smp", String(c.cpus), "-m", String(c.memoryMiB),
            "-nodefaults", "-vga", "none",
            "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0",
            "-device", "usb-tablet,bus=xhci.0", "-device", "virtio-rng-pci",
            "-netdev", "user,id=net,guestfwd=tcp:10.0.2.4:445-cmd:/usr/bin/nc 127.0.0.1 \(sharing.port)", "-device", "virtio-net-pci,netdev=net,romfile=,mac=\(c.mac)",
            "-blockdev", block(["driver":"file","node-name":"code-file","filename":c.firmware,"read-only":true]),
            "-blockdev", block(["driver":"raw","node-name":"code","file":"code-file","read-only":true]),
            "-blockdev", block(["driver":"file","node-name":"vars-file","filename":c.variables]),
            "-blockdev", block(["driver":"raw","node-name":"vars","file":"vars-file"]),
            "-blockdev", block(["driver":"file","node-name":"disk-file","filename":c.disk]),
            "-blockdev", block(["driver":"qcow2","node-name":"disk","file":"disk-file"]),
            "-device", "nvme,drive=disk,serial=perpendicular,bootindex=1",
            "-drive", "if=none,id=bootstrap,media=cdrom,readonly=on",
            "-device", "usb-bot,id=usbcd,bus=xhci.0", "-device", "scsi-cd,drive=bootstrap,bus=usbcd.0",
            "-chardev", "socket,id=tpmchar,path=\(tpmSocket)", "-tpmdev", "emulator,id=tpm,chardev=tpmchar",
            "-device", native == nil && c.dynamicMemory == nil ? "tpm-tis-device,tpmdev=tpm,ppi=off":"tpm-tis-device,tpmdev=tpm",
            "-display", nativeGraphicsEnabled ? "egl-headless,gl=es":"none", "-vnc", "unix:\(desktopSocket)",
            "-qmp", "unix:\(controlSocket),server=on,wait=off",
            "-monitor", "none", "-serial", "file:\(directory.path)/serial.log", "-rtc", "base=localtime"
        ]
        if nativeGraphicsEnabled {
            // First qualify the reference backend's single scanout. Additional
            // monitor outputs require their own topology/capture integration.
            // Retina window capture needs contiguous 16 MiB driver pools. The
            // measured 256 MiB aperture fragmented below that size with two
            // ordinary apps; use the next PCI BAR size for this local 3D path.
            // Windows caches the monitor's initial mode envelope. Include the
            // full display, not only its work area, so fullscreen also fits.
            let fullDisplay=hostDisplays.first.map {
                let scale=mixedDisplaysEnabled ? CGFloat(MixedDisplayPlan.rasterScale(hostDisplays)):$0.scale
                return NSSize(width:$0.frame.width*scale,height:$0.frame.height*scale)
            } ?? NSSize(width:1280,height:800)
            let scale=min(1,4096/fullDisplay.width,4096/fullDisplay.height,sqrt(8_388_608/(fullDisplay.width*fullDisplay.height)))
            let initialDisplay=NSSize(width:max(640,(fullDisplay.width*scale).rounded()),height:max(480,(fullDisplay.height*scale).rounded()))
            arguments += ["-device","virtio-ramfb-gl,id=display0,addr=0x8,disable-legacy=on,neptune=on,blob=on,hostmem=512M,max_outputs=1,xres=\(Int(initialDisplay.width)),yres=\(Int(initialDisplay.height))"]
            if mixedDisplaysEnabled {
                let appScale=MixedDisplayPlan.rasterScale(hostDisplays)
                for (index,host) in hostDisplays.enumerated() {
                    let size=NSSize(width:host.frame.width*CGFloat(appScale),height:host.frame.height*CGFloat(appScale))
                    let slot=String(9+index,radix:16)
                    arguments += ["-device","virtio-gpu-pci,id=appdisplay\(index),addr=0x\(slot),disable-legacy=on,max_outputs=1,xres=\(Int(size.width)),yres=\(Int(size.height))"]
                }
            }
        }else{arguments += ["-device","ramfb"]}
        if let memory=c.dynamicMemory {
            let index=arguments.firstIndex(of:"-m")!+1
            arguments[index]="\(c.memoryMiB)M,slots=2,maxmem=\(c.memoryMiB+memory.hotplugMiB)M"
            arguments += ["-device","virtio-balloon-pci,id=balloon0,deflate-on-oom=on",
                "-object","memory-backend-ram,id=vmemram,size=\(memory.hotplugMiB)M",
                "-device","virtio-mem-pci,id=vmem0,memdev=vmemram,requested-size=0,block-size=2M,dynamic-memslots=off"]
        }
        var launchEnvironment=native?.environment(directory:displayDirectory,session:session,primary:HostDisplay.current().first(where:\.primary))
        // Never inherit an experiment flag into an ordinary VM. The runtime
        // changes the primary PCI identity only for this explicit configuration.
        if native != nil {launchEnvironment?["PERP_VIRTIO_MIXED_DISPLAYS"]=mixedDisplaysEnabled ? "1":"0"}
        if c.dynamicMemory != nil {
            launchEnvironment=(launchEnvironment ?? [:]).merging(["PERP_HVF_BALLOON_RECLAIM":"1","PERP_HVF_VIRTIO_MEM":"1"]){_,new in new}
        }
        machine = try launch("qemu-system-aarch64",arguments,log:"qemu.log",executable:native?.executable,
            environment:launchEnvironment)
        if mixedDisplaysEnabled {
            let value=AppDisplayBindings(machineID:c.id,pid:machine!.processIdentifier,
                displays:hostDisplays.enumerated().map{AppDisplayBinding(hostID:$0.element.stableID!,slot:9+$0.offset)})
            let path=directory.appendingPathComponent("app-displays.json")
            try JSONEncoder().encode(value).write(to:path,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        }
        let endpoint=nativeGraphicsEnabled ? NativeDisplayEndpoint(socketPath:displayDirectory.appendingPathComponent("native-display.sock").path,
            serverPID:machine!.processIdentifier,expectedUID:getuid(),sessionHi:UInt64(session.prefix(16),radix:16)!,sessionLo:UInt64(session.suffix(16),radix:16)!,epoch:1):nil
        let state=DesktopLaunch(machineID:c.id,pid:machine!.processIdentifier,socket:desktopSocket,native:endpoint,
            wgcSocket:nativeGraphicsEnabled ? NativeWindowFrames.shared.socketPath:nil,fileSharing:"smb")
        let launchFile=directory.appendingPathComponent("desktop-launch.json")
        try JSONEncoder().encode(state).write(to:launchFile,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:launchFile.path)
        let companion=tpm
        machine?.terminationHandler={_ in
            if companion?.isRunning==true{companion?.terminate()}
        }
        let readyDeadline=Date().addingTimeInterval(4)
        while Date()<readyDeadline {
            if machine?.isRunning != true {
                if tpm?.isRunning==true{tpm?.terminate()}
                throw CocoaError(.executableRuntimeMismatch,userInfo:[NSLocalizedDescriptionKey:"Windows could not start. See qemu.log in the machine folder."])
            }
            if FileManager.default.fileExists(atPath:controlSocket),case .running=await observedState() {return}
            try await Task.sleep(for:.milliseconds(30))
        }
        // A live VM can take longer on its first launch. The guest connection
        // and desktop retry report readiness; do not label a slow boot failed.
        guard machine?.isRunning == true else {
            throw CocoaError(.executableNotLoadable,userInfo:[NSLocalizedDescriptionKey:"Windows stopped while starting."])
        }
    }

    private func stopPreviousTPM(socket:String,vm:URL) async throws {
        guard let text=try? String(contentsOf:directory.appendingPathComponent("swtpm.pid"),encoding:.utf8),let pid=Int32(text),kill(pid,0) == 0 else{return}
        let inspect=Process();inspect.executableURL=URL(fileURLWithPath:"/bin/ps");inspect.arguments=["-p",String(pid),"-o","command="]
        let pipe=Pipe();inspect.standardOutput=pipe;try inspect.run()
        let command=String(data:pipe.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? "";inspect.waitUntilExit()
        guard command.contains(socket),command.contains(vm.path+"/tpm") else{throw CocoaError(.executableRuntimeMismatch,userInfo:[NSLocalizedDescriptionKey:"The saved TPM process does not belong to this machine."])}
        kill(pid,SIGTERM)
        let deadline=Date().addingTimeInterval(3)
        while kill(pid,0) == 0,Date()<deadline {try await Task.sleep(for:.milliseconds(30))}
        guard kill(pid,0) != 0 else{throw CocoaError(.executableRuntimeMismatch,userInfo:[NSLocalizedDescriptionKey:"The virtual TPM is still stopping."])}
    }
    private func launch(_ name: String, _ arguments: [String], log: String,executable:URL?=nil,environment:[String:String]?=nil) throws -> Process {
        let process = Process()
        process.executableURL=executable ?? runtime.appendingPathComponent(name)
        if let environment {
            var inherited=ProcessInfo.processInfo.environment
            for name in ["PERP_PRIMARY_MONITOR_WIDTH_MM","PERP_PRIMARY_MONITOR_HEIGHT_MM","PERP_PRIMARY_MONITOR_ID"] {
                inherited.removeValue(forKey:name)
            }
            process.environment=inherited.merging(environment){_,new in new}
        }
        process.arguments = arguments
        let logURL = directory.appendingPathComponent(log)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions:0o600])
        }
        let output = try FileHandle(forWritingTo: logURL)
        try output.seekToEnd()
        process.standardOutput = output; process.standardError = output
        try process.run()
        try Data(String(process.processIdentifier).utf8).write(to: directory.appendingPathComponent(name + ".pid"), options: .atomic)
        return process
    }
}
