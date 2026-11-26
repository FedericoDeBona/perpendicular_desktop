import AppKit
import CryptoKit

@MainActor
private final class DesktopSurface:NSView {
    private static let concealedCursor=NSCursor(image:NSImage(size:NSSize(width:1,height:1)),hotSpot:.zero)
    private static let scrollPointsPerNotch=40.0
    // .NET Framework WinForms loads its embedded Hand.cur as a custom cursor.
    private static let winFormsHandDigest: [UInt8] = [
        0x62,0xf1,0x45,0x1b,0xb7,0x65,0x86,0x8f,0x36,0x62,0x79,0x9a,0x88,0x90,0x10,0x21,
        0xf5,0x8d,0x08,0x31,0x11,0x0a,0xaa,0x44,0x68,0xb7,0x88,0x54,0x32,0x67,0x46,0x3b
    ]
    let renderer:WindowRenderer
    var onResize:(()->Void)?
    var onUserInput:(()->Void)?
    var connection:DesktopConnection? {didSet{if oldValue !== connection {scrollRemainder=0}}}
    var bridge:GuestBridge?
    var inputAvailable=true
    private var clipboardRequest:UUID?
    private var clipboardBusy=false
    private var consumed=Set<UInt16>()
    var inputScreen=DesktopScreen(id:0,x:0,y:0,width:800,height:600)
    var source=NSSize(width:800,height:600)
    private var buttons:UInt8=0
    private var keys:[UInt16:UInt32]=[:]
    private var modifiers=Set<UInt32>()
    private var cursor=NSPoint.zero
    private var scrollRemainder=0.0
    private var desktopCursor=concealedCursor
    private var activeForHover:Bool {NSApp.isActive && window?.isKeyWindow == true}
    var usesDesktopCursor:Bool {activeForHover && NSCursor.current === desktopCursor}
    var usesMacPointingHand:Bool {usesDesktopCursor && desktopCursor === NSCursor.pointingHand}
    override var isFlipped:Bool {true}
    override var acceptsFirstResponder:Bool {true}
    override func acceptsFirstMouse(for event:NSEvent?)->Bool{true}
    init(renderer:WindowRenderer){
        self.renderer=renderer
        super.init(frame:NSRect(x:0,y:0,width:960,height:640));wantsLayer=true;layer=renderer.layer
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    override func setFrameSize(_ size:NSSize){super.setFrameSize(size);resize()}
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();resize()}
    override func viewDidChangeBackingProperties(){super.viewDidChangeBackingProperties();resize()}
    private func resize(){renderer.resize(bounds.size,scale:Double(window?.backingScaleFactor ?? 1));if !inLiveResize {onResize?()}}
    override func viewDidEndLiveResize(){super.viewDidEndLiveResize();onResize?()}
    override func updateTrackingAreas(){
        for area in trackingAreas {removeTrackingArea(area)}
        addTrackingArea(NSTrackingArea(rect:bounds,options:[.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self))
        super.updateTrackingAreas()
    }
    override func resetCursorRects(){
        addCursorRect(visibleRect,cursor:activeForHover ? desktopCursor:.arrow)
    }
    func setDesktopCursor(_ value:[String:Any]?){
        desktopCursor=cursorShape(value)
        updateDesktopCursor()
    }
    func updateDesktopCursor(){
        guard let window else{return}
        window.invalidateCursorRects(for:self)
        if activeForHover,window.attachedSheet == nil,
           visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream,from:nil)) {
            desktopCursor.set()
        }
    }
    private func cursorShape(_ value:[String:Any]?)->NSCursor {
        switch value?["name"] as? String {
        case nil,"hidden":return Self.concealedCursor
        case "hand":return .pointingHand
        case "text":return .iBeam
        case "crosshair":return .crosshair
        case "forbidden":return .operationNotAllowed
        case "move":return .openHand
        case "resizeHorizontal":return .resizeLeftRight
        case "resizeVertical":return .resizeUpDown
        case "resizeNWSE":return ResizeEdges([.top,.left]).cursor
        case "resizeNESW":return ResizeEdges([.top,.right]).cursor
        case "image":
            guard let value,let w=value["width"] as? Int,let h=value["height"] as? Int,
                  (1...128).contains(w),(1...128).contains(h),
                  let x=value["x"] as? Int,let y=value["y"] as? Int,(0..<w).contains(x),(0..<h).contains(y),
                  let encoded=value["bgra"] as? String,encoded.utf8.count==((w*h*4+2)/3)*4,
                  let data=Data(base64Encoded:encoded),data.count==w*h*4 else{return .arrow}
            if w == 32,h == 32,x == 5,y == 0,SHA256.hash(data:data).elementsEqual(Self.winFormsHandDigest) {
                return .pointingHand
            }
            guard let provider=CGDataProvider(data:data as CFData),
                  let cg=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,
                      space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:[.byteOrder32Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue)],
                      provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else{return .arrow}
            let scale=window?.backingScaleFactor ?? 1
            let image=NSImage(cgImage:cg,size:NSSize(width:Double(w)/scale,height:Double(h)/scale))
            return NSCursor(image:image,hotSpot:NSPoint(x:Double(x)/scale,y:Double(y)/scale))
        default:return .arrow
        }
    }
    private func mouse(_ event:NSEvent){
        guard inputAvailable,source.width>0,source.height>0,bounds.width>0,bounds.height>0 else{return}
        window?.makeFirstResponder(self)
        // Desktop presentation fills the view on both axes. Input must use
        // that same transform, including the taskbar and all four corners.
        let local=convert(event.locationInWindow,from:nil)
        let x=max(0,min(1,local.x/bounds.width)),y=max(0,min(1,local.y/bounds.height))
        cursor=NSPoint(x:inputScreen.x+Int((x*Double(inputScreen.width-1)).rounded()),y:inputScreen.y+Int((y*Double(inputScreen.height-1)).rounded()))
        connection?.pointer(x:Int(cursor.x),y:Int(cursor.y),buttons:buttons)
    }
    override func mouseMoved(with event:NSEvent){if activeForHover {mouse(event)}}
    override func mouseEntered(with event:NSEvent){if activeForHover {mouse(event)}}
    override func mouseExited(with event:NSEvent){scrollRemainder=0}
    override func mouseDragged(with event:NSEvent){mouse(event)}
    override func rightMouseDragged(with event:NSEvent){mouse(event)}
    override func mouseDown(with event:NSEvent){guard inputAvailable else{return};buttons |= 1;mouse(event);onUserInput?()}
    override func mouseUp(with event:NSEvent){buttons &= ~1;mouse(event)}
    override func rightMouseDown(with event:NSEvent){guard inputAvailable else{return};buttons |= 4;mouse(event);onUserInput?()}
    override func rightMouseUp(with event:NSEvent){buttons &= ~4;mouse(event)}
    override func scrollWheel(with event:NSEvent){
        guard inputAvailable,let connection else{return}
        let delta=Double(event.scrollingDeltaY)
        let notches:Int
        if event.hasPreciseScrollingDeltas {
            if event.phase.contains(.began) || event.momentumPhase.contains(.began) {scrollRemainder=0}
            defer {
                if !event.phase.intersection([.ended,.cancelled]).isEmpty || event.momentumPhase.contains(.ended) {
                    scrollRemainder=0
                }
            }
            // RFB carries whole wheel notches. Retain sub-notch movement
            // within the gesture instead of sending a notch per trackpad event.
            let limit=Self.scrollPointsPerNotch*8
            scrollRemainder+=max(-limit,min(limit,delta))
            notches=Int(scrollRemainder/Self.scrollPointsPerNotch)
            scrollRemainder-=Double(notches)*Self.scrollPointsPerNotch
        }else{
            scrollRemainder=0
            notches=delta == 0 ? 0 : (delta>0 ? 1:-1)
        }
        guard notches != 0 else{return}
        mouse(event)
        let wheel:UInt8=notches>0 ? 8:16
        for _ in 0..<abs(notches) {
            connection.pointer(x:Int(cursor.x),y:Int(cursor.y),buttons:buttons | wheel)
            connection.pointer(x:Int(cursor.x),y:Int(cursor.y),buttons:buttons)
        }
    }
    private func symbol(_ event:NSEvent)->UInt32?{
        let specials:[UInt16:UInt32]=[36:0xff0d,48:0xff09,51:0xff08,53:0xff1b,117:0xffff,
            115:0xff50,119:0xff57,116:0xff55,121:0xff56,123:0xff51,124:0xff53,125:0xff54,126:0xff52]
        if let value=specials[event.keyCode]{return value}
        guard let value=event.charactersIgnoringModifiers?.unicodeScalars.first?.value else{return nil}
        if value<256{return value}
        if (0xf704...0xf70f).contains(value){return 0xffbe+(value-0xf704)}
        return 0x01000000|value
    }
    private func chord(_ values:[UInt32]){
        releaseInput()
        for value in values {connection?.key(value,down:true)}
        for value in values.reversed(){connection?.key(value,down:false)}
        onUserInput?()
    }
    @objc func closeDocument(_ sender:Any?){chord([0xffe3,0x77])}
    override func selectAll(_ sender:Any?){chord([0xffe3,0x61])}
    @objc func copy(_ sender:Any?){transferClipboard("copy")}
    @objc func cut(_ sender:Any?){transferClipboard("cut")}
    @objc func paste(_ sender:Any?){transferClipboard("paste")}
    private func clipboardError(_ message:String){
        guard let window else{return}
        let alert=NSAlert();alert.messageText="Appunti";alert.informativeText=message;alert.beginSheetModal(for:window)
    }
    private func transferClipboard(_ action:String){
        guard inputAvailable,!clipboardBusy,window?.isKeyWindow == true,window?.firstResponder === self,let bridge else{return}
        let board=NSPasteboard.general,version=board.changeCount,nonce=UUID()
        var request:[String:Any]=["action":action == "paste" ? "write":"prepare"]
        if action == "paste" {
            guard !board.canReadObject(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]),let text=board.string(forType:.string),!text.contains("\0"),text.utf8.count<=262_144 else{
                clipboardError("Il trasferimento supporta testo fino a 256 KB. I file non sono ancora supportati.");return
            }
            request["text"]=text
        }
        releaseInput();clipboardRequest=nonce;clipboardBusy=true
        bridge.command("desktop_clipboard",request,timeout:.seconds(3)){[weak self] result in
            guard let self,self.clipboardRequest == nonce else{return}
            guard self.window?.isKeyWindow == true else{self.clipboardBusy=false;return}
            guard case .success(let reply)=result,let value=reply["value"] as? [String:Any] else{
                self.clipboardBusy=false
                if case .failure(let error)=result {self.clipboardError(error.localizedDescription)}
                return
            }
            self.chord([0xffe3,action == "paste" ? 0x76:action == "cut" ? 0x78:0x63])
            if action == "paste" {self.clipboardBusy=false;return}
            self.connection?.inputSubmitted{[weak self] in
                guard let self,self.clipboardRequest == nonce,self.window?.isKeyWindow == true else{return}
                bridge.command("desktop_clipboard",["action":"read","sequence":value["sequence"] ?? 0,"foreground":value["foreground"] ?? 0],timeout:.seconds(3)){[weak self] result in
                    guard let self,self.clipboardRequest == nonce else{return}
                    self.clipboardBusy=false
                    guard self.window?.isKeyWindow == true else{return}
                    guard case .success(let reply)=result,let value=reply["value"] as? [String:Any],let text=value["text"] as? String else{
                        if case .failure(let error)=result {self.clipboardError(error.localizedDescription)}
                        return
                    }
                    guard board.changeCount == version else{self.clipboardError("Gli appunti Mac sono cambiati durante la copia; li ho conservati.");return}
                    board.clearContents();board.setString(text,forType:.string)
                }
            }
        }
    }
    override func performKeyEquivalent(with event:NSEvent)->Bool{
        guard window?.isKeyWindow == true,window?.firstResponder === self,event.modifierFlags.contains(.command) else{return false}
        if [4,46,48,49,50,43].contains(event.keyCode) || (event.keyCode == 3 && event.modifierFlags.contains(.control)){return false}
        keyDown(with:event);return true
    }
    override func keyDown(with event:NSEvent){
        guard inputAvailable,!clipboardBusy else{return}
        let flags=event.modifierFlags,shift:[UInt32]=flags.contains(.shift) ? [0xffe1]:[]
        if flags.contains(.command),!flags.contains(.control),!flags.contains(.option){
            consumed.insert(event.keyCode)
            switch event.keyCode {
            case 8:if !event.isARepeat {copy(nil)};return
            case 7:if !event.isARepeat {cut(nil)};return
            case 9:if !event.isARepeat {paste(nil)};return
            case 12:if !event.isARepeat {chord([0xffe9,0xffc1])};return
            case 6 where flags.contains(.shift):chord([0xffe3,0x79]);return
            case 123:chord(shift+[0xff50]);return
            case 124:chord(shift+[0xff57]);return
            case 126:chord(shift+[0xffe3,0xff50]);return
            case 125:chord(shift+[0xffe3,0xff57]);return
            case 51:chord([0xffe1,0xff50]);chord([0xff08]);return
            default:if let value=symbol(event){chord(shift+[0xffe3,value])};return
            }
        }
        if flags.contains(.option),!flags.contains(.command),!flags.contains(.control),[51,117,123,124].contains(event.keyCode),let value=symbol(event){
            consumed.insert(event.keyCode);chord(shift+[0xffe3,value]);return
        }
        synchronizeModifiers(flags)
        if let value=symbol(event){keys[event.keyCode]=value;connection?.key(value,down:true);onUserInput?()}
    }
    override func keyUp(with event:NSEvent){if consumed.remove(event.keyCode) != nil{return};if let value=keys.removeValue(forKey:event.keyCode){connection?.key(value,down:false)}}
    override func flagsChanged(with event:NSEvent){if inputAvailable && !clipboardBusy {synchronizeModifiers(event.modifierFlags)}}
    private func synchronizeModifiers(_ flags:NSEvent.ModifierFlags){
        var next=Set<UInt32>()
        // Match the application-window convention: Command is Control in the
        // guest. AppKit can consume Command shortcuts without tapping Windows
        // and accidentally opening Start when the console loses focus.
        for (flag,key):(NSEvent.ModifierFlags,UInt32) in [(.shift,0xffe1),(.control,0xffe3),(.option,0xffe9),(.command,0xffe3)] {
            if flags.contains(flag){next.insert(key)}
        }
        for key in modifiers.subtracting(next){connection?.key(key,down:false)}
        for key in next.subtracting(modifiers){connection?.key(key,down:true)}
        modifiers=next
    }
    func cancelClipboard(){clipboardRequest=nil;clipboardBusy=false}
    func releaseInput(){
        for key in Set(keys.values).union(modifiers){connection?.key(key,down:false)}
        keys.removeAll();modifiers.removeAll();buttons=0;scrollRemainder=0
        connection?.pointer(x:Int(cursor.x),y:Int(cursor.y),buttons:0)
    }
}

@MainActor
final class DesktopWindow:NSObject,NSWindowDelegate {
    private struct CursorProbe {
        let id=UUID()
        let started=ProcessInfo.processInfo.systemUptime
        let background:UInt32
        let size:NSSize
        let reply:([String:Any])->Void
        var samples=[[String:Any]]()
    }

    let window:NSWindow
    private let surface:DesktopSurface
    private let socket:String
    private let endpoint:()->NativeDisplayEndpoint?
    private var desktop:DesktopConnection?
    private var native:NativeDisplayReader?
    private var connectionID:UUID?
    private var readerID:UUID?
    private var nativeActive=false
    private var timer:Timer?
    private var visible=false
    private var fullScreenTransition=false
    private var pendingResolution:NSSize?
    private var cursorLease:String?
    private var cursorName:String?
    private var cursorLastReply=0.0
    private var cursorProbe:CursorProbe?
    private var nativeReceivedFrames:UInt64=0
    private var presentedDrawables:UInt64=0
    private var lastNativeReceiveSeconds=0.0
    private var lastPresentationSeconds=0.0
    private let resized:(NSSize)->Void

    var state:[String:Any] {["visible":visible,"fullScreen":window.styleMask.contains(.fullScreen),"fullScreenTransition":fullScreenTransition,"resolutionPending":pendingResolution != nil,"viewWidth":Int(surface.bounds.width),"viewHeight":Int(surface.bounds.height),"backingScale":window.backingScaleFactor,"nativeActive":nativeActive,"width":Int(surface.source.width),"height":Int(surface.source.height),"nativeReceivedFrames":nativeReceivedFrames,"presentedDrawables":presentedDrawables,"lastNativeReceiveHostSeconds":lastNativeReceiveSeconds,"lastPresentationHostSeconds":lastPresentationSeconds,"usesDesktopCursor":surface.usesDesktopCursor,"cursorShape":cursorName as Any? ?? NSNull(),"cursorTracking":cursorLease != nil]}
    init(socket:String,endpoint:@escaping ()->NativeDisplayEndpoint?,resized:@escaping (NSSize)->Void = {_ in},input:@escaping ()->Void = {})throws{
        self.socket=socket;self.endpoint=endpoint;self.resized=resized;surface=DesktopSurface(renderer:try WindowRenderer(opaque:true,fillBounds:true))
        window=NSWindow(contentRect:NSRect(x:140,y:120,width:960,height:640),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init()
        surface.renderer.onPresented={ [weak self] _ in
            guard let self else{return}
            self.presentedDrawables &+= 1
            self.lastPresentationSeconds=ProcessInfo.processInfo.systemUptime
        }
        surface.onUserInput=input
        window.title="Desktop Mode";window.isReleasedWhenClosed=false;window.contentView=surface;window.delegate=self
        surface.onResize={ [weak self] in self?.publishSize() }
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.backgroundColor = .black
        window.minSize=NSSize(width:480,height:320);window.acceptsMouseMovedEvents=true
    }
    func configureClipboard(_ bridge:GuestBridge?){surface.bridge=bridge}
    private var cursorEligible:Bool {
        visible && window.isVisible && !window.isMiniaturized &&
            surface.inputAvailable && surface.connection != nil && surface.bridge?.desktopCursorAvailable == true
    }
    private func refreshCursorLease(){
        guard cursorEligible else{releaseCursorLease();return}
        // Ask for a fresh shape after a delayed reply without explicitly
        // showing the Windows pointer between consecutive active leases.
        if cursorLease != nil,ProcessInfo.processInfo.systemUptime-cursorLastReply>2.5 {
            cursorLease=nil;cursorName=nil;surface.setDesktopCursor(nil)
        }
        let lease=cursorLease ?? UUID().uuidString.replacingOccurrences(of:"-",with:"")
        if cursorLease == nil {cursorLease=lease;cursorLastReply=ProcessInfo.processInfo.systemUptime}
        surface.bridge?.desktopCursorLease(lease,active:true)
    }
    private func releaseCursorLease(){
        guard let lease=cursorLease else{return}
        cursorLease=nil;cursorName=nil
        surface.setDesktopCursor(nil)
        surface.bridge?.desktopCursorLease(lease,active:false)
    }
    func acceptCursor(_ header:[String:Any]){
        guard cursorEligible,let cursorLease,header["lease"] as? String == cursorLease else{return}
        cursorLastReply=ProcessInfo.processInfo.systemUptime
        guard header["hidden"] as? Bool == true else{
            cursorName=nil;surface.setDesktopCursor(nil);return
        }
        if let shape=header["cursor"] as? [String:Any],let name=shape["name"] as? String {
            cursorName=name;surface.setDesktopCursor(shape)
        }
    }
    func cursorConnectionChanged(){releaseCursorLease();refreshCursorLease()}
    func probeCursorFrames(background:UInt32,reply:@escaping ([String:Any])->Void){
        guard visible,nativeActive,pendingResolution == nil,cursorProbe == nil else {
            reply(["ok":false,"error":"Open an idle, accelerated Desktop Mode window before starting a cursor probe."]);return
        }
        let probe=CursorProbe(background:background,size:surface.source,reply:reply)
        cursorProbe=probe
        Task { @MainActor [self,id=probe.id] in
            try? await Task.sleep(for:.seconds(8))
            guard cursorProbe?.id == id else{return}
            finishCursorProbe()
        }
    }
    private func sampleCursorFrame(_ frame:NativeDisplayFrame){
        guard let started=cursorProbe?.started,let background=cursorProbe?.background else{return}
        guard surface.source == cursorProbe?.size else {
            finishCursorProbe(error:"The desktop resolution changed during the cursor probe.");return
        }
        var sample=frame.measureCursorRegion(background:background)
        sample["milliseconds"]=Int((ProcessInfo.processInfo.systemUptime-started)*1000)
        sample["frame"]=frame.traceID
        sample["cursor"]=cursorName as Any? ?? NSNull()
        sample["usingMacCursor"]=surface.usesDesktopCursor
        sample["usingMacPointingHand"]=surface.usesMacPointingHand
        cursorProbe?.samples.append(sample)
        if cursorProbe?.samples.count == 640 {finishCursorProbe()}
    }
    private func finishCursorProbe(error:String?=nil){
        guard let probe=cursorProbe else{return}
        cursorProbe=nil
        if let error {probe.reply(["ok":false,"error":error]);return}
        let matched=probe.samples.filter{$0["backgroundMatched"] as? Bool == true}
        let marked=matched.filter{($0["differentPixels"] as? Int ?? 0)>0}.count
        probe.reply(["ok":true,"result":["frames":probe.samples.count,"backgroundFrames":matched.count,
                     "framesWithMarks":marked,"samples":probe.samples]])
    }
    private func publishSize(){
        guard visible,!fullScreenTransition,!window.inLiveResize else{return}
        resized(surface.convertToBacking(surface.bounds).size)
    }
    func beginResolutionChange(_ size:NSSize){
        finishCursorProbe(error:"The desktop started resizing during the cursor probe.")
        pendingResolution=size;surface.releaseInput();surface.inputAvailable=false;releaseCursorLease()
    }
    func finishResolutionChange(){pendingResolution=nil;surface.inputAvailable=true;refreshCursorLease()}
    func show(){
        visible=true;window.makeKeyAndOrderFront(nil);window.makeFirstResponder(surface)
        NSApp.activate(ignoringOtherApps:true);connect();surface.onResize?()
        refreshCursorLease()
        if timer == nil {timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] _ in
            Task{@MainActor in self?.connect();self?.refreshCursorLease()}
        }}
    }
    func stop(){
        finishCursorProbe(error:"Desktop Mode closed during the cursor probe.")
        visible=false;timer?.invalidate();timer=nil;releaseCursorLease();surface.cancelClipboard();surface.releaseInput()
        connectionID=nil;readerID=nil;surface.connection=nil
        desktop?.stop();desktop=nil;native?.stop();native=nil;nativeActive=false;surface.renderer.clear()
    }
    private func connect(){
        guard visible else{return}
        if desktop == nil {
            let id=UUID();connectionID=id
            let client=DesktopConnection(path:socket,receive:{[weak self] pixels,width,height in
                guard let self,self.visible,self.connectionID == id,!self.nativeActive,self.pendingResolution == nil else{return}
                self.surface.source=NSSize(width:width,height:height)
                self.surface.renderer.present(pixels,width:width,height:height);self.window.title="Desktop Mode"
            },layout:{[weak self] screen in
                guard let self,self.connectionID == id,!self.nativeActive else{return};self.surface.inputScreen=screen
            },failed:{[weak self] message in
                guard let self,self.connectionID == id else{return}
                self.desktop=nil;self.surface.connection=nil;self.releaseCursorLease()
                if !self.nativeActive {self.window.title="Desktop Mode — \(message)"}
            })
            desktop=client;surface.connection=client;client.start()
        }
        if native == nil,let endpoint=endpoint(),FileManager.default.fileExists(atPath:endpoint.socketPath){
            let id=UUID();readerID=id
            let reader=NativeDisplayReader(endpoint:endpoint,device:surface.renderer.device,receive:{[weak self] frame in
                guard let self,self.visible,self.readerID == id else{return}
                if let pending=self.pendingResolution,
                   frame.texture.width != Int(pending.width) || frame.texture.height != Int(pending.height) {
                    frame.finishReading();return
                }
                self.nativeActive=true;self.desktop?.requestPixels(false)
                self.nativeReceivedFrames &+= 1
                self.lastNativeReceiveSeconds=ProcessInfo.processInfo.systemUptime
                self.surface.source=NSSize(width:frame.texture.width,height:frame.texture.height)
                self.surface.inputScreen=DesktopScreen(id:0,x:0,y:0,width:frame.texture.width,height:frame.texture.height)
                self.sampleCursorFrame(frame)
                self.surface.renderer.present(frame);self.window.title="Desktop Mode"
            },failed:{[weak self] message in
                guard let self,self.readerID == id else{return}
                let wasNative=self.nativeActive
                self.readerID=nil;self.native?.stop();self.native=nil;self.nativeActive=false
                self.finishCursorProbe(error:"The accelerated desktop disconnected during the cursor probe.")
                if wasNative {
                    if self.pendingResolution == nil {self.surface.renderer.clear()}
                    self.desktop?.requestPixels(true)
                }
                if self.pendingResolution != nil {
                    Task{@MainActor [weak self] in
                        try? await Task.sleep(for:.milliseconds(250))
                        guard let self,self.visible,self.pendingResolution != nil,self.native == nil else{return}
                        self.connect()
                    }
                }else{self.window.title="Desktop Mode — \(message)"}
            })
            native=reader;reader.start()
        }
    }
    func windowWillClose(_ notification:Notification){stop()}
    func windowDidBecomeKey(_ notification:Notification){surface.updateDesktopCursor();refreshCursorLease()}
    func windowDidResignKey(_ notification:Notification){surface.updateDesktopCursor();surface.cancelClipboard();surface.releaseInput()}
    func windowDidMiniaturize(_ notification:Notification){releaseCursorLease()}
    func windowDidDeminiaturize(_ notification:Notification){refreshCursorLease()}
    func windowWillEnterFullScreen(_ notification:Notification){fullScreenTransition=true}
    func windowWillExitFullScreen(_ notification:Notification){fullScreenTransition=true}
    func windowDidEnterFullScreen(_ notification:Notification){fullScreenTransition=false;publishSize()}
    func windowDidExitFullScreen(_ notification:Notification){fullScreenTransition=false;publishSize()}
    func windowDidFailToEnterFullScreen(_ window:NSWindow){fullScreenTransition=false;publishSize()}
    func windowDidFailToExitFullScreen(_ window:NSWindow){fullScreenTransition=false;publishSize()}
    func windowDidResize(_ notification:Notification){publishSize()}
    func windowDidChangeScreen(_ notification:Notification){publishSize()}
    func windowDidChangeBackingProperties(_ notification:Notification){publishSize()}
}
