import AppKit

@MainActor
private final class DesktopSurface:NSView {
    let renderer:WindowRenderer
    var onResize:(()->Void)?
    var onUserInput:(()->Void)?
    var connection:DesktopConnection?
    var bridge:GuestBridge?
    private var clipboardRequest:UUID?
    private var clipboardBusy=false
    private var consumed=Set<UInt16>()
    var inputScreen=DesktopScreen(id:0,x:0,y:0,width:800,height:600)
    var source=NSSize(width:800,height:600)
    private var buttons:UInt8=0
    private var keys:[UInt16:UInt32]=[:]
    private var modifiers=Set<UInt32>()
    private var cursor=NSPoint.zero
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
        addTrackingArea(NSTrackingArea(rect:bounds,options:[.mouseMoved,.activeInKeyWindow,.inVisibleRect],owner:self))
        super.updateTrackingAreas()
    }
    private func mouse(_ event:NSEvent){
        guard source.width>0,source.height>0 else{return}
        window?.makeFirstResponder(self)
        let local=convert(event.locationInWindow,from:nil),fit=min(bounds.width/source.width,bounds.height/source.height)
        let origin=NSPoint(x:(bounds.width-source.width*fit)/2,y:(bounds.height-source.height*fit)/2)
        let x=max(0,min(1,(local.x-origin.x)/(source.width*fit))),y=max(0,min(1,(local.y-origin.y)/(source.height*fit)))
        cursor=NSPoint(x:inputScreen.x+Int((x*Double(inputScreen.width-1)).rounded()),y:inputScreen.y+Int((y*Double(inputScreen.height-1)).rounded()))
        connection?.pointer(x:Int(cursor.x),y:Int(cursor.y),buttons:buttons)
    }
    override func mouseMoved(with event:NSEvent){mouse(event)}
    override func mouseDragged(with event:NSEvent){mouse(event)}
    override func rightMouseDragged(with event:NSEvent){mouse(event)}
    override func mouseDown(with event:NSEvent){buttons |= 1;mouse(event);onUserInput?()}
    override func mouseUp(with event:NSEvent){buttons &= ~1;mouse(event)}
    override func rightMouseDown(with event:NSEvent){buttons |= 4;mouse(event);onUserInput?()}
    override func rightMouseUp(with event:NSEvent){buttons &= ~4;mouse(event)}
    override func scrollWheel(with event:NSEvent){
        mouse(event);guard event.scrollingDeltaY != 0 else{return}
        connection?.pointer(x:Int(cursor.x),y:Int(cursor.y),buttons:buttons | (event.scrollingDeltaY>0 ? 8:16))
        connection?.pointer(x:Int(cursor.x),y:Int(cursor.y),buttons:buttons)
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
        guard !clipboardBusy,window?.isKeyWindow == true,window?.firstResponder === self,let bridge else{return}
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
        guard !clipboardBusy else{return}
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
    override func flagsChanged(with event:NSEvent){if !clipboardBusy {synchronizeModifiers(event.modifierFlags)}}
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
        keys.removeAll();modifiers.removeAll();buttons=0
        connection?.pointer(x:Int(cursor.x),y:Int(cursor.y),buttons:0)
    }
}

@MainActor
final class DesktopWindow:NSObject,NSWindowDelegate {
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

    var state:[String:Any] {["visible":visible,"fullScreen":window.styleMask.contains(.fullScreen),"viewWidth":Int(surface.bounds.width),"viewHeight":Int(surface.bounds.height),"backingScale":window.backingScaleFactor,"nativeActive":nativeActive,"width":Int(surface.source.width),"height":Int(surface.source.height)]}
    init(socket:String,endpoint:@escaping ()->NativeDisplayEndpoint?,resized:@escaping (NSSize)->Void = {_ in},input:@escaping ()->Void = {})throws{
        self.socket=socket;self.endpoint=endpoint;surface=DesktopSurface(renderer:try WindowRenderer(opaque:true))
        window=NSWindow(contentRect:NSRect(x:140,y:120,width:960,height:640),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init()
        surface.onUserInput=input
        window.title="Desktop Mode";window.isReleasedWhenClosed=false;window.contentView=surface;window.delegate=self
        surface.onResize={ [weak self] in
            guard let self,self.visible else{return}
            resized(self.surface.convertToBacking(self.surface.bounds).size)
        }
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.backgroundColor = .black
        window.minSize=NSSize(width:480,height:320);window.acceptsMouseMovedEvents=true
    }
    func configureClipboard(_ bridge:GuestBridge?){surface.bridge=bridge}
    func show(){
        visible=true;window.makeKeyAndOrderFront(nil);window.makeFirstResponder(surface)
        NSApp.activate(ignoringOtherApps:true);connect();surface.onResize?()
        if timer == nil {timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] _ in Task{@MainActor in self?.connect()}}}
    }
    func stop(){
        visible=false;timer?.invalidate();timer=nil;surface.cancelClipboard();surface.releaseInput()
        connectionID=nil;readerID=nil;surface.connection=nil
        desktop?.stop();desktop=nil;native?.stop();native=nil;nativeActive=false;surface.renderer.clear()
    }
    private func connect(){
        guard visible else{return}
        if desktop == nil {
            let id=UUID();connectionID=id
            let client=DesktopConnection(path:socket,receive:{[weak self] pixels,width,height in
                guard let self,self.visible,self.connectionID == id,!self.nativeActive else{return}
                self.surface.source=NSSize(width:width,height:height)
                self.surface.renderer.present(pixels,width:width,height:height);self.window.title="Desktop Mode"
            },layout:{[weak self] screen in
                guard let self,self.connectionID == id,!self.nativeActive else{return};self.surface.inputScreen=screen
            },failed:{[weak self] message in
                guard let self,self.connectionID == id else{return}
                self.desktop=nil;self.surface.connection=nil
                if !self.nativeActive {self.window.title="Desktop Mode — \(message)"}
            })
            desktop=client;surface.connection=client;client.start()
        }
        if native == nil,let endpoint=endpoint(),FileManager.default.fileExists(atPath:endpoint.socketPath){
            let id=UUID();readerID=id
            let reader=NativeDisplayReader(endpoint:endpoint,device:surface.renderer.device,receive:{[weak self] frame in
                guard let self,self.visible,self.readerID == id else{return}
                self.nativeActive=true;self.desktop?.requestPixels(false)
                self.surface.source=NSSize(width:frame.texture.width,height:frame.texture.height)
                self.surface.inputScreen=DesktopScreen(id:0,x:0,y:0,width:frame.texture.width,height:frame.texture.height)
                self.surface.renderer.present(frame);self.window.title="Desktop Mode"
            },failed:{[weak self] message in
                guard let self,self.readerID == id else{return}
                let wasNative=self.nativeActive
                self.readerID=nil;self.native?.stop();self.native=nil;self.nativeActive=false
                if wasNative {self.surface.renderer.clear();self.desktop?.requestPixels(true)}
                self.window.title="Desktop Mode — \(message)"
            })
            native=reader;reader.start()
        }
    }
    func windowWillClose(_ notification:Notification){stop()}
    func windowDidResignKey(_ notification:Notification){surface.cancelClipboard();surface.releaseInput()}
}
