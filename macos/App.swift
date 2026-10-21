import AppKit
import SwiftUI
import CryptoKit
import ImageIO

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
    @Published private(set) var catalogueLoading=false
    @Published var launcherNotice:String?
    @Published private(set) var openingApps:Set<String>=[]
    @Published private(set) var activeApps:Set<String>=[]
    @Published private(set) var applicationIcons:[String:NSImage]=[:]
    @Published private(set) var loadingIconID:String?
    private var launcherEpoch=UUID()
    private var catalogueRequest=UUID()
    private var visibleIcons:Set<String>=[]
    private var iconVisibility:[String:Int]=[:]
    private var failedIcons:Set<String>=[]
    private var iconOrder:[String]=[]
    private var openingTasks:[String:Task<Void,Never>]=[:]
    private var openingNoticeApp:String?
    private var windowApps:[String:String]=[:]
    private var focusWarnedWindows:Set<String>=[]
    private var launcher:NSWindow!
    private var machine:VirtualMachineController!
    private var bridge:GuestBridge!
    private var localControl:MacLocalControl?
    private var guestCapabilities:[String:Bool]=[:]
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
    private var sharedGeometryCapable=false
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
                self.launcherEpoch=UUID();self.catalogueLoading=false;self.loadingIconID=nil;self.failedIcons=[]
                self.focusWarnedWindows=[]
                for task in self.openingTasks.values {task.cancel()}
                self.openingTasks=[:];self.openingApps=[]
                if !value {
                    self.activeApps=[]
                    self.guestCapabilities=[:]
                    self.displayEpoch=nil;self.displayReadable=false;self.displayConfigurable=false;self.sharedGeometryCapable=false
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
            do {
                localControl=try MacLocalControl(directory:directory.appendingPathComponent("Control")){[weak self] data,reply in
                    guard let self else{return}
                    self.localControlRequest(data,reply:reply)
                }
            }catch{
                try? FileHandle.standardError.write(contentsOf:Data(("Local control unavailable: "+error.localizedDescription+"\n").utf8))
            }
            if !machine.isRunning{try machine.start()}
        }catch{status=error.localizedDescription;launcherNotice="Windows non può essere avviato. "+error.localizedDescription}
        launcher=NSWindow(contentRect:NSRect(x:200,y:160,width:800,height:660),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        launcher.title="Perpendicular";launcher.isReleasedWhenClosed=false
        launcher.minSize=NSSize(width:640,height:480)
        launcher.setFrameAutosaveName("PerpendicularLauncher")
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
    @objc func showApplications(){launcher.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);NotificationCenter.default.post(name:.launcherFocusSearch,object:nil)}
    @objc func closeCurrentWindow(){(NSApp.keyWindow ?? NSApp.mainWindow)?.performClose(nil)}
    func applicationWillTerminate(_ notification:Notification){localControl?.stop();bridge?.command("release");machine?.closeDesktop()}
    var desktopAvailable:Bool {machine != nil}
    @objc func showWindows(){do{guard let machine else{return};try machine.showDesktop()}catch{status=error.localizedDescription;launcherNotice="Non riesco ad aprire il desktop Windows. "+error.localizedDescription}}
    @objc func shutdownWindows(){do{try machine.shutdown()}catch{status=error.localizedDescription}}

    private func localResponse(_ value:[String:Any],reply:MacLocalControl.Reply){
        let data=(try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])) ?? Data("{\"ok\":false,\"error\":\"Response could not be encoded.\"}".utf8)
        reply(data)
    }
    private func localBridgeResponse(_ result:Result<[String:Any],Error>,reply:MacLocalControl.Reply){
        switch result {
        case .success(let value):localResponse(["ok":true,"result":value["value"] ?? [:]],reply:reply)
        case .failure(let error):localResponse(["ok":false,"error":error.localizedDescription],reply:reply)
        }
    }
    private func localControlRequest(_ data:Data,reply:@escaping MacLocalControl.Reply){
        guard let request=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let command=request["command"] as? String else {
            localResponse(["ok":false,"error":"Expected a JSON command."],reply:reply);return
        }
        let allowed:Set<String>=["status","execute","display_info","driver_info","graphics_info","geometry_snapshot"]
        guard allowed.contains(command) else {
            localResponse(["ok":false,"error":"This local command is not supported."],reply:reply);return
        }
        let fields:Set<String>=command == "execute" ? ["command","executable","args","timeoutSeconds"]:["command"]
        guard Set(request.keys).isSubset(of:fields) else {
            localResponse(["ok":false,"error":"Unexpected command fields."],reply:reply);return
        }
        if command == "status" {
            localResponse(["ok":true,"result":["connected":connected,"machineRunning":machine?.isRunning ?? false,
                "status":status,"displayStatus":displayStatus,"primaryMatchesHost":sharedDisplay != nil,
                "windowCount":windows.count,"capabilities":guestCapabilities,
                "frameChannel":bridge?.separateFrames ?? false,
                "lastCommandRTTMilliseconds":bridge?.lastRoundTripMilliseconds ?? 0,
                "frameReceiveMilliseconds":bridge?.frameReceiveMilliseconds ?? 0]],reply:reply);return
        }
        guard connected,let bridge else {
            localResponse(["ok":false,"error":"Windows is not connected."],reply:reply);return
        }
        if command == "execute" {
            guard guestCapabilities["execute"] == true else {
                localResponse(["ok":false,"error":"The connected guest does not support execute."],reply:reply);return
            }
            let seconds=request["timeoutSeconds"] as? Int ?? 15
            guard let executable=request["executable"] as? String,!executable.isEmpty,!executable.contains("\0"),
                  let args=request["args"] as? [String],args.allSatisfy({!$0.contains("\0")}),
                  (1...60).contains(seconds) else {
                localResponse(["ok":false,"error":"Expected executable, string args and timeoutSeconds from 1 to 60."],reply:reply);return
            }
            let values:[String:Any]=["executable":executable,"args":args,"timeoutSeconds":seconds]
            guard let encoded=try? JSONSerialization.data(withJSONObject:values),encoded.count<=15_000 else {
                localResponse(["ok":false,"error":"Execute arguments exceed the guest protocol limit."],reply:reply);return
            }
            bridge.command("execute",values,timeout:.seconds(seconds+5)){[weak self] result in
                self?.localBridgeResponse(result,reply:reply)
            }
            return
        }
        if command == "geometry_snapshot" {
            localGeometrySnapshot(Array(windows.keys.sorted())[...],rows:[],epoch:displayEpoch,reply:reply);return
        }
        let capabilities=["display_info":"displayInfo","driver_info":"driverInfo","graphics_info":"graphicsInfo"]
        guard let capability=capabilities[command],guestCapabilities[capability] == true else {
            localResponse(["ok":false,"error":"The connected guest does not support this query."],reply:reply);return
        }
        bridge.command(command,timeout:.seconds(command == "driver_info" ? 35:6)){[weak self] result in
            self?.localBridgeResponse(result,reply:reply)
        }
    }
    private func localGeometrySnapshot(_ ids:ArraySlice<String>,rows:[[String:Any]],epoch:String?,reply:@escaping MacLocalControl.Reply){
        guard connected,displayEpoch == epoch else {
            localResponse(["ok":false,"error":"Windows reconnected while reading geometry."],reply:reply);return
        }
        guard let id=ids.first else {
            localResponse(["ok":true,"result":["windows":rows,"primaryMatchesHost":sharedDisplay != nil]],reply:reply);return
        }
        guard let controller=windows[id] else {
            localGeometrySnapshot(ids.dropFirst(),rows:rows,epoch:epoch,reply:reply);return
        }
        let frame=controller.window.frame
        let row:[String:Any]=["id":id,"title":controller.window.title,"role":controller.role.rawValue,
            "macFramePoints":["x":frame.minX,"y":frame.minY,"width":frame.width,"height":frame.height]]
        bridge.command("geometry",["window":id],timeout:.seconds(2)){[weak self] result in
            guard let self else{return}
            var item=row
            switch result {
            case .success(let value):item["guest"]=value["value"] ?? [:]
            case .failure(let error):item["error"]=error.localizedDescription
            }
            self.localGeometrySnapshot(ids.dropFirst(),rows:rows+[item],epoch:epoch,reply:reply)
        }
    }
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
        guard connected,!catalogueLoading else{return}
        catalogueLoading=true;launcherNotice=nil
        catalogueRequest=UUID();let request=catalogueRequest,epoch=launcherEpoch
        readDisplay()
        bridge.command("catalogue"){[weak self] result in
            guard let self,self.launcherEpoch == epoch,self.catalogueRequest == request else{return}
            self.catalogueLoading=false
            switch result{
            case .success(let reply):
                guard let values=reply["value"] as? [[String:Any]] else {
                    self.launcherNotice="L’elenco delle app non è disponibile. Riprova con Aggiorna.";return
                }
                var identities:Set<String>=[]
                self.apps=values.prefix(1024).compactMap{value in
                    guard let id=value["id"] as? String,id.utf8.count==64,let name=value["name"] as? String,name.utf8.count<=512 else{return nil}
                    guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,identities.insert(id).inserted else{return nil}
                    return WindowsApplication(id:id,name:name)
                }.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}
                self.failedIcons=[]
                self.visibleIcons.formIntersection(identities)
                self.iconVisibility=self.iconVisibility.filter{identities.contains($0.key)}
                self.applicationIcons=self.applicationIcons.filter{identities.contains($0.key)}
                self.iconOrder.removeAll{!identities.contains($0)}
                self.status="\(self.apps.count) applications"
                self.pumpApplicationIcons()
            case .failure(let error):self.status=error.localizedDescription;self.launcherNotice="Non riesco ad aggiornare le app. "+error.localizedDescription
            }
        }
    }
    func launch(_ app:WindowsApplication){
        guard connected,!openingApps.contains(app.id) else{return}
        launcherNotice=nil;beginOpening(app)
        status="Opening \(app.name)…"
        let epoch=launcherEpoch
        bridge.command("launch",["app":app.id]){[weak self] result in
            guard let self,self.launcherEpoch == epoch else{return}
            switch result {
            case .failure(let error):
                self.finishOpening(app.id);self.status=error.localizedDescription
                self.launcherNotice="Non riesco ad aprire \(app.name). "+error.localizedDescription;self.openingNoticeApp=app.id
            case .success(let reply):
                if let value=reply["value"] as? [String:Any],value["existing"] as? Bool == true,value["ready"] as? Bool != false {self.finishOpening(app.id,appeared:true)}
            }
        }
    }
    private func beginOpening(_ app:WindowsApplication){
        openingApps.insert(app.id);openingTasks.removeValue(forKey:app.id)?.cancel()
        let epoch=launcherEpoch
        openingTasks[app.id]=Task{@MainActor [weak self] in
            try? await Task.sleep(for:.seconds(32))
            guard !Task.isCancelled,let self,self.launcherEpoch == epoch,self.openingApps.contains(app.id) else{return}
            self.finishOpening(app.id)
            self.launcherNotice="La finestra di \(app.name) non è ancora disponibile. Apri Windows per continuare.";self.openingNoticeApp=app.id
        }
    }
    private func finishOpening(_ id:String,appeared:Bool=false){
        guard openingApps.contains(id) || openingTasks[id] != nil || (appeared && openingNoticeApp == id) else{return}
        openingTasks.removeValue(forKey:id)?.cancel()
        if openingApps.contains(id) {openingApps.remove(id)}
        if appeared,openingNoticeApp == id {launcherNotice=nil;openingNoticeApp=nil}
    }
    private func inputFocusFailed(){
        let message="Windows non ha attivato l’app. Il clic o il testo non è stato inviato."
        status=message;launcherNotice=message+" Apri Windows, seleziona l’app e torna a questa finestra."
        guard let controller=windows.values.first(where:{$0.window === NSApp.keyWindow && !$0.role.transient}),
              controller.window.attachedSheet == nil,focusWarnedWindows.insert(controller.id).inserted else{return}
        let alert=NSAlert()
        alert.messageText="L’app non è attiva in Windows"
        alert.informativeText="Questo input non è stato inviato. Apri il desktop Windows e seleziona l’app, poi torna qui."
        alert.addButton(withTitle:"Apri Windows");alert.addButton(withTitle:"Chiudi")
        alert.beginSheetModal(for:controller.window){[weak self] response in
            if response == .alertFirstButtonReturn {self?.showWindows()}
        }
    }
    func applicationBecameVisible(_ app:WindowsApplication){iconVisibility[app.id,default:0]+=1;visibleIcons.insert(app.id);pumpApplicationIcons()}
    func applicationBecameHidden(_ app:WindowsApplication){
        let count=max(0,(iconVisibility[app.id] ?? 0)-1)
        if count==0 {iconVisibility.removeValue(forKey:app.id);visibleIcons.remove(app.id)}else{iconVisibility[app.id]=count}
    }
    private func pumpApplicationIcons(){
        guard connected,guestCapabilities["appIcon"] == true,loadingIconID == nil,
              let app=apps.first(where:{visibleIcons.contains($0.id) && applicationIcons[$0.id] == nil && !failedIcons.contains($0.id)}) else{return}
        let epoch=launcherEpoch;loadingIconID=app.id
        bridge.command("app_icon",["app":app.id],timeout:.seconds(8)){[weak self] result in
            guard let self,self.launcherEpoch == epoch,self.loadingIconID == app.id else{return}
            self.loadingIconID=nil
            if case .success(let reply)=result,let value=reply["value"] as? [String:Any],
               value["app"] as? String == app.id,let width=value["width"] as? Int,let height=value["height"] as? Int,
               (1...128).contains(width),(1...128).contains(height),
               let encoded=value["pngBase64"] as? String,encoded.utf8.count<=174_764,
               let data=Data(base64Encoded:encoded),data.count<=131_072,
               data.starts(with:[137,80,78,71,13,10,26,10]),
               let expected=value["sha256"] as? String,
               SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined() == expected.lowercased(),
               let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
               CGImageSourceGetCount(source)==1,
               let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any],
               properties[kCGImagePropertyPixelWidth as String] as? Int == width,
               properties[kCGImagePropertyPixelHeight as String] as? Int == height,
               let image=CGImageSourceCreateImageAtIndex(source,0,nil) {
                if self.applicationIcons.count>=64,let evicted=self.iconOrder.first(where:{!self.visibleIcons.contains($0)}) ?? self.iconOrder.first {
                    self.applicationIcons.removeValue(forKey:evicted);self.iconOrder.removeAll{$0 == evicted}
                }
                self.applicationIcons[app.id]=NSImage(cgImage:image,size:NSSize(width:width,height:height))
                self.iconOrder.append(app.id)
            }else{self.failedIcons.insert(app.id)}
            self.pumpApplicationIcons()
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
            guard !Task.isCancelled,let self,self.machine?.desktopIsKey != true else{return}
            let point=NSEvent.mouseLocation
            guard !self.windows.values.contains(where:{$0.window.isVisible && $0.window.frame.contains(point)}) else{return}
            self.bridge.command("input",["window":id,"event":"leave"])
        }
    }
    private func invalidateDisplay(_ message:String){
        displayRevision+=1;sharedDisplay=nil;displayStatus=message
        for window in windows.values {window.setSharedDisplay(nil)}
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
                self.invalidateDisplay("Windows display could not be checked.");return
            }
            self.acceptDisplay(snapshot)
        }
    }
    private func acceptDisplay(_ snapshot:[String:Any]){
        let host=HostDisplay.current()
        let confirmed=host.first(where:\.primary).flatMap{SharedDisplay.primary(host:$0,snapshot:snapshot)}
        sharedDisplay=sharedGeometryCapable ? confirmed:nil
        for window in windows.values {window.setSharedDisplay(sharedDisplay)}
        if confirmed != nil {displayStatus="Primary Windows display matches this Mac."}
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
            guestCapabilities=Dictionary(uniqueKeysWithValues:["execute","displayInfo","driverInfo","graphicsInfo","sharedGeometry","appIcon"].map{($0,capabilities[$0] as? Bool == true)})
            pumpApplicationIcons()
            displayReadable=capabilities["displayInfo"] as? Bool == true
            displayConfigurable=capabilities["displayConfigure"] as? Bool == true
            sharedGeometryCapable=capabilities["sharedGeometry"] as? Bool == true
            readDisplay()
            prepareDisplay()
            if ProcessInfo.processInfo.environment["PERPENDICULAR_STATE_TRACE"] == "1" {
                let epoch=displayEpoch
                if capabilities["driverInfo"] as? Bool == true {
                    bridge.command("driver_info",timeout:.seconds(30)){[weak self] result in
                        guard let self,self.connected,self.displayEpoch == epoch,
                              case .success(let reply)=result else{return}
                        if let data=try? JSONSerialization.data(withJSONObject:["type":"driver_info","guest":reply["value"] ?? [:]],options:[.sortedKeys]) {
                            try? FileHandle.standardError.write(contentsOf:data+Data([10]))
                        }
                        // Older guests serialize both diagnostic operations.
                        guard capabilities["graphicsInfo"] as? Bool == true else{return}
                        self.bridge.command("graphics_info",timeout:.seconds(3)){[weak self] result in
                            guard let self,self.connected,self.displayEpoch == epoch,
                                  case .success(let reply)=result else{return}
                            if let data=try? JSONSerialization.data(withJSONObject:["type":"graphics_info","guest":reply["value"] ?? [:]],options:[.sortedKeys]) {
                                try? FileHandle.standardError.write(contentsOf:data+Data([10]))
                            }
                        }
                    }
                }else if capabilities["graphicsInfo"] as? Bool == true {
                    bridge.command("graphics_info",timeout:.seconds(3)){[weak self] result in
                        guard let self,self.connected,self.displayEpoch == epoch,
                              case .success(let reply)=result else{return}
                        if let data=try? JSONSerialization.data(withJSONObject:["type":"graphics_info","guest":reply["value"] ?? [:]],options:[.sortedKeys]) {
                            try? FileHandle.standardError.write(contentsOf:data+Data([10]))
                        }
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
            focusWarnedWindows.formIntersection(current)
            windowApps=items.reduce(into:[:]){result,item in
                if let id=item["id"] as? String,let app=item["app"] as? String {result[id]=app}
            }
            let nextActiveApps:Set<String>=Set(items.compactMap{item in
                guard item["role"] as? String != "popup",item["role"] as? String != "tooltip" else{return nil}
                return item["app"] as? String
            })
            if nextActiveApps != activeApps {activeApps=nextActiveApps}
            for id in Array(windows.keys) where !current.contains(id){windows.removeValue(forKey:id)?.retire();earlyFrames.removeValue(forKey:id)}
            for item in items{
                guard let id=item["id"] as? String,let title=item["title"] as? String else{continue}
                if windows[id]==nil{
                    let role=WindowRole(rawValue:item["role"] as? String ?? "dialog") ?? .dialog
                    let controller=ApplicationWindow(id:id,title:title,role:role,bridge:bridge)
                    controller.activateOnFirstShow=machine?.desktopIsKey != true
                    controller.onError={ [weak self] message in self?.status=message;self?.launcherNotice=message }
                    controller.onClose={ [weak self] in self?.windows.removeValue(forKey:id) }
                    controller.onGeometry={ [weak self] in self?.layoutChildren() }
                    controller.onPointerExit={ [weak self] in self?.pointerExited(id) }
                    controller.setSharedDisplay(sharedDisplay)
                    windows[id]=controller
                }
                windows[id]?.update(item)
                if let frame=earlyFrames.removeValue(forKey:id){windows[id]?.present(frame);if let app=windowApps[id]{finishOpening(app,appeared:true)}}
            }
            layoutChildren()
            if !items.isEmpty,status != "Windows connected" {status="Windows connected"}
        case "frame":
            guard let id=value["window"] as? String else{return}
            if let window=windows[id]{window.present(packet);if let app=windowApps[id]{finishOpening(app,appeared:true)}}else if earlyFrames.count<16{earlyFrames[id]=packet}
        case "activate":
            if machine?.desktopIsKey != true,let id=value["window"] as? String {windows[id]?.window.makeKeyAndOrderFront(nil)}
        case "launch_state":
            if value["state"] as? String == "waiting",let id=value["app"] as? String,
               let app=apps.first(where:{$0.id == id}) {beginOpening(app)}
        case "reply":
            if value["ok"] as? Bool == false,value["operation"] as? String == "input",
               value["message"] as? String == "Windows did not grant this window keyboard focus" {inputFocusFailed()}
        case "window_error","launch_error":
            status=value["message"] as? String ?? "This application is unavailable. Use Show Windows."
            launcherNotice=value["message"] as? String ?? "Questa app non è disponibile. Puoi continuare dal desktop Windows."
            if let app=value["app"] as? String {finishOpening(app);if value["type"] as? String == "launch_error" {openingNoticeApp=app}}
        default:break
        }
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
