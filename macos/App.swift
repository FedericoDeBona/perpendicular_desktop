import AppKit
import SwiftUI

struct WindowsApplication:Identifiable {
    let id:String
    let name:String
}

@MainActor
final class ApplicationModel:NSObject,NSApplicationDelegate,NSMenuItemValidation,ObservableObject {
    @Published var apps:[WindowsApplication]=[]
    @Published var status="Waiting for Windows…"
    @Published var displayStatus="Waiting for Windows display…"
    @Published var connected=false
    private var launcher:NSWindow!
    private var machine:VirtualMachineController!
    private var bridge:GuestBridge!
    private var windows:[String:ApplicationWindow]=[:]
    private var earlyFrames:[String:GuestPacket]=[:]
    private var layoutInProgress=false
    private var pointerExitTask:Task<Void,Never>?
    private var displaySetupTask:Task<Void,Never>?
    private var displaySetupID=UUID()
    private var displayEpoch:String?
    private var displayRevision=0
    private var displayReadable=false
    private var displayConfigurable=false
    private var displayReadTask:Task<Void,Never>?
    private var sharedDisplay:SharedDisplay?
    private var recoveryItem:NSMenuItem!
    private var displayItems:[NSMenuItem]=[]
    private var restarting=false

    func applicationDidFinishLaunching(_ notification:Notification){
        do{
            let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Perpendicular Restart")
            let runtime:URL
            if let override=ProcessInfo.processInfo.environment["PERPENDICULAR_RUNTIME"] {runtime=URL(fileURLWithPath:override)}
            else {runtime=try RuntimeStore.prepare(contents:Bundle.main.bundleURL.appendingPathComponent("Contents"),directory:directory)}
            machine=try VirtualMachineController(directory:directory,runtime:runtime)
            bridge=try GuestBridge(port:machine.configuration.guestPort,token:machine.configuration.token)
            bridge.onConnection={ [weak self] value in
                guard let self else{return};self.connected=value;self.status=value ? "Windows connected":"Reconnecting to Windows…"
                if !value {
                    self.displayEpoch=nil;self.displayReadable=false;self.displayConfigurable=false
                    self.displaySetupTask?.cancel();self.displaySetupTask=nil
                    self.displaySetupID=UUID()
                    self.displayReadTask?.cancel();self.displayReadTask=nil
                    self.invalidateDisplay("Waiting for Windows display…")
                }
                if value{
                    self.refresh()
                    if ProcessInfo.processInfo.environment["PERPENDICULAR_AUDIT"] == "1" {self.bridge.command("diagnostics",timeout:.seconds(35)){result in
                        if case .success(let reply)=result,let data=try? JSONSerialization.data(withJSONObject:reply["value"] ?? [:],options:[.prettyPrinted,.sortedKeys]){
                            let report=directory.appendingPathComponent("guest-diagnostics.json")
                            try? data.write(to:report,options:.atomic)
                            try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:report.path)
                            try? FileManager.default.removeItem(at:directory.appendingPathComponent("guest-diagnostics-error.txt"))
                        }else if case .failure(let error)=result{
                            try? Data(error.localizedDescription.utf8).write(to:directory.appendingPathComponent("guest-diagnostics-error.txt"),options:.atomic)
                        }
                    }}
                }
            }
            bridge.onPacket={ [weak self] packet in self?.receive(packet) }
            if !machine.isRunning{try machine.start()}
        }catch{status=error.localizedDescription}
        launcher=NSWindow(contentRect:NSRect(x:200,y:160,width:560,height:620),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        launcher.title="Windows Applications";launcher.isReleasedWhenClosed=false
        launcher.contentView=NSHostingView(rootView:Launcher(model:self))
        launcher.center();launcher.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        let main=NSMenu();let appItem=NSMenuItem();main.addItem(appItem)
        let menu=NSMenu();appItem.submenu=menu
        let applications=NSMenuItem(title:"Applications",action:#selector(showApplications),keyEquivalent:"l");applications.target=self;menu.addItem(applications)
        let show=NSMenuItem(title:"Show Windows",action:#selector(showWindows),keyEquivalent:"");show.target=self;menu.addItem(show)
        let displayItem=NSMenuItem(title:"Display",action:nil,keyEquivalent:"")
        let displayMenu=NSMenu();displayItem.submenu=displayMenu;menu.addItem(displayItem)
        for (profile,title) in [("standard","Standard"),("native3D","Experimental 3D")] {
            let item=NSMenuItem(title:title,action:#selector(selectDisplay(_:)),keyEquivalent:"")
            item.target=self;item.representedObject=profile
            item.state=machine?.configuration.graphics == profile ? .on:.off
            displayItems.append(item);displayMenu.addItem(item)
        }
        recoveryItem=NSMenuItem(title:"Recovery Display",action:#selector(toggleRecoveryDisplay),keyEquivalent:"")
        recoveryItem.target=self;recoveryItem.state=machine?.configuration.recoveryDisplay == true ? .on:.off
        recoveryItem.isEnabled=machine != nil;menu.addItem(recoveryItem)
        let shutdown=NSMenuItem(title:"Shut Down Windows",action:#selector(shutdownWindows),keyEquivalent:"");shutdown.target=self;menu.addItem(shutdown)
        menu.addItem(.separator());menu.addItem(withTitle:"Quit",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        NSApp.mainMenu=main
        NotificationCenter.default.addObserver(self,selector:#selector(hostDisplaysChanged),
            name:NSApplication.didChangeScreenParametersNotification,object:nil)
        let editItem=NSMenuItem();main.addItem(editItem)
        let edit=NSMenu(title:"Edit");editItem.submenu=edit
        edit.addItem(withTitle:"Cut",action:#selector(NSText.cut(_:)),keyEquivalent:"x")
        edit.addItem(withTitle:"Copy",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
        edit.addItem(withTitle:"Paste",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        edit.addItem(withTitle:"Select All",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        let windowItem=NSMenuItem();main.addItem(windowItem)
        let windowMenu=NSMenu(title:"Window");windowItem.submenu=windowMenu;NSApp.windowsMenu=windowMenu
        windowMenu.addItem(withTitle:"Minimize",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m")
        let close=NSMenuItem(title:"Close",action:#selector(closeCurrentWindow),keyEquivalent:"w");close.target=self;windowMenu.addItem(close)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool{showApplications();return false}
    @objc func showApplications(){launcher.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    @objc func closeCurrentWindow(){(NSApp.keyWindow ?? NSApp.mainWindow)?.performClose(nil)}
    func applicationWillTerminate(_ notification:Notification){bridge?.command("release");machine?.closeDesktop()}
    @objc func showWindows(){do{try machine.showDesktop()}catch{status=error.localizedDescription}}
    @objc func shutdownWindows(){do{try machine.shutdown()}catch{status=error.localizedDescription}}
    @objc private func toggleRecoveryDisplay(){
        guard let previous=machine,!restarting else{return}
        let enabled=previous.configuration.recoveryDisplay != true
        restartDisplay(graphics:nil,recovery:enabled)
    }
    @objc private func selectDisplay(_ sender:NSMenuItem){
        guard let profile=sender.representedObject as? String else{return}
        guard machine?.configuration.graphics != profile || machine?.configuration.recoveryDisplay == true else{return}
        restartDisplay(graphics:profile,recovery:false)
    }
    func validateMenuItem(_ item:NSMenuItem)->Bool {
        if item.action == #selector(selectDisplay(_:)) || item.action == #selector(toggleRecoveryDisplay) {
            return machine != nil && !restarting
        }
        return true
    }
    private func restartDisplay(graphics:String?,recovery:Bool){
        guard let previous=machine,!restarting else{return}
        restarting=true;recoveryItem.isEnabled=false;status="Restarting Windows…"
        Task{@MainActor [weak self] in
            guard let self else{return}
            defer {self.restarting=false;self.recoveryItem.isEnabled=true}
            do {
                try previous.shutdown()
                let deadline=Date().addingTimeInterval(60)
                while previous.isRunning,Date()<deadline {try await Task.sleep(for:.milliseconds(500))}
                guard !previous.isRunning else {
                    self.status="Windows has not shut down. Save your work or use Show Windows.";return
                }
                previous.closeDesktop()
                self.machine=try previous.withDisplay(graphics:graphics,recovery:recovery)
                self.recoveryItem.state=recovery ? .on:.off
                for item in self.displayItems {item.state=self.machine.configuration.graphics == item.representedObject as? String ? .on:.off}
                try self.machine.start();try self.machine.showDesktop()
                self.status="Starting Windows…"
            }catch {self.status=error.localizedDescription}
        }
    }
    func refresh(){
        readDisplay()
        bridge.command("catalogue"){[weak self] result in
            guard let self else{return}
            switch result{
            case .success(let reply):
                let values=reply["value"] as? [[String:Any]] ?? []
                self.apps=values.prefix(1024).compactMap{value in
                    guard let id=value["id"] as? String,id.utf8.count==64,let name=value["name"] as? String,name.utf8.count<=512 else{return nil}
                    return WindowsApplication(id:id,name:name)
                }
                self.status="\(self.apps.count) applications"
            case .failure(let error):self.status=error.localizedDescription
            }
        }
    }
    func launch(_ app:WindowsApplication){
        status="Opening \(app.name)…"
        bridge.command("launch",["app":app.id]){[weak self] result in
            if case .failure(let error)=result{self?.status=error.localizedDescription}
        }
    }
    private func layoutChildren(){
        guard !layoutInProgress else{return};layoutInProgress=true
        defer{layoutInProgress=false}
        for controller in windows.values.sorted(by:{$0.zOrder>$1.zOrder}) where controller.parentID != nil {
            if let parent=controller.parentID,let owner=windows[parent]{controller.attach(to:owner)}
        }
    }
    private func pointerExited(_ id:String){
        pointerExitTask?.cancel()
        pointerExitTask=Task{@MainActor [weak self] in
            try? await Task.sleep(for:.milliseconds(80))
            guard !Task.isCancelled,let self else{return}
            let point=NSEvent.mouseLocation
            guard !self.windows.values.contains(where:{$0.window.isVisible && $0.window.frame.contains(point)}) else{return}
            self.bridge.command("input",["window":id,"event":"leave"])
        }
    }
    private func invalidateDisplay(_ message:String){
        displayRevision+=1;sharedDisplay=nil;displayStatus=message
    }
    @objc private func hostDisplaysChanged(){
        displaySetupTask?.cancel();displaySetupTask=nil
        displaySetupID=UUID()
        invalidateDisplay("Checking Windows display…")
        guard connected else{return}
        machine.synchronizePrimaryDisplay()
        readDisplay()
        prepareDisplay()
    }
    private func prepareDisplay(){
        guard displayConfigurable,machine.virtualDisplayEnabled,let host=HostDisplay.current().first(where:\.primary) else{return}
        let width=min(4096,Int((host.frame.width*host.scale).rounded()))
        let height=min(4096,8_388_608/max(1,width),Int((host.frame.height*host.scale).rounded()))
        configureDisplay(width:width,height:height,epoch:displayEpoch)
    }
    private func readDisplay(){
        guard connected,displayReadable,let epoch=displayEpoch else{return}
        displayRevision+=1;let revision=displayRevision
        bridge.command("display_info",timeout:.seconds(5)){[weak self] result in
            guard let self,self.connected,self.displayEpoch == epoch,self.displayRevision == revision else{return}
            guard case .success(let reply)=result,let snapshot=reply["value"] as? [String:Any] else{
                self.sharedDisplay=nil;self.displayStatus="Windows display could not be checked.";return
            }
            self.acceptDisplay(snapshot)
        }
    }
    private func acceptDisplay(_ snapshot:[String:Any]){
        let host=HostDisplay.current()
        sharedDisplay=host.first(where:\.primary).flatMap{SharedDisplay.primary(host:$0,snapshot:snapshot)}
        if sharedDisplay != nil {displayStatus="Primary Windows display matches this Mac."}
        else if let primary=(snapshot["displays"] as? [[String:Any]])?.first(where:{$0["primary"] as? Bool == true}),
                let width=primary["width"] as? Int,let height=primary["height"] as? Int,
                let dpi=primary["dpi"] as? Int {
            displayStatus="Windows display: \(width) × \(height), \(Int((Double(dpi)*100/96).rounded()))% scale."
        }else {displayStatus="Windows display is unavailable."}
        if ProcessInfo.processInfo.environment["PERPENDICULAR_STATE_TRACE"] == "1",
           let data=try? JSONSerialization.data(withJSONObject:["type":"display_info","guest":snapshot,
                "host":host.map(\.description),"primaryMatchesHost":sharedDisplay != nil],options:[.sortedKeys]) {
            try? FileHandle.standardError.write(contentsOf:data+Data([10]))
        }
    }
    private func configureDisplay(width:Int,height:Int,epoch:String?,attempt:Int=0){
        displaySetupTask?.cancel()
        displaySetupID=UUID();let setupID=displaySetupID
        displaySetupTask=Task{@MainActor [weak self] in
            // The interactive session can connect before the display driver
            // accepts a mode switch. Retry only a few times during this setup.
            try? await Task.sleep(for:.seconds([1,3,8][attempt]))
            guard !Task.isCancelled,let self,self.connected,self.displayEpoch == epoch,self.displaySetupID == setupID else{return}
            self.invalidateDisplay("Preparing Windows display…")
            let revision=self.displayRevision
            self.bridge.command("display_configure",["width":width,"height":height],timeout:.seconds(5)){[weak self] result in
                guard let self,self.connected,self.displayEpoch == epoch,self.displaySetupID == setupID else{return}
                self.displaySetupTask=nil
                // Windows broadcasts its mode change while this request is in
                // flight. Read once more instead of publishing an older snapshot.
                guard self.displayRevision == revision else{self.readDisplay();return}
                if case .failure=result {
                    if attempt<2 {self.configureDisplay(width:width,height:height,epoch:epoch,attempt:attempt+1)}
                    else {self.status="Windows could not match the Mac display size.";self.readDisplay()}
                    return
                }
                if case .success(let reply)=result,let snapshot=reply["value"] as? [String:Any] {self.acceptDisplay(snapshot)}
                if ProcessInfo.processInfo.environment["PERPENDICULAR_STATE_TRACE"] == "1",case .success(let reply)=result,
                   let data=try? JSONSerialization.data(withJSONObject:["type":"display_configured","guest":reply["value"] ?? [:]],options:[.sortedKeys]) {
                    try? FileHandle.standardError.write(contentsOf:data+Data([10]))
                }
            }
        }
    }
    private func receive(_ packet:GuestPacket){
        let value=packet.header
        if ProcessInfo.processInfo.environment["PERPENDICULAR_STATE_TRACE"] == "1" {
            let kind=value["type"] as? String ?? ""
            if kind=="windows" || kind=="window_error" || kind=="launch_error" || (kind=="reply" && value["ok"] as? Bool==false){
                if let data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]){try? FileHandle.standardError.write(contentsOf:data+Data([10]))}
            }
        }
        switch value["type"] as? String{
        case "hello":
            machine.synchronizePrimaryDisplay()
            displayEpoch=value["epoch"] as? String
            invalidateDisplay("Checking Windows display…")
            let capabilities=value["capabilities"] as? [String:Any] ?? [:]
            displayReadable=capabilities["displayInfo"] as? Bool == true
            displayConfigurable=capabilities["displayConfigure"] as? Bool == true
            readDisplay()
            prepareDisplay()
            if ProcessInfo.processInfo.environment["PERPENDICULAR_STATE_TRACE"] == "1",
               let capabilities=value["capabilities"] as? [String:Any],capabilities["driverInfo"] as? Bool == true {
                bridge.command("driver_info",timeout:.seconds(30)){result in
                    guard case .success(let reply)=result else{return}
                    if let data=try? JSONSerialization.data(withJSONObject:["type":"driver_info","guest":reply["value"] ?? [:]],options:[.sortedKeys]) {
                        try? FileHandle.standardError.write(contentsOf:data+Data([10]))
                    }
                }
            }
            if ProcessInfo.processInfo.environment["PERPENDICULAR_STATE_TRACE"] == "1",
               let capabilities=value["capabilities"] as? [String:Any],capabilities["graphicsInfo"] as? Bool == true {
                bridge.command("graphics_info",timeout:.seconds(3)){result in
                    guard case .success(let reply)=result else{return}
                    if let data=try? JSONSerialization.data(withJSONObject:["type":"graphics_info","guest":reply["value"] ?? [:]],options:[.sortedKeys]) {
                        try? FileHandle.standardError.write(contentsOf:data+Data([10]))
                    }
                }
            }
        case "display_changed":
            guard value["epoch"] as? String == displayEpoch else{return}
            invalidateDisplay("Checking Windows display…")
            displayReadTask?.cancel()
            displayReadTask=Task{@MainActor [weak self] in
                try? await Task.sleep(for:.milliseconds(250))
                guard !Task.isCancelled,let self else{return}
                self.displayReadTask=nil;self.readDisplay()
            }
        case "windows":
            guard let items=value["windows"] as? [[String:Any]],items.count<=16 else{return}
            let current=Set(items.compactMap{$0["id"] as? String})
            for id in Array(windows.keys) where !current.contains(id){windows.removeValue(forKey:id)?.retire();earlyFrames.removeValue(forKey:id)}
            for item in items{
                guard let id=item["id"] as? String,let title=item["title"] as? String else{continue}
                if windows[id]==nil{
                    let role=WindowRole(rawValue:item["role"] as? String ?? "dialog") ?? .dialog
                    let controller=ApplicationWindow(id:id,title:title,role:role,bridge:bridge)
                    controller.onError={ [weak self] message in self?.status=message }
                    controller.onClose={ [weak self] in self?.windows.removeValue(forKey:id) }
                    controller.onGeometry={ [weak self] in self?.layoutChildren() }
                    controller.onPointerExit={ [weak self] in self?.pointerExited(id) }
                    windows[id]=controller
                }
                windows[id]?.update(item)
                if let frame=earlyFrames.removeValue(forKey:id){windows[id]?.present(frame)}
            }
            layoutChildren()
            if !items.isEmpty{status="Windows connected"}
        case "frame":
            guard let id=value["window"] as? String else{return}
            if let window=windows[id]{window.present(packet)}else if earlyFrames.count<16{earlyFrames[id]=packet}
        case "activate":
            if let id=value["window"] as? String{windows[id]?.window.makeKeyAndOrderFront(nil)}
        case "window_error","launch_error":status=value["message"] as? String ?? "This application is unavailable. Use Show Windows."
        default:break
        }
    }
}

@MainActor
struct Launcher:View{
    @ObservedObject var model:ApplicationModel
    @State private var search=""
    var body:some View{
        VStack(spacing:0){
            HStack{
                TextField("Search Windows applications",text:$search).textFieldStyle(.roundedBorder)
                Button(action:model.refresh){Image(systemName:"arrow.clockwise")}.disabled(!model.connected)
                Button("Show Windows",action:model.showWindows)
            }.padding(14)
            List(model.apps.filter{search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)}){app in
                Button{model.launch(app)}label:{HStack(spacing:12){Image(systemName:"app").font(.system(size:24)).frame(width:32,height:32);Text(app.name);Spacer()}.padding(.vertical,5).contentShape(Rectangle())}
                    .buttonStyle(.plain).disabled(!model.connected)
            }
            Divider()
            VStack(alignment:.leading,spacing:3){Text(model.status);Text(model.displayStatus)}
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading).padding(10)
        }.frame(minWidth:420,minHeight:360)
    }
}

@main
@MainActor
struct PerpendicularApplication{
    static func main(){
        let app=NSApplication.shared
        let delegate=ApplicationModel();app.delegate=delegate;app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate){app.run()}
    }
}
