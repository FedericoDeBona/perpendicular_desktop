import SwiftUI

extension Notification.Name {
    static let launcherShowSettings=Notification.Name("PerpendicularLauncherShowSettings")
}

@MainActor
struct MachineSettingsPanel:View {
    @ObservedObject var model:ApplicationModel
    @State private var page=Page.general
    @State private var advanced=false
    private enum Page:String,CaseIterable,Identifiable {
        case general="Generali",system="Sistema",sharing="Condivisione"
        var id:Self {self}
    }
    private func number(_ key:WritableKeyPath<MachineSettings,Int>)->Binding<Int>{
        Binding(get:{model.vmSettings?[keyPath:key] ?? 0},set:{value in
            guard var settings=model.vmSettings else{return}
            settings[keyPath:key]=value;model.saveVMSettings(settings)
        })
    }
    private func folder(_ kind:SharedFolderKind)->Binding<Bool>{
        Binding(get:{model.vmSettings?.shares(kind) ?? false},set:{value in
            guard var settings=model.vmSettings else{return}
            settings.setShared(kind,enabled:value);model.saveVMSettings(settings)
        })
    }
    private func memory(_ value:Int)->String {value%1024 == 0 ? "\(value/1024) GB":"\(value) MB"}
    private func choices(from minimum:Int,through maximum:Int,current:Int)->[Int]{
        Array(Set([1024,1536,2048,3072,4096,6144,8192,12288,16384,current].filter{minimum...maximum ~= $0})).sorted()
    }
    var body:some View {
        VStack(spacing:0){
            Picker("Sezione",selection:$page){ForEach(Page.allCases){Text($0.rawValue).tag($0)}}
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal,28).padding(.vertical,18)
            ScrollView {
                VStack(alignment:.leading,spacing:16){
                    if page != .general && !model.canEditVMSettings {
                        Label("Spegni Windows per modificare queste impostazioni.",systemImage:"lock")
                            .font(.system(size:12)).foregroundStyle(.secondary)
                    }
                    switch page {
                    case .general:general
                    case .sharing:if model.vmSettings != nil {sharing}else{unavailable}
                    case .system:if let settings=model.vmSettings {system(settings)}else{unavailable}
                    }
                    if model.settingsFailed,let notice=model.settingsNotice {
                        Text(notice).font(.system(size:12)).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }.frame(maxWidth:620,alignment:.leading).padding(.horizontal,28).padding(.top,6).padding(.bottom,24)
                    .frame(maxWidth:.infinity)
            }
        }
    }
    private var unavailable:some View {Text("Impostazioni di Windows non disponibili.").foregroundStyle(.secondary)}
    private func card<Content:View>(@ViewBuilder content:()->Content)->some View {
        VStack(alignment:.leading,spacing:0,content:content)
            .padding(16).frame(maxWidth:.infinity,alignment:.leading)
            .background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:14))
            .overlay(RoundedRectangle(cornerRadius:14).strokeBorder(Color.primary.opacity(0.06)))
    }
    private var general:some View {
        card {
            HStack {
                Label("Tema",systemImage:"circle.lefthalf.filled").font(.system(size:13,weight:.medium))
                Spacer()
                Picker("Tema",selection:Binding(get:{model.launcherAppearance},set:model.setLauncherAppearance)){
                    ForEach(LauncherAppearance.allCases){Text($0.title).tag($0)}
                }.labelsHidden().pickerStyle(.segmented).frame(width:240)
            }
        }
    }
    private var sharing:some View {
        VStack(alignment:.leading,spacing:12){
            card {
                ForEach(Array(SharedFolderKind.allCases.enumerated()),id:\.element.id){index,kind in
                    if index>0 {Divider().padding(.vertical,6)}
                    Toggle(isOn:folder(kind)){
                        Label(kind.title,systemImage:kind.icon).frame(maxWidth:.infinity,alignment:.leading)
                    }.toggleStyle(.switch).controlSize(.mini).accessibilityIdentifier("shared-folder-"+kind.rawValue)
                }
            }.disabled(!model.canEditVMSettings)
            if model.folderIntegrationFailed {
                Button("Riprova collegamento"){model.prepareSharedFolders()}.disabled(!model.connected || model.folderIntegrationBusy).help(model.folderIntegrationStatus)
            }
        }
    }
    private func system(_ settings:MachineSettings)->some View {
        card {
            HStack {
                Label("Processori",systemImage:"cpu")
                Spacer()
                Picker("Processori",selection:number(\.cpus)){
                    ForEach(1...MachineSettings.cpuLimit,id:\.self){Text("\($0)").tag($0)}
                }.labelsHidden().frame(width:110)
            }
            Divider().padding(.vertical,14)
            HStack {
                Label("RAM massima",systemImage:"memorychip")
                Spacer()
                Picker("RAM massima",selection:number(\.maximumMemoryMiB)){
                    ForEach(choices(from:settings.initialMemoryMiB,through:min(MachineSettings.memoryLimitMiB,settings.initialMemoryMiB+8192),current:settings.maximumMemoryMiB),id:\.self){Text(memory($0)).tag($0)}
                }.labelsHidden().frame(width:110)
            }
            Divider().padding(.vertical,14)
            DisclosureGroup("Avanzate",isExpanded:$advanced){
                HStack {
                    Text("RAM all’avvio")
                    Spacer()
                    Picker("RAM all’avvio",selection:number(\.initialMemoryMiB)){
                        ForEach(choices(from:max(1024,settings.maximumMemoryMiB-8192),through:settings.maximumMemoryMiB,current:settings.initialMemoryMiB),id:\.self){Text(memory($0)).tag($0)}
                    }.labelsHidden().frame(width:110)
                }.padding(.top,12)
            }.font(.system(size:12))
        }.font(.system(size:13)).disabled(!model.canEditVMSettings)
    }
}
