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

private enum MouseMode {case pending,move,resize(ResizeEdges),remote,discard}
@MainActor
private final class MouseGesture {
    let identity=UUID()
    let origin:NSPoint
    let frame:NSRect
    let down:[String:Any]
    let clicks:Int
    var mode:MouseMode = .pending
    var latest:(NSPoint,[String:Any])?
    var up:(NSPoint,[String:Any])?
    init(point:NSPoint,frame:NSRect,down:[String:Any],clicks:Int){
        origin=point;self.frame=frame;self.down=down;self.clicks=clicks
    }
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
    private var gesture:MouseGesture?
    private var canResize=true
    private var nativeResizing=false
    private var resizeSerial=0
    private var expectedSize:NSSize?
    private var resizeDeadline:Task<Void,Never>?
    private var pixelScale=1.0
    private var zoomRestore:NSRect?
    var onError:((String)->Void)?
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
            window=GuestDocumentWindow(contentRect:rect,styleMask:[.borderless,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        }else{
            window=NSWindow(contentRect:rect,styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        }
        super.init()
        window.title=title;window.contentView=content;window.delegate=self;window.isReleasedWhenClosed=false
        window.isOpaque=false;window.backgroundColor = .clear
        window.hasShadow = !role.transient;window.acceptsMouseMovedEvents=true
        window.isMovable = !role.transient
        if !role.transient {window.minSize=window.frameRect(forContentRect:NSRect(x:0,y:0,width:160,height:100)).size}
        content.transient=role.transient
        content.input={ [weak self] event in
            guard let self else{return}
            var value=event;value["window"]=self.id;self.bridge.command("input",value)
        }
        if role == .main {content.leftMouse={ [weak self] event,value in self?.leftMouse(event,value) }}
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
            // Mac placement is local. Guest positions only anchor transient surfaces.
            sourceRect=next
        }
        canResize=item["resizable"] as? Bool ?? true
        if let maxWidth=item["maxWidth"] as? Double,let maxHeight=item["maxHeight"] as? Double,maxWidth>=160,maxHeight>=100 {
            window.maxSize=window.frameRect(forContentRect:NSRect(x:0,y:0,width:maxWidth*pixelScale,height:maxHeight*pixelScale)).size
        }
        if !role.transient {
            if canResize {window.styleMask.insert(.resizable)}else{window.styleMask.remove(.resizable)}
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
        if first {pixelScale=min(1,min(1100/Double(width),800/Double(height)))}
        let changed=nextSize != frameSize
        frameSize=nextSize;content.present(packet)
        if let expectedSize,expectedSize == nextSize {finishResize()}
        else if changed && !role.transient && !nativeResizing && self.expectedSize == nil {applyFrameSize()}
        onGeometry?()
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
    private func send(_ value:[String:Any]){
        var packet=value;packet["window"]=id;bridge.command("input",packet)
    }
    private func applyFrameSize(){
        guard frameSize.width>0,frameSize.height>0 else{return}
        let top=NSPoint(x:window.frame.minX,y:window.frame.maxY)
        window.setContentSize(NSSize(width:frameSize.width*pixelScale,height:frameSize.height*pixelScale))
        window.setFrameTopLeftPoint(top)
    }
    private func leftMouse(_ event:NSEvent,_ value:[String:Any]){
        // Use the position recorded in this event, in global coordinates.
        // Reading the current mouse position loses queued drag samples; converting
        // old window-relative samples after moving the window adds the move twice.
        let point:NSPoint
        if let recorded=event.cgEvent?.location {
            point=NSPoint(x:recorded.x,y:(NSScreen.screens.first?.frame.maxY ?? 0)-recorded.y)
        }else {point=window.convertPoint(toScreen:event.locationInWindow)}
        switch event.type {
        case .leftMouseDown:
            guard expectedSize == nil,!nativeResizing else{bridge.command("release");return}
            let next=MouseGesture(point:point,frame:window.frame,down:value,clicks:event.clickCount)
            gesture=next
            var edges:ResizeEdges=[]
            if canResize {
                let local=event.locationInWindow
                if local.x<6 {edges.insert(.left)}
                if local.x>window.frame.width-6 {edges.insert(.right)}
                if local.y<6 {edges.insert(.bottom)}
                if local.y>window.frame.height-6 {edges.insert(.top)}
            }
            if !edges.isEmpty {resolve(next,.resize(edges));return}
            var query=value;query["window"]=id
            bridge.command("hit_test",query,timeout:.milliseconds(400)){ [weak self,weak next] result in
                guard let self,let next,self.gesture === next else{return}
                guard case .success(let reply)=result,let payload=reply["value"] as? [String:Any],let hit=payload["hit"] as? Int else{
                    self.resolve(next,.discard);self.bridge.command("release");return
                }
                if hit == 2 {self.resolve(next,.move)}
                else if hit == 9 {self.resolve(next,.discard);self.toggleZoom()}
                else {
                    let edges=ResizeEdges(hit:hit)
                    self.resolve(next,self.canResize && !edges.isEmpty ? .resize(edges):.remote)
                }
            }
        case .leftMouseDragged:
            guard let gesture else{return}
            gesture.latest=(point,value)
            if case .pending=gesture.mode {return}
            perform(gesture,point:point,value:value,up:false)
        case .leftMouseUp:
            guard let gesture else{send(["event":"button","button":"left","down":false]);return}
            gesture.up=(point,value)
            if case .pending=gesture.mode {return}
            perform(gesture,point:point,value:value,up:true)
        default:break
        }
    }
    private func resolve(_ gesture:MouseGesture,_ mode:MouseMode){
        guard self.gesture === gesture else{return}
        gesture.mode=mode
        switch mode {
        case .remote:send(gesture.down)
        case .move:
            bridge.command("cancel_interaction",["window":id]);content.clearModifiers()
            if gesture.clicks == 2 {gesture.mode = .discard;toggleZoom()}
        case .resize:beginResize()
        default:break
        }
        if let sample=gesture.latest {perform(gesture,point:sample.0,value:sample.1,up:false)}
        if let sample=gesture.up {perform(gesture,point:sample.0,value:sample.1,up:true)}
    }
    private func perform(_ gesture:MouseGesture,point:NSPoint,value:[String:Any],up:Bool){
        let delta=NSPoint(x:point.x-gesture.origin.x,y:point.y-gesture.origin.y)
        switch gesture.mode {
        case .remote:send(value)
        case .move:window.setFrameOrigin(NSPoint(x:gesture.frame.minX+delta.x,y:gesture.frame.minY+delta.y))
        case .resize(let edges):
            window.setFrame(edges.frame(from:gesture.frame,delta:delta,minimum:window.minSize,maximum:window.maxSize),display:true)
            if up {commitResize()}
        default:break
        }
        if up,self.gesture === gesture {self.gesture=nil}
        if up {trace("gesture_finished")}
    }
    private func beginResize(){
        resizeSerial+=1;resizeDeadline?.cancel();expectedSize=nil
        nativeResizing=true;content.suspendedPointer=true;content.clearModifiers()
        bridge.command("cancel_interaction",["window":id])
    }
    private func commitResize(){
        guard canResize,!role.transient else{nativeResizing=false;content.suspendedPointer=false;return}
        resizeSerial+=1;let serial=resizeSerial
        nativeResizing=false;expectedSize = .zero;content.suspendedPointer=true
        let width=max(160,Int((content.bounds.width/pixelScale).rounded()))
        let height=max(100,Int((content.bounds.height/pixelScale).rounded()))
        trace("resize_requested")
        resizeDeadline?.cancel()
        resizeDeadline=Task{@MainActor [weak self] in
            try? await Task.sleep(for:.seconds(3))
            guard !Task.isCancelled,let self,self.resizeSerial == serial,self.expectedSize != nil else{return}
            self.finishResize();self.onError?("Windows did not finish resizing the window.")
        }
        bridge.command("resize",["window":id,"width":width,"height":height],timeout:.seconds(2)){ [weak self] result in
            guard let self,self.resizeSerial == serial,self.expectedSize != nil else{return}
            guard case .success(let reply)=result,let value=reply["value"] as? [String:Any],let width=value["width"] as? Int,let height=value["height"] as? Int else{
                self.finishResize();self.onError?("Windows could not resize this window.");return
            }
            self.expectedSize=NSSize(width:width,height:height)
            if self.frameSize == self.expectedSize {self.finishResize();return}
            // Applications can impose their own minimum size. Confirm the actual
            // geometry instead of waiting forever for an impossible requested size.
            Task{@MainActor [weak self] in
                try? await Task.sleep(for:.milliseconds(180))
                guard let self,self.resizeSerial == serial,self.expectedSize != nil else{return}
                self.bridge.command("geometry",["window":self.id],timeout:.seconds(1)){ [weak self] result in
                    guard let self,self.resizeSerial == serial,self.expectedSize != nil,
                          case .success(let reply)=result,let value=reply["value"] as? [String:Any],
                          let width=value["width"] as? Int,let height=value["height"] as? Int else{return}
                    self.expectedSize=NSSize(width:width,height:height)
                    if self.frameSize == self.expectedSize {self.finishResize()}
                }
            }
        }
    }
    private func finishResize(){
        resizeDeadline?.cancel();resizeDeadline=nil;expectedSize=nil
        nativeResizing=false;content.suspendedPointer=false
        applyFrameSize();bridge.command("release");onGeometry?()
        trace("resize_finished")
    }
    private func trace(_ event:String){
        guard ProcessInfo.processInfo.environment["PERPENDICULAR_STATE_TRACE"] == "1" else{return}
        let value:[String:Any]=["type":event,"window":id,
            "mac":[window.frame.minX,window.frame.minY,window.frame.width,window.frame.height],
            "guest":[sourceRect.minX,sourceRect.minY,sourceRect.width,sourceRect.height]]
        if let data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]){try? FileHandle.standardError.write(contentsOf:data+Data([10]))}
    }
    private func toggleZoom(){
        guard canResize,expectedSize == nil else{return}
        beginResize()
        if let restore=zoomRestore {window.setFrame(restore,display:true);zoomRestore=nil}
        else {zoomRestore=window.frame;let top=window.frame.maxY;window.setFrame(NSRect(x:window.frame.minX,y:top-window.maxSize.height,width:window.maxSize.width,height:window.maxSize.height),display:true)}
        commitResize()
    }
    func windowDidBecomeKey(_ notification:Notification){if !role.transient{bridge.command("activate",["window":id])}}
    func windowDidResignKey(_ notification:Notification){
        if !role.transient {
            gesture=nil;content.clearModifiers();bridge.command("release")
            if nativeResizing {nativeResizing=false;content.suspendedPointer=false;applyFrameSize()}
        }
    }
    func windowDidDeminiaturize(_ notification:Notification){bridge.command("activate",["window":id])}
    func windowDidMove(_ notification:Notification){onGeometry?()}
    func windowDidResize(_ notification:Notification){onGeometry?()}
    func windowWillStartLiveResize(_ notification:Notification){if !role.transient{beginResize()}}
    func windowDidEndLiveResize(_ notification:Notification){if !role.transient{commitResize()}}
    func windowShouldZoom(_ window:NSWindow,toFrame newFrame:NSRect)->Bool{toggleZoom();return false}
}
