import SwiftUI

struct GuestProcess:Identifiable {
    let pid:Int
    let creation:String
    let name:String
    let canTerminate:Bool
    var id:String {"\(pid):\(creation)"}
    init?(_ row:[String:Any]) {
        guard let pid=row["pid"] as? Int,pid>0,pid<=Int(UInt32.max),
              let creation=row["creation"] as? String,UInt64(creation) != nil,
              let name=row["name"] as? String,name.utf8.count<=32768 else{return nil}
        self.pid=pid;self.creation=creation;self.name=name;canTerminate=row["canTerminate"] as? Bool == true
    }
}
struct GuestApplicationState {
    struct Window {let id:String;let stopped:Bool}
    let id:String
    let activationPending:Bool
    let processes:Set<String>
    let windows:[Window]
    var running:Bool {!processes.isEmpty}
    init?(_ row:[String:Any]) {
        guard let id=row["app"] as? String,id.utf8.count==64,
              let processes=row["processes"] as? [[String:Any]],processes.count<=16,
              let windows=row["windows"] as? [[String:Any]],windows.count<=16 else{return nil}
        self.id=id;activationPending=row["activationPending"] as? Bool == true
        self.processes=Set(processes.compactMap{row in
            guard let pid=row["pid"] as? Int,let creation=row["creation"] as? String else{return nil}
            return "\(pid):\(creation)"
        })
        self.windows=windows.compactMap{row in
            guard let id=row["id"] as? String else{return nil}
            return Window(id:id,stopped:row["captureStopped"] as? Bool != false)
        }
    }
}

@MainActor
struct GuestProcessesPanel:View {
    @ObservedObject var model:ApplicationModel
    @Environment(\.dismiss) private var dismiss
    @State private var search=""
    private var rows:[GuestProcess] {
        model.guestProcesses.filter{process in
            let matches=model.processFilterApp.map{model.applicationStates[$0]?.processes.contains(process.id) == true} ?? true
            return matches && (search.isEmpty || process.name.localizedStandardContains(search) || String(process.pid).contains(search))
        }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16){
            HStack{
                VStack(alignment:.leading,spacing:5){
                    Text("Processi Windows").font(.title2.bold())
                    Text("Processi del tuo utente nella sessione collegata.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Aggiorna",action:model.refreshProcesses).disabled(!model.connected || model.processesLoading)
                Button("Fine"){dismiss()}.keyboardShortcut(.cancelAction)
            }
            if let app=model.processFilterApp {
                HStack{
                    Text(model.apps.first(where:{$0.id == app})?.name ?? "App selezionata")
                    Text(model.applicationStateLabel(app)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Tutti i processi"){model.processFilterApp=nil}
                }
            }
            TextField("Cerca nome o PID",text:$search).textFieldStyle(.roundedBorder)
            if let notice=model.processNotice {Text(notice).foregroundStyle(.orange).textSelection(.enabled)}
            if !model.connected {Text("Windows non è collegato. Lo stato dei processi non è disponibile.")}
            List(rows){process in
                HStack(spacing:14){
                    VStack(alignment:.leading,spacing:3){
                        Text(process.name).fontWeight(.medium)
                        Text("PID \(process.pid)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.terminatingProcesses.contains(process.id) {ProgressView().controlSize(.small)}
                    Button("Termina…"){model.terminateProcess(process)}.buttonStyle(.bordered)
                        .disabled(!model.connected || !process.canTerminate || model.terminatingProcesses.contains(process.id))
                        .help(process.canTerminate ? "Termina questo processo Windows":"Processo protetto")
                        .accessibilityLabel("Termina \(process.name), PID \(process.pid)")
                }.padding(.vertical,4).accessibilityElement(children:.contain)
            }.overlay{if rows.isEmpty {Text(model.processesLoading ? "Lettura processi…":"Nessun processo corrispondente").foregroundStyle(.secondary)}}
            Text("La terminazione può perdere i dati non salvati. Per una chiusura normale usa Chiudi finestre dal menu dell’app.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width:680,height:530)
        .task{
            while !Task.isCancelled {
                model.refreshProcesses()
                do {try await Task.sleep(for:.seconds(3))}catch{return}
            }
        }
    }
}
