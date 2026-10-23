import AppKit

@MainActor
final class ApplicationContent:NSView {
    var input:(([String:Any])->Void)?
    var pointerExited:(()->Void)?
    var transient=false
    var suspendedPointer=false
    var inputSuspended=false
    var leftMouse:((NSEvent,[String:Any])->Void)?
    var onFramePresented:((UInt64)->Void)?
    var onRenderError:((String)->Void)?
    var resizeEnabled=false {didSet{if oldValue != resizeEnabled {window?.invalidateCursorRects(for:self)}}}
    private(set) var presentationID:UInt64=0
    private(set) var generation:UInt64=0
    private var renderer:WindowRenderer?
    private var latestPixels=Data()
    private var latestSurface:GuestFrameSurface?
    private var sourceStride=0
    private(set) var renderFailure:String?
    var currentImage:CGImage? {
        if let latestSurface {return latestSurface.makeImage()}
        guard source.width>0,source.height>0,let provider=CGDataProvider(data:latestPixels as CFData) else{return nil}
        return CGImage(width:Int(source.width),height:Int(source.height),bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:sourceStride,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:[.byteOrder32Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue)],
            provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)
    }
    private var source=NSSize.zero
    private var modifiers:Set<Int>=[]
    private var virtualKeys:Set<UInt16>=[]
    private var pendingText=""
    private var pendingTextBytes=0
    private var textFlush:Task<Void,Never>?
    private var scrollRemainder=0.0
    private var tracking:NSTrackingArea?
    override var acceptsFirstResponder:Bool {true}
    override var isFlipped:Bool {true}
    override var mouseDownCanMoveWindow:Bool {false}
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
    var imageRect:NSRect {
        guard source.width>0,source.height>0 else{return .zero}
        let scale=min(bounds.width/source.width,bounds.height/source.height)
        return NSRect(x:(bounds.width-source.width*scale)/2,y:(bounds.height-source.height*scale)/2,
                      width:source.width*scale,height:source.height*scale)
    }
    var imageScale:Double {source.width>0 ? imageRect.width/source.width:1}

    override init(frame:NSRect) {
        super.init(frame:frame);wantsLayer=true
        do {
            let renderer=try WindowRenderer();self.renderer=renderer;layer=renderer.layer
            renderer.onError={ [weak self] message in self?.renderFailure=message;self?.onRenderError?(message) }
            renderer.onPresented={ [weak self] id in
                self?.onFramePresented?(id)
            }
        }catch {
            renderFailure="Metal is unavailable: \(error.localizedDescription)"
            layer?.backgroundColor=NSColor.clear.cgColor;layer?.contentsGravity = .resizeAspect
            layer?.minificationFilter = .linear;layer?.magnificationFilter = .linear
        }
        updateRendererSize()
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    override func setFrameSize(_ newSize:NSSize){super.setFrameSize(newSize);updateRendererSize()}
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();updateRendererSize()}
    override func viewDidChangeBackingProperties(){super.viewDidChangeBackingProperties();updateRendererSize()}
    private func updateRendererSize(){renderer?.resize(bounds.size,scale:Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1))}
    override func updateTrackingAreas(){
        if let tracking{removeTrackingArea(tracking)}
        let area=NSTrackingArea(rect:.zero,options:[.mouseMoved,.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self)
        addTrackingArea(area);tracking=area;super.updateTrackingAreas()
    }
    override func resetCursorRects(){
        guard resizeEnabled else{addCursorRect(bounds,cursor:.arrow);return}
        for (edges,rect) in ResizeEdges.regions(in:bounds) {
            let flipped=NSRect(x:rect.minX,y:bounds.maxY-rect.maxY,width:rect.width,height:rect.height)
            addCursorRect(flipped,cursor:edges.cursor)
        }
    }
    @discardableResult func present(_ packet:GuestPacket,requireSolidFrame:Bool=false)->Bool{
        guard let width=packet.header["width"] as? Int,let height=packet.header["height"] as? Int,
              let generation=packet.header["generation"] as? UInt64,
              width>0,height>0,width<=8_388_608/height else{return false}
        let stride=packet.header["stride"] as? Int ?? width*4
        guard stride>=width*4,stride<=34*1024*1024/height else{return false}
        if let surface=packet.surface {
            guard surface.width==width,surface.height==height,surface.stride==stride,surface.byteCount==stride*height else{return false}
            if requireSolidFrame,!Self.hasSolidFrame(surface.contents,width:width,height:height,stride:stride){return false}
            latestSurface=surface;latestPixels=Data()
        }else{
            guard packet.pixels.count==stride*height else{return false}
            if requireSolidFrame,!packet.pixels.withUnsafeBytes({Self.hasSolidFrame($0.baseAddress!,width:width,height:height,stride:stride)}){return false}
            latestSurface=nil;latestPixels=packet.pixels
        }
        self.generation=generation;source=NSSize(width:width,height:height);sourceStride=stride
        redrawCurrentFrame();return true
    }
    /// Only a transition gate for rectangular app windows, not a content oracle.
    /// Allow rounded corners, but don't uncover an empty or mostly missing image.
    private static func hasSolidFrame(_ pointer:UnsafeRawPointer,width:Int,height:Int,stride:Int)->Bool{
        let bytes=pointer.assumingMemoryBound(to:UInt8.self)
        var opaque=0,total=0
        for row in Swift.stride(from:0,to:height,by:max(1,height/24)) {
            for column in Swift.stride(from:0,to:width,by:max(1,width/32)) {
                total+=1;if bytes[row*stride+column*4+3]>=224 {opaque+=1}
            }
        }
        return opaque*100>=total*85
    }
    @discardableResult func redrawCurrentFrame()->Bool{
        guard source.width>0,source.height>0 else{return false}
        presentationID &+= 1
        if let renderer {
            if let latestSurface {renderer.present(latestSurface,presentationID:presentationID)}
            else {renderer.present(latestPixels,width:Int(source.width),height:Int(source.height),stride:sourceStride,presentationID:presentationID)}
        }else {
            let id=presentationID
            CATransaction.begin();CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock{[weak self] in Task{@MainActor in
                guard let self,self.presentationID == id else{return};self.onFramePresented?(id)
            }}
            layer?.contents=currentImage;CATransaction.commit()
        }
        return true
    }
    private func point(_ event:NSEvent)->[String:Any]?{
        guard source.width>0,source.height>0 else{return nil}
        let scale=min(bounds.width/source.width,bounds.height/source.height)
        guard scale>0 else{return nil}
        let origin=NSPoint(x:(bounds.width-source.width*scale)/2,y:(bounds.height-source.height*scale)/2)
        let local=convert(event.locationInWindow,from:nil)
        return ["x":Int(max(0,min(source.width-1,(local.x-origin.x)/scale))),
                "y":Int(max(0,min(source.height-1,(local.y-origin.y)/scale))),"generation":generation]
    }
    func flushText(){
        textFlush?.cancel();textFlush=nil
        guard !pendingText.isEmpty else{return}
        let text=pendingText;pendingText="";pendingTextBytes=0
        input?(["event":"text","text":text])
    }
    private func queueText(_ text:String){
        // Coalesce only adjacent Unicode text. A short timer bounds ordinary
        // typing latency; every non-text input flushes synchronously first.
        for scalar in text.unicodeScalars {
            let part=String(scalar),count=part.utf8.count
            if pendingTextBytes+count>1024 {flushText()}
            pendingText.append(contentsOf:part);pendingTextBytes+=count
        }
        guard textFlush == nil,!pendingText.isEmpty else{return}
        textFlush=Task{@MainActor [weak self] in
            try? await Task.sleep(for:.milliseconds(8))
            guard !Task.isCancelled else{return}
            self?.flushText()
        }
    }
    private func emit(_ value:[String:Any]){flushText();input?(value)}
    private func mouse(_ event:NSEvent,button:String?=nil,down:Bool?=nil){
        if down == false,let button {emit(["event":"button","button":button,"down":false]);return}
        guard !suspendedPointer else{return}
        if button != nil && !transient {window?.makeFirstResponder(self)}
        guard var value=point(event)else{return}
        value["event"]=button == nil ? "pointer":"button"
        if let button,let down{value["button"]=button;value["down"]=down}
        emit(value)
    }
    override func mouseMoved(with event:NSEvent){mouse(event)}
    override func mouseEntered(with event:NSEvent){mouse(event)}
    override func mouseExited(with event:NSEvent){flushText();pointerExited?()}
    private func left(_ event:NSEvent,down:Bool?=nil){
        flushText()
        guard let leftMouse else{mouse(event,button:down == nil ? nil:"left",down:down);return}
        window?.makeFirstResponder(self)
        var value=point(event) ?? [:]
        value["event"]=down == nil ? "pointer":"button"
        if let down {value["button"]="left";value["down"]=down}
        leftMouse(event,value)
    }
    override func mouseDragged(with event:NSEvent){left(event)}
    override func rightMouseDragged(with event:NSEvent){mouse(event)}
    override func mouseDown(with event:NSEvent){left(event,down:true)}
    override func mouseUp(with event:NSEvent){left(event,down:false)}
    override func rightMouseDown(with event:NSEvent){mouse(event,button:"right",down:true)}
    override func rightMouseUp(with event:NSEvent){mouse(event,button:"right",down:false)}
    override func scrollWheel(with event:NSEvent){
        guard !suspendedPointer else{return}
        guard var value=point(event)else{return}
        scrollRemainder+=Double(event.scrollingDeltaY)*(event.hasPreciseScrollingDeltas ? 3:120)
        let amount=Int(scrollRemainder);scrollRemainder-=Double(amount)
        guard amount != 0 else{return}
        value["event"]="scroll";value["delta"]=max(-2400,min(2400,amount));emit(value)
    }
    override func flagsChanged(with event:NSEvent){
        guard !inputSuspended else{return}
        synchronizeModifiers(event.modifierFlags)
    }
    private func synchronizeModifiers(_ flags:NSEvent.ModifierFlags){
        var current=Set<Int>()
        if flags.contains(.shift){current.insert(0x10)}
        if flags.contains(.command)||flags.contains(.control){current.insert(0x11)}
        if flags.contains(.option){current.insert(0x12)}
        for key in current.subtracting(modifiers){emit(["event":"key","key":key,"down":true])}
        for key in modifiers.subtracting(current){emit(["event":"key","key":key,"down":false])}
        modifiers=current
    }
    func clearModifiers(){flushText();modifiers.removeAll();virtualKeys.removeAll()}
    private func shortcut(_ key:Int){
        chord([0x11,key])
    }
    private func chord(_ keys:[Int]){emit(["event":"chord","keys":keys]);modifiers.removeAll();virtualKeys.removeAll()}
    override func selectAll(_ sender:Any?){shortcut(0x41)}
    @objc func copy(_ sender:Any?){emit(["event":"clipboard","action":"copy"])}
    @objc func paste(_ sender:Any?){emit(["event":"clipboard","action":"paste"])}
    @objc func cut(_ sender:Any?){emit(["event":"clipboard","action":"cut"])}
    override func performKeyEquivalent(with event:NSEvent)->Bool {
        guard window?.isKeyWindow == true,window?.firstResponder === self,event.modifierFlags.contains(.command) else{return false}
        // Preserve app switching, hide/minimize, system controls and full screen.
        if [4,46,48,49,50,43].contains(event.keyCode) || (event.keyCode == 3 && event.modifierFlags.contains(.control)){return false}
        keyDown(with:event);return true
    }
    override func keyDown(with event:NSEvent){
        guard !inputSuspended else{return}
        let flags=event.modifierFlags
        let shift=flags.contains(.shift) ? [0x10]:[]
        if flags.contains(.command),!flags.contains(.control),!flags.contains(.option){
            switch event.keyCode {
            case 8:if !event.isARepeat {copy(nil)};return
            case 7:if !event.isARepeat {cut(nil)};return
            case 9:if !event.isARepeat {paste(nil)};return
            case 12:chord([0x12,0x73]);return // Command-Q → Alt-F4.
            case 6 where flags.contains(.shift):chord([0x11,0x59]);return
            case 123:chord(shift+[0x24]);return
            case 124:chord(shift+[0x23]);return
            case 126:chord(shift+[0x11,0x24]);return
            case 125:chord(shift+[0x11,0x23]);return
            case 51:chord([0x10,0x24]);chord([0x08]);return
            default:if let key=Self.keys[event.keyCode]{chord(shift+[0x11,key]);return}
            }
        }
        if flags.contains(.option),!flags.contains(.command),!flags.contains(.control),
           [51,117,123,124].contains(event.keyCode),let key=Self.keys[event.keyCode]{chord(shift+[0x11,key]);return}
        synchronizeModifiers(event.modifierFlags)
        // AppKit reports backward Delete as U+007F, which is not printable.
        // Route navigation/editing keys before considering committed text.
        if [36,48,51,53,115,116,117,119,121,123,124,125,126].contains(event.keyCode),let key=Self.keys[event.keyCode]{
            virtualKeys.insert(event.keyCode);emit(["event":"key","key":key,"down":true]);return
        }
        if !event.modifierFlags.contains(.command),!event.modifierFlags.contains(.control),
           let text=event.characters,!text.isEmpty,text.unicodeScalars.allSatisfy({$0.properties.generalCategory != .control && !($0.value>=0xF700 && $0.value<=0xF8FF)}){
            // Option produces committed Mac symbols, not a Windows Alt chord.
            synchronizeModifiers(event.modifierFlags.subtracting(.option))
            queueText(text);return
        }
        if let key=Self.keys[event.keyCode]{virtualKeys.insert(event.keyCode);emit(["event":"key","key":key,"down":true])}
    }
    override func keyUp(with event:NSEvent){
        if virtualKeys.remove(event.keyCode) != nil,let key=Self.keys[event.keyCode]{emit(["event":"key","key":key,"down":false])}
    }
    private static let keys:[UInt16:Int]=[
        0:0x41,1:0x53,2:0x44,3:0x46,4:0x48,5:0x47,6:0x5A,7:0x58,8:0x43,9:0x56,11:0x42,
        12:0x51,13:0x57,14:0x45,15:0x52,16:0x59,17:0x54,18:0x31,19:0x32,20:0x33,21:0x34,22:0x36,23:0x35,
        25:0x39,26:0x37,28:0x38,29:0x30,31:0x4F,32:0x55,34:0x49,35:0x50,37:0x4C,38:0x4A,40:0x4B,
        45:0x4E,46:0x4D,36:0x0D,48:0x09,49:0x20,51:0x08,53:0x1B,115:0x24,116:0x21,117:0x2E,119:0x23,121:0x22,
        123:0x25,124:0x27,125:0x28,126:0x26,
        122:0x70,120:0x71,99:0x72,118:0x73,96:0x74,97:0x75,98:0x76,100:0x77,101:0x78,109:0x79,103:0x7A,111:0x7B]
}
