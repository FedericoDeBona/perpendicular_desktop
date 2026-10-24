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
}

@MainActor
final class VirtualMachineController {
    let directory: URL
    let runtime: URL
    let configuration: MachineConfiguration
    private var machine: Process?
    private var tpm: Process?
    var onDesktopSize:((NSSize)->Void)?
    var desktopState:[String:Any] {desktop?.state ?? ["visible":false]}
    private var desktop:DesktopWindow?
    private var displayControl:DesktopConnection?
    private var displayRequest:UUID?
    let controlSocket: String

    init(directory: URL, runtime: URL) throws {
        self.directory = directory
        self.runtime = runtime
        configuration = try JSONDecoder().decode(MachineConfiguration.self,
            from: Data(contentsOf: directory.appendingPathComponent("machine.json")))
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
    var virtualDisplayEnabled:Bool {nativeGraphicsEnabled}
    var desktopIsKey:Bool {desktop?.window.isKeyWindow == true}

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
            if desktop == nil {desktop=try DesktopWindow(socket:launch.socket,endpoint:{[weak self] in self?.desktopLaunch()?.native},resized:{[weak self] size in self?.onDesktopSize?(size)})}
            desktop?.show();return
        }
        let path=directory.appendingPathComponent("qemu-system-aarch64.pid")
        guard let text=try? String(contentsOf:path,encoding:.utf8),let pid=Int32(text),
              let application=NSRunningApplication(processIdentifier:pid) else {return}
        application.unhide();application.activate(options:[])
    }
    func fitDesktopContent(to size:NSSize){desktop?.fitContent(to:size)}
    func closeDesktop(){desktop?.stop();desktop?.window.close();desktop=nil}
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
        var arguments = [
            "-name", "Perpendicular Windows", "-uuid", c.id,
            "-L",runtime.deletingLastPathComponent().appendingPathComponent("share/qemu").path,
            "-k",c.keyboardLayout ?? "en-us",
            "-machine", "virt,gic-version=3,highmem=on,pflash0=code,pflash1=vars",
            "-accel", native == nil ? "hvf":"hvf,ipa-granule-size=4096", "-cpu", "host", "-smp", String(c.cpus), "-m", String(c.memoryMiB),
            "-nodefaults", "-vga", "none",
            "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0",
            "-device", "usb-tablet,bus=xhci.0", "-device", "virtio-rng-pci",
            "-netdev", "user,id=net", "-device", "virtio-net-pci,netdev=net,romfile=,mac=\(c.mac)",
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
            "-device", native == nil ? "tpm-tis-device,tpmdev=tpm,ppi=off":"tpm-tis-device,tpmdev=tpm",
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
            // The signed v0.4 driver deduplicates connected->connected
            // notifications, so a later RFB resize may not refresh its modes.
            // Seed the single monitor with the Mac's bounded Retina raster.
            let initialDisplay=HostDisplay.current().first?.guestPixelSize ?? NSSize(width:1280,height:800)
            arguments += ["-device","virtio-ramfb-gl,id=display0,addr=0x8,disable-legacy=on,neptune=on,blob=on,hostmem=512M,max_outputs=1,xres=\(Int(initialDisplay.width)),yres=\(Int(initialDisplay.height))"]
        }else{arguments += ["-device","ramfb"]}
        machine = try launch("qemu-system-aarch64",arguments,log:"qemu.log",executable:native?.executable,
            environment:native?.environment(directory:displayDirectory,session:session,primary:HostDisplay.current().first(where:\.primary)))
        let endpoint=nativeGraphicsEnabled ? NativeDisplayEndpoint(socketPath:displayDirectory.appendingPathComponent("native-display.sock").path,
            serverPID:machine!.processIdentifier,expectedUID:getuid(),sessionHi:UInt64(session.prefix(16),radix:16)!,sessionLo:UInt64(session.suffix(16),radix:16)!,epoch:1):nil
        let state=DesktopLaunch(machineID:c.id,pid:machine!.processIdentifier,socket:desktopSocket,native:endpoint)
        let launchFile=directory.appendingPathComponent("desktop-launch.json")
        try JSONEncoder().encode(state).write(to:launchFile,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:launchFile.path)
        let companion=tpm
        machine?.terminationHandler={_ in if companion?.isRunning==true{companion?.terminate()}}
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
