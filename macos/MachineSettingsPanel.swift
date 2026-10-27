import SwiftUI

extension Notification.Name {
    static let launcherShowSettings=Notification.Name("PerpendicularLauncherShowSettings")
}

@MainActor
struct MachineSettingsPanel:View {
    @ObservedObject var model:ApplicationModel
    @State private var draft=MachineSettings(cpus:1,initialMemoryMiB:2048,automaticMemory:true,maximumMemoryMiB:4096,backgroundMemoryMiB:1536,reserveMemoryMiB:512)
    @State private var advanced=false
    private func number(_ key:WritableKeyPath<MachineSettings,Int>)->Binding<Int>{
        Binding(get:{draft[keyPath:key]},set:{draft[keyPath:key]=$0;model.settingsNotice=nil})
    }
    private func memory(_ value:Int)->String {
        value%1024 == 0 ? "\(value/1024) GB":"\(value) MB"
    }
    private func choices(from minimum:Int,through maximum:Int,current:Int)->[Int]{
        Array(Set([1024,1536,2048,3072,4096,6144,8192,12288,16384,current].filter{minimum...maximum ~= $0})).sorted()
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
                            Picker("Processori",selection:number(\.cpus)){
                                ForEach(1...MachineSettings.cpuLimit,id:\.self){Text("\($0)").tag($0)}
                            }
                        }.padding(12)
                    }label:{Label("Processori",systemImage:"cpu")}
                    GroupBox {
                        VStack(alignment:.leading,spacing:16){
                            Picker("RAM massima",selection:number(\.maximumMemoryMiB)){
                                ForEach(choices(from:draft.initialMemoryMiB,through:min(MachineSettings.memoryLimitMiB,draft.initialMemoryMiB+8192),current:draft.maximumMemoryMiB),id:\.self){Text(memory($0)).tag($0)}
                            }
                            Text(draft.maximumMemoryMiB == draft.initialMemoryMiB ? "Windows usa una quantità fissa di RAM." : "È il limite totale della RAM di Windows, inclusa quella iniziale. Perpendicular aggiunge e restituisce memoria automaticamente.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("La VM usa anche memoria per grafica e servizi: il consumo complessivo sul Mac può essere superiore a questo limite.")
                                .font(.caption).foregroundStyle(.secondary)
                            if draft.maximumMemoryMiB == draft.initialMemoryMiB {
                                Text("Con il massimo uguale alla RAM iniziale, la memoria rimane fissa.").font(.caption).foregroundStyle(.secondary)
                            }
                            DisclosureGroup("Avanzate",isExpanded:$advanced){
                                VStack(alignment:.leading,spacing:10){
                                    Picker("RAM all’avvio",selection:number(\.initialMemoryMiB)){
                                        ForEach(choices(from:max(1024,draft.maximumMemoryMiB-8192),through:draft.maximumMemoryMiB,current:draft.initialMemoryMiB),id:\.self){Text(memory($0)).tag($0)}
                                    }
                                    Text("Quantità con cui Windows si avvia prima che la gestione automatica sia disponibile.").font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.top,10)
                            }
                        }.padding(12)
                    }label:{Label("Memoria",systemImage:"memorychip")}
                    if let current=model.currentVMSettings {
                        GroupBox {
                            VStack(spacing:12){
                                LabeledContent("Windows",value:model.machineStateLabel)
                                LabeledContent("RAM all’avvio",value:memory(current.initialMemoryMiB))
                                LabeledContent("RAM massima",value:memory(current.automaticMemory ? current.maximumMemoryMiB:current.initialMemoryMiB))
                                if model.vmMemoryState["ready"] as? Bool == true {
                                    Divider()
                                    if let value=model.vmMemoryState["actualMiB"] as? UInt64 {LabeledContent("RAM assegnata",value:memory(Int(value)))}
                                    if let value=model.vmMemoryState["guestAvailableMiB"] as? UInt64 {LabeledContent("Disponibile in Windows",value:memory(Int(value)))}
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
