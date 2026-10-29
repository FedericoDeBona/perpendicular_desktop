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

/// Anchor a titlebar drag in global AppKit points for its entire duration.
/// Do not let native per-screen frame constraints replace the pointer offset.
@MainActor
final class LauncherWindow:NSWindow {
    private var dragOffset:NSPoint?
    private(set) var dragSamples=0
    override func constrainFrameRect(_ frameRect:NSRect,to screen:NSScreen?)->NSRect {
        dragOffset == nil ? super.constrainFrameRect(frameRect,to:screen):frameRect
    }
    override func sendEvent(_ event:NSEvent){
        if event.type == .leftMouseDown,event.clickCount == 1 {
            let point=event.locationInWindow
            let contentHeight=styleMask.contains(.fullSizeContentView) ? frame.height-35:contentRect(forFrameRect:frame).height
            // Leave traffic lights, resize edges and titlebar double-clicks native.
            if point.y>=contentHeight,point.y<frame.height-4,point.x>100,point.x<frame.width-8 {
                let pointer=NSEvent.mouseLocation
                dragOffset=NSPoint(x:pointer.x-frame.minX,y:pointer.y-frame.minY)
                makeKeyAndOrderFront(nil)
                return
            }
        }
        if let offset=dragOffset {
            if event.type == .leftMouseDragged || event.type == .leftMouseUp {
                let pointer=NSEvent.mouseLocation
                setFrameOrigin(NSPoint(x:pointer.x-offset.x,y:pointer.y-offset.y))
                dragSamples+=1
                if event.type == .leftMouseUp {dragOffset=nil}
                return
            }
        }
        super.sendEvent(event)
    }
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
                        appSection("Preferiti",apps:sections.favorites,large:true)
                        appSection("Recenti",apps:sections.recent)
                        appSection("Altre app",apps:sections.remaining)
                    }else{appSection("Risultati",apps:results)}
                    if model.catalogueLoading {ProgressView().controlSize(.small).frame(maxWidth:.infinity).padding(12)}
                }.padding(.horizontal,16).padding(.top,22).padding(.bottom,24)
            }
            .onChange(of:selection){_,id in if let id {proxy.scrollTo(id,anchor:nil)}}
        }
    }
    @ViewBuilder private func appSection(_ title:String,apps:[WindowsApplication],large:Bool=false)->some View {
        VStack(alignment:.leading,spacing:10){
            Text(title).font(.system(size:11,weight:.medium)).foregroundStyle(.secondary).padding(.horizontal,8)
            if apps.isEmpty {
                Text(large ? "Aggiungi qui le tue app con la stella.":(title == "Recenti" ? "Qui ritrovi le app aperte di recente.":"Nessuna app trovata."))
                    .font(.system(size:12)).foregroundStyle(.secondary).padding(8)
            }else{
                LazyVGrid(columns:[GridItem(.adaptive(minimum:large ? 112:92,maximum:large ? 132:108),spacing:10)],alignment:.leading,spacing:10){
                    ForEach(apps){app in
                        LauncherAppTile(app:app,icon:model.applicationIcons[app.id],opening:model.openingApps.contains(app.id),active:model.activeApps.contains(app.id),enabled:model.connected && model.machineOperation == nil,selected:selection==app.id,highlight:highlight,large:large,pinned:model.launcherPreferences.pinned.contains(app.id),launch:{model.launch(app)},pin:{model.togglePin(app)})
                            .id(app.id).contextMenu{appMenu(app)}
                            .onAppear{model.applicationBecameVisible(app)}.onDisappear{model.applicationBecameHidden(app)}
                    }
                }
            }
        }
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
private struct LauncherAppTile:View {
    let app:WindowsApplication
    let icon:NSImage?
    let opening:Bool
    let active:Bool
    let enabled:Bool
    let selected:Bool
    let highlight:Color
    let large:Bool
    let pinned:Bool
    let launch:()->Void
    let pin:()->Void
    @State private var hovered=false
    var body:some View {
        ZStack(alignment:.topTrailing){
            Button(action:launch){
                VStack(spacing:9){
                    ZStack(alignment:.bottomTrailing){
                        LauncherAppIcon(icon:icon,size:large ? 38:30)
                        if opening {ProgressView().controlSize(.mini).padding(3).background(.regularMaterial,in:Circle()).offset(x:6,y:4)}
                        else if active {Circle().fill(.green).frame(width:6,height:6).offset(x:4,y:2)}
                    }
                    Text(app.name).font(.system(size:large ? 12:11)).lineLimit(2).multilineTextAlignment(.center)
                        .frame(maxWidth:.infinity).frame(height:28,alignment:.top)
                }.padding(.horizontal,7).frame(maxWidth:.infinity,maxHeight:.infinity).contentShape(RoundedRectangle(cornerRadius:12))
            }.buttonStyle(.plain).disabled(!enabled || opening).accessibilityLabel("Apri "+app.name).help(app.name)
            Button(action:pin){Image(systemName:pinned ? "star.fill":"star").font(.system(size:10)).frame(width:26,height:26).contentShape(Rectangle())}
                .buttonStyle(.plain).foregroundStyle(.secondary).opacity(hovered || pinned ? 1:0)
                .help(pinned ? "Rimuovi dai preferiti":"Aggiungi ai preferiti")
                .accessibilityLabel((pinned ? "Rimuovi dai preferiti: ":"Aggiungi ai preferiti: ")+app.name)
        }.aspectRatio(1,contentMode:.fit)
            .background(hovered || selected ? highlight:Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(Color.primary.opacity(0.045)))
            .onHover{hovered=$0}
    }
}
