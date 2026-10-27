import AppKit
import SwiftUI

extension Notification.Name {
    static let launcherFocusSearch=Notification.Name("PerpendicularLauncherFocusSearch")
}

enum LauncherAppearance:String,CaseIterable,Identifiable {
    case system,light,dark
    var id:Self {self}
    var title:String {switch self {case .system:"Sistema";case .light:"Chiaro";case .dark:"Scuro"}}
    var native:NSAppearance? {switch self {case .system:nil;case .light:NSAppearance(named:.aqua);case .dark:NSAppearance(named:.darkAqua)}}
    var scheme:ColorScheme? {switch self {case .system:nil;case .light:.light;case .dark:.dark}}
}

struct LauncherWindowsStatus {
    enum Kind {case off,connected,busy,attention,graphics,disconnected,unknown}
    let kind:Kind
    let title:String
    let detail:String
    var symbol:String {switch kind {
        case .off:"circle";case .connected:"checkmark.circle.fill";case .busy:"circle.dotted"
        case .attention,.graphics:"exclamationmark.triangle.fill";case .disconnected:"network.slash";case .unknown:"questionmark.circle"
    }}
    var color:Color {switch kind {
        case .off,.unknown:.secondary;case .connected:.green;case .busy,.attention,.disconnected:.orange;case .graphics:.red
    }}
}

/// A single native backdrop; no timers or frame-driven effects.
@MainActor
private struct LauncherGlass:NSViewRepresentable {
    func makeNSView(context:Context)->NSVisualEffectView {
        let view=NSVisualEffectView()
        view.material = .hudWindow;view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view:NSVisualEffectView,context:Context){}
}

@MainActor
struct Launcher:View {
    @ObservedObject var model:ApplicationModel
    @Environment(\.colorScheme) private var scheme
    @State private var search=""
    @State private var settings=false
    @State private var statusOpen=false
    @State private var selection:String?
    @FocusState private var searchFocused:Bool
    private var query:String {search.trimmingCharacters(in:.whitespacesAndNewlines)}
    private var sections:(favorites:[WindowsApplication],recent:[WindowsApplication],remaining:[WindowsApplication]) {model.launcherPreferences.sections(model.apps)}
    private var results:[WindowsApplication] {model.apps.filter{$0.matches(query)}}
    private var navigation:[WindowsApplication] {query.isEmpty ? sections.favorites+sections.recent+sections.remaining:results}
    private var highlight:Color {Color.primary.opacity(scheme == .dark ? 0.075:0.055)}
    var body:some View {
        VStack(spacing:0){
            Text("Perpendicular").font(.system(size:11,weight:.medium)).foregroundStyle(.tertiary)
                .frame(maxWidth:.infinity).frame(height:35).allowsHitTesting(false)
            if settings {
                HStack(spacing:12){
                    Button{showApps()}label:{Image(systemName:"arrow.left").frame(width:28,height:28)}
                        .buttonStyle(.plain).help("Torna alle app").accessibilityLabel("Torna alle app")
                    Text("Impostazioni").font(.system(size:23,weight:.medium)).tracking(-0.5)
                    Spacer()
                }.padding(.horizontal,22).padding(.vertical,14)
                Divider().opacity(0.6)
                HStack {
                    Label("Aspetto",systemImage:"circle.lefthalf.filled").font(.system(size:13))
                    Spacer()
                    Picker("Tema",selection:Binding(get:{model.launcherAppearance},set:model.setLauncherAppearance)){
                        ForEach(LauncherAppearance.allCases){Text($0.title).tag($0)}
                    }.pickerStyle(.segmented).frame(width:240)
                }.padding(.horizontal,32).padding(.vertical,22)
                MachineSettingsPanel(model:model)
            }else{
                searchField
                Divider().opacity(0.65)
                catalogue
            }
            Divider().opacity(0.65)
            statusBar
        }
        .background(scheme == .dark ? Color.black.opacity(0.32):Color.white.opacity(0.23))
        .background(LauncherGlass())
        .overlay(alignment:.top){LinearGradient(colors:[.white.opacity(scheme == .dark ? 0.13:0.7),.clear],startPoint:.top,endPoint:.bottom).frame(height:1).allowsHitTesting(false)}
        .frame(minWidth:540,minHeight:480)
        .ignoresSafeArea()
        .preferredColorScheme(model.launcherAppearance.scheme)
        .background(Button(""){showApps()}.keyboardShortcut("f",modifiers:.command).hidden())
        .onAppear{searchFocused=true;resetSelection()}
        .onChange(of:search){_,_ in resetSelection()}
        .onChange(of:model.apps.map(\.id)){_,_ in resetSelection()}
        .onChange(of:model.launcherPreferences.pinned){_,_ in resetSelection()}
        .onReceive(NotificationCenter.default.publisher(for:.launcherFocusSearch)){_ in showApps()}
        .onReceive(NotificationCenter.default.publisher(for:.launcherShowSettings)){_ in showSettings()}
        .onExitCommand{if settings {showApps()}else if !search.isEmpty {search=""}}
    }
    private func showApps(){settings=false;searchFocused=true}
    private func showSettings(){settings=true;statusOpen=false;search="";searchFocused=false}
    private func resetSelection(){selection=navigation.first?.id}
    private func moveSelection(_ delta:Int){
        let apps=navigation;guard !apps.isEmpty else{return}
        let index=apps.firstIndex{$0.id==selection} ?? 0
        selection=apps[(index+delta+apps.count)%apps.count].id
    }
    private var searchField:some View {
        HStack(spacing:17){
            Image(systemName:"magnifyingglass").font(.system(size:23,weight:.light)).foregroundStyle(.secondary)
            TextField("Cerca un’app…",text:$search).textFieldStyle(.plain).font(.system(size:27,weight:.regular)).tracking(-0.5)
                .focused($searchFocused).accessibilityLabel("Cerca app Windows")
                .onSubmit{if let app=navigation.first(where:{$0.id==selection}) ?? navigation.first {model.launch(app)}}
                .onKeyPress(.downArrow){moveSelection(1);return .handled}
                .onKeyPress(.upArrow){moveSelection(-1);return .handled}
            if !search.isEmpty {
                Button{search="";searchFocused=true}label:{Image(systemName:"xmark.circle.fill").foregroundStyle(.tertiary)}
                    .buttonStyle(.plain).accessibilityLabel("Cancella ricerca")
            }
        }.padding(.horizontal,28).padding(.top,13).padding(.bottom,25)
    }
    private var catalogue:some View {
        ScrollViewReader {proxy in
            ScrollView {
                VStack(alignment:.leading,spacing:24){
                    if query.isEmpty {
                        appSection("Preferiti",apps:sections.favorites,tiles:true)
                        appSection("Recenti",apps:sections.recent)
                        appSection("Altre app",apps:sections.remaining)
                    }else{appSection("Risultati",apps:results)}
                    if model.catalogueLoading {ProgressView().controlSize(.small).frame(maxWidth:.infinity).padding(12)}
                }.padding(.horizontal,16).padding(.top,22).padding(.bottom,24)
            }
            .onChange(of:selection){_,id in if let id {proxy.scrollTo(id,anchor:nil)}}
        }
    }
    @ViewBuilder private func appSection(_ title:String,apps:[WindowsApplication],tiles:Bool=false)->some View {
        VStack(alignment:.leading,spacing:9){
            Text(title).font(.system(size:11,weight:.medium)).foregroundStyle(.secondary).padding(.horizontal,12)
            if apps.isEmpty {
                Text(tiles ? "Aggiungi qui le tue app con la stella.":(title == "Recenti" ? "Qui ritrovi le app aperte di recente.":"Nessuna app trovata."))
                    .font(.system(size:12)).foregroundStyle(.secondary).padding(.horizontal,12).padding(.vertical,14)
            }else if tiles {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:112,maximum:170),spacing:8)],alignment:.leading,spacing:8){
                    ForEach(apps){app in favoriteTile(app).id(app.id)}
                }
            }else{
                LazyVStack(spacing:2){ForEach(apps){app in appRow(app).id(app.id)}}
            }
        }
    }
    private func favoriteTile(_ app:WindowsApplication)->some View {
        LauncherFavoriteTile(app:app,icon:model.applicationIcons[app.id],opening:model.openingApps.contains(app.id),active:model.activeApps.contains(app.id),enabled:model.connected && model.machineOperation == nil,selected:selection==app.id,highlight:highlight,launch:{model.launch(app)},unpin:{model.togglePin(app)})
            .contextMenu{appMenu(app)}
            .onAppear{model.applicationBecameVisible(app)}.onDisappear{model.applicationBecameHidden(app)}
    }
    private func appRow(_ app:WindowsApplication)->some View {
        LauncherAppRow(app:app,icon:model.applicationIcons[app.id],opening:model.openingApps.contains(app.id),active:model.activeApps.contains(app.id),enabled:model.connected && model.machineOperation == nil,selected:selection==app.id,highlight:highlight,launch:{model.launch(app)},pin:{model.togglePin(app)},pinned:model.launcherPreferences.pinned.contains(app.id))
            .contextMenu{appMenu(app)}
            .onAppear{model.applicationBecameVisible(app)}.onDisappear{model.applicationBecameHidden(app)}
    }
    @ViewBuilder private func appMenu(_ app:WindowsApplication)->some View {
        Button(model.launcherPreferences.pinned.contains(app.id) ? "Rimuovi dai preferiti":"Aggiungi ai preferiti"){model.togglePin(app)}
        Button("Chiudi finestre"){model.closeApplication(app)}.disabled(!model.activeApps.contains(app.id))
    }
    private var statusBar:some View {
        HStack(spacing:12){
            Button{statusOpen.toggle()}label:{
                Image(systemName:model.launcherWindowsStatus.symbol).font(.system(size:13,weight:.medium))
                    .foregroundStyle(model.launcherWindowsStatus.color).frame(width:28,height:28).contentShape(Rectangle())
            }.buttonStyle(.plain).help(model.launcherWindowsStatus.title+(model.launcherNotice.map{" · "+$0} ?? ""))
                .accessibilityLabel(model.launcherWindowsStatus.title).accessibilityIdentifier("launcher-windows-status")
                .popover(isPresented:$statusOpen,arrowEdge:.bottom){statusDetails}
            Divider().frame(height:14)
            Button(action:model.showWindows){Label("Desktop Windows",systemImage:"macwindow").font(.system(size:11))}
                .buttonStyle(.plain).foregroundStyle(.secondary).disabled(!model.desktopAvailable || model.machineOperation != nil)
            Spacer(minLength:10)
            if model.catalogueLoading {ProgressView().controlSize(.mini)}
            Button{model.refresh()}label:{Image(systemName:"arrow.clockwise").font(.system(size:12)).frame(width:25,height:28)}
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Aggiorna app").accessibilityLabel("Aggiorna app")
                .disabled(!model.connected || model.catalogueLoading)
            Button{settings ? showApps():showSettings()}label:{Image(systemName:"slider.horizontal.3").font(.system(size:13)).frame(width:28,height:28)}
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Impostazioni · ⌘,").accessibilityLabel("Impostazioni")
        }.padding(.horizontal,16).frame(height:46).background(Color.primary.opacity(0.025))
    }
    private var statusDetails:some View {
        VStack(alignment:.leading,spacing:12){
            Label(model.launcherWindowsStatus.title,systemImage:model.launcherWindowsStatus.symbol).font(.system(size:13,weight:.medium))
            Text(model.launcherWindowsStatus.detail).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if let notice=model.launcherNotice {
                Divider()
                Text(notice).font(.system(size:12)).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                Button("Chiudi avviso"){model.launcherNotice=nil}.font(.system(size:12))
            }
            Divider()
            Button("Accendi Windows",action:model.startWindows).disabled(!model.canStartWindows)
            Button("Spegni Windows",action:model.shutdownWindows).disabled(!model.canStopWindows)
            Menu("Altre azioni"){
                Button("Arresto forzato…",role:.destructive,action:model.forceStopWindows).disabled(!model.canStopWindows)
            }.menuStyle(.borderlessButton)
        }.padding(18).frame(width:310)
    }
}

@MainActor
private struct LauncherAppIcon:View {
    let icon:NSImage?
    let size:CGFloat
    var body:some View {
        Group {
            if let icon {Image(nsImage:icon).resizable().interpolation(.high).scaledToFit()}
            else {Image(systemName:"app.dashed").resizable().scaledToFit().foregroundStyle(.tertiary).padding(size*0.12)}
        }.frame(width:size,height:size).accessibilityHidden(true)
    }
}

@MainActor
private struct LauncherFavoriteTile:View {
    let app:WindowsApplication
    let icon:NSImage?
    let opening:Bool
    let active:Bool
    let enabled:Bool
    let selected:Bool
    let highlight:Color
    let launch:()->Void
    let unpin:()->Void
    @State private var hovered=false
    var body:some View {
        ZStack(alignment:.topTrailing){
            Button(action:launch){
                VStack(spacing:12){
                    ZStack(alignment:.bottomTrailing){
                        LauncherAppIcon(icon:icon,size:40)
                        if opening {ProgressView().controlSize(.mini).padding(3).background(.regularMaterial,in:Circle()).offset(x:6,y:4)}
                        else if active {Circle().fill(.green).frame(width:6,height:6).offset(x:4,y:2)}
                    }
                    Text(app.name).font(.system(size:12)).lineLimit(1).truncationMode(.tail).frame(maxWidth:.infinity)
                }.padding(.horizontal,8).padding(.top,18).padding(.bottom,15).contentShape(RoundedRectangle(cornerRadius:11))
            }.buttonStyle(.plain).disabled(!enabled || opening).accessibilityLabel("Apri "+app.name).help(app.name)
            Button(action:unpin){Image(systemName:"xmark").font(.system(size:9,weight:.medium)).frame(width:25,height:25).contentShape(Rectangle())}
                .buttonStyle(.plain).foregroundStyle(.secondary).opacity(hovered ? 1:0.2)
                .help("Rimuovi dai preferiti").accessibilityLabel("Rimuovi dai preferiti: "+app.name)
        }.background(hovered || selected ? highlight:.clear,in:RoundedRectangle(cornerRadius:11)).onHover{hovered=$0}
    }
}

@MainActor
private struct LauncherAppRow:View {
    let app:WindowsApplication
    let icon:NSImage?
    let opening:Bool
    let active:Bool
    let enabled:Bool
    let selected:Bool
    let highlight:Color
    let launch:()->Void
    let pin:()->Void
    let pinned:Bool
    @State private var hovered=false
    var body:some View {
        HStack(spacing:0){
            Button(action:launch){
                HStack(spacing:12){
                    LauncherAppIcon(icon:icon,size:26)
                    Text(app.name).font(.system(size:13)).lineLimit(1)
                    Spacer(minLength:6)
                    if opening {ProgressView().controlSize(.mini)}
                    else if active {Circle().fill(.green).frame(width:5,height:5).help("Finestra aperta")}
                }.padding(.leading,12).padding(.trailing,8).frame(maxWidth:.infinity,minHeight:44).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!enabled || opening).accessibilityLabel("Apri "+app.name)
            Button(action:pin){Image(systemName:pinned ? "star.fill":"star").font(.system(size:11)).foregroundStyle(.secondary).frame(width:32,height:36).contentShape(Rectangle())}
                .buttonStyle(.plain).padding(.trailing,5).help(pinned ? "Rimuovi dai preferiti":"Aggiungi ai preferiti")
                .accessibilityLabel((pinned ? "Rimuovi dai preferiti: ":"Aggiungi ai preferiti: ")+app.name)
        }.background(hovered || selected ? highlight:.clear,in:RoundedRectangle(cornerRadius:8)).onHover{hovered=$0}
    }
}
