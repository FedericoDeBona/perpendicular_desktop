import AppKit

enum WindowRole:String {
    case main,dialog,popup,tooltip
    var transient:Bool {self == .popup || self == .tooltip}
}

@MainActor
private final class GuestDocumentWindow:NSWindow {
    var closeRequested:(()->Void)?
    override var canBecomeKey:Bool {true}
    override var canBecomeMain:Bool {true}
    override func performClose(_ sender:Any?){closeRequested?()}
}

@MainActor
private final class GuestPopupPanel:NSPanel {
    override var canBecomeKey:Bool {false}
    override var canBecomeMain:Bool {false}
}

@MainActor
final class ApplicationWindow:NSObject,NSWindowDelegate {
    let id:String
    let role:WindowRole
    let window:NSWindow
    let content=ApplicationContent(frame:NSRect(x:0,y:0,width:640,height:480))
    private let bridge:GuestBridge
    private var sourceClosed=false
    private var closing=false
    private var hasFrame=false
    private var frameSize=NSSize.zero
    private var sourceRect=NSRect.zero
    private var minimized=false
    private var visible=true
    private var placedDialog=false
    var parentID:String?
    var zOrder=0
    var onClose:(()->Void)?
    var onGeometry:(()->Void)?
    var onPointerExit:(()->Void)?

    init(id:String,title:String,role:WindowRole,bridge:GuestBridge){
        self.id=id;self.role=role;self.bridge=bridge
        let rect=NSRect(x:160,y:140,width:640,height:480)
        if role.transient {
            let panel=GuestPopupPanel(contentRect:rect,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            // Its visibility follows the Windows surface and its owner, not AppKit's
            // floating-panel policy. Showing a nonactivating panel must never hide it.
            panel.isFloatingPanel=false;panel.hidesOnDeactivate=false
            panel.becomesKeyOnlyIfNeeded=true;panel.isExcludedFromWindowsMenu=true
            window=panel
        }else if role == .main {
            window=GuestDocumentWindow(contentRect:rect,styleMask:[.borderless,.closable,.miniaturizable],backing:.buffered,defer:false)
        }else{
            window=NSWindow(contentRect:rect,styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        }
        super.init()
        window.title=title;window.contentView=content;window.delegate=self;window.isReleasedWhenClosed=false
        window.isOpaque=false;window.backgroundColor = .clear
        window.hasShadow = !role.transient;window.acceptsMouseMovedEvents=true
        window.isMovable = role == .dialog
        if !role.transient {window.minSize=NSSize(width:160,height:100)}
        content.transient=role.transient
        content.input={ [weak self] event in
            guard let self else{return}
            var value=event;value["window"]=self.id;self.bridge.command("input",value)
        }
        content.pointerExited={ [weak self] in self?.onPointerExit?() }
        (window as? GuestDocumentWindow)?.closeRequested={ [weak self] in self?.requestClose() }
        if role == .main {NSApp.addWindowsItem(window,title:title,filename:false)}
    }
    func update(_ item:[String:Any]){
        window.title=item["title"] as? String ?? ""
        if role == .main {NSApp.changeWindowsItem(window,title:window.title,filename:false)}
        parentID=item["parent"] as? String
        zOrder=item["z"] as? Int ?? 0
        visible=item["visible"] as? Bool ?? true
        let nextMinimized=item["minimized"] as? Bool ?? false
        if !nextMinimized,let x=item["x"] as? Double,let y=item["y"] as? Double,
           let width=item["width"] as? Double,let height=item["height"] as? Double,width>0,height>0 {
            let next=NSRect(x:x,y:y,width:width,height:height)
            if !sourceRect.isEmpty,!minimized,role == .main {
                let scale=content.imageScale
                let dx=(next.minX-sourceRect.minX)*scale,dy=(next.minY-sourceRect.minY)*scale
                if abs(dx)>0.1 || abs(dy)>0.1 {
                    window.setFrameOrigin(NSPoint(x:window.frame.minX+dx,y:window.frame.minY-dy))
                }
            }
            sourceRect=next
        }
        minimized=nextMinimized
        if !hasFrame && !role.transient && visible && !minimized && !window.isVisible {
            window.makeKeyAndOrderFront(nil);window.makeFirstResponder(content)
        }
        if role == .main {
            if minimized && !window.isMiniaturized {window.miniaturize(nil)}
            if !minimized && window.isMiniaturized {window.deminiaturize(nil)}
        }
        if !visible {window.orderOut(nil)}else if hasFrame && !minimized && !role.transient && !window.isVisible {window.orderFront(nil)}
    }
    func attach(to owner:ApplicationWindow){
        if window.parent != owner.window {
            window.parent?.removeChildWindow(window)
            owner.window.addChildWindow(window,ordered:.above)
        }
        guard !sourceRect.isEmpty,!owner.sourceRect.isEmpty else{return}
        if role.transient || (role == .dialog && !placedDialog) {
            let scale=owner.content.imageScale
            let image=owner.content.imageRect
            let local=NSPoint(x:image.minX+(sourceRect.minX-owner.sourceRect.minX)*scale,
                              y:image.minY+(sourceRect.minY-owner.sourceRect.minY)*scale)
            let top=owner.window.convertPoint(toScreen:owner.content.convert(local,to:nil))
            if role.transient {
                let size=frameSize == .zero ? sourceRect.size:frameSize
                window.setFrame(NSRect(x:top.x,y:top.y-size.height*scale,width:size.width*scale,height:size.height*scale),display:true)
            }else{
                window.setFrameTopLeftPoint(top);placedDialog=true
            }
        }
        if role.transient && hasFrame && visible && !minimized && owner.window.isVisible && !owner.window.isMiniaturized {
            window.orderFront(nil)
        }else if role.transient {window.orderOut(nil)}
    }
    func present(_ packet:GuestPacket){
        let first = !hasFrame
        guard let width=packet.header["width"] as? Int,let height=packet.header["height"] as? Int else{return}
        let nextSize=NSSize(width:width,height:height)
        hasFrame=true
        if nextSize != frameSize && !role.transient {
            let top=NSPoint(x:window.frame.minX,y:window.frame.maxY)
            let factor=min(1,min(1100/Double(width),800/Double(height)))
            window.setContentSize(NSSize(width:Double(width)*factor,height:Double(height)*factor))
            window.setFrameTopLeftPoint(top)
        }
        frameSize=nextSize;content.present(packet);onGeometry?()
        if first,ProcessInfo.processInfo.environment["PERPENDICULAR_CAPTURE_DIAGNOSTIC"]=="1",let image=content.currentImage{
            let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Perpendicular Restart/QA")
            try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let name=id.replacingOccurrences(of:":",with:"-")
            try? NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent(name+".png"))
            var metadata=packet.header;metadata["title"]=window.title;metadata["role"]=role.rawValue
            if let bytes=try? JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted]){try? bytes.write(to:directory.appendingPathComponent(name+".json"))}
        }
    }
    func retire(){sourceClosed=true;window.close()}
    private func requestClose(){if windowShouldClose(window){window.close()}}
    func windowShouldClose(_ sender:NSWindow)->Bool{
        if sourceClosed || !bridge.connected{return true}
        guard !closing else{return false};closing=true
        bridge.command("close",["window":id])
        Task{@MainActor [weak self] in try? await Task.sleep(for:.seconds(3));self?.closing=false}
        return false
    }
    func windowWillClose(_ notification:Notification){
        if role == .main {NSApp.removeWindowsItem(window)}
        if !role.transient {content.clearModifiers();bridge.command("release")}
        onClose?()
    }
    func windowDidBecomeKey(_ notification:Notification){if !role.transient{bridge.command("activate",["window":id])}}
    func windowDidResignKey(_ notification:Notification){if !role.transient{content.clearModifiers();bridge.command("release")}}
    func windowDidDeminiaturize(_ notification:Notification){bridge.command("activate",["window":id])}
    func windowDidMove(_ notification:Notification){onGeometry?()}
    func windowDidEndLiveResize(_ notification:Notification){
        guard hasFrame,role == .dialog else{return}
        bridge.command("resize",["window":id,"width":Int(content.bounds.width),"height":Int(content.bounds.height)])
    }
}
