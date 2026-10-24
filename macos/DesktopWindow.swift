import AppKit

@MainActor
private final class DesktopSurface:NSView {
    let renderer:WindowRenderer
    var onResize:(()->Void)?
    var connection:DesktopConnection?
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
    override func mouseDown(with event:NSEvent){buttons |= 1;mouse(event)}
    override func mouseUp(with event:NSEvent){buttons &= ~1;mouse(event)}
    override func rightMouseDown(with event:NSEvent){buttons |= 4;mouse(event)}
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
    override func keyDown(with event:NSEvent){if let value=symbol(event){keys[event.keyCode]=value;connection?.key(value,down:true)}}
    override func keyUp(with event:NSEvent){if let value=keys.removeValue(forKey:event.keyCode) ?? symbol(event){connection?.key(value,down:false)}}
    override func flagsChanged(with event:NSEvent){
        var next=Set<UInt32>()
        // Match the application-window convention: Command is Control in the
        // guest. AppKit can consume Command shortcuts without tapping Windows
        // and accidentally opening Start when the console loses focus.
        for (flag,key):(NSEvent.ModifierFlags,UInt32) in [(.shift,0xffe1),(.control,0xffe3),(.option,0xffe9),(.command,0xffe3)] {
            if event.modifierFlags.contains(flag){next.insert(key)}
        }
        for key in modifiers.subtracting(next){connection?.key(key,down:false)}
        for key in next.subtracting(modifiers){connection?.key(key,down:true)}
        modifiers=next
    }
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
    init(socket:String,endpoint:@escaping ()->NativeDisplayEndpoint?,resized:@escaping (NSSize)->Void = {_ in})throws{
        self.socket=socket;self.endpoint=endpoint;surface=DesktopSurface(renderer:try WindowRenderer(opaque:true))
        window=NSWindow(contentRect:NSRect(x:140,y:120,width:960,height:640),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init()
        window.title="Windows Desktop";window.isReleasedWhenClosed=false;window.contentView=surface;window.delegate=self
        surface.onResize={ [weak self] in
            guard let self,self.visible else{return}
            resized(self.surface.convertToBacking(self.surface.bounds).size)
        }
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.backgroundColor = .black
        window.minSize=NSSize(width:480,height:320);window.acceptsMouseMovedEvents=true
    }
    func show(){
        visible=true;window.makeKeyAndOrderFront(nil);window.makeFirstResponder(surface)
        NSApp.activate(ignoringOtherApps:true);connect();surface.onResize?()
        if timer == nil {timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] _ in Task{@MainActor in self?.connect()}}}
    }
    func stop(){
        visible=false;timer?.invalidate();timer=nil;surface.releaseInput()
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
                self.surface.renderer.present(pixels,width:width,height:height);self.window.title="Windows Desktop"
            },layout:{[weak self] screen in
                guard let self,self.connectionID == id,!self.nativeActive else{return};self.surface.inputScreen=screen
            },failed:{[weak self] message in
                guard let self,self.connectionID == id else{return}
                self.desktop=nil;self.surface.connection=nil
                if !self.nativeActive {self.window.title="Windows Desktop — \(message)"}
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
                self.surface.renderer.present(frame);self.window.title="Windows Desktop"
            },failed:{[weak self] message in
                guard let self,self.readerID == id else{return}
                let wasNative=self.nativeActive
                self.readerID=nil;self.native?.stop();self.native=nil;self.nativeActive=false
                if wasNative {self.surface.renderer.clear();self.desktop?.requestPixels(true)}
                self.window.title="Windows Desktop — \(message)"
            })
            native=reader;reader.start()
        }
    }
    func windowWillClose(_ notification:Notification){stop()}
    func windowDidResignKey(_ notification:Notification){surface.releaseInput()}
}
