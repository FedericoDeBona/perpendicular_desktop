import AppKit
import SwiftUI

@MainActor
final class FirstRunInstaller:ObservableObject {
    let directory:URL
    @Published var message="Scegli la ISO di Windows 11 IoT Enterprise LTSC 2024 ARM64. Poi Perpendicular prepara tutto automaticamente."
    @Published var iso:URL?
    @Published var accepted=false
    @Published var busy=false
    @Published var failed=false
    private var window:NSWindow?
    private var poll:Task<Void,Never>?
    private var checking=false
    var prepared:(()->Void)?
    var restart:(()async throws->Void)?
    var ready:(()->Void)?
    var pending:Bool {InstallerState.load(directory)?.phase != "ready"}
    init(directory:URL){self.directory=directory}
    static func needed(_ directory:URL)->Bool {
        !FileManager.default.fileExists(atPath:directory.appendingPathComponent("machine.json").path) ||
        InstallerState.load(directory).map{$0.phase != "ready"} == true
    }
    func show(){
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:620,height:380),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title="Installa Windows con Perpendicular";window.isReleasedWhenClosed=false
        window.contentView=NSHostingView(rootView:FirstRunView(model:self));window.center();window.makeKeyAndOrderFront(nil)
        self.window=window;NSApp.activate(ignoringOtherApps:true)
        if let state=InstallerState.load(directory),state.phase != "ready" {
            busy=true;message="Riprendo la preparazione di Windows. I progressi già salvati vengono conservati."
        }else if let path=ProcessInfo.processInfo.environment["PERPENDICULAR_INSTALL_ISO"],
                 ProcessInfo.processInfo.environment["PERPENDICULAR_INSTALL_ACCEPT_LICENSE"]=="1" {
            iso=URL(fileURLWithPath:path);accepted=true;start()
        }
    }
    func chooseISO(){
        let panel=NSOpenPanel();panel.allowedContentTypes=[.init(filenameExtension:"iso")!];panel.allowsMultipleSelection=false;panel.canChooseDirectories=false
        if panel.runModal() == .OK {iso=panel.url;failed=false}
    }
    func start(){
        guard let iso,accepted,!busy else{return}
        busy=true;failed=false;message="Controllo la ISO e preparo lo spazio per Windows…"
        let directory=directory,contents=Bundle.main.bundleURL.appendingPathComponent("Contents")
        Task { [weak self] in
            do {
                try await Task.detached {try InstallerPreparation.prepare(iso:iso,root:directory,contents:contents)}.value
                guard let self else{return};self.message="Installazione di Windows in corso. Puoi lasciare lavorare Perpendicular; non sono richieste operazioni dentro Windows."
                self.prepared?()
            }catch{self?.failed=true;self?.busy=false;self?.message=error.localizedDescription}
        }
    }
    func started(machine:VirtualMachineController){
        // Only the new installation's optical boot may request a key. Never
        // send boot input to an adopted/running VM or after the first guest hello.
        guard InstallerState.load(directory)?.phase == "installing" else{return}
        Task { [weak self] in
            for _ in 0..<2 {
                try? await Task.sleep(for:.seconds(3))
                guard let self,self.poll == nil,case .running(let pid)=await machine.observedState() else{return}
                let socket=machine.controlSocket,id=machine.configuration.id
                try? await Task.detached {_ = try MachineControl.execute(socket:socket,operation:"send-key",arguments:["keys":[["type":"qcode","data":"ret"]],"hold-time":100],expectedUUID:id,expectedPID:pid)}.value
            }
        }
    }
    func connected(bridge:GuestBridge,machine:VirtualMachineController){
        guard poll==nil,!checking else{return}
        poll=Task { [weak self] in
            guard let self else{return}
            defer{self.poll=nil}
            while !Task.isCancelled,self.pending {
                guard bridge.connected else{return}
                do {
                    self.checking=true
                    let final=InstallerState.load(self.directory)?.phase == "verifying"
                    let args=["-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File","C:\\ProgramData\\Perpendicular\\Setup\\Read-Status.ps1"]+(final ? ["-Final"]:[])
                    let resultData:Data=try await withCheckedThrowingContinuation { continuation in
                        bridge.command("execute",["executable":"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe","args":args,"timeoutSeconds":final ? 45:15],timeout:.seconds(final ? 50:20)){value in
                            switch value {
                            case .success(let reply):
                                do {continuation.resume(returning:try JSONSerialization.data(withJSONObject:reply["value"] as? [String:Any] ?? [:]))}
                                catch {continuation.resume(throwing:error)}
                            case .failure(let error):continuation.resume(throwing:error)
                            }
                        }
                    }
                    self.checking=false
                    let result=try JSONSerialization.jsonObject(with:resultData) as? [String:Any] ?? [:]
                    if result["exitCode"] as? Int == 0,let output=result["stdout"] as? String,
                       let data=output.data(using:.utf8),let report=try JSONSerialization.jsonObject(with:data) as? [String:Any] {
                        if report["phase"] as? String == "failed" {throw InstallerPreparation.failure(report["message"] as? String ?? "Installazione Windows non riuscita.")}
                        if let phase=report["phase"] as? String,["base-installed","installed"].contains(phase),var state=InstallerState.load(self.directory) {
                            if state.phase == "installing" || state.phase == "configuring" {
                                self.message="Componenti installati. Riavvio Windows e verifico che sia tutto pronto…"
                                try await machine.shutdown()
                                let deadline=Date().addingTimeInterval(90)
                                while await machine.observedState() != .stopped,Date()<deadline {try await Task.sleep(for:.milliseconds(500))}
                                guard await machine.observedState() == .stopped else{throw InstallerPreparation.failure("Windows non ha ancora terminato il riavvio. Riapri Perpendicular per riprendere.")}
                                let path=self.directory.appendingPathComponent("machine.json")
                                var configuration=try JSONSerialization.jsonObject(with:Data(contentsOf:path)) as! [String:Any]
                                configuration.removeValue(forKey:"installationISO");configuration.removeValue(forKey:"installationAnswer");configuration.removeValue(forKey:"installationSoftwareCPU")
                                configuration["graphics"]="native3D";configuration["mixedDisplays"]=true
                                if phase == "installed" {configuration["dynamicMemory"]=["hotplugMiB":min(4096,max(128,Int(ProcessInfo.processInfo.physicalMemory/1_048_576)-4096)),"backgroundMiB":1024,"reserveMiB":512]}
                                try JSONSerialization.data(withJSONObject:configuration,options:[.prettyPrinted,.sortedKeys]).write(to:path,options:.atomic)
                                state.phase=phase == "base-installed" ? "configuring":"verifying";try state.save(self.directory)
                                try await self.restart?();return
                            }
                            if state.phase == "verifying",report["verified"] as? Bool == true {
                                // This directory and ISO contain generated setup credentials.
                                // They belong only to this new installation and are now detached.
                                for name in ["InstallationMedia","installation-answer.iso","installation-windows.iso"] {
                                    let file=self.directory.appendingPathComponent(name)
                                    if FileManager.default.fileExists(atPath:file.path){try FileManager.default.removeItem(at:file)}
                                }
                                state.phase="ready";try state.save(self.directory)
                                self.message="Windows è pronto.";self.window?.close();self.ready?();return
                            }
                        }
                    }
                }catch {
                    self.checking=false
                    if !bridge.connected {return}
                    self.message="La preparazione richiede attenzione: "+error.localizedDescription
                    self.failed=true;return
                }
                try? await Task.sleep(for:.seconds(3))
            }
        }
    }
}

@MainActor
private struct FirstRunView:View {
    @ObservedObject var model:FirstRunInstaller
    var body:some View {
        VStack(alignment:.leading,spacing:20){
            Label("Windows, pronto nel tuo Mac",systemImage:"desktopcomputer").font(.system(size:23,weight:.semibold))
            Text(model.message).font(.system(size:14)).fixedSize(horizontal:false,vertical:true)
            if model.busy {ProgressView().controlSize(.small)}else{
                Button(model.iso?.lastPathComponent ?? "Scegli la ISO di Windows…"){model.chooseISO()}.lineLimit(1)
                Toggle("Accetto i termini di licenza di Windows per la ISO scelta.",isOn:$model.accepted).font(.system(size:12))
                Text("La licenza Windows deve essere valida per il tuo utilizzo. La ISO e Windows non sono inclusi nella release.").font(.system(size:11)).foregroundStyle(.secondary)
                Button("Installa Windows"){model.start()}.buttonStyle(.borderedProminent).disabled(model.iso==nil || !model.accepted)
            }
            if model.failed {Text("I dati esistenti sono conservati. Puoi riaprire Perpendicular per riprendere.").font(.system(size:12)).foregroundStyle(.secondary)}
            Spacer(minLength:0)
        }.padding(30).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
    }
}
