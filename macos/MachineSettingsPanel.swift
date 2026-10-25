import SwiftUI

extension Notification.Name {
    static let launcherShowSettings=Notification.Name("PerpendicularLauncherShowSettings")
}

@MainActor
struct MachineSettingsPanel:View {
    @ObservedObject var model:ApplicationModel
    @State private var draft=MachineSettings(cpus:1,initialMemoryMiB:2048,automaticMemory:true,maximumMemoryMiB:4096,backgroundMemoryMiB:1536,reserveMemoryMiB:512)
    private func number(_ key:WritableKeyPath<MachineSettings,Int>)->Binding<Int>{
        Binding(get:{draft[keyPath:key]},set:{draft[keyPath:key]=$0;model.settingsNotice=nil})
    }
    private func memory(_ value:Int)->String {
        value%1024 == 0 ? "\(value/1024) GB":"\(value) MB"
    }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22){
                if model.vmSettings != nil {
                    Text("Le modifiche si applicano al prossimo avvio di Windows.")
                        .font(.system(size:13)).foregroundStyle(.secondary)
                    if model.settingsPending {
                        Label("Modifiche salvate per il prossimo avvio",systemImage:"clock")
                            .font(.system(size:13,weight:.medium)).foregroundStyle(.indigo)
                    }
                    GroupBox {
                        VStack(alignment:.leading,spacing:16){
                            Stepper(value:number(\.cpus),in:1...MachineSettings.cpuLimit){LabeledContent("Processori",value:"\(draft.cpus)")}
                            Divider()
                            Stepper(value:number(\.initialMemoryMiB),in:1024...MachineSettings.memoryLimitMiB,step:128){
                                LabeledContent("RAM all’avvio",value:memory(draft.initialMemoryMiB))
                            }
                            Text("Puoi scegliere 1 GB (1024 MB) per la tua prova. L’avvio con questa quantità non è ancora stato verificato su questa VM.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(12)
                    }label:{Label("Avvio",systemImage:"power")}
                    GroupBox {
                        VStack(alignment:.leading,spacing:16){
                            Toggle("RAM automatica",isOn:$draft.automaticMemory)
                            Text("Aggiunge memoria quando serve e cerca di restituirla al Mac in background.")
                                .font(.caption).foregroundStyle(.secondary)
                            if draft.automaticMemory {
                                Divider()
                                Stepper(value:number(\.maximumMemoryMiB),in:1152...MachineSettings.memoryLimitMiB,step:128){
                                    LabeledContent("Limite RAM",value:memory(draft.maximumMemoryMiB))
                                }
                                Stepper(value:number(\.backgroundMemoryMiB),in:1024...MachineSettings.memoryLimitMiB,step:128){
                                    LabeledContent("Minimo in background",value:memory(draft.backgroundMemoryMiB))
                                }
                                Stepper(value:number(\.reserveMemoryMiB),in:256...2048,step:128){
                                    LabeledContent("Riserva disponibile",value:memory(draft.reserveMemoryMiB))
                                }
                                Text("Il limite include la RAM iniziale. Il minimo è un obiettivo: Windows può trattenere memoria ancora in uso. La riserva lascia spazio alle nuove richieste delle app.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(12)
                    }label:{Label("Memoria",systemImage:"memorychip")}
                    if let current=model.currentVMSettings {
                        GroupBox {
                            VStack(spacing:12){
                                LabeledContent("Windows",value:model.machineStateLabel)
                                LabeledContent("Processori configurati",value:"\(current.cpus)")
                                LabeledContent("RAM iniziale configurata",value:memory(current.initialMemoryMiB))
                                if model.vmMemoryState["ready"] as? Bool == true {
                                    Divider()
                                    if let value=model.vmMemoryState["actualMiB"] as? UInt64 {LabeledContent("RAM assegnata",value:memory(Int(value)))}
                                    if let value=model.vmMemoryState["guestAvailableMiB"] as? UInt64 {LabeledContent("Disponibile in Windows",value:memory(Int(value)))}
                                    if let value=model.vmMemoryState["pluggedMiB"] as? UInt64 {LabeledContent("RAM aggiunta",value:memory(Int(value)))}
                                    if let value=model.vmMemoryState["balloonMiB"] as? UInt64 {LabeledContent("Nel balloon",value:memory(Int(value)))}
                                    if model.vmMemoryState["pending"] as? Bool == true {Text("Adattamento della memoria in corso").font(.caption).foregroundStyle(.secondary)}
                                }else if current.automaticMemory {
                                    Text(model.vmMemoryState["error"] as? String ?? "I valori della memoria saranno disponibili quando Windows sarà collegato.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(12)
                        }label:{Label("Stato attuale",systemImage:"gauge.with.dots.needle.33percent")}
                    }
                    if let notice=model.settingsNotice {Text(notice).font(.system(size:13)).foregroundStyle(model.settingsFailed ? Color.orange:Color.secondary).textSelection(.enabled)}
                    HStack {
                        Button("Ripristina valori salvati"){if let settings=model.vmSettings {draft=settings};model.settingsNotice=nil}
                            .disabled(draft == model.vmSettings)
                        Spacer()
                        Button("Salva per il prossimo avvio"){model.saveVMSettings(draft)}.buttonStyle(.borderedProminent)
                            .disabled(draft == model.vmSettings || model.machineOperation != nil)
                    }
                    Text("Per applicarle, spegni Windows e poi avvialo. Il salvataggio non interrompe le app aperte.")
                        .font(.caption).foregroundStyle(.secondary)
                }else{Text("Impostazioni della VM non disponibili.").foregroundStyle(.secondary)}
            }.padding(.horizontal,32).padding(.bottom,32)
        }
        .onAppear{if let settings=model.vmSettings {draft=settings}}
        .onChange(of:model.vmSettings){_,settings in if let settings {draft=settings}}
    }
}
