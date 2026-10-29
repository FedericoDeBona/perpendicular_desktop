import AppKit
import SwiftUI
import CryptoKit
import ImageIO

private struct DesktopSingletonState:Sendable {
    let focused:Bool
    let visible:Bool
    let primary:Bool
    let maxMoves:Int
    let rect:String
    let checkedAt:Double
    let zoomed:Bool
    let moveKey:String?
    let adjustment:String?
}
@MainActor
final class ApplicationModel:NSObject,NSApplicationDelegate,NSMenuItemValidation,ObservableObject {
    private let desktopOnly=Bundle.main.object(forInfoDictionaryKey:"PerpendicularDesktopOnly") as? Bool == true
    @Published var apps:[WindowsApplication]=[]
    @Published var launcherPreferences=LauncherPreferences()
    @Published private(set) var launcherAppearance=LauncherAppearance(rawValue:UserDefaults.standard.string(forKey:"LauncherAppearance") ?? "system") ?? .system
    @Published private(set) var launcherDisplays:[[String:Any]]=[]
    private var launcherLibrary:LauncherLibrary?
    private var iconDiskChecked:Set<String>=[]
    private var iconCacheHits=0
    private var iconFetches=0
    @Published var status="Waiting for Windows…"
    @Published var displayStatus="Waiting for Windows display…"
    @Published var connected=false
    @Published private(set) var machineState:MachineRuntimeState = .unreachable(nil)
    @Published private(set) var machineOperation:String?
    private var machineStateTask:Task<Void,Never>?
    private var machineStateRevision=UUID()
    @Published private(set) var catalogueLoading=false
    @Published var launcherNotice:String?
    private var mixedDisplayNotice:String?
    private var windowNotice:(id:String,message:String,frame:Bool)?
    @Published private(set) var openingApps:Set<String>=[]
    private var seamlessTransferApps:Set<String>=[]
    @Published private(set) var activeApps:Set<String>=[]
    @Published private(set) var applicationIcons:[String:NSImage]=[:]
    @Published private(set) var loadingIconID:String?
    @Published private(set) var applicationStates:[String:GuestApplicationState]=[:]
    @Published private(set) var applicationStatusAvailable=false
    @Published private(set) var vmSettings:MachineSettings?
    @Published private(set) var currentVMSettings:MachineSettings?
    @Published private(set) var settingsPending=false
    @Published var settingsNotice:String?
    @Published private(set) var settingsFailed=false
    @Published private(set) var vmMemoryState:[String:Any]=[:]
    private var applicationStatusTask:Task<Void,Never>?
    private var applicationStatusBusy=false
    private var receivedWindows:Set<String>=[]
    private var failedWindows:Set<String>=[]
    private var launcherEpoch=UUID()
    private var catalogueRequest=UUID()
    private var lastCatalogueRefresh:TimeInterval=0
    private var catalogueNotice:String?
    private var catalogueRefreshes=0
    private var visibleIcons:Set<String>=[]
    private var iconVisibility:[String:Int]=[:]
    private var failedIcons:Set<String>=[]
    private var iconOrder:[String]=[]
    private var openingTasks:[String:Task<Void,Never>]=[:]
    private var openingRequests:[String:UUID]=[:]
    private var openingNoticeApp:String?
    private var openingNoticeTimedOut=false
    private var cancelledOpeningApps:Set<String>=[]
    private var windowApps:[String:String]=[:]
    private var focusWarnedWindows:Set<String>=[]
    private var launcher:LauncherWindow!
    private var machine:VirtualMachineController!
    private var bridge:GuestBridge!
    private var memoryController:RuntimeMemoryController?
    private let folderIntegration=SharedFolderIntegration()
    @Published private(set) var folderIntegrationStatus="Le cartelle saranno preparate quando Windows sarà collegato."
    @Published private(set) var folderIntegrationBusy=false
    @Published private(set) var folderIntegrationFailed=false
    private var localControl:MacLocalControl?
    private var guestCapabilities:[String:Bool]=[:]
    private var windows:[String:ApplicationWindow]=[:]
    private var earlyFrames:[String:GuestPacket]=[:]
    private var layoutInProgress=false
    private var pointerExitTask:Task<Void,Never>?
    private var desktopFocusTask:Task<Void,Never>?
    private var desktopFocusRequest=UUID()
    private var desktopRecoveryTask:Task<Void,Never>?
    private var desktopRecoveryRequest=UUID()
    private var displaySetupTask:Task<Void,Never>?
    private var displaySetupID=UUID()
    private var displayEpoch:String?
    private var displayRevision=0
    private var displayUpdating=false
    private var displayReadable=false
    private var displayConfigurable=false
    private var sharedGeometryCapable=false
    private var displayReadTask:Task<Void,Never>?
    private var sharedDisplay:SharedDisplay?
    private var sharedDisplays:[SharedDisplay]=[]
    private var mixedDisplayConfiguring=false
    private var lastHostDisplays:[HostDisplay]=[]
    private var mixedDisplayChecks=0
    private var mixedDisplayApplies=0
    private var displayInvalidations=0
    private var recoveryItem:NSMenuItem!
    private var displayItems:[NSMenuItem]=[]
    private var desktopSize=NSSize.zero
    private var desktopConfirmed=NSSize.zero
    private var desktopResizeTask:Task<Void,Never>?
    private var desktopReadRequest:UUID?
    private var desktopReadAgain=false
    private var desktopResizeRequest:UUID?
    private var desktopAttempted=NSSize.zero
    private var restarting=false
    private var awaitingInitialGuest=false
    private var guestContactEstablished=false

    func applicationDidFinishLaunching(_ notification:Notification){
        do{
            let directory:URL
            if let path=ProcessInfo.processInfo.environment["PERPENDICULAR_MACHINE_DIRECTORY"] ?? Bundle.main.object(forInfoDictionaryKey:"PerpendicularMachineDirectory") as? String {
                guard path.hasPrefix("/") else{throw CocoaError(.fileReadInvalidFileName)}
                directory=URL(fileURLWithPath:path,isDirectory:true)
            }else{directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Perpendicular Memory IoT")}
            launcherLibrary=try LauncherLibrary(directory:directory)
            launcherPreferences=launcherLibrary?.loadPreferences() ?? .init()
            apps=launcherLibrary?.loadCatalogue() ?? []
            let runtime:URL
            if let override=ProcessInfo.processInfo.environment["PERPENDICULAR_RUNTIME"] {runtime=URL(fileURLWithPath:override)}
            else {runtime=try RuntimeStore.prepare(contents:Bundle.main.bundleURL.appendingPathComponent("Contents"),directory:directory)}
            machine=try VirtualMachineController(directory:directory,runtime:runtime)
            try NativeWindowFrames.shared.prepare(directory:directory,machineID:machine.configuration.id)
            bridge=try GuestBridge(port:machine.configuration.guestPort,token:machine.configuration.token,individualWindows:true)
            configureMachineControllers();loadVMSettings()
            bridge.onConnection={ [weak self] value in
                guard let self else{return};self.connected=value;self.status=value ? "Windows connected":"Reconnecting to Windows…"
                if value {self.awaitingInitialGuest=false;self.guestContactEstablished=true}
                self.launcherEpoch=UUID();self.catalogueLoading=false;self.loadingIconID=nil;self.failedIcons=[]
                self.focusWarnedWindows=[]
                self.applicationStatusTask?.cancel();self.applicationStatusTask=nil;self.applicationStatusBusy=false
                self.applicationStates=[:];self.applicationStatusAvailable=false;self.receivedWindows=[];self.failedWindows=[]
                for task in self.openingTasks.values {task.cancel()}
                self.openingTasks=[:];self.openingRequests=[:];self.openingApps=[];self.cancelledOpeningApps=[]
                if !value {
                    self.folderIntegration.cancel()
                    self.folderIntegrationStatus="Le cartelle saranno preparate quando Windows sarà collegato."
                    self.folderIntegrationFailed=false;self.folderIntegrationBusy=false
                    self.mixedDisplayConfiguring=false
                    self.desktopResizeTask?.cancel();self.desktopResizeTask=nil
                    self.desktopReadRequest=nil;self.desktopReadAgain=false
                    self.machine?.finishDesktopResolution()
                    self.desktopResizeRequest=nil;self.desktopAttempted = .zero;self.desktopConfirmed = .zero
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
        }catch{status=error.localizedDescription;launcherNotice="Windows non può essere avviato. "+error.localizedDescription}
        launcher=LauncherWindow(contentRect:NSRect(x:200,y:160,width:760,height:760),styleMask:[.titled,.closable,.resizable,.miniaturizable,.fullSizeContentView],backing:.buffered,defer:false)
        launcher.title="Perpendicular";launcher.isReleasedWhenClosed=false
        // The custom title strip has one drag owner. Native titlebar tracking
        // must not start a second movement path through the full-size content.
        launcher.isMovable=false;launcher.acceptsMouseMovedEvents=true
        launcher.titleVisibility = .hidden
        launcher.titlebarAppearsTransparent=true;launcher.toolbarStyle = .unified
        launcher.isOpaque=false;launcher.backgroundColor = .clear
        launcher.appearance=launcherAppearance.native
        launcher.minSize=NSSize(width:540,height:480)
        launcher.setFrameAutosaveName("PerpendicularLauncher")
        let launcherContent=LauncherHostingView(rootView:Launcher(model:self))
        // AppKit owns the window frame. Content and screen safe-area changes
        // must not resize/reposition it during a native cross-display drag.
        launcherContent.sizingOptions=[]
        launcher.contentView=launcherContent
        launcher.center();launcher.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        let main=NSMenu();let appItem=NSMenuItem();main.addItem(appItem)
        let menu=NSMenu();appItem.submenu=menu
        let applications=NSMenuItem(title:"Seamless Apps",action:#selector(showApplications),keyEquivalent:"l");applications.target=self;menu.addItem(applications)
        let settings=NSMenuItem(title:"Impostazioni…",action:#selector(showSettings),keyEquivalent:",");settings.target=self;menu.addItem(settings)
        let show=NSMenuItem(title:"Desktop Mode",action:#selector(showWindows),keyEquivalent:"");show.target=self;menu.addItem(show)
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
        let start=NSMenuItem(title:"Avvia Windows",action:#selector(startWindows),keyEquivalent:"");start.target=self;menu.addItem(start)
        let shutdown=NSMenuItem(title:"Spegni Windows",action:#selector(shutdownWindows),keyEquivalent:"");shutdown.target=self;menu.addItem(shutdown)
        let force=NSMenuItem(title:"Arresta Windows forzatamente…",action:#selector(forceStopWindows),keyEquivalent:"");force.target=self;menu.addItem(force)
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
        windowMenu.addItem(withTitle:"Schermo intero",action:#selector(NSWindow.toggleFullScreen(_:)),keyEquivalent:"")
        windowMenu.addItem(withTitle:"Minimize",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m")
        let close=NSMenuItem(title:"Close",action:#selector(closeCurrentWindow),keyEquivalent:"w");close.target=self;windowMenu.addItem(close)
        startMachineObservation()
        startWindows()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool{showApplications();return false}
    @objc func showApplications(){launcher.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);NotificationCenter.default.post(name:.launcherFocusSearch,object:nil)}
    @objc func showSettings(){launcher.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);NotificationCenter.default.post(name:.launcherShowSettings,object:nil)}
    @objc func closeCurrentWindow(){
        if NSApp.sendAction(NSSelectorFromString("closeDocument:"),to:nil,from:self){return}
        (NSApp.keyWindow ?? NSApp.mainWindow)?.performClose(nil)
    }
    func applicationWillTerminate(_ notification:Notification){machineStateTask?.cancel();memoryController?.stop();localControl?.stop();bridge?.command("release");machine?.closeDesktop()}
    var desktopAvailable:Bool {machine != nil}
    var canStartWindows:Bool {machine != nil && machineState == .stopped && machineOperation == nil && !restarting}
    var canStopWindows:Bool {machine != nil && machineState.pid != nil && machineOperation == nil && !restarting}
    func setLauncherAppearance(_ value:LauncherAppearance){
        launcherAppearance=value
        UserDefaults.standard.set(value.rawValue,forKey:"LauncherAppearance")
        launcher?.appearance=value.native
    }
    var launcherWindowsStatus:LauncherWindowsStatus {
        let running:Bool?
        switch machineState {case .stopped:running=false;case .running:running=true;case .unreachable:running=nil}
        let warning:(title:String,detail:String)?
        if let launcherNotice {
            warning=(launcherNotice == catalogueNotice ? "Elenco app non disponibile":"Avviso",launcherNotice)
        }else if folderIntegrationFailed {warning=("Cartelle non collegate",folderIntegrationStatus)}
        else {warning=nil}
        let imageError=(!failedWindows.isEmpty || windowNotice?.frame == true) ? (windowNotice?.message ?? "Una finestra non ha un’immagine disponibile."):nil
        let ready=(machine?.mixedDisplaysEnabled != true || !sharedDisplays.isEmpty) && !(catalogueLoading && apps.isEmpty)
        return .resolve(running:running,operation:machineOperation,restarting:restarting,connected:connected,
                        awaitingGuest:awaitingInitialGuest,contactEstablished:guestContactEstablished,
                        appsReady:ready,imageError:imageError,warning:warning)
    }
    var launcherStatusMessage:String? {
        let state=launcherWindowsStatus
        if let launcherNotice {return launcherNotice}
        if folderIntegrationFailed {return folderIntegrationStatus}
        if state.needsAttention {return state.detail}
        return nil
    }
    var machineStateLabel:String {
        if let machineOperation {return machineOperation}
        switch machineState {
        case .stopped:return "Windows spento"
        case .running:return connected ? "Windows acceso e collegato":"Windows acceso · collegamento in attesa"
        case .unreachable:return "Stato Windows non verificabile"
        }
    }
    private func acceptMachineState(_ state:MachineRuntimeState){
        let changed=machineState != state
        if changed {machineState=state}
        if state == .stopped,changed {
            awaitingInitialGuest=false;guestContactEstablished=false
            bridge?.disconnect()
            for window in Array(windows.values) {window.retire()}
            windows=[:];earlyFrames=[:];windowApps=[:]
            machine?.closeDesktop();status="Windows spento"
            if launcherNotice==displayStatus {launcherNotice=nil}
            launcherDisplays=[];displayStatus="Windows spento"
        }else if case .running=state,!connected {
            status="Windows acceso · collegamento in attesa"
        }
    }
    private func startMachineObservation(){
        machineStateTask=Task{@MainActor [weak self] in
            while !Task.isCancelled {
                if let self,let machine=self.machine,self.machineOperation == nil,!self.restarting {
                    let revision=self.machineStateRevision
                    let state=await machine.observedState()
                    if !Task.isCancelled,self.machine === machine,self.machineStateRevision == revision,
                       self.machineOperation == nil,!self.restarting {
                        self.acceptMachineState(state)
                        let memory=state.pid != nil ? (self.memoryController?.state ?? [:]):[:]
                        // Only these fields are displayed. Device counters and
                        // the polling timestamp must not invalidate the entire
                        // SwiftUI launcher while a Windows frame is arriving.
                        let fields:Set<String>=["ready","actualMiB","guestAvailableMiB","pending","error"]
                        let visible=memory.filter{fields.contains($0.key)}
                        let prior=self.vmMemoryState.filter{fields.contains($0.key)}
                        let changed = !NSDictionary(dictionary:prior).isEqual(to:visible)
                        if changed {self.vmMemoryState=memory}
                        PipelineTrace.record("ui-state-poll","memory",["published":changed])
                        self.refreshCatalogueIfNeeded()
                    }
                }
                do {try await Task.sleep(for:.seconds(2))}catch{return}
            }
        }
    }
    private func configureMachineControllers(){
        memoryController?.stop();memoryController=nil;vmMemoryState=[:]
        machine.desktopClipboardBridge=bridge
        machine.onDesktopSize={ [weak self] size in self?.desktopSize=size;self?.scheduleDesktopResize() }
        machine.onDesktopInput={ [weak self] in
            self?.desktopRecoveryTask?.cancel()
            self?.followDesktopFocus()
        }
        if let configuration=machine.configuration.dynamicMemory,let bridge {
            memoryController=RuntimeMemoryController(machine:machine,bridge:bridge,configuration:configuration){[weak self] in
                guard let self,NSApp.isActive,!NSApp.isHidden else{return false}
                return self.machine?.desktopState["visible"] as? Bool == true || self.windows.values.contains{$0.window.isVisible}
            }
            memoryController?.guestReady=guestCapabilities["memoryStatus"] == true
            memoryController?.start()
        }
    }
    func prepareSharedFolders(){
        guard connected,guestCapabilities["execute"] == true,let machine else{return}
        guard machine.usesSMBFolders else {
            folderIntegrationStatus="Le cartelle passeranno al nuovo collegamento al prossimo avvio di Windows."
            return
        }
        folderIntegration.apply(exports:machine.configuration.folderExports,bridge:bridge,directory:machine.directory){[weak self] text,failed,busy in
            self?.folderIntegrationStatus=text;self?.folderIntegrationFailed=failed;self?.folderIntegrationBusy=busy
        }
    }
    private func loadVMSettings(){
        guard let machine else{return}
        currentVMSettings=machine.configuration.settings
        do {
            var pending=try MachineSettingsStore.pending(in:machine.directory,machineID:machine.configuration.id)
            if pending == nil,machine.configuration.sharedFolders == nil,var defaults=currentVMSettings {
                defaults.sharedFolderSelection=Dictionary(uniqueKeysWithValues:SharedFolderKind.allCases.map{($0.rawValue,true)})
                defaults.useAutomaticMemoryPolicy()
                try MachineSettingsStore.save(defaults,in:machine.directory,machineID:machine.configuration.id,current:machine.configuration.settings,forcePending:true)
                pending=defaults
            }
            vmSettings=pending ?? currentVMSettings;settingsPending=pending != nil
        }catch {
            vmSettings=currentVMSettings;settingsPending=false
            settingsFailed=true;settingsNotice=error.localizedDescription
        }
    }
    var canEditVMSettings:Bool {machine != nil && machineState == .stopped && machineOperation == nil && !restarting}
    func saveVMSettings(_ requested:MachineSettings){
        guard canEditVMSettings,let machine else{return}
        do {
            var settings=requested;settings.useAutomaticMemoryPolicy()
            try MachineSettingsStore.save(settings,in:machine.directory,machineID:machine.configuration.id,current:machine.configuration.settings,forcePending:machine.configuration.sharedFolders == nil)
            loadVMSettings();settingsFailed=false
            settingsNotice=nil
            machineOperation="Aggiornamento impostazioni…"
            Task{@MainActor [weak self] in
                guard let self else{return}
                defer{self.machineOperation=nil}
                do {_ = try await self.prepareMachineForStart()}
                catch{self.settingsFailed=true;self.settingsNotice=error.localizedDescription}
            }
        }catch{settingsFailed=true;settingsNotice=error.localizedDescription}
    }
    private func prepareMachineForStart()async throws->VirtualMachineController {
        let previous=machine!
        let next=try await previous.applyingPendingSettings()
        if next !== previous {
            previous.closeDesktop();machine=next
            configureMachineControllers();loadVMSettings()
            settingsNotice=nil;settingsFailed=false
        }
        return next
    }
    @objc func startWindows(){
        guard machine != nil,machineOperation == nil,!restarting else{return}
        machineStateRevision=UUID();machineOperation="Avvio di Windows…";launcherNotice=nil
        Task{@MainActor [weak self] in
            guard let self else{return}
            defer{self.machineOperation=nil}
            do {
                let machine=try await self.prepareMachineForStart()
                if await machine.observedState() == .stopped {self.awaitingInitialGuest=true;self.guestContactEstablished=false}
                try await machine.start();try NativeWindowFrames.shared.publishEndpoint();self.acceptMachineState(await machine.observedState())
            }
            catch {self.acceptMachineState(await self.machine.observedState());self.launcherNotice="Non riesco ad avviare Windows. "+error.localizedDescription}
        }
    }
    @objc func forceStopWindows(){
        guard canStopWindows,let machine,let pid=machineState.pid else{return}
        let alert=NSAlert();alert.alertStyle = .warning
        alert.messageText="Arrestare forzatamente Windows?"
        alert.informativeText="Windows e tutte le sue app verranno interrotti immediatamente. Le modifiche non salvate possono andare perse. Usa Spegni Windows per una chiusura normale."
        alert.addButton(withTitle:"Annulla")
        alert.addButton(withTitle:"Arresta Windows").hasDestructiveAction=true
        guard alert.runModal() == .alertSecondButtonReturn else{return}
        guard self.machine === machine,machineState.pid == pid,machineOperation == nil,!restarting else{return}
        machineStateRevision=UUID();machineOperation="Arresto forzato di Windows…";launcherNotice=nil
        Task{@MainActor [weak self] in
            guard let self else{return}
            defer{self.machineOperation=nil}
            var commandError:Error?
            do {try await machine.forceStop(expectedPID:pid)}catch {commandError=error}
            var actual=await machine.observedState()
            let deadline=Date().addingTimeInterval(10)
            while commandError == nil,actual != .stopped,Date()<deadline {
                try? await Task.sleep(for:.milliseconds(250));actual=await machine.observedState()
            }
            self.acceptMachineState(actual)
            if actual != .stopped {
                self.launcherNotice="L’arresto di Windows non è confermato. "+(commandError?.localizedDescription ?? "Il processo è ancora attivo.")
            }
        }
    }
    private func followDesktopFocus(){
        guard connected,guestCapabilities["modeFocus"] == true else{return}
        desktopFocusTask?.cancel();let request=UUID();desktopFocusRequest=request
        let epoch=displayEpoch
        desktopFocusTask=Task{@MainActor [weak self] in
            // Only follow a real Desktop input, never merely opening Desktop.
            // The bounded grace period covers Shell/singleton activation.
            for _ in 0..<16 {
                do {try await Task.sleep(for:.milliseconds(250))}catch{return}
                guard let self,!Task.isCancelled,self.desktopFocusRequest == request,
                      self.displayEpoch == epoch,self.machine?.desktopIsKey == true else{return}
                let handled:Bool=await withCheckedContinuation { continuation in
                    self.bridge.command("desktop_focus_target",["transfer":true],timeout:.seconds(1)){[weak self] result in
                        guard let self,self.desktopFocusRequest == request,self.displayEpoch == epoch,
                              self.machine?.desktopIsKey == true,case .success(let reply)=result,
                              let value=reply["value"] as? [String:Any] else{continuation.resume(returning:false);return}
                        if let singleton=value["desktopSingleton"] as? [String:Any],
                           let app=singleton["app"] as? String,let target=singleton["target"] as? [String:Any] {
                            self.recoverDesktopSingleton(app:app,target:target)
                            continuation.resume(returning:true);return
                        }
                        guard let id=value["window"] as? String,let window=self.windows[id] else{continuation.resume(returning:false);return}
                        window.activate();continuation.resume(returning:true)
                    }
                }
                if handled{return}
            }
        }
    }
    private func desktopSingletonState(app:String,target:[String:Any],place:Bool=false,seamless:Bool=false) async throws->DesktopSingletonState {
        let checkedAt=ProcessInfo.processInfo.systemUptime
        return try await withCheckedThrowingContinuation {continuation in
            bridge.command("desktop_singleton_state",["app":app,"target":target,"place":place,"destination":seamless ? "seamless":"desktop"],timeout:.seconds(1)){result in
                switch result {
                case .failure(let error):continuation.resume(throwing:error)
                case .success(let reply):
                    let value=reply["value"] as? [String:Any] ?? [:]
                    continuation.resume(returning:DesktopSingletonState(focused:value["focused"] as? Bool == true,
                        visible:value["onDesktop"] as? Bool == true,primary:value["onPrimary"] as? Bool == true,
                        maxMoves:min(8,max(1,value["maxMoves"] as? Int ?? 1)),rect:String(describing:value["rect"] ?? ""),checkedAt:checkedAt,
                        zoomed:value["zoomed"] as? Bool == true,moveKey:value["moveKey"] as? String,adjustment:value["adjustment"] as? String))
                }
            }
        }
    }
    private func recoverDesktopSingleton(app:String,target:[String:Any],seamless:Bool=false,restoringAfterFailure:String?=nil){
        desktopRecoveryTask?.cancel();let request=UUID();desktopRecoveryRequest=request
        let epoch=displayEpoch
        desktopRecoveryTask=Task{@MainActor [weak self] in
            guard let self,let machine=self.machine else{return}
            defer{if self.desktopRecoveryRequest==request {
                self.desktopRecoveryTask=nil
                if Task.isCancelled {self.finishOpening(app)}
            }}
            do {
                try await machine.showDesktop()
                @MainActor func current() throws {
                    try Task.checkCancellation()
                    guard self.desktopRecoveryRequest==request,self.displayEpoch==epoch,self.connected,machine.desktopIsKey else{
                        throw CocoaError(.userCancelled)
                    }
                }
                try current()
                _=try await self.desktopSingletonState(app:app,target:target,place:true,seamless:seamless)
                try await Task.sleep(for:.milliseconds(180));try current()
                var state=try await self.desktopSingletonState(app:app,target:target,seamless:seamless)
                for _ in 0..<8 where !state.focused {
                    try current()
                    try await machine.cycleApplicationFocus(notAfter:state.checkedAt+0.5)
                    try await Task.sleep(for:.milliseconds(160));try current()
                    state=try await self.desktopSingletonState(app:app,target:target,seamless:seamless)
                }
                var seen=Set<String>()
                var fitted=false
                var restored=false
                var moves=0
                for _ in 0..<(seamless ? 32:state.maxMoves+1) {
                    try current()
                    if state.focused && state.visible {
                        if seamless {
                            try await withCheckedThrowingContinuation {(continuation:CheckedContinuation<Void,Error>) in
                                self.bridge.command("seamless_adopt",["app":app,"target":target],timeout:.seconds(2)){ result in
                                    switch result {
                                    case .success:continuation.resume()
                                    case .failure(let error):continuation.resume(throwing:error)
                                    }
                                }
                            }
                            // The first captured frame, rather than this ACK,
                            // completes the normal launcher opening gate.
                        }else{self.finishOpening(app,appeared:true)}
                        self.launcherNotice=restoringAfterFailure;return
                    }
                    guard state.focused else{break}
                    if state.primary {
                        if seamless,state.zoomed,!restored {
                            restored=true
                            try await machine.restoreDesktopApplication(notAfter:state.checkedAt+0.5)
                        }else if seamless,let key=state.moveKey,let direction=state.adjustment {
                            try await machine.nudgeApplication(moveKey:key,direction:direction,notAfter:state.checkedAt+1)
                        }else {
                            guard !fitted else{break};fitted=true
                            try await machine.fitDesktopApplication(notAfter:state.checkedAt+0.5)
                        }
                    }else {
                        guard moves<state.maxMoves,seen.insert(state.rect).inserted else{break};moves+=1
                        try await machine.moveApplicationToNextDisplay(notAfter:state.checkedAt+0.5)
                    }
                    let previous=state.rect
                    // Display/DPI changes arrive after the device ACK. Wait
                    // for Windows' geometry, never replay the move merely
                    // because its first readback still has the old rectangle.
                    for _ in 0..<10 {
                        try await Task.sleep(for:.milliseconds(150));try current()
                        do {
                            state=try await self.desktopSingletonState(app:app,target:target,seamless:seamless)
                        }catch {
                            // Windows can still be completing our system-menu
                            // gesture after the device has released its keys.
                            // Wait for idle readback before any further input.
                            if error.localizedDescription.contains("Finish the current Windows interaction") {continue}
                            throw error
                        }
                        if state.visible || state.rect != previous {break}
                    }
                    if !state.visible && state.rect == previous {break}
                }
                throw NSError(domain:"Guest",code:1,userInfo:[NSLocalizedDescriptionKey:"Windows non ha completato il passaggio dell’app alla modalità richiesta. L’istanza è stata conservata."])
            }catch {
                guard self.desktopRecoveryRequest==request else{return}
                self.finishOpening(app)
                guard !Task.isCancelled,machine.desktopIsKey,self.displayEpoch==epoch else{return}
                if seamless {
                    self.seamlessTransferApps.remove(app)
                    self.recoverDesktopSingleton(app:app,target:target,restoringAfterFailure:
                        "Passaggio a Seamless non completato; l’app è stata conservata nel Desktop. "+error.localizedDescription)
                }else{self.launcherNotice=error.localizedDescription}
            }
        }
    }
    @objc func showWindows(){
        guard machine != nil,machineOperation == nil,!restarting else{return}
        machineStateRevision=UUID();machineOperation="Apertura desktop Windows…"
        Task{@MainActor [weak self] in
            guard let self else{return};defer{self.machineOperation=nil}
            do {let machine=try await self.prepareMachineForStart();try await machine.showDesktop();self.acceptMachineState(await machine.observedState())}
            catch {self.launcherNotice="Non riesco ad aprire il desktop Windows. "+error.localizedDescription;self.showApplications()}
        }
    }
    @objc func shutdownWindows(){
        guard canStopWindows,let machine else{return}
        machineStateRevision=UUID();machineOperation="Richiesta di spegnimento…";launcherNotice=nil
        Task{@MainActor [weak self] in
            guard let self else{return};defer{self.machineOperation=nil}
            do {try await machine.shutdown();self.acceptMachineState(await machine.observedState())}
            catch {self.launcherNotice="Non riesco a richiedere lo spegnimento. "+error.localizedDescription}
        }
    }

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
        let allowed:Set<String>=["status","memory_status","execute","display_info","display_topology","driver_info","graphics_info","geometry_snapshot","application_status","process_list","process_terminate","pipeline_clock","window_refresh"]
        guard allowed.contains(command) else {
            localResponse(["ok":false,"error":"This local command is not supported."],reply:reply);return
        }
        let fields:Set<String>=command == "execute" ? ["command","executable","args","timeoutSeconds"]:command == "process_terminate" ? ["command","pid","creation"]:command == "window_refresh" ? ["command","window"]:["command"]
        guard Set(request.keys).isSubset(of:fields) else {
            localResponse(["ok":false,"error":"Unexpected command fields."],reply:reply);return
        }
        if command == "status" {
            let running:Any
            switch machineState {case .running:running=true;case .stopped:running=false;case .unreachable:running=NSNull()}
            let memoryState:[String:Any]=memoryController?.state ?? ["enabled":false]
            let sharedDownloads:[String:String]
            if let share=machine?.configuration.folderExports.first(where:{$0.kind == .downloads}) {sharedDownloads=["hostPath":share.hostPath]}
            else {sharedDownloads=[:]}
            let folderState:[String:Any]=["status":folderIntegrationStatus,"failed":folderIntegrationFailed,
                "active":machine?.configuration.folderExports.map{["id":$0.kind.rawValue,"hostPath":$0.hostPath]} ?? [],
                "selected":vmSettings?.enabledSharedFolders.map(\.rawValue) ?? []]
            localResponse(["ok":true,"result":["connected":connected,"machineRunning":running,
                "machineState":machineStateLabel,"machineOperation":machineOperation as Any? ?? NSNull(),
                "status":status,"displayStatus":displayStatus,"primaryMatchesHost":sharedDisplay != nil,
                "displayChecks":mixedDisplayChecks,"displayApplies":mixedDisplayApplies,"displayInvalidations":displayInvalidations,
                "mappedDisplays":sharedDisplays.count,"displaySetupComplete":machine?.mixedDisplaysEnabled == true ? sharedDisplays.count==HostDisplay.current().count:sharedDisplay != nil,
                "appLaunchReady":machine?.mixedDisplaysEnabled != true || !sharedDisplays.isEmpty,
                "memory":memoryState,"sharedDownloads":sharedDownloads,"sharedFolders":folderState,
                "vmSettings":["pending":settingsPending,"initialMemoryMiB":vmSettings?.initialMemoryMiB ?? 0,"maximumMemoryMiB":vmSettings?.maximumMemoryMiB ?? 0,"cpus":vmSettings?.cpus ?? 0],
                "windowCount":windows.count,"capabilities":guestCapabilities,
                "frameChannel":bridge?.separateFrames ?? false,
                "windowGPU":NativeWindowFrames.shared.diagnostics,
                "windowGPUCache":NativeWindowFrames.shared.cacheDiagnostics,
                "launcher":["cursor":launcher.cursorDiagnostics,"catalogueAutomaticEligible":launcher.isVisible && !launcher.isMiniaturized,"catalogueAgeSeconds":ProcessInfo.processInfo.systemUptime-lastCatalogueRefresh,"catalogueRefreshes":catalogueRefreshes,"statusMessage":launcherStatusMessage as Any? ?? NSNull(),"dragSamples":launcher.dragSamples,"dragPointer":["x":launcher.dragPointer.x,"y":launcher.dragPointer.y],"dragRequested":["x":launcher.dragRequested.x,"y":launcher.dragRequested.y],"frame":["x":launcher.frame.minX,"y":launcher.frame.minY,"width":launcher.frame.width,"height":launcher.frame.height],"screen":launcher.screen?.localizedName ?? "", "apps":apps.map{["id":$0.id,"name":$0.name,"key":$0.key,"essential":$0.essential]},"opening":Array(openingApps).sorted(),"notice":launcherNotice as Any? ?? NSNull(),"iconCacheHits":iconCacheHits,"iconFetches":iconFetches,"cachedIcons":applicationIcons.count,"recent":launcherPreferences.recent(apps).map(\.id),"favorites":launcherPreferences.sections(apps).favorites.map(\.id),"appearance":launcherAppearance.rawValue,"indicator":launcherWindowsStatus.title],
                "desktop":machine?.desktopState ?? [:],
                "lastCommandRTTMilliseconds":bridge?.lastRoundTripMilliseconds ?? 0,
                "frameReceiveMilliseconds":bridge?.frameReceiveMilliseconds ?? 0,
                "frameTimings":bridge?.lastFrameTimings ?? [:]]],reply:reply);return
        }
        guard connected,let bridge else {
            localResponse(["ok":false,"error":"Windows is not connected."],reply:reply);return
        }
        if command == "pipeline_clock" {
            let started=ProcessInfo.processInfo.systemUptime
            bridge.command("trial_clock",timeout:.seconds(2)){[weak self] result in
                switch result {
                case .success(let value):self?.localResponse(["ok":true,"result":["hostBefore":started,"hostAfter":ProcessInfo.processInfo.systemUptime,"guest":value]],reply:reply)
                case .failure(let error):self?.localResponse(["ok":false,"error":error.localizedDescription],reply:reply)
                }
            };return
        }
        if command == "window_refresh" {
            guard bridge.windowRefreshAvailable,let id=request["window"] as? String,windows[id] != nil else {
                localResponse(["ok":false,"error":"Expected an active native window and current guest tools."],reply:reply);return
            }
            bridge.command(command,["window":id],timeout:.seconds(3)){[weak self] result in self?.localBridgeResponse(result,reply:reply)}
            return
        }
        if command == "application_status" || command == "process_list" || command == "process_terminate" {
            let capability=command == "application_status" ? "applicationStatus":"processControl"
            guard guestCapabilities[capability] == true else {
                localResponse(["ok":false,"error":"Guest update required for process control."],reply:reply);return
            }
            var values:[String:Any]=[:]
            if command == "process_terminate" {
                guard let pid=request["pid"] as? Int,pid>0,pid<=Int(UInt32.max),
                    let creation=request["creation"] as? String,UInt64(creation) != nil else {
                    localResponse(["ok":false,"error":"Expected PID and exact creation identity."],reply:reply);return
                }
                values=["pid":pid,"creation":creation]
            }
            bridge.command(command,values,timeout:.seconds(6)){[weak self] result in self?.localBridgeResponse(result,reply:reply)}
            return
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
        let capabilities=["memory_status":"memoryStatus","display_info":"displayInfo","display_topology":"displayTopology","driver_info":"driverInfo","graphics_info":"graphicsInfo"]
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
            localResponse(["ok":true,"result":["windows":rows,"primaryMatchesHost":sharedDisplay != nil,
                "hostDisplays":HostDisplay.current().map(\.description)]],reply:reply);return
        }
        guard let controller=windows[id] else {
            localGeometrySnapshot(ids.dropFirst(),rows:rows,epoch:epoch,reply:reply);return
        }
        let frame=controller.window.frame
        let content=controller.window.contentRect(forFrameRect:frame)
        let row:[String:Any]=["id":id,"title":controller.window.title,"role":controller.role.rawValue,
            "presentation":controller.presentationState,
            "macMinimumFramePoints":["width":controller.window.minSize.width,"height":controller.window.minSize.height],
            "macMaximumFramePoints":["width":controller.window.maxSize.width,"height":controller.window.maxSize.height],
            "macContentPoints":["x":content.minX,"y":content.minY,"width":content.width,"height":content.height],
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
        if item.action == #selector(startWindows) {return canStartWindows}
        if item.action == #selector(forceStopWindows) || item.action == #selector(shutdownWindows) {return canStopWindows}
        if item.action == #selector(selectDisplay(_:)) || item.action == #selector(toggleRecoveryDisplay) {
            return machine != nil && !restarting && machineOperation == nil
        }
        return true
    }
    private func restartDisplay(graphics:String?,recovery:Bool){
        guard let previous=machine,!restarting,machineOperation == nil else{return}
        restarting=true;recoveryItem.isEnabled=false;status="Restarting Windows…"
        Task{@MainActor [weak self] in
            guard let self else{return}
            defer {self.restarting=false;self.recoveryItem.isEnabled=true}
            do {
                try await previous.shutdown()
                let deadline=Date().addingTimeInterval(60)
                while await previous.observedState() != .stopped,Date()<deadline {try await Task.sleep(for:.milliseconds(500))}
                guard await previous.observedState() == .stopped else {
                    self.status="Windows has not shut down. Save your work or open Desktop Mode.";return
                }
                previous.closeDesktop()
                self.machine=try previous.withDisplay(graphics:graphics,recovery:recovery)
                self.configureMachineControllers();self.loadVMSettings()
                self.recoveryItem.state=recovery ? .on:.off
                for item in self.displayItems {item.state=self.machine.configuration.graphics == item.representedObject as? String ? .on:.off}
                let machine=try await self.prepareMachineForStart();try await machine.start();try await machine.showDesktop()
                self.status="Starting Windows…"
            }catch {self.status=error.localizedDescription}
        }
    }
    func refreshCatalogueIfNeeded(){
        guard launcher?.isVisible == true,launcher?.isMiniaturized == false,
              ProcessInfo.processInfo.systemUptime-lastCatalogueRefresh>=30 else{return}
        refresh(checkDisplay:false)
    }
    func refresh(checkDisplay:Bool=true){
        guard connected,!catalogueLoading else{return}
        lastCatalogueRefresh=ProcessInfo.processInfo.systemUptime;catalogueRefreshes+=1
        catalogueLoading=true
        if launcherNotice==catalogueNotice {launcherNotice=nil}
        catalogueNotice=nil
        catalogueRequest=UUID();let request=catalogueRequest,epoch=launcherEpoch
        if checkDisplay {readDisplay()}
        bridge.command("catalogue"){[weak self] result in
            guard let self,self.launcherEpoch == epoch,self.catalogueRequest == request else{return}
            self.catalogueLoading=false
            switch result{
            case .success(let reply):
                guard let values=reply["value"] as? [[String:Any]] else {
                    let message="L’elenco delle app non è disponibile. Riprovo automaticamente."
                    self.catalogueNotice=message;self.launcherNotice=message;return
                }
                let previousRevisions=Dictionary(uniqueKeysWithValues:self.apps.map{($0.id,$0.iconRevision)})
                var identities:Set<String>=[]
                self.apps=values.prefix(1024).compactMap{value in
                    guard let id=value["id"] as? String,id.utf8.count==64,let name=value["name"] as? String,name.utf8.count<=512 else{return nil}
                    guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,identities.insert(id).inserted else{return nil}
                    return WindowsApplication(id:id,name:name,key:value["key"] as? String ?? "",essential:value["essential"] as? Bool == true,iconRevision:value["iconRevision"] as? String ?? "")
                }.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}
                try? self.launcherLibrary?.saveCatalogue(self.apps)
                self.failedIcons=[];self.iconDiskChecked=[]
                self.visibleIcons.formIntersection(identities)
                self.iconVisibility=self.iconVisibility.filter{identities.contains($0.key)}
                let revisions=Dictionary(uniqueKeysWithValues:self.apps.map{($0.id,$0.iconRevision)})
                self.applicationIcons=self.applicationIcons.filter{identities.contains($0.key) && previousRevisions[$0.key] == revisions[$0.key]}
                self.iconOrder.removeAll{!identities.contains($0)}
                self.status="\(self.apps.count) applications"
                self.pumpApplicationIcons()
            case .failure(let error):
                self.status=error.localizedDescription
                let message="Non riesco ad aggiornare le app. "+error.localizedDescription
                self.catalogueNotice=message;self.launcherNotice=message
            }
        }
    }
    func launch(_ app:WindowsApplication){
        guard connected,!openingApps.contains(app.id) else{return}
        if machine?.mixedDisplaysEnabled == true,sharedDisplays.isEmpty {
            launcherNotice="Attendi che Windows completi la preparazione degli schermi.";return
        }
        launcherNotice=nil;openingNoticeApp=nil;openingNoticeTimedOut=false
        cancelledOpeningApps.remove(app.id);beginOpening(app)
        status="Opening \(app.name)…"
        let epoch=launcherEpoch,request=openingRequests[app.id]
        PipelineTrace.record("app-launch-request",app.id)
        bridge.command("launch",["app":app.id]){[weak self] result in
            guard let self,self.launcherEpoch == epoch else{return}
            if PipelineTrace.enabled {
                switch result {
                case .success(let reply):PipelineTrace.record("app-launch-reply",app.id,["value":reply["value"] ?? [:]])
                case .failure:PipelineTrace.record("app-launch-failed",app.id)
                }
            }
            if case .success=result {
                self.launcherPreferences.record(app.id);try? self.launcherLibrary?.save(self.launcherPreferences)
            }
            guard self.openingRequests[app.id] == request else{return}
            self.refreshApplicationStates()
            switch result {
            case .failure(let error):
                self.finishOpening(app.id);self.status=error.localizedDescription
                self.launcherNotice="Non riesco ad aprire \(app.name). "+error.localizedDescription;self.openingNoticeApp=app.id
            case .success(let reply):
                if let value=reply["value"] as? [String:Any],value["existing"] as? Bool == true,value["ready"] as? Bool != false,
                   self.windows.contains(where:{self.windowApps[$0.key] == app.id && $0.value.readyForInput}) {
                    self.finishOpening(app.id,appeared:true)
                }
            }
        }
    }
    private func beginOpening(_ app:WindowsApplication){
        // Only an explicit launcher request starts this clock. A guest window
        // gap after a Desktop transfer is not a new launch.
        guard !openingApps.contains(app.id) else{return}
        let request=UUID();openingRequests[app.id]=request
        openingApps.insert(app.id);openingTasks.removeValue(forKey:app.id)?.cancel()
        let epoch=launcherEpoch
        openingTasks[app.id]=Task{@MainActor [weak self] in
            try? await Task.sleep(for:.seconds(32))
            guard !Task.isCancelled,let self,self.launcherEpoch == epoch,self.openingRequests[app.id] == request else{return}
            if self.windows.contains(where:{self.windowApps[$0.key] == app.id && $0.value.readyForInput}) {
                self.finishOpening(app.id,appeared:true);return
            }
            self.finishOpening(app.id)
            self.launcherNotice="La finestra di \(app.name) non è ancora disponibile. Apri Desktop per continuare.";self.openingNoticeApp=app.id;self.openingNoticeTimedOut=true
        }
    }
    private func finishOpening(_ id:String,appeared:Bool=false){
        seamlessTransferApps.remove(id)
        guard openingApps.contains(id) || openingTasks[id] != nil || (appeared && openingNoticeApp == id) else{return}
        PipelineTrace.record(appeared ? "app-launch-ready":"app-launch-ended",id)
        openingTasks.removeValue(forKey:id)?.cancel()
        openingRequests.removeValue(forKey:id)
        if openingApps.contains(id) {openingApps.remove(id)}
        if appeared,openingNoticeApp == id {launcherNotice=nil;openingNoticeApp=nil;openingNoticeTimedOut=false}
    }
    private func startApplicationStatusUpdates(){
        guard guestCapabilities["applicationStatus"] == true else{return}
        applicationStatusTask?.cancel()
        applicationStatusTask=Task{@MainActor [weak self] in
            while !Task.isCancelled {
                self?.refreshApplicationStates()
                do {try await Task.sleep(for:.seconds(2))}catch{return}
            }
        }
    }
    func refreshApplicationStates(){
        guard connected,guestCapabilities["applicationStatus"] == true,!applicationStatusBusy else{return}
        applicationStatusBusy=true;let epoch=launcherEpoch
        bridge.command("application_status",timeout:.seconds(4)){[weak self] result in
            guard let self,self.launcherEpoch == epoch else{return}
            self.applicationStatusBusy=false
            guard case .success(let reply)=result,let value=reply["value"] as? [String:Any],
                value["epoch"] as? String == self.displayEpoch,
                let rows=value["applications"] as? [[String:Any]],rows.count<=8 else {
                self.applicationStatusAvailable=false;return
            }
            var states:[String:GuestApplicationState]=[:]
            for row in rows {if let state=GuestApplicationState(row) {states[state.id]=state}}
            let changed=self.applicationStates != states
            if changed {self.applicationStates=states}
            if !self.applicationStatusAvailable {self.applicationStatusAvailable=true}
            let active=Set(states.values.filter{$0.running || !$0.windows.isEmpty}.map(\.id))
            if self.activeApps != active {self.activeApps=active}
            // Presentation and status travel independently. Reconcile ready
            // windows even if their ready callback preceded the launch reply.
            for id in Array(self.openingApps) where self.windows.contains(where:{self.windowApps[$0.key] == id && $0.value.readyForInput}) {
                self.finishOpening(id,appeared:true)
            }
            if self.openingNoticeTimedOut,let id=self.openingNoticeApp,
               !self.openingApps.contains(id),
               states[id].map({!$0.activationPending && !$0.running && $0.windows.isEmpty}) ?? true {
                self.finishOpening(id,appeared:true)
            }
            PipelineTrace.record("ui-state-poll","applications",["published":changed])
        }
    }
    func applicationStateLabel(_ id:String)->String {
        guard connected else{return "Stato non disponibile"}
        guard guestCapabilities["applicationStatus"] == true else{return activeApps.contains(id) ? "Finestra rilevata":"Apri"}
        guard applicationStatusAvailable else{return "Verifica stato…"}
        guard let state=applicationStates[id] else{return openingApps.contains(id) ? "Avvio richiesto…":"Apri"}
        if state.activationPending {return "Avvio in corso…"}
        if state.windows.contains(where:{$0.stopped || failedWindows.contains($0.id)}) {return "Cattura interrotta"}
        if state.windows.contains(where:{receivedWindows.contains($0.id)}) {return "Finestra disponibile"}
        if !state.windows.isEmpty {return "In attesa dell’immagine"}
        return state.running ? "In esecuzione · senza finestra":"Nessun processo rilevato"
    }
    func closeApplication(_ app:WindowsApplication){
        guard connected else{return};let epoch=launcherEpoch
        bridge.command("application_close",["app":app.id],timeout:.seconds(4)){[weak self] result in
            guard let self,self.launcherEpoch == epoch else{return}
            if case .failure(let error)=result {self.launcherNotice=error.localizedDescription}
            self.refreshApplicationStates()
        }
    }
    private func inputFocusFailed(){
        let message="Windows non ha attivato l’app. Il clic o il testo non è stato inviato."
        status=message;launcherNotice=message+" Apri Desktop, seleziona l’app e torna a questa finestra."
        guard let controller=windows.values.first(where:{$0.window === NSApp.keyWindow && !$0.role.transient}),
              controller.window.attachedSheet == nil,focusWarnedWindows.insert(controller.id).inserted else{return}
        // A modal warning can consume the next typed Return and unexpectedly
        // open the desktop. Keep the failure visible without stealing input.
        windowNotice=(controller.id,launcherNotice ?? message,false)
    }
    func applicationBecameVisible(_ app:WindowsApplication){iconVisibility[app.id,default:0]+=1;visibleIcons.insert(app.id);pumpApplicationIcons()}
    func applicationBecameHidden(_ app:WindowsApplication){
        let count=max(0,(iconVisibility[app.id] ?? 0)-1)
        if count==0 {iconVisibility.removeValue(forKey:app.id);visibleIcons.remove(app.id)}else{iconVisibility[app.id]=count}
    }
    private func pumpApplicationIcons(){
        let needed=visibleIcons.union(windowApps.values)
        for app in apps where needed.contains(app.id) && applicationIcons[app.id] == nil && !iconDiskChecked.contains(app.id) {
            iconDiskChecked.insert(app.id)
            if let data=launcherLibrary?.cachedIcon(for:app),let image=Self.decodeIcon(data) {
                applicationIcons[app.id]=image;iconOrder.append(app.id);iconCacheHits+=1
            }
        }
        guard connected,guestCapabilities["appIcon"] == true,loadingIconID == nil,
              let app=apps.first(where:{needed.contains($0.id) && applicationIcons[$0.id] == nil && !failedIcons.contains($0.id)}) else{return}
        let epoch=launcherEpoch;loadingIconID=app.id;iconFetches+=1
        bridge.command("app_icon",["app":app.id],timeout:.seconds(8)){[weak self] result in
            guard let self,self.launcherEpoch == epoch,self.loadingIconID == app.id else{return}
            self.loadingIconID=nil
            if case .success(let reply)=result,let value=reply["value"] as? [String:Any],
               value["app"] as? String == app.id,let width=value["width"] as? Int,let height=value["height"] as? Int,
               (1...256).contains(width),(1...256).contains(height),
               let encoded=value["pngBase64"] as? String,encoded.utf8.count<=699_052,
               let data=Data(base64Encoded:encoded),data.count<=524_288,
               data.starts(with:[137,80,78,71,13,10,26,10]),
               let expected=value["sha256"] as? String,
               SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined() == expected.lowercased(),
               let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
               CGImageSourceGetCount(source)==1,
               let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any],
               properties[kCGImagePropertyPixelWidth as String] as? Int == width,
               properties[kCGImagePropertyPixelHeight as String] as? Int == height,
               let image=CGImageSourceCreateImageAtIndex(source,0,nil) {
                if self.applicationIcons.count>=128,let evicted=self.iconOrder.first(where:{!self.visibleIcons.contains($0)}) ?? self.iconOrder.first {
                    self.applicationIcons.removeValue(forKey:evicted);self.iconOrder.removeAll{$0 == evicted}
                }
                try? self.launcherLibrary?.saveIcon(data,for:app)
                self.applicationIcons[app.id]=NSImage(cgImage:image,size:NSSize(width:width,height:height))
                self.iconOrder.append(app.id)
                for (id,window) in self.windows where self.windowApps[id] == app.id {
                    window.identifyApplication(name:app.name,icon:self.applicationIcons[app.id])
                }
            }else{self.failedIcons.insert(app.id)}
            self.pumpApplicationIcons()
        }
    }
    func togglePin(_ app:WindowsApplication){
        var next=launcherPreferences
        if !next.pinned.insert(app.id).inserted {next.pinned.remove(app.id)}
        do {
            guard let launcherLibrary else{throw CocoaError(.fileNoSuchFile)}
            try launcherLibrary.save(next)
            launcherPreferences=next
        }catch {launcherNotice="Non riesco a salvare i preferiti. "+error.localizedDescription}
    }
    private static func decodeIcon(_ data:Data)->NSImage? {
        guard data.starts(with:[137,80,78,71,13,10,26,10]),
              let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),CGImageSourceGetCount(source)==1,
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any],
              let width=properties[kCGImagePropertyPixelWidth as String] as? Int,let height=properties[kCGImagePropertyPixelHeight as String] as? Int,
              (1...256).contains(width),(1...256).contains(height),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else{return nil}
        return NSImage(cgImage:image,size:NSSize(width:width,height:height))
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
        displayRevision+=1;displayInvalidations+=1;displayUpdating=true;sharedDisplay=nil;sharedDisplays=[];displayStatus=message
        for window in windows.values {window.setDisplayUpdating(true);window.setSharedDisplay(nil)}
    }
    @objc private func hostDisplaysChanged(){
        let hosts=HostDisplay.current()
        guard hosts != lastHostDisplays else{return}
        lastHostDisplays=hosts
        mixedDisplayConfiguring=false
        displaySetupTask?.cancel();displaySetupTask=nil
        displaySetupID=UUID()
        invalidateDisplay("Checking Windows display…")
        guard connected else{return}
        if !desktopOnly,machine.mixedDisplaysEnabled != true {machine.synchronizePrimaryDisplay()}
        readDisplay()
        prepareDisplay()
    }
    private func prepareDisplay(){
        if machine?.mixedDisplaysEnabled == true {readMixedDisplay();return}
        guard !desktopOnly,displayConfigurable,machine.virtualDisplayEnabled,let host=HostDisplay.current().first(where:\.primary) else{return}
        let size=host.guestPixelSize
        let width=Int(size.width),height=Int(size.height)
        configureDisplay(width:width,height:height,epoch:displayEpoch)
    }
    private func readDisplay(){
        if machine?.mixedDisplaysEnabled == true {readMixedDisplay();return}
        if desktopOnly {readDesktopDisplay();return}
        guard connected,displayReadable,let epoch=displayEpoch else{return}
        displayRevision+=1;let revision=displayRevision
        bridge.command("display_info",timeout:.seconds(5)){[weak self] result in
            guard let self,self.connected,self.displayEpoch == epoch,self.displayRevision == revision else{return}
            guard case .success(let reply)=result,let snapshot=reply["value"] as? [String:Any] else{
                self.invalidateDisplay("Windows display could not be checked.")
                for window in self.windows.values {window.failFrameTransition()};return
            }
            self.acceptDisplay(snapshot)
        }
    }
    private func acceptDisplay(_ snapshot:[String:Any]){
        // A primary-console snapshot cannot replace the independently verified
        // mappings of the N+1 app displays.
        if machine?.mixedDisplaysEnabled == true {readMixedDisplay();return}
        launcherDisplays=snapshot["displays"] as? [[String:Any]] ?? []
        displayUpdating=false
        if desktopOnly,let displays=snapshot["displays"] as? [[String:Any]],displays.count == 1,
           let primary=displays.first,let width=primary["width"] as? Int,let height=primary["height"] as? Int {
            desktopConfirmed=NSSize(width:width,height:height)
            scheduleDesktopResize()
        }
        let host=HostDisplay.current()
        let confirmed=host.first(where:\.primary).flatMap{SharedDisplay.primary(host:$0,snapshot:snapshot)}
        sharedDisplay=sharedGeometryCapable ? confirmed:nil
        for window in windows.values {window.setSharedDisplay(sharedDisplay);window.setDisplayUpdating(false)}
        if confirmed != nil {displayStatus="Windows geometry matches Mac points (Retina presentation)."}
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
    private func acceptMixedDisplay(_ plan:MixedDisplayPlan,_ snapshot:[String:Any])throws {
        let mappings=try plan.mappings(snapshot:snapshot)
        mixedDisplayConfiguring=false
        if guestCapabilities["nativeAppInput"] == true {
            bridge.command("app_input_mode",["enabled":true]){[weak self] result in
                if case .failure(let error)=result {self?.launcherNotice=error.localizedDescription}
            }
        }
        lastHostDisplays=HostDisplay.current()
        sharedDisplay=nil;sharedDisplays=mappings;displayUpdating=false
        launcherDisplays=((snapshot["monitors"] as? [String:Any])?["displays"] as? [[String:Any]] ?? []).map{monitor in
            var monitor=monitor
            if let index=plan.devices.firstIndex(of:monitor["device"] as? String ?? "") {
                monitor["label"]="Schermo Mac \(index+1)";monitor["appScreen"]=true
            }else{monitor["label"]="Desktop Mode";monitor["appScreen"]=false}
            return monitor
        }
        displayStatus=plan.unavailableHosts==0 ? "\(mappings.count) schermi Mac collegati, desktop Windows separato.":
            "\(mappings.count) di \(mappings.count+plan.unavailableHosts) schermi pronti. Puoi aprire le app sugli schermi disponibili; spegni e avvia Windows da Perpendicular per aggiungere gli altri."
        if launcherNotice==mixedDisplayNotice {launcherNotice=nil}
        mixedDisplayNotice=nil
        if plan.unavailableHosts>0 {launcherNotice=displayStatus;mixedDisplayNotice=displayStatus}
        for window in windows.values {
            window.setSharedDisplays(mappings);window.setDisplayUpdating(false)
            if machine.desktopIsKey != true,let first=mappings.first {window.placeOnAppDisplayIfNeeded(first)}
        }
        if let primary=launcherDisplays.first(where:{$0["primary"] as? Bool == true}),
           let width=primary["width"] as? Int,let height=primary["height"] as? Int {
            desktopConfirmed=NSSize(width:width,height:height)
            if desktopConfirmed==desktopAttempted,launcherNotice=="Windows non ha confermato la risoluzione richiesta." {
                launcherNotice=nil
            }
        }
        layoutChildren()
        scheduleDesktopResize()
    }
    private func readMixedDisplay(attempt:Int=0){
        guard connected,let epoch=displayEpoch,!mixedDisplayConfiguring,desktopResizeRequest == nil else{return}
        guard guestCapabilities["displayTopology"] == true,let bindings=machine.appDisplayBindings else {
            failMixedDisplay("La configurazione multischermo richiede gli strumenti Windows aggiornati e un nuovo avvio.");return
        }
        mixedDisplayConfiguring=true;mixedDisplayChecks+=1
        let request=UUID();displaySetupID=request
        bridge.command("display_topology",timeout:.seconds(8)){[weak self] result in
            guard let self,self.connected,self.displayEpoch==epoch,self.displaySetupID==request else{return}
            do {
                let reply=try result.get()
                guard let topology=reply["value"] as? [String:Any] else{throw CocoaError(.coderReadCorrupt)}
                let plan=try MixedDisplayPlan(hosts:HostDisplay.current(),bindings:bindings,topology:topology)
                // Settings notifications do not prove that topology changed.
                // A verified unchanged layout must preserve an in-flight drag,
                // resize and keyboard focus, without another display command.
                if (try? plan.mappings(snapshot:topology)) != nil {
                    try self.acceptMixedDisplay(plan,topology);return
                }
                self.invalidateDisplay("Aggiornamento degli schermi…")
                self.mixedDisplayApplies+=1
                Task{@MainActor [weak self] in
                    guard let self else{return}
                    do {
                        try await self.machine.prepareAppMonitorModes(plan.modes)
                        guard self.connected,self.displayEpoch==epoch,self.displaySetupID==request else{return}
                        self.bridge.command("display_layout",["layout":plan.layout],timeout:.seconds(12)){[weak self] result in
                            guard let self,self.connected,self.displayEpoch==epoch,self.displaySetupID==request else{return}
                            do {
                                let reply=try result.get()
                                guard let snapshot=reply["value"] as? [String:Any] else{throw CocoaError(.coderReadCorrupt)}
                                try self.acceptMixedDisplay(plan,snapshot)
                            }catch{self.retryMixedDisplay(error.localizedDescription,attempt:attempt,epoch:epoch,request:request)}
                        }
                    }catch{
                        guard self.connected,self.displayEpoch==epoch,self.displaySetupID==request else{return}
                        self.retryMixedDisplay(error.localizedDescription,attempt:attempt,epoch:epoch,request:request)
                    }
                }
            }catch{
                self.retryMixedDisplay(error.localizedDescription,attempt:attempt,epoch:epoch,request:request)
            }
        }
    }
    private func retryMixedDisplay(_ message:String,attempt:Int,epoch:String,request:UUID){
        mixedDisplayConfiguring=false
        guard attempt<2 else{failMixedDisplay(message);return}
        // Re-enumerating an app monitor can temporarily invalidate Windows'
        // configuration. Read a fresh topology before another exact apply.
        displayReadTask?.cancel()
        displayReadTask=Task{@MainActor [weak self] in
            try? await Task.sleep(for:.milliseconds(300))
            guard !Task.isCancelled,let self,self.connected,self.displayEpoch==epoch,self.displaySetupID==request else{return}
            self.displayReadTask=nil;self.readMixedDisplay(attempt:attempt+1)
        }
    }
    private func failMixedDisplay(_ message:String){
        mixedDisplayConfiguring=false;sharedDisplay=nil;sharedDisplays=[];displayUpdating=false
        displayStatus=message;launcherNotice=message;mixedDisplayNotice=message
        for window in windows.values {window.setSharedDisplay(nil);window.setDisplayUpdating(false);window.failFrameTransition()}
    }
    private func readDesktopDisplay(){
        guard connected,displayReadable,let epoch=displayEpoch,desktopResizeRequest == nil else{return}
        guard desktopReadRequest == nil else{desktopReadAgain=true;return}
        let request=UUID();desktopReadRequest=request
        bridge.command("display_info",timeout:.seconds(5)){[weak self] result in
            guard let self,self.connected,self.displayEpoch == epoch,self.desktopReadRequest == request else{return}
            self.desktopReadRequest=nil
            if self.desktopReadAgain {self.desktopReadAgain=false;self.readDesktopDisplay();return}
            if case .success(let reply)=result,let snapshot=reply["value"] as? [String:Any] {self.acceptDisplay(snapshot)}
            else {self.displayStatus="Windows display could not be checked."}
        }
    }
    private func scheduleDesktopResize(){
        guard (desktopOnly || machine?.mixedDisplaysEnabled == true),connected,displayConfigurable,!mixedDisplayConfiguring,desktopResizeRequest == nil,desktopReadRequest == nil,
              desktopSize.width>0,desktopSize.height>0,
              machine?.desktopState["visible"] as? Bool == true else{return}
        desktopResizeTask?.cancel()
        desktopResizeTask=Task{@MainActor [weak self] in
            try? await Task.sleep(for:.milliseconds(300))
            guard !Task.isCancelled,let self,self.desktopResizeRequest == nil,self.desktopReadRequest == nil,self.connected,
                  let epoch=self.displayEpoch,self.machine?.desktopState["visible"] as? Bool == true else{return}
            let desired=self.desktopSize
            // Preserve the user's window. Publish its exact Retina raster to
            // the driver's custom mode rather than selecting a standard mode.
            let scale=min(1,4096/desired.width,4096/desired.height,sqrt(8_388_608/(desired.width*desired.height)))
            let mode=NSSize(width:max(640,(desired.width*scale).rounded()),height:max(480,(desired.height*scale).rounded()))
            guard mode != self.desktopConfirmed,mode != self.desktopAttempted else{return}
            self.desktopAttempted=mode
            let request=UUID();self.desktopResizeRequest=request
            self.machine?.requestDesktopResolution(mode)
            // The driver's resolution event and application are asynchronous.
            // Keep one transaction pending and verify actual Windows geometry.
            var checks=0
            let deadline=ProcessInfo.processInfo.systemUptime+12
            while checks<5 && ProcessInfo.processInfo.systemUptime<deadline {
                try? await Task.sleep(for:.milliseconds(300))
                guard !Task.isCancelled,self.connected,self.displayEpoch == epoch,self.desktopResizeRequest == request else{return}
                // Keep this transaction until the monitor is reattached. A
                // newer request must not race the previous final host raster.
                if self.machine?.desktopResolutionPending == true {continue}
                checks+=1
                let matched=await withCheckedContinuation { continuation in
                    self.bridge.command("display_info",timeout:.seconds(5)){result in
                        guard self.displayEpoch == epoch,self.desktopResizeRequest == request else{continuation.resume(returning:false);return}
                        if case .success(let reply)=result,let snapshot=reply["value"] as? [String:Any],
                           let primary=(snapshot["displays"] as? [[String:Any]])?.first(where:{$0["primary"] as? Bool == true}),
                           primary["width"] as? Int == Int(mode.width),primary["height"] as? Int == Int(mode.height) {
                            self.machine?.finishDesktopResolution();self.desktopResizeRequest=nil
                            self.desktopReadAgain=false
                            if self.launcherNotice=="Windows non ha confermato la risoluzione richiesta." {self.launcherNotice=nil}
                            if self.machine?.mixedDisplaysEnabled == true {
                                self.desktopConfirmed=mode;self.readMixedDisplay()
                            }else{self.acceptDisplay(snapshot)}
                            continuation.resume(returning:true)
                        }else if case .success=result {
                            // The monitor notification may complete after the
                            // driver's helper first tries the mode. Apply the
                            // exact raster once its mode set becomes available;
                            // the next read still confirms Windows' actual size.
                            self.bridge.command("display_configure",["width":Int(mode.width),"height":Int(mode.height)],timeout:.seconds(3)){_ in
                                continuation.resume(returning:false)
                            }
                        }else {continuation.resume(returning:false)}
                    }
                }
                if matched {return}
            }
            self.machine?.finishDesktopResolution();self.desktopResizeRequest=nil
            self.launcherNotice="Windows non ha confermato la risoluzione richiesta."
            self.readDisplay()
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
            if self.sharedDisplay?.guestFrame.size != NSSize(width:width,height:height) {
                self.invalidateDisplay("Preparing Windows display…")
            }
            let revision=self.displayRevision
            self.bridge.command("display_configure",["width":width,"height":height],timeout:.seconds(5)){[weak self] result in
                guard let self,self.connected,self.displayEpoch == epoch,self.displaySetupID == setupID else{return}
                self.displaySetupTask=nil
                // Windows broadcasts its mode change while this request is in
                // flight. Read once more instead of publishing an older snapshot.
                guard self.displayRevision == revision else{self.readDisplay();return}
                if case .failure=result {
                    if attempt<2 {self.configureDisplay(width:width,height:height,epoch:epoch,attempt:attempt+1)}
                    else {
                        self.status="Windows could not match the Mac display size.";self.readDisplay()
                        for window in self.windows.values {window.failFrameTransition()}
                    }
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
            if !desktopOnly {machine.synchronizePrimaryDisplay()}
            displayEpoch=value["epoch"] as? String
            invalidateDisplay("Checking Windows display…")
            let capabilities=value["capabilities"] as? [String:Any] ?? [:]
            guestCapabilities=Dictionary(uniqueKeysWithValues:["nativeAppInput","modeFocus","memoryStatus","execute","displayInfo","displayTopology","driverInfo","graphicsInfo","sharedGeometry","appIcon","applicationStatus","processControl","clipboard"].map{($0,capabilities[$0] as? Bool == true)})
            memoryController?.guestReady=guestCapabilities["memoryStatus"] == true
            prepareSharedFolders()
            startApplicationStatusUpdates()
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
            if machine?.mixedDisplaysEnabled == true,mixedDisplayConfiguring {return}
            if machine?.mixedDisplaysEnabled != true {invalidateDisplay("Checking Windows display…")}
            displayReadTask?.cancel()
            displayReadTask=Task{@MainActor [weak self] in
                try? await Task.sleep(for:.milliseconds(250))
                guard !Task.isCancelled,let self else{return}
                self.displayReadTask=nil;self.readDisplay()
            }
        case "windows":
            guard let items=value["windows"] as? [[String:Any]],items.count<=16 else{return}
            let previousMainApps=Set(windows.compactMap{!$0.value.role.transient ? windowApps[$0.key]:nil})
            let currentMainApps=Set(items.compactMap{item->String? in
                guard let role=WindowRole(rawValue:item["role"] as? String ?? "dialog"),!role.transient else{return nil}
                return item["app"] as? String
            })
            for app in previousMainApps.subtracting(currentMainApps) {
                // Retiring the last mirror includes a Desktop transfer and a
                // close in Windows. Neither may leave its launch spinner alive.
                cancelledOpeningApps.insert(app);finishOpening(app,appeared:true)
            }
            let current=Set(items.compactMap{$0["id"] as? String})
            if let notice=windowNotice,!current.contains(notice.id) {
                if launcherNotice==notice.message {launcherNotice=nil}
                windowNotice=nil
            }
            focusWarnedWindows.formIntersection(current)
            windowApps=items.reduce(into:[:]){result,item in
                if let id=item["id"] as? String,let app=item["app"] as? String {result[id]=app}
            }
            let nextActiveApps:Set<String>=Set(items.compactMap{item in
                guard item["role"] as? String != "popup",item["role"] as? String != "tooltip" else{return nil}
                return item["app"] as? String
            })
            if guestCapabilities["applicationStatus"] != true,nextActiveApps != activeApps {activeApps=nextActiveApps}
            receivedWindows.formIntersection(current);failedWindows.formIntersection(current)
            for id in Array(windows.keys) where !current.contains(id){windows.removeValue(forKey:id)?.retire();earlyFrames.removeValue(forKey:id);NativeWindowFrames.shared.retire(window:id)}
            for item in items{
                guard let id=item["id"] as? String,let title=item["title"] as? String else{continue}
                let isolationNotice="Questa app resta visibile anche in Windows. Puoi continuare a usarla."
                if item["macOwned"] as? Bool == true,let failure=item["cloakError"] as? String,!failure.isEmpty {
                    if launcherNotice != isolationNotice {launcherNotice=isolationNotice}
                    windowNotice=(id,isolationNotice,false)
                }else if item["guestIsolated"] as? Bool == true,windowNotice?.id == id,windowNotice?.message == isolationNotice {
                    if launcherNotice == isolationNotice {launcherNotice=nil}
                    windowNotice=nil
                }
                if windows[id]==nil{
                    PipelineTrace.record("app-window-discovered",id,["app":item["app"] ?? "","role":item["role"] ?? ""])
                    let role=WindowRole(rawValue:item["role"] as? String ?? "dialog") ?? .dialog
                    let controller=ApplicationWindow(id:id,title:title,role:role,bridge:bridge)
                    let closeEpoch=displayEpoch
                    controller.onDeviceClose={ [weak self,weak controller] deadline in
                        guard let self,let controller,self.displayEpoch==closeEpoch,
                              self.connected,controller.window.isKeyWindow,let machine=self.machine else {
                            throw CocoaError(.executableRuntimeMismatch)
                        }
                        try await machine.closeForegroundApplication(notAfter:deadline)
                    }
                    controller.onDeviceFocus={ [weak self,weak controller] deadline in
                        guard let self,let controller,self.displayEpoch==closeEpoch,
                              self.connected,controller.window.isKeyWindow,let machine=self.machine else {
                            throw CocoaError(.executableRuntimeMismatch)
                        }
                        try await machine.cycleApplicationFocus(notAfter:deadline)
                    }
                    controller.activateOnFirstShow=openingApps.contains(item["app"] as? String ?? "")
                        && (machine?.desktopIsKey != true || seamlessTransferApps.contains(item["app"] as? String ?? ""))
                    controller.onError={ [weak self] message in
                        self?.status=message;self?.launcherNotice=message;self?.windowNotice=(id,message,false)
                    }
                    controller.onReady={ [weak self] in
                        guard let self else{return}
                        if let app=self.windowApps[id] {self.finishOpening(app,appeared:true)}
                        guard let notice=self.windowNotice,notice.id==id,notice.frame else{return}
                        if self.launcherNotice==notice.message {self.launcherNotice=nil}
                        self.windowNotice=nil
                    }
                    controller.onCloseRequested={ [weak self] in
                        guard let self,let app=self.windowApps[id] else{return}
                        self.cancelledOpeningApps.insert(app)
                        self.finishOpening(app)
                        if self.openingNoticeApp==app {self.launcherNotice=nil;self.openingNoticeApp=nil}
                    }
                    controller.onClose={ [weak self] in self?.windows.removeValue(forKey:id);NativeWindowFrames.shared.retire(window:id) }
                    controller.onGeometry={ [weak self] in self?.layoutChildren() }
                    controller.onPointerExit={ [weak self] in self?.pointerExited(id) }
                    controller.onRecovery={ [weak self] in self?.showWindows() }
                    controller.setDisplayUpdating(displayUpdating && displayReadable)
                    if machine?.mixedDisplaysEnabled == true {controller.setSharedDisplays(sharedDisplays)}
                    else {controller.setSharedDisplay(sharedDisplay)}
                    windows[id]=controller
                }
                if let appID=windowApps[id] {
                    windows[id]?.identifyApplication(name:apps.first(where:{$0.id == appID})?.name ?? "App Windows",icon:applicationIcons[appID])
                }
                windows[id]?.update(item)
                if machine?.mixedDisplaysEnabled == true,machine.desktopIsKey != true,let first=sharedDisplays.first {
                    windows[id]?.placeOnAppDisplayIfNeeded(first)
                }
                if let frame=earlyFrames.removeValue(forKey:id){windows[id]?.present(frame)}
            }
            layoutChildren()
            pumpApplicationIcons()
            if !items.isEmpty,status != "Windows connected" {status="Windows connected"}
        case "frame":
            guard let id=value["window"] as? String else{return}
            receivedWindows.insert(id);failedWindows.remove(id)
            if let window=windows[id]{window.present(packet)}else if earlyFrames.count<16{earlyFrames[id]=packet}
        case "activate":
            if machine?.desktopIsKey != true,let id=value["window"] as? String {windows[id]?.activate()}
        case "seamless_transfer":
            guard let app=value["app"] as? String,openingApps.contains(app),!cancelledOpeningApps.contains(app),
                  let target=value["target"] as? [String:Any] else{return}
            seamlessTransferApps.insert(app)
            recoverDesktopSingleton(app:app,target:target,seamless:true)
        case "desktop_focus":
            guard let app=value["app"] as? String,openingApps.contains(app),!cancelledOpeningApps.contains(app) else{return}
            if let target=value["target"] as? [String:Any] {recoverDesktopSingleton(app:app,target:target)}
            else {finishOpening(app,appeared:true);showWindows()}
        case "launch_state":
            guard let id=value["app"] as? String else{return}
            if value["state"] as? String == "desktop" {
                cancelledOpeningApps.insert(id);finishOpening(id,appeared:true)
            }
            // Waiting/window_available describe the guest's current work;
            // only launch() can create a new host opening request. Readiness
            // still requires the matching window's presented frame.
        case "reply":
            if value["ok"] as? Bool == false,value["operation"] as? String == "input",
               let id=value["window"] as? String,let message=value["message"] as? String {
                windows[id]?.recordInputFailure(message)
            }
            if value["ok"] as? Bool == false,value["operation"] as? String == "input",
               value["message"] as? String == "Windows did not grant this window keyboard focus" {inputFocusFailed()}
        case "window_notice":
            // A recovery warning is not a stopped capture. It can arrive after
            // the first frame on the separate frame connection.
            guard let id=value["window"] as? String,windows[id] != nil else{return}
            launcherNotice=value["message"] as? String
            if let message=launcherNotice {windowNotice=(id,message,false)}
        case "window_error","launch_error":
            if value["type"] as? String == "launch_error",let app=value["app"] as? String,
               cancelledOpeningApps.contains(app) {return}
            if let id=value["window"] as? String {failedWindows.insert(id);windows[id]?.failFrameTransition()}
            refreshApplicationStates()
            // A rejected suggestion is diagnosed per surface in the guest.
            // It does not make its still-running document unavailable.
            if value["type"] as? String == "window_error",value["role"] as? String == "tooltip" {return}
            status=value["message"] as? String ?? "This application is unavailable. Open Desktop Mode."
            launcherNotice=value["message"] as? String ?? "Questa app non è disponibile. Puoi continuare dal desktop Windows."
            if let id=value["window"] as? String,let message=launcherNotice {windowNotice=(id,message,value["type"] as? String == "window_error")}
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
