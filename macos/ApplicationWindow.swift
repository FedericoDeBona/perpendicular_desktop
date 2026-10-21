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

private enum MouseMode {case pending,move,resize(ResizeEdges),remote,zoom,discard}
private enum WindowInput {
    case input([String:Any])
    case leftMouse(NSEvent,[String:Any])
    var textBytes:Int {
        if case .input(let value)=self {return (value["text"] as? String)?.utf8.count ?? 0}
        return 0
    }
    func replacesPointer(_ previous:WindowInput)->Bool {
        switch (self,previous) {
        case let (.input(value),.input(old)):
            return value["event"] as? String == "pointer" && old["event"] as? String == "pointer"
        case let (.leftMouse(event,_),.leftMouse(old,_)):
            return event.type == .leftMouseDragged && old.type == .leftMouseDragged
        default:return false
        }
    }
}
@MainActor
private final class MouseGesture {
    let identity=UUID()
    let origin:NSPoint
    let frame:NSRect
    let down:[String:Any]
    let clicks:Int
    var mode:MouseMode = .pending
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
    private var inputBlocked=false
    private var deferredInput:[WindowInput]=[]
    private var deferredTextBytes=0
    private var drainingInput=false
    private var discardingInput=false
    private var canResize=true
    private var nativeResizing=false
    private var resizeSerial=0
    private var expectedSize:NSSize?
    private var resizeDeadline:Task<Void,Never>?
    private var liveResizeTimer:Timer?
    private var liveResizeSize:NSSize?
    private var liveResizeInFlight=false
    private var liveResizeFailed=false
    private var liveResizeSentSize:NSSize?
    private var nextLiveResizeAt=0.0
    private var pixelScale=1.0
    private var fallbackPixelScale=1.0
    private var sharedDisplay:SharedDisplay?
    private var applyingSourceGeometry=false
    private var maximumPixels=NSSize(width:4096,height:4096)
    private var geometryInteraction:String?
    private var geometrySerial=0
    private var geometryActive=false
    private var geometryFinishing=false
    private var geometryInFlight=false
    private var geometryPending:NSRect?
    private var geometrySent:NSRect?
    private var geometryExpected:NSRect?
    private var geometryConfirmed:NSRect?
    private var geometryNextSend=0.0
    private var geometryTimer:Timer?
    private var geometryDeadline:Task<Void,Never>?
    private var geometryRead:Task<Void,Never>?
    private var nativeMoveTimer:Timer?
    private var zoomRestore:NSRect?
    var onError:((String)->Void)?
    var parentID:String?
    var zOrder=0
    var onClose:(()->Void)?
    var onGeometry:(()->Void)?
    var onPointerExit:(()->Void)?
    var activateOnFirstShow=true

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
            // AppKit's implicit borderless resize tracking competes with the
            // Windows hit-test gesture. Main windows use our explicit edges;
            // dialogs retain AppKit's ordinary titled resize frame.
            window=GuestDocumentWindow(contentRect:rect,styleMask:[.borderless,.closable,.miniaturizable],backing:.buffered,defer:false)
        }else{
            window=NSWindow(contentRect:rect,styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        }
        super.init()
        window.title=title;window.contentView=content;window.delegate=self;window.isReleasedWhenClosed=false
        // Dialogs use native Mac chrome, which needs a solid backing rather
        // than showing the owner's pixels through the title bar.
        window.isOpaque = role == .dialog
        window.backgroundColor = role == .dialog ? .windowBackgroundColor:.clear
        if role == .dialog {window.titlebarAppearsTransparent=false}
        window.hasShadow = !role.transient;window.acceptsMouseMovedEvents=true
        window.isMovable = !role.transient
        if !role.transient {window.minSize=window.frameRect(forContentRect:NSRect(x:0,y:0,width:160,height:100)).size}
        content.transient=role.transient
        content.input={ [weak self] event in
            self?.receive(.input(event))
        }
        if role == .main {content.leftMouse={ [weak self] event,value in self?.receive(.leftMouse(event,value)) }}
        content.pointerExited={ [weak self] in self?.onPointerExit?() }
        (window as? GuestDocumentWindow)?.closeRequested={ [weak self] in self?.requestClose() }
        if role == .main {NSApp.addWindowsItem(window,title:title,filename:false)}
    }
    /// Only a display snapshot confirmed by the frontend can enable shared
    /// placement. Removing that snapshot invalidates every outstanding gesture.
    func setSharedDisplay(_ display:SharedDisplay?){
        guard sharedDisplay != display else{return}
        cancelSharedGeometry()
        if nativeResizing || expectedSize != nil {
            resizeSerial+=1;resizeDeadline?.cancel();resizeDeadline=nil
            liveResizeTimer?.invalidate();liveResizeTimer=nil;liveResizeSize=nil
            nativeResizing=false;liveResizeInFlight=false;expectedSize=nil
            content.suspendedPointer=false;bridge.command("release")
        }
        if inputBlocked || !deferredInput.isEmpty {cancelInput("The display changed before the pending input could be sent.")}
        else {gesture=nil}
        zoomRestore=nil;sharedDisplay=display
        pixelScale=display.map{Double($0.pixelScale)} ?? fallbackPixelScale
        applySizeLimits()
        if display != nil {applySourceFrame()}else if hasFrame{applyFrameSize()}
        onGeometry?()
    }
    private func applySizeLimits(){
        guard !role.transient else{return}
        window.minSize=window.frameRect(forContentRect:NSRect(x:0,y:0,width:160*pixelScale,height:100*pixelScale)).size
        window.maxSize=window.frameRect(forContentRect:NSRect(origin:.zero,
            size:NSSize(width:maximumPixels.width*pixelScale,height:maximumPixels.height*pixelScale))).size
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
            sourceRect=next
        }
        canResize=item["resizable"] as? Bool ?? true
        if let maxWidth=item["maxWidth"] as? Double,let maxHeight=item["maxHeight"] as? Double,maxWidth>=160,maxHeight>=100 {
            maximumPixels=NSSize(width:maxWidth,height:maxHeight);applySizeLimits()
        }
        if !role.transient && role != .main {
            if canResize {window.styleMask.insert(.resizable)}else{window.styleMask.remove(.resizable)}
        }
        minimized=nextMinimized
        if sharedDisplay != nil,!geometryActive,!geometryFinishing,!minimized {applySourceFrame()}
        if !hasFrame && !role.transient && visible && !minimized && !window.isVisible {
            if activateOnFirstShow {window.makeKeyAndOrderFront(nil)}
            else {window.orderBack(nil)}
            window.makeFirstResponder(content)
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
        if role.transient || (role == .dialog && sharedDisplay == nil && !placedDialog) {
            let scale=owner.content.imageScale
            let image=owner.content.imageRect
            let local=NSPoint(x:image.minX+(sourceRect.minX-owner.sourceRect.minX)*scale,
                              y:image.minY+(sourceRect.minY-owner.sourceRect.minY)*scale)
            let top=owner.window.convertPoint(toScreen:owner.content.convert(local,to:nil))
            if role.transient {
                let size=frameSize == .zero ? sourceRect.size:frameSize
                let frame=NSRect(x:top.x,y:top.y-size.height*scale,width:size.width*scale,height:size.height*scale)
                if window.frame != frame {window.setFrame(frame,display:true)}
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
        if first {
            fallbackPixelScale=min(1,min(1100/Double(width),800/Double(height)))
            pixelScale=sharedDisplay.map{Double($0.pixelScale)} ?? fallbackPixelScale
            applySizeLimits()
        }
        let changed=nextSize != frameSize
        frameSize=nextSize;content.present(packet)
        if let failure=content.renderFailure {onError?(failure)}
        if geometryFinishing,geometryConfirmed != nil,let expectedSize,expectedSize == nextSize {finishSharedGeometry()}
        else if geometryInteraction == nil {
            if let expectedSize,expectedSize == nextSize {finishResize()}
            else if changed && !role.transient && !nativeResizing && self.expectedSize == nil {applyFrameSize()}
        }
        if first || changed {onGeometry?()}
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
        if !role.transient {cancelInput()}
        cancelSharedGeometry()
        if role == .main {NSApp.removeWindowsItem(window)}
        onClose?()
    }
    private func receive(_ value:WindowInput){
        guard !discardingInput else{return}
        if inputBlocked || drainingInput {
            if let previous=deferredInput.last,value.replacesPointer(previous) {
                deferredInput[deferredInput.count-1]=value;return
            }
            guard deferredInput.count<128,value.textBytes<=32*1024-deferredTextBytes else{
                cancelInput("The click took too long. The pending input was not sent.");return
            }
            deferredInput.append(value);deferredTextBytes+=value.textBytes
        }else {deliver(value)}
    }
    private func deliver(_ value:WindowInput){
        switch value {
        case .input(let packet):send(packet)
        case .leftMouse(let event,let packet):leftMouse(event,packet)
        }
    }
    private func drainInput(){
        guard !drainingInput else{return}
        drainingInput=true
        defer{drainingInput=false}
        while !inputBlocked,!deferredInput.isEmpty {
            let value=deferredInput.removeFirst();deferredTextBytes-=value.textBytes
            deliver(value)
        }
    }
    private func cancelInput(_ message:String?=nil){
        let interrupted=inputBlocked || !deferredInput.isEmpty
        // clearModifiers also flushes composed text. Cancellation must discard
        // that tail rather than deliver it to the control preceding the click.
        discardingInput=interrupted;content.clearModifiers();discardingInput=false
        gesture=nil;inputBlocked=false;deferredInput.removeAll();deferredTextBytes=0
        bridge.command("release")
        if interrupted,let message {onError?(message)}
    }
    private func send(_ value:[String:Any]){
        var packet=value;packet["window"]=id;bridge.command("input",packet)
    }
    private func applyFrameSize(){
        if sharedDisplay != nil {applySourceFrame();return}
        guard frameSize.width>0,frameSize.height>0 else{return}
        let top=NSPoint(x:window.frame.minX,y:window.frame.maxY)
        window.setContentSize(NSSize(width:frameSize.width*pixelScale,height:frameSize.height*pixelScale))
        window.setFrameTopLeftPoint(top)
        // A guest DPI/mode change can grow an existing window downward. Keep a
        // window that fits the current Mac display reachable after reconciliation.
        if let area=(window.screen ?? NSScreen.screens.first)?.visibleFrame {
            var origin=window.frame.origin
            if window.frame.width<=area.width {origin.x=min(max(origin.x,area.minX),area.maxX-window.frame.width)}
            if window.frame.height<=area.height {origin.y=min(max(origin.y,area.minY),area.maxY-window.frame.height)}
            if origin != window.frame.origin {window.setFrameOrigin(origin)}
        }
    }
    private func applySourceFrame(){
        guard let sharedDisplay,!sourceRect.isEmpty,!geometryActive,!geometryFinishing else{return}
        let mapped=sharedDisplay.macFrame(forGuest:sourceRect)
        let frame=window.frameRect(forContentRect:mapped)
        guard window.frame != frame else{return}
        applyingSourceGeometry=true
        window.setFrame(frame,display:true)
        applyingSourceGeometry=false
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
            inputBlocked=true
            bridge.command("hit_test",query,timeout:.milliseconds(400)){ [weak self,weak next] result in
                guard let self,let next,self.gesture === next else{return}
                guard case .success(let reply)=result,let payload=reply["value"] as? [String:Any],let hit=payload["hit"] as? Int else{
                    self.cancelInput("Windows could not determine where you clicked. The pending input was not sent.");return
                }
                if hit == 2 {self.resolve(next,.move)}
                else if hit == 9 {self.resolve(next,.zoom)}
                else {
                    let edges=ResizeEdges(hit:hit)
                    self.resolve(next,self.canResize && !edges.isEmpty ? .resize(edges):.remote)
                }
            }
        case .leftMouseDragged:
            guard let gesture else{return}
            perform(gesture,point:point,value:value,up:false)
        case .leftMouseUp:
            guard let gesture else{send(["event":"button","button":"left","down":false]);return}
            perform(gesture,point:point,value:value,up:true)
        default:break
        }
    }
    private func resolve(_ gesture:MouseGesture,_ mode:MouseMode){
        guard self.gesture === gesture else{return}
        if inputBlocked {
            content.flushText()
            guard self.gesture === gesture else{return}
        }
        gesture.mode=mode
        switch mode {
        case .remote:send(gesture.down)
        case .move:
            if sharedDisplay != nil {beginSharedGeometry()}
            else {bridge.command("cancel_interaction",["window":id]);content.clearModifiers()}
            if gesture.clicks == 2 {gesture.mode = .discard;toggleZoom()}
        case .resize:beginResize()
        case .zoom:gesture.mode = .discard;toggleZoom()
        default:break
        }
        // Geometry setup can flush composed text, so keep it behind the same
        // gate until the down has been classified. A later down starts a new
        // hit-test and pauses this FIFO without replacing the preceding click.
        inputBlocked=false;drainInput()
    }
    private func perform(_ gesture:MouseGesture,point:NSPoint,value:[String:Any],up:Bool){
        let delta=NSPoint(x:point.x-gesture.origin.x,y:point.y-gesture.origin.y)
        switch gesture.mode {
        case .remote:send(value)
        case .move:
            window.setFrameOrigin(NSPoint(x:gesture.frame.minX+delta.x,y:gesture.frame.minY+delta.y))
            if sharedDisplay != nil {
                if up {commitSharedGeometry()}else{updateSharedGeometry()}
            }
        case .resize(let edges):
            window.setFrame(edges.frame(from:gesture.frame,delta:delta,minimum:window.minSize,maximum:window.maxSize),display:true)
            if !up {updateLiveResize()}
            if up {commitResize()}
        default:break
        }
        if up,self.gesture === gesture {self.gesture=nil}
        if up {trace("gesture_finished")}
    }
    private func beginResize(){
        if sharedDisplay != nil {beginSharedGeometry();nativeResizing=true;return}
        resizeSerial+=1;resizeDeadline?.cancel();expectedSize=nil
        liveResizeTimer?.invalidate();liveResizeTimer=nil;liveResizeSize=nil
        liveResizeInFlight=false;liveResizeFailed=false
        liveResizeSentSize=resizeTargetSize;nextLiveResizeAt=0
        nativeResizing=true;content.suspendedPointer=true;content.clearModifiers()
        bridge.command("cancel_interaction",["window":id])
    }
    private var resizeTargetSize:NSSize {
        // content.bounds can lag behind a programmatic setFrame during tracking.
        // Derive the target from the requested window frame, including dialog chrome.
        let size=window.contentRect(forFrameRect:window.frame).size
        return NSSize(width:max(160,(size.width/pixelScale).rounded()),height:max(100,(size.height/pixelScale).rounded()))
    }
    private func updateLiveResize(){
        if sharedDisplay != nil {
            if nativeResizing {updateSharedGeometry()}
            return
        }
        guard nativeResizing,canResize,!role.transient,!liveResizeFailed else{return}
        let size=resizeTargetSize
        if size == liveResizeSentSize {
            liveResizeSize=nil;liveResizeTimer?.invalidate();liveResizeTimer=nil;return
        }
        liveResizeSize=size
        guard !liveResizeInFlight,liveResizeTimer == nil else{return}
        let serial=resizeSerial
        let delay=max(0,nextLiveResizeAt-ProcessInfo.processInfo.systemUptime)
        if delay == 0 {sendLiveResize(serial);return}
        let timer=Timer(timeInterval:delay,repeats:false){[weak self] _ in
            MainActor.assumeIsolated {
                guard let self,self.resizeSerial == serial else{return}
                self.liveResizeTimer=nil;self.sendLiveResize(serial)
            }
        }
        // AppKit tracks native dialog resizes in an event-tracking run loop.
        // Common modes keep this coalesced sender active during that gesture.
        liveResizeTimer=timer;RunLoop.main.add(timer,forMode:.common)
    }
    private func sendLiveResize(_ serial:Int){
        guard resizeSerial == serial,nativeResizing,let size=liveResizeSize else{return}
        liveResizeSize=nil;liveResizeSentSize=size;liveResizeInFlight=true
        nextLiveResizeAt=ProcessInfo.processInfo.systemUptime+0.045
        trace("resize_live_requested")
        bridge.command("resize",["window":id,"width":Int(size.width),"height":Int(size.height)],timeout:.seconds(1)){[weak self] result in
            guard let self,self.resizeSerial == serial,self.nativeResizing else{return}
            self.liveResizeInFlight=false
            if case .failure=result {self.liveResizeFailed=true;return}
            if self.liveResizeSize != nil {self.updateLiveResize()}
        }
    }
    private func commitResize(){
        if sharedDisplay != nil {nativeResizing=false;commitSharedGeometry();return}
        guard canResize,!role.transient else{nativeResizing=false;content.suspendedPointer=false;return}
        resizeSerial+=1;let serial=resizeSerial
        liveResizeTimer?.invalidate();liveResizeTimer=nil;liveResizeSize=nil;liveResizeInFlight=false
        nativeResizing=false;expectedSize = .zero;content.suspendedPointer=true
        let size=resizeTargetSize,width=Int(size.width),height=Int(size.height)
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
        liveResizeTimer?.invalidate();liveResizeTimer=nil;liveResizeSize=nil;liveResizeInFlight=false
        nativeResizing=false;content.suspendedPointer=false
        applyFrameSize();bridge.command("release");onGeometry?()
        trace("resize_finished")
    }
    private var sharedTarget:NSRect? {
        guard let sharedDisplay else{return nil}
        let frame=sharedDisplay.guestFrame(forMac:window.contentRect(forFrameRect:window.frame))
        return NSRect(x:frame.minX.rounded(),y:frame.minY.rounded(),
                      width:max(160,frame.width.rounded()),height:max(100,frame.height.rounded()))
    }
    private func beginSharedGeometry(){
        cancelSharedGeometry()
        geometryInteraction=UUID().uuidString;geometryActive=true
        geometryNextSend=0;geometrySent=sharedTarget
        content.suspendedPointer=true;content.clearModifiers()
        bridge.command("cancel_interaction",["window":id])
    }
    private func updateSharedGeometry(){
        guard geometryActive,let target=sharedTarget else{return}
        geometryPending=target == geometrySent ? nil:target
        pumpSharedGeometry()
    }
    private func commitSharedGeometry(){
        guard geometryInteraction != nil,let target=sharedTarget else{return}
        nativeMoveTimer?.invalidate();nativeMoveTimer=nil
        geometryActive=false;geometryFinishing=true;geometryPending=target
        geometryTimer?.invalidate();geometryTimer=nil
        let interaction=geometryInteraction
        geometryDeadline=Task{@MainActor [weak self] in
            try? await Task.sleep(for:.seconds(3))
            guard !Task.isCancelled,let self,self.geometryInteraction == interaction else{return}
            self.finishSharedGeometry(error:"Windows did not finish updating the window geometry.")
        }
        pumpSharedGeometry()
    }
    private func pumpSharedGeometry(){
        guard let interaction=geometryInteraction,!geometryInFlight,let target=geometryPending else{return}
        let delay=geometryFinishing ? 0:max(0,geometryNextSend-ProcessInfo.processInfo.systemUptime)
        if delay>0 {
            guard geometryTimer == nil else{return}
            let timer=Timer(timeInterval:delay,repeats:false){[weak self] _ in
                MainActor.assumeIsolated {
                    guard let self,self.geometryInteraction == interaction else{return}
                    self.geometryTimer=nil;self.pumpSharedGeometry()
                }
            }
            geometryTimer=timer;RunLoop.main.add(timer,forMode:.common);return
        }
        geometryPending=nil;geometrySent=target;geometryInFlight=true
        geometryNextSend=ProcessInfo.processInfo.systemUptime+0.045
        geometrySerial+=1;let serial=geometrySerial,final=geometryFinishing
        let request:[String:Any]=["window":id,"gesture":interaction,"serial":serial,
            "x":Int(target.minX),"y":Int(target.minY),"width":Int(target.width),"height":Int(target.height)]
        trace(final ? "geometry_final_requested":"geometry_live_requested")
        bridge.command("set_geometry",request,timeout:.seconds(1)){[weak self] result in
            guard let self,self.geometryInteraction == interaction else{return}
            self.geometryInFlight=false
            guard case .success(let reply)=result,let value=reply["value"] as? [String:Any],
                  value["accepted"] as? Bool == true,value["gesture"] as? String == interaction,
                  value["serial"] as? Int == serial else {
                // An unsuccessful intermediate update ends this interaction;
                // the next snapshot can restore the actual guest placement.
                self.finishSharedGeometry(error:"Windows could not update this window geometry.");return
            }
            if final {
                guard let expected=self.geometryRect(value) else {
                    self.finishSharedGeometry(error:"Windows could not confirm the requested window geometry.");return
                }
                self.geometryExpected=expected;self.geometryConfirmed=nil;self.expectedSize=nil
                self.readSharedGeometry(interaction)
            }
            else {self.pumpSharedGeometry()}
        }
    }
    private func geometryRect(_ value:[String:Any])->NSRect? {
        guard let x=value["x"] as? Double,let y=value["y"] as? Double,
              let width=value["width"] as? Double,let height=value["height"] as? Double,
              x.isFinite,y.isFinite,width.isFinite,height.isFinite,width>0,height>0 else{return nil}
        return NSRect(x:x,y:y,width:width,height:height)
    }
    private func readSharedGeometry(_ interaction:String){
        geometryRead?.cancel()
        geometryRead=Task{@MainActor [weak self] in
            try? await Task.sleep(for:.milliseconds(180))
            guard !Task.isCancelled,let self,self.geometryInteraction == interaction else{return}
            self.bridge.command("geometry",["window":self.id],timeout:.seconds(1)){[weak self] result in
                guard let self,self.geometryInteraction == interaction,self.geometryFinishing else{return}
                guard case .success(let reply)=result,let value=reply["value"] as? [String:Any],
                      let actual=self.geometryRect(value),let expected=self.geometryExpected else {
                    self.finishSharedGeometry(error:"Windows could not confirm this window geometry.");return
                }
                self.sourceRect=actual
                // An async SetWindowPos can still be queued on the app thread.
                // Old dimensions matching an old frame do not complete a move.
                self.geometryConfirmed=actual == expected ? actual:nil
                self.expectedSize=self.geometryConfirmed?.size
                if actual == expected,self.frameSize == actual.size {self.finishSharedGeometry()}
                else {self.readSharedGeometry(interaction)}
            }
        }
    }
    private func finishSharedGeometry(error:String?=nil){
        guard geometryInteraction != nil else{return}
        if error != nil {
            if inputBlocked || !deferredInput.isEmpty {cancelInput()}
            else {gesture=nil}
        }
        else if let geometryConfirmed {sourceRect=geometryConfirmed}
        cancelSharedGeometry()
        applySourceFrame();bridge.command("release");onGeometry?()
        if let error {onError?(error)}
        trace("geometry_finished")
    }
    private func cancelSharedGeometry(){
        let hadInteraction=geometryInteraction != nil
        geometryInteraction=nil;geometryActive=false;geometryFinishing=false
        geometryInFlight=false;geometryPending=nil;geometrySent=nil
        geometryExpected=nil;geometryConfirmed=nil
        geometryTimer?.invalidate();geometryTimer=nil
        geometryDeadline?.cancel();geometryDeadline=nil
        geometryRead?.cancel();geometryRead=nil
        nativeMoveTimer?.invalidate();nativeMoveTimer=nil
        if hadInteraction {
            nativeResizing=false;expectedSize=nil;content.suspendedPointer=false
            content.clearModifiers();bridge.command("release")
        }
    }
    private func trace(_ event:String){
        guard ProcessInfo.processInfo.environment["PERPENDICULAR_STATE_TRACE"] == "1" else{return}
        let value:[String:Any]=["type":event,"window":id,
            "nativeResizing":nativeResizing,"expectedSize":expectedSize != nil,"inputBlocked":inputBlocked,
            "mac":[window.frame.minX,window.frame.minY,window.frame.width,window.frame.height],
            "guest":[sourceRect.minX,sourceRect.minY,sourceRect.width,sourceRect.height]]
        if let data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]){try? FileHandle.standardError.write(contentsOf:data+Data([10]))}
    }
    private func toggleZoom(){
        guard canResize,expectedSize == nil else{return}
        beginResize()
        if let restore=zoomRestore {window.setFrame(restore,display:true);zoomRestore=nil}
        else if let sharedDisplay {
            zoomRestore=window.frame
            let area=sharedDisplay.macFrame(forGuest:sharedDisplay.guestWorkArea ?? sharedDisplay.guestFrame)
            window.setFrame(window.frameRect(forContentRect:area),display:true)
        }
        else {zoomRestore=window.frame;let top=window.frame.maxY;window.setFrame(NSRect(x:window.frame.minX,y:top-window.maxSize.height,width:window.maxSize.width,height:window.maxSize.height),display:true)}
        commitResize()
    }
    func windowDidBecomeKey(_ notification:Notification){if !role.transient{bridge.command("activate",["window":id])}}
    func windowDidResignKey(_ notification:Notification){
        if !role.transient {
            cancelInput("The window lost focus before the pending input could be sent.")
            if geometryInteraction != nil {finishSharedGeometry()}
            if nativeResizing {
                resizeSerial+=1;liveResizeTimer?.invalidate();liveResizeTimer=nil;liveResizeSize=nil;liveResizeInFlight=false
                nativeResizing=false;content.suspendedPointer=false;applyFrameSize()
            }
        }
    }
    func windowDidDeminiaturize(_ notification:Notification){bridge.command("activate",["window":id])}
    func windowWillMove(_ notification:Notification){
        guard role == .dialog,sharedDisplay != nil,!applyingSourceGeometry,
              NSEvent.pressedMouseButtons & 1 != 0,NSApp.currentEvent?.window === window else{return}
        beginSharedGeometry()
        let timer=Timer(timeInterval:0.05,repeats:true){[weak self] _ in
            MainActor.assumeIsolated {
                guard let self,self.geometryActive else{return}
                if NSEvent.pressedMouseButtons & 1 == 0 {self.commitSharedGeometry()}
            }
        }
        nativeMoveTimer=timer;RunLoop.main.add(timer,forMode:.common)
    }
    func windowDidMove(_ notification:Notification){
        if !applyingSourceGeometry,geometryActive,!nativeResizing {updateSharedGeometry()}
        onGeometry?()
    }
    func windowDidResize(_ notification:Notification){updateLiveResize();onGeometry?()}
    func windowWillStartLiveResize(_ notification:Notification){if !role.transient{beginResize()}}
    func windowDidEndLiveResize(_ notification:Notification){if !role.transient{commitResize()}}
    func windowShouldZoom(_ window:NSWindow,toFrame newFrame:NSRect)->Bool{toggleZoom();return false}
}
