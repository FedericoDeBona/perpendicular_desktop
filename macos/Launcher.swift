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
    var cursorDiagnostics:[String:Bool] {
        ["hoveredControl":LauncherPointerState.shared.active,"automaticCursorRects":areCursorRectsEnabled,
         "pointingHand":NSCursor.current === NSCursor.pointingHand]
    }
    private(set) var dragSamples=0
    private(set) var dragPointer=NSPoint.zero
    private(set) var dragRequested=NSPoint.zero
    override func constrainFrameRect(_ frameRect:NSRect,to screen:NSScreen?)->NSRect {
        dragOffset == nil ? super.constrainFrameRect(frameRect,to:screen):frameRect
    }
    override func sendEvent(_ event:NSEvent){
        // Consume cursor updates before a child responder can briefly install
        // the arrow. Reapplying the hand after dispatch produces visible flicker.
        if event.type == .cursorUpdate,LauncherPointerState.shared.active {
            LauncherPointerState.shared.restore();return
        }
        guard [.leftMouseDown,.leftMouseDragged,.leftMouseUp].contains(event.type) else {
            super.sendEvent(event)
            if event.type == .mouseMoved || event.type == .cursorUpdate {LauncherPointerState.shared.restore()}
            return
        }
        // Freeze this event before moving the window; polling the current mouse
        // can read a later queued sample and change the grab point.
        let sample=WindowMouseSample(event:event,window:self)
        if event.type == .leftMouseDown {dragOffset=nil}
        if event.type == .leftMouseDown,event.clickCount == 1 {
            let point=event.locationInWindow
            let contentHeight=styleMask.contains(.fullSizeContentView) ? frame.height-35:contentRect(forFrameRect:frame).height
            // Leave traffic lights, resize edges and titlebar double-clicks native.
            if point.y>=contentHeight,point.y<frame.height-4,point.x>100,point.x<frame.width-8 {
                let pointer=sample.screenLocation
                dragOffset=NSPoint(x:pointer.x-frame.minX,y:pointer.y-frame.minY)
                makeKeyAndOrderFront(nil)
                return
            }
        }
        if let offset=dragOffset {
            if event.type == .leftMouseDragged || event.type == .leftMouseUp {
                let pointer=sample.screenLocation
                dragPointer=pointer
                dragRequested=NSPoint(x:pointer.x-offset.x,y:pointer.y-offset.y)
                setFrameOrigin(dragRequested)
                dragSamples+=1
                if event.type == .leftMouseUp {dragOffset=nil}
                return
            }
        }
        super.sendEvent(event)
    }
}

@MainActor
private final class LauncherPointerState {
    static let shared=LauncherPointerState()
    weak var host:NSView?
    private var targets:Set<UUID>=[]
    private weak var suspendedWindow:NSWindow?
    var active:Bool {!targets.isEmpty}
    func set(_ id:UUID,hovered:Bool){
        let changed=hovered ? targets.insert(id).inserted:targets.remove(id) != nil
        guard changed else{return}
        if active {restore()}
        else {
            suspendedWindow?.enableCursorRects();suspendedWindow=nil
            if let host {host.window?.invalidateCursorRects(for:host)}
        }
    }
    func restore(){
        guard active else{return}
        // One cursor owner while hovering. Native cursor rectangles otherwise
        // install the arrow before each manual hand update during mouse movement.
        if let window=host?.window,window.areCursorRectsEnabled {
            window.disableCursorRects();suspendedWindow=window
        }
        NSCursor.pointingHand.set()
    }
}

@MainActor
final class LauncherHostingView:NSHostingView<Launcher> {
    override func viewDidMoveToWindow(){
        super.viewDidMoveToWindow()
        if window != nil {LauncherPointerState.shared.host=self}
    }
    override func resetCursorRects(){
        super.resetCursorRects()
        if LauncherPointerState.shared.active {addCursorRect(visibleRect,cursor:.pointingHand)}
    }
    override func cursorUpdate(with event:NSEvent){
        if LauncherPointerState.shared.active {LauncherPointerState.shared.restore()}
        else {super.cursorUpdate(with:event)}
    }
}

@MainActor
private struct LauncherHandPointer:ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @State private var id=UUID()
    @State private var hovered=false
    func body(content:Content)->some View {
        content.onHover{over in
            hovered=over;LauncherPointerState.shared.set(id,hovered:over && enabled)
        }
        .onChange(of:enabled){_,value in LauncherPointerState.shared.set(id,hovered:hovered && value)}
        .onDisappear{LauncherPointerState.shared.set(id,hovered:false)}
    }
}

private struct LauncherChromeButtonStyle:ButtonStyle {
    var prominent=false
    @Environment(\.isEnabled) private var enabled
    @State private var hovered=false
    func makeBody(configuration:Configuration)->some View {
        configuration.label
            .foregroundStyle(enabled && (hovered || configuration.isPressed) ? Color.primary:Color.secondary)
            .background(Color.primary.opacity(configuration.isPressed ? 0.17:hovered ? 0.11:prominent ? 0.065:0),in:RoundedRectangle(cornerRadius:9))
            .overlay(RoundedRectangle(cornerRadius:9).strokeBorder(Color.primary.opacity(prominent ? (hovered ? 0.2:0.12):0)))
            .opacity(enabled ? 1:0.4)
            .scaleEffect(configuration.isPressed ? 0.96:1)
            .onHover{hovered=$0}
    }
}

private struct LauncherTileButtonStyle:ButtonStyle {
    func makeBody(configuration:Configuration)->some View {
        configuration.label.opacity(configuration.isPressed ? 0.65:1)
            .scaleEffect(configuration.isPressed ? 0.97:1)
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
                        .buttonStyle(LauncherChromeButtonStyle()).modifier(LauncherHandPointer()).help("Torna alle app").accessibilityLabel("Torna alle app")
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
    private func showApps(){settings=false;searchFocused=true;model.refreshCatalogueIfNeeded()}
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
                Button{search="";searchFocused=true}label:{Image(systemName:"xmark.circle.fill").frame(width:28,height:28)}
                    .buttonStyle(LauncherChromeButtonStyle()).modifier(LauncherHandPointer()).accessibilityLabel("Cancella ricerca")
            }
            Button(action:model.showWindows){
                Image(systemName:"square.grid.2x2.fill").font(.system(size:17)).frame(width:40,height:36).contentShape(Rectangle())
            }.buttonStyle(LauncherChromeButtonStyle(prominent:true)).modifier(LauncherHandPointer())
                .help("Desktop Windows").accessibilityLabel("Desktop Windows").accessibilityIdentifier("launcher-open-desktop")
                .disabled(!model.desktopAvailable || model.machineOperation != nil)
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
            }else if large {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:112,maximum:132),spacing:10)],alignment:.leading,spacing:10){
                    ForEach(apps){app in
                        LauncherAppTile(app:app,icon:model.applicationIcons[app.id],opening:model.openingApps.contains(app.id),active:model.activeApps.contains(app.id),enabled:model.connected && model.machineOperation == nil,selected:selection==app.id,highlight:highlight,large:large,pinned:model.launcherPreferences.pinned.contains(app.id),launch:{model.launch(app)},pin:{model.togglePin(app)})
                            .id(app.id).contextMenu{appMenu(app)}
                            .onAppear{model.applicationBecameVisible(app)}.onDisappear{model.applicationBecameHidden(app)}
                    }
                }
            }else{
                LazyVStack(spacing:2){
                    ForEach(apps){app in
                        LauncherAppRow(app:app,icon:model.applicationIcons[app.id],opening:model.openingApps.contains(app.id),active:model.activeApps.contains(app.id),enabled:model.connected && model.machineOperation == nil,selected:selection==app.id,highlight:highlight,launch:{model.launch(app)},pin:{model.togglePin(app)},pinned:model.launcherPreferences.pinned.contains(app.id))
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
        let state=model.launcherWindowsStatus
        return HStack(spacing:10){
            Button{statusOpen.toggle()}label:{
                HStack(spacing:7){
                    Image(systemName:state.symbol).font(.system(size:14,weight:.medium))
                        .foregroundStyle(state.color).frame(width:19,height:20)
                    Text(state.title).font(.system(size:12,weight:.medium))
                    if state.working {ProgressView().controlSize(.mini).frame(width:14,height:14)}
                }.padding(.horizontal,7).frame(height:30).contentShape(Rectangle())
            }.buttonStyle(LauncherChromeButtonStyle()).modifier(LauncherHandPointer())
                .help(state.detail).accessibilityLabel("Windows: "+state.title).accessibilityIdentifier("launcher-windows-status")
                .popover(isPresented:$statusOpen,arrowEdge:.bottom){statusDetails}
            if let message=model.launcherStatusMessage {
                Button{statusOpen=true}label:{
                    HStack(spacing:6){
                        if !state.needsAttention {Image(systemName:"exclamationmark.triangle.fill").foregroundStyle(.orange)}
                        Text(message).lineLimit(1).truncationMode(.tail)
                    }.font(.system(size:11)).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                }.buttonStyle(LauncherChromeButtonStyle()).modifier(LauncherHandPointer()).help(message)
            }
            Spacer(minLength:10)
            Button{settings ? showApps():showSettings()}label:{Image(systemName:"slider.horizontal.3").font(.system(size:13)).frame(width:28,height:28)}
                .buttonStyle(LauncherChromeButtonStyle()).modifier(LauncherHandPointer()).help("Impostazioni · ⌘,").accessibilityLabel("Impostazioni")
        }.padding(.horizontal,16).frame(height:46).background(Color.primary.opacity(0.025))
    }
    private var statusDetails:some View {
        VStack(alignment:.leading,spacing:12){
            Label(model.launcherWindowsStatus.title,systemImage:model.launcherWindowsStatus.symbol).font(.system(size:13,weight:.medium))
            Text(model.launcherWindowsStatus.detail).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if let notice=model.launcherNotice {
                if notice != model.launcherWindowsStatus.detail {
                    Divider()
                    Text(notice).font(.system(size:12)).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                }
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
            }.buttonStyle(LauncherTileButtonStyle()).modifier(LauncherHandPointer()).disabled(!enabled || opening).accessibilityLabel("Apri "+app.name).help(app.name)
            Button(action:pin){Image(systemName:pinned ? "star.fill":"star").font(.system(size:10)).frame(width:26,height:26).contentShape(Rectangle())}
                .buttonStyle(LauncherChromeButtonStyle()).modifier(LauncherHandPointer()).opacity(hovered || pinned ? 1:0)
                .help(pinned ? "Rimuovi dai preferiti":"Aggiungi ai preferiti")
                .accessibilityLabel((pinned ? "Rimuovi dai preferiti: ":"Aggiungi ai preferiti: ")+app.name)
        }.aspectRatio(1,contentMode:.fit)
            .background(hovered || selected ? highlight:Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(Color.primary.opacity(0.045)))
            .onHover{hovered=$0}
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
            }.buttonStyle(LauncherTileButtonStyle()).modifier(LauncherHandPointer()).disabled(!enabled || opening).accessibilityLabel("Apri "+app.name)
            Button(action:pin){Image(systemName:pinned ? "star.fill":"star").font(.system(size:11)).frame(width:32,height:36).contentShape(Rectangle())}
                .buttonStyle(LauncherChromeButtonStyle()).modifier(LauncherHandPointer()).padding(.trailing,5).help(pinned ? "Rimuovi dai preferiti":"Aggiungi ai preferiti")
                .accessibilityLabel((pinned ? "Rimuovi dai preferiti: ":"Aggiungi ai preferiti: ")+app.name)
        }.background(hovered || selected ? highlight:.clear,in:RoundedRectangle(cornerRadius:8)).onHover{hovered=$0}
    }
}
