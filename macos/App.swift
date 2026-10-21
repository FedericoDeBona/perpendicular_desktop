import AppKit
import SwiftUI

struct WindowsApplication:Identifiable {
    let id:String
    let name:String
}

@MainActor
final class ApplicationModel:NSObject,NSApplicationDelegate,ObservableObject {
    @Published var apps:[WindowsApplication]=[]
    @Published var status="Waiting for Windows…"
    @Published var connected=false
    private var launcher:NSWindow!
    private var machine:VirtualMachineController!
    private var bridge:GuestBridge!
    private var windows:[String:ApplicationWindow]=[:]
    private var earlyFrames:[String:GuestPacket]=[:]
    private var layoutInProgress=false
    private var pointerExitTask:Task<Void,Never>?

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
                if value{
                    self.refresh()
                    if ProcessInfo.processInfo.environment["PERPENDICULAR_AUDIT"] == "1" {self.bridge.command("diagnostics"){result in
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
        let shutdown=NSMenuItem(title:"Shut Down Windows",action:#selector(shutdownWindows),keyEquivalent:"");shutdown.target=self;menu.addItem(shutdown)
        menu.addItem(.separator());menu.addItem(withTitle:"Quit",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        NSApp.mainMenu=main
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
    func refresh(){
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
            if let capabilities=value["capabilities"] as? [String:Any],capabilities["displayInfo"] as? Bool == true {
                bridge.command("display_info",timeout:.seconds(3)){result in
                    guard ProcessInfo.processInfo.environment["PERPENDICULAR_STATE_TRACE"] == "1",
                          case .success(let reply)=result,let state=reply["value"] as? [String:Any] else{return}
                    let value:[String:Any]=["type":"display_info","guest":state,"host":HostDisplay.current().map(\.description)]
                    if let data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]){try? FileHandle.standardError.write(contentsOf:data+Data([10]))}
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
            Divider();Text(model.status).font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading).padding(10)
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
