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
private final class ResizePreviewView:NSView {
    override func draw(_ dirtyRect:NSRect){
        let outline=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:2,yRadius:2)
        NSColor.controlAccentColor.withAlphaComponent(0.08).setFill();outline.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke();outline.lineWidth=1;outline.stroke()
    }
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
    private let transitionView=WindowTransitionView(frame:.zero)
    private var transitionActive=false
    private var transitionID=UUID()
    private var transitionAfterPresentation:UInt64=0
    private var lastPresentedID:UInt64=0
    private var receivedSequence:UInt64=0
    private var acceptedSequence:UInt64=0
    private var transitionTimeout:Task<Void,Never>?
    private var displayUpdating=false
    private var displayPriorRaster:NSSize?
    private var allowTransparentFrame=false
    private var rejectedTransitionPacket:GuestPacket?
    private let bridge:GuestBridge
    private var sourceClosed=false
    private var closing=false
    private var hasFrame=false
    private var rejectedDiagnosticFrames=0
    private var frameSize=NSSize.zero
    private var sourceRect=NSRect.zero
    private var minimized=false
    private var visible=true
    private var placedDialog=false
    private var gesture:MouseGesture?
    private var inputBlocked=false
    private var clipboardRequest:UUID?
    private var deferredInput:[WindowInput]=[]
    private var deferredTextBytes=0
    private var drainingInput=false
    private var discardingInput=false
    private var canResize=true
    private var nativeResizing=false
    private var resizePreview:NSPanel?
    private var resizePreviewFrame:NSRect?
    private var resizePreviewPacket:GuestPacket?
    private var resizePreviewObservedGeometry:NSRect?
    private var nativeResizeFrame:NSRect?
    private var nativeResizeFromLeft=false
    private var nativeResizeFromBottom=false
    private var resizeSerial=0
    private var expectedSize:NSSize?
    private var resizeDeadline:Task<Void,Never>?
    private var pixelScale=1.0
    private var fallbackPixelScale=1.0
    private var sharedDisplay:SharedDisplay?
    private var applyingSourceGeometry=false
    private var adjustedInitialPlacement=false
    private var maximumPixels=NSSize(width:4096,height:4096)
    private var minimumPixels=NSSize(width:160,height:100)
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
    var onRecovery:(()->Void)?
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
        let container=NSView(frame:rect)
        content.frame=container.bounds;content.autoresizingMask=[.width,.height];container.addSubview(content)
        transitionView.frame=container.bounds;transitionView.autoresizingMask=[.width,.height]
        if !role.transient {container.addSubview(transitionView)}
        window.title=title;window.contentView=container;window.delegate=self;window.isReleasedWhenClosed=false
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
        content.onFramePresented={ [weak self] id in self?.frameWasPresented(id) }
        content.onRenderError={ [weak self] message in self?.failFrameTransition();self?.onError?(message) }
        transitionView.recovery={ [weak self] in self?.onRecovery?() }
        transitionView.reveal={ [weak self] in
            guard let self else{return};self.allowTransparentFrame=true
            if let packet=self.rejectedTransitionPacket {self.rejectedTransitionPacket=nil;self.present(packet)}
            else {self.endFrameTransition()}
        }
        (window as? GuestDocumentWindow)?.closeRequested={ [weak self] in self?.requestClose() }
        if role == .main {NSApp.addWindowsItem(window,title:title,filename:false)}
        beginFrameTransition("Preparazione della finestra…")
    }
    func identifyApplication(name:String,icon:NSImage?){transitionView.identify(name:name,icon:icon)}
    func setDisplayUpdating(_ updating:Bool){
        if updating,!displayUpdating {displayPriorRaster=sharedDisplay?.guestFrame.size}
        displayUpdating=updating
        if updating {beginFrameTransition("Connessione a Windows…")}
        else if transitionActive,hasFrame,sourceRect.size == frameSize,
                content.presentationID>=transitionAfterPresentation
                    || (displayPriorRaster != nil && displayPriorRaster == sharedDisplay?.guestFrame.size) {
            // A settings notification need not repaint an unchanged window.
            // Re-present its valid image only when the raster is unchanged.
            content.redrawCurrentFrame()
        }
        trace(updating ? "frame_display_wait":"frame_display_ready")
    }
    private func beginFrameTransition(_ message:String){
        guard !role.transient,!transitionActive else{return}
        if hasFrame {content.clearModifiers();bridge.command("release")}
        transitionActive=true;transitionID=UUID();allowTransparentFrame=false
        content.inputSuspended=true
        transitionAfterPresentation=content.presentationID+1
        content.resizeEnabled=false;transitionView.begin(message)
        transitionTimeout?.cancel();let identity=transitionID
        transitionTimeout=Task{@MainActor [weak self] in
            try? await Task.sleep(for:.seconds(10))
            guard !Task.isCancelled,let self,self.transitionID == identity,self.transitionActive else{return}
            self.failFrameTransition("Windows sta impiegando più tempo.")
        }
        trace("frame_transition_started")
        onGeometry?()
    }
    func failFrameTransition(_ message:String="La finestra non è ancora pronta."){
        guard !role.transient else{return}
        if !transitionActive {beginFrameTransition(message)}
        transitionTimeout?.cancel();transitionTimeout=nil
        transitionAfterPresentation=content.presentationID+1
        transitionView.stalled(message,canReveal:hasFrame || rejectedTransitionPacket != nil)
        trace("frame_transition_stalled")
    }
    private func frameWasPresented(_ id:UInt64){
        lastPresentedID=max(lastPresentedID,id)
        if transitionActive {trace("frame_transition_presented")}
        guard transitionActive,id>=transitionAfterPresentation,!displayUpdating,
              !geometryFinishing,expectedSize == nil,!nativeResizing else{return}
        endFrameTransition()
    }
    private func endFrameTransition(){
        content.clearModifiers();content.inputSuspended=false
        transitionActive=false;transitionTimeout?.cancel();transitionTimeout=nil;rejectedTransitionPacket=nil
        content.resizeEnabled=role == .main && canResize
        if window.isKeyWindow {window.makeFirstResponder(content)}
        let identity=transitionID
        transitionView.finish{[weak self] in
            guard let self,self.transitionID == identity,!self.transitionActive else{return}
            self.transitionView.isHidden=true
        }
        trace("frame_transition_finished")
        onGeometry?()
    }
    /// Only a display snapshot confirmed by the frontend can enable shared
    /// placement. Removing that snapshot invalidates every outstanding gesture.
    func setSharedDisplay(_ display:SharedDisplay?){
        guard sharedDisplay != display else{return}
        cancelSharedGeometry()
        if nativeResizing || expectedSize != nil {
            resizeSerial+=1;resizeDeadline?.cancel();resizeDeadline=nil
            nativeResizing=false;expectedSize=nil
            content.suspendedPointer=false;bridge.command("release")
        }
        if inputBlocked || !deferredInput.isEmpty {cancelInput("The display changed before the pending input could be sent.")}
        else {gesture=nil}
        zoomRestore=nil;adjustedInitialPlacement=false;sharedDisplay=display
        pixelScale=display.map{Double($0.pixelScale)} ?? fallbackPixelScale
        applySizeLimits()
        if display != nil {applySourceFrame()}else if hasFrame{applyFrameSize()}
        onGeometry?()
    }
    private func applySizeLimits(){
        guard !role.transient else{return}
        window.minSize=window.frameRect(forContentRect:NSRect(origin:.zero,
            size:NSSize(width:minimumPixels.width*pixelScale,height:minimumPixels.height*pixelScale))).size
        window.maxSize=window.frameRect(forContentRect:NSRect(origin:.zero,
            size:NSSize(width:max(minimumPixels.width,maximumPixels.width)*pixelScale,
                        height:max(minimumPixels.height,maximumPixels.height)*pixelScale))).size
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
            if next.size != sourceRect.size,next.size != frameSize,!nativeResizing {
                beginFrameTransition("Aggiornamento della finestra…")
            }
            sourceRect=next
        }
        canResize=item["resizable"] as? Bool ?? true
        content.resizeEnabled=role == .main && canResize && !transitionActive
        if let width=item["minWidth"] as? Double,let height=item["minHeight"] as? Double,
           width.isFinite,height.isFinite,(1...32768).contains(width),(1...32768).contains(height) {
            minimumPixels=NSSize(width:max(160,width),height:max(100,height))
        }else {minimumPixels=NSSize(width:160,height:100)}
        if let maxWidth=item["maxWidth"] as? Double,let maxHeight=item["maxHeight"] as? Double,maxWidth>=160,maxHeight>=100 {
            maximumPixels=NSSize(width:maxWidth,height:maxHeight)
        }
        applySizeLimits()
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
        if role.transient,owner.transitionActive {window.orderOut(nil);return}
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
        receivedSequence=(packet.header["sequence"] as? NSNumber)?.uint64Value ?? 0
        let nextSize=NSSize(width:width,height:height)
        if resizePreviewFrame != nil {
            // Keep the original window and image intact until the mouse-up
            // request is confirmed and a frame of that resulting size arrives.
            guard !nativeResizing,let expectedSize,expectedSize == nextSize,
                  geometryInteraction == nil || geometryConfirmed?.size == nextSize else {
                resizePreviewPacket=packet;return
            }
            removeResizePreview()
        }
        let changed=nextSize != frameSize
        if first || changed {beginFrameTransition("Aggiornamento della finestra…")}
        guard content.present(packet,requireSolidFrame:transitionActive && !allowTransparentFrame && !role.transient) else {
            recordRejectedDiagnostic(packet)
            rejectedTransitionPacket=packet;trace("frame_transition_rejected");return
        }
        acceptedSequence=receivedSequence
        hasFrame=true
        if first {
            fallbackPixelScale=min(1,min(1100/Double(width),800/Double(height)))
            pixelScale=sharedDisplay.map{Double($0.pixelScale)} ?? fallbackPixelScale
            applySizeLimits()
        }
        frameSize=nextSize
        if let failure=content.renderFailure {onError?(failure)}
        if geometryFinishing,geometryConfirmed != nil,let expectedSize,expectedSize == nextSize {finishSharedGeometry()}
        else if geometryInteraction == nil {
            if let expectedSize,expectedSize == nextSize {finishResize()}
            else if changed && !role.transient && !nativeResizing && self.expectedSize == nil {applyFrameSize()}
        }
        if first || changed {onGeometry?()}
        if transitionActive {trace("frame_transition_accepted")}
        let diagnosticSequence=(packet.header["sequence"] as? NSNumber)?.uint64Value ?? 0
        if (first || (1...3).contains(diagnosticSequence)),ProcessInfo.processInfo.environment["PERPENDICULAR_CAPTURE_DIAGNOSTIC"]=="1",let image=content.currentImage{
            let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Perpendicular Restart/QA")
            try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let name=id.replacingOccurrences(of:":",with:"-")+(first ? "":"-frame-\(diagnosticSequence)")
            try? NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent(name+".png"))
            var metadata=packet.header;metadata["title"]=window.title;metadata["role"]=role.rawValue
            if let bytes=try? JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted]){try? bytes.write(to:directory.appendingPathComponent(name+".json"))}
        }
    }
    /// Accepted-frame diagnostics above cannot explain an image rejected by
    /// the transition gate. Preserve up to three raw rejected packets as well;
    /// never substitute the last accepted image or a composited Mac screenshot.
    private func recordRejectedDiagnostic(_ packet:GuestPacket){
        guard ProcessInfo.processInfo.environment["PERPENDICULAR_CAPTURE_DIAGNOSTIC"]=="1",
              rejectedDiagnosticFrames<3,
              let width=packet.header["width"] as? Int,let height=packet.header["height"] as? Int,
              width>0,height>0,width<=16_384,height<=16_384,width<=8_388_608/height else{return}
        let stride=packet.header["stride"] as? Int ?? width*4
        guard stride>=width*4,stride<=34*1024*1024/height else{return}
        let image:CGImage?
        if let surface=packet.surface {
            guard surface.width==width,surface.height==height,surface.stride==stride else{return}
            image=surface.makeImage()
        }else{
            guard packet.pixels.count==stride*height,let provider=CGDataProvider(data:packet.pixels as CFData) else{return}
            image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:stride,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:[.byteOrder32Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue)],
                provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)
        }
        guard let image else{return}
        rejectedDiagnosticFrames+=1
        let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Perpendicular Restart/QA")
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let sequence=(packet.header["sequence"] as? NSNumber)?.uint64Value ?? 0
        let name=id.replacingOccurrences(of:":",with:"-")+"-rejected-\(rejectedDiagnosticFrames)-frame-\(sequence)"
        try? NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent(name+".png"))
        // PNG conversion may discard RGB stored under alpha zero. Keep the
        // original padded BGRA bytes for an exact comparison with GPU memory.
        let raw=packet.surface.map{Data(bytesNoCopy:$0.contents,count:$0.byteCount,deallocator:.none)} ?? packet.pixels
        withExtendedLifetime(packet.surface){try? raw.write(to:directory.appendingPathComponent(name+".bgra"))}
        var metadata=packet.header;metadata["title"]=window.title;metadata["role"]=role.rawValue
        metadata["diagnosticPixelFormat"]="BGRA8-premultiplied"
        metadata["diagnosticStage"]="received-before-presentation";metadata["transitionAccepted"]=false
        if let bytes=try? JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted]){try? bytes.write(to:directory.appendingPathComponent(name+".json"))}
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
        transitionTimeout?.cancel();transitionTimeout=nil
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
        guard !transitionActive else{return}
        switch value {
        case .input(let packet):
            if packet["event"] as? String == "clipboard",let action=packet["action"] as? String {transferClipboard(action)}
            else {send(packet)}
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
        clipboardRequest=nil
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
    private func transferClipboard(_ action:String){
        guard window.isKeyWindow,window.firstResponder === content else{return}
        let pasteboard=NSPasteboard.general,version=pasteboard.changeCount
        var request:[String:Any]=["window":id,"action":action]
        if action == "paste" {
            guard let text=pasteboard.string(forType:.string),!text.contains("\0"),text.utf8.count<=262_144 else {
                onError?("Gli appunti devono contenere testo, fino a 256 KB.");return
            }
            request["text"]=text
            guard let encoded=try? JSONSerialization.data(withJSONObject:request),encoded.count<1_000_000 else {
                onError?("Il testo degli appunti supera il limite di trasferimento.");return
            }
        }
        let nonce=UUID();clipboardRequest=nonce;inputBlocked=true
        content.clearModifiers()
        bridge.command("clipboard",request,timeout:.seconds(3)){[weak self] result in
            guard let self,self.clipboardRequest == nonce else{return}
            self.clipboardRequest=nil
            defer{self.inputBlocked=false;self.drainInput()}
            guard self.window.isKeyWindow,self.window.firstResponder === self.content else{return}
            guard case .success(let reply)=result,let value=reply["value"] as? [String:Any] else {
                if case .failure(let error)=result {self.onError?(error.localizedDescription)};return
            }
            if action != "paste",let text=value["text"] as? String,text.utf8.count<=262_144 {
                guard pasteboard.changeCount == version else{self.onError?("Gli appunti Mac sono cambiati durante la copia; li ho conservati.");return}
                pasteboard.clearContents();pasteboard.setString(text,forType:.string)
            }
        }
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
        // AppKit rounds titled windows to whole points. An odd guest height
        // at 2:1 scale can therefore differ by half a point without moving
        // the window. Sending that rounding back to a fixed-size dialog asks
        // Windows for an impossible resize and strands its first-frame gate.
        let placed=window.frame
        let roundedPlacement=abs(placed.minX-frame.minX)<=0.5 && abs(placed.minY-frame.minY)<=0.5
            && abs(placed.maxX-frame.maxX)<=0.5 && abs(placed.maxY-frame.maxY)<=0.5
        if !role.transient,hasFrame,window.isVisible,!roundedPlacement,!adjustedInitialPlacement {
            // Reconcile AppKit's placement only after the window is visible
            // with an image. An unsuccessful correction must not restart on
            // every snapshot and keep input suspended indefinitely.
            adjustedInitialPlacement=true
            beginSharedGeometry();commitSharedGeometry()
        }
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
            let edges=canResize ? ResizeEdges(point:event.locationInWindow,bounds:NSRect(origin:.zero,size:window.frame.size)):[]
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
            edges.cursor.set()
            let frame=edges.frame(from:gesture.frame,delta:delta,minimum:window.minSize,maximum:window.maxSize)
            updateResizePreview(frame)
            if up {commitResize()}
        default:break
        }
        if up,self.gesture === gesture {self.gesture=nil}
        if up {trace("gesture_finished")}
    }
    private func beginResize(preview:Bool=true){
        if sharedDisplay != nil {
            beginSharedGeometry();nativeResizing=true
            if preview {updateResizePreview(window.frame)}
            return
        }
        resizeSerial+=1;resizeDeadline?.cancel();expectedSize=nil
        nativeResizing=true;content.suspendedPointer=true;content.clearModifiers()
        bridge.command("cancel_interaction",["window":id])
        if preview {updateResizePreview(window.frame)}
    }
    private func updateResizePreview(_ frame:NSRect){
        resizePreviewFrame=frame
        if resizePreview == nil {
            let panel=GuestPopupPanel(contentRect:frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=false
            panel.ignoresMouseEvents=true;panel.isReleasedWhenClosed=false
            panel.isFloatingPanel=false;panel.hidesOnDeactivate=false
            panel.isExcludedFromWindowsMenu=true
            panel.contentView=ResizePreviewView(frame:NSRect(origin:.zero,size:frame.size))
            window.addChildWindow(panel,ordered:.above);resizePreview=panel
        }
        resizePreview?.setFrame(frame,display:true);resizePreview?.orderFront(nil)
        trace("resize_preview_updated")
    }
    private func closeResizePreviewPanel(){
        if let panel=resizePreview {window.removeChildWindow(panel);panel.close()}
        resizePreview=nil
    }
    private func removeResizePreview(){
        closeResizePreviewPanel()
        resizePreviewFrame=nil;resizePreviewPacket=nil
        resizePreviewObservedGeometry=nil
        nativeResizeFrame=nil
    }
    private func presentResizePreviewPacket(){
        if let packet=resizePreviewPacket {present(packet)}
    }
    private var resizeTargetSize:NSSize {
        // content.bounds can lag behind a programmatic setFrame during tracking.
        // Derive the target from the requested window frame, including dialog chrome.
        let size=window.contentRect(forFrameRect:resizePreviewFrame ?? window.frame).size
        return NSSize(width:max(160,(size.width/pixelScale).rounded()),height:max(100,(size.height/pixelScale).rounded()))
    }
    private func commitResize(){
        if resizeTargetSize == frameSize,(sharedDisplay == nil || sharedTarget == sourceRect) {
            if sharedDisplay != nil {cancelSharedGeometry()}else{finishResize()}
            if transitionActive,hasFrame {endFrameTransition()}
            return
        }
        beginFrameTransition("Aggiornamento della finestra…")
        // Commit the Mac container immediately under the cover. Retain the
        // requested geometry and packet gate until Windows confirms its frame.
        nativeResizing=false;nativeResizeFrame=nil
        closeResizePreviewPanel()
        if let frame=resizePreviewFrame {
            applyingSourceGeometry=true
            window.setFrame(frame,display:true)
            applyingSourceGeometry=false
            trace("resize_mac_committed")
        }
        if sharedDisplay != nil {nativeResizing=false;commitSharedGeometry();return}
        guard canResize,!role.transient else{nativeResizing=false;content.suspendedPointer=false;removeResizePreview();return}
        resizeSerial+=1;let serial=resizeSerial
        nativeResizing=false;expectedSize = .zero;content.suspendedPointer=true
        let size=resizeTargetSize,width=Int(size.width),height=Int(size.height)
        trace("resize_requested")
        resizeDeadline?.cancel()
        resizeDeadline=Task{@MainActor [weak self] in
            try? await Task.sleep(for:.seconds(3))
            guard !Task.isCancelled,let self,self.resizeSerial == serial,self.expectedSize != nil else{return}
            self.finishResize();self.failFrameTransition();self.onError?("Windows did not finish resizing the window.")
        }
        bridge.command("resize",["window":id,"width":width,"height":height],timeout:.seconds(2)){ [weak self] result in
            guard let self,self.resizeSerial == serial,self.expectedSize != nil else{return}
            guard case .success(let reply)=result,let value=reply["value"] as? [String:Any],let width=value["width"] as? Int,let height=value["height"] as? Int else{
                self.finishResize();self.failFrameTransition();self.onError?("Windows could not resize this window.");return
            }
            self.expectedSize=NSSize(width:width,height:height)
            self.presentResizePreviewPacket()
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
                    self.presentResizePreviewPacket()
                    if self.frameSize == self.expectedSize {self.finishResize()}
                }
            }
        }
    }
    private func finishResize(){
        removeResizePreview()
        resizeDeadline?.cancel();resizeDeadline=nil;expectedSize=nil
        nativeResizing=false;content.suspendedPointer=false
        applyFrameSize();bridge.command("release");onGeometry?()
        trace("resize_finished")
    }
    private var sharedTarget:NSRect? {
        guard let sharedDisplay else{return nil}
        let frame=sharedDisplay.guestFrame(forMac:window.contentRect(forFrameRect:resizePreviewFrame ?? window.frame))
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
                // A resize can be clamped by the app's own minimum. Confirm
                // that alternative twice, with a new capture of the same size.
                let packet=self.resizePreviewPacket
                let hasNewFrame=(packet?.header["generation"] as? UInt64).map{$0>self.content.generation} == true
                    && packet?.header["width"] as? Int == Int(actual.width)
                    && packet?.header["height"] as? Int == Int(actual.height)
                let acceptedMinimum=self.resizePreviewFrame != nil && hasNewFrame
                    && self.resizePreviewObservedGeometry == actual
                self.resizePreviewObservedGeometry=actual
                self.geometryConfirmed=actual == expected || acceptedMinimum ? actual:nil
                self.expectedSize=self.geometryConfirmed?.size
                self.presentResizePreviewPacket()
                guard self.geometryInteraction == interaction else{return}
                if self.geometryConfirmed != nil,self.frameSize == actual.size {self.finishSharedGeometry()}
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
        if let error {failFrameTransition();onError?(error)}
        trace("geometry_finished")
    }
    private func cancelSharedGeometry(){
        removeResizePreview()
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
    var presentationState:[String:Any] {
        ["transitionActive":transitionActive,"displayUpdating":displayUpdating,
         "requiredPresentationID":transitionAfterPresentation,"presentedID":lastPresentedID,
         "submittedID":content.presentationID,"hasFrame":hasFrame,
         "receivedSequence":receivedSequence,"acceptedSequence":acceptedSequence,
         "framePixels":[frameSize.width,frameSize.height],
         "geometryFinishing":geometryFinishing,"nativeResizing":nativeResizing,
         "expectedSize":expectedSize != nil]
    }
    private func trace(_ event:String){
        guard ProcessInfo.processInfo.environment["PERPENDICULAR_STATE_TRACE"] == "1" else{return}
        var value:[String:Any]=["type":event,"window":id,
            "uptime":ProcessInfo.processInfo.systemUptime,"mouseButtons":NSEvent.pressedMouseButtons,
            "nativeResizing":nativeResizing,"expectedSize":expectedSize != nil,"inputBlocked":inputBlocked,
            "presentation":presentationState,
            "mac":[window.frame.minX,window.frame.minY,window.frame.width,window.frame.height],
            "guest":[sourceRect.minX,sourceRect.minY,sourceRect.width,sourceRect.height]]
        if let preview=resizePreviewFrame {value["previewMac"]=[preview.minX,preview.minY,preview.width,preview.height]}
        if let data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]){try? FileHandle.standardError.write(contentsOf:data+Data([10]))}
    }
    private func toggleZoom(){
        guard canResize,expectedSize == nil else{return}
        beginFrameTransition("Aggiornamento della finestra…")
        beginResize(preview:false)
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
                resizeSerial+=1
                nativeResizing=false;content.suspendedPointer=false;applyFrameSize()
                removeResizePreview()
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
    func windowDidResize(_ notification:Notification){onGeometry?()}
    func windowWillStartLiveResize(_ notification:Notification){
        guard !role.transient else{return}
        beginResize()
        nativeResizeFrame=window.frame
        let mouse=NSEvent.mouseLocation
        nativeResizeFromLeft=mouse.x<window.frame.midX
        nativeResizeFromBottom=mouse.y<window.frame.midY
    }
    func windowWillResize(_ sender:NSWindow,to frameSize:NSSize)->NSSize{
        guard nativeResizing,let original=nativeResizeFrame else{return frameSize}
        let size=NSSize(width:min(window.maxSize.width,max(window.minSize.width,frameSize.width)),
                        height:min(window.maxSize.height,max(window.minSize.height,frameSize.height)))
        updateResizePreview(NSRect(x:nativeResizeFromLeft ? original.maxX-size.width:original.minX,
                                   y:nativeResizeFromBottom ? original.maxY-size.height:original.minY,
                                   width:size.width,height:size.height))
        return original.size
    }
    func windowDidEndLiveResize(_ notification:Notification){if !role.transient{commitResize()}}
    func windowShouldZoom(_ window:NSWindow,toFrame newFrame:NSRect)->Bool{toggleZoom();return false}
}
