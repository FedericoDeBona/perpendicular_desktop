import AppKit
import Metal
import QuartzCore

// CAMetalLayer is not Sendable. This bridge transfers only its blocking
// nextDrawable call to one serial queue. WindowRenderer keeps drawing=true
// from acquisition through GPU completion, so it never changes layer
// configuration while acquisition is pending. No view or frame state crosses
// this boundary; the returned drawable is consumed on the MainActor.
private final class DrawableAccess:@unchecked Sendable {
    private let layer:CAMetalLayer
    private let work=DispatchQueue(label:"perpendicular.drawable.acquire",qos:.userInteractive)
    init(_ layer:CAMetalLayer){self.layer=layer}
    func request(traceID:String,_ completed:@escaping @MainActor @Sendable ((any CAMetalDrawable)?)->Void){
        work.async { [self] in
            PipelineTrace.record("drawable-call",traceID)
            let drawable=autoreleasepool{layer.nextDrawable()}
            PipelineTrace.record("drawable-return",traceID,["available":drawable != nil])
            FrameDelivery.main{completed(drawable)}
        }
    }
}

/// Presents a desktop lease, immutable GPU window image or legacy pixel image.
@MainActor
final class WindowRenderer {
    let layer=CAMetalLayer()
    let device:any MTLDevice
    private let queue:any MTLCommandQueue
    private let pipeline:any MTLRenderPipelineState
    private var texture:(any MTLTexture)?
    private var external:NativeDisplayFrame?
    private var shared:GuestFrameSurface?
    private var nativeCache=false
    private let opaque:Bool
    private let fillBounds:Bool
    private var pixels=Data()
    private var pixelStride=0
    private var size=NSSize.zero
    private var revision:UInt64=0
    private var uploaded:UInt64=0
    private var drawing=false
    private var dirty=false
    private var drawableRetry:Task<Void,Never>?
    private var drawableFailures=0
    private var presentationID:UInt64=0
    private var targetDrawableSize=CGSize.zero
    private var targetScale=1.0
    private lazy var drawableAccess=DrawableAccess(layer)
    private var reportedSources=Set<String>()
    private let traceRenderer=UUID().uuidString
    private var traceDraw:UInt64=0
    private var traceSource=""
    var onError:((String)->Void)?
    var onPresented:((UInt64)->Void)?

    // Device and pipeline are immutable and shared by all window presenters.
    // Keep command queues per presenter so a slow window does not change the
    // ordering or retirement of another window's frames. Cache only success.
    private static var metalResources:(device:any MTLDevice,pipeline:any MTLRenderPipelineState)?
    private static func resources() throws -> (device:any MTLDevice,pipeline:any MTLRenderPipelineState) {
        if let metalResources {return metalResources}
        guard let device=MTLCreateSystemDefaultDevice() else {throw CocoaError(.featureUnsupported)}
        let source="""
        #include <metal_stdlib>
        using namespace metal;
        struct Vertex {float4 position [[position]]; float2 uv;};
        vertex Vertex window_vertex(uint index [[vertex_id]],constant float2 &scale [[buffer(0)]]) {
            const float2 points[6]={float2(-1,-1),float2(1,-1),float2(-1,1),
                                    float2(1,-1),float2(1,1),float2(-1,1)};
            float2 point=points[index];
            return {float4(point*scale,0,1),float2((point.x+1)*0.5,(1-point.y)*0.5)};
        }
        fragment float4 window_fragment(Vertex in [[stage_in]],texture2d<float> image [[texture(0)]],constant uint &opaque [[buffer(0)]]) {
            constexpr sampler sample(filter::linear,address::clamp_to_edge);
            float4 value=image.sample(sample,in.uv);
            if(opaque) value.a=1;
            return value;
        }
        """
        let library=try device.makeLibrary(source:source,options:nil)
        let descriptor=MTLRenderPipelineDescriptor()
        descriptor.vertexFunction=library.makeFunction(name:"window_vertex")
        descriptor.fragmentFunction=library.makeFunction(name:"window_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline=try device.makeRenderPipelineState(descriptor:descriptor)
        let resources=(device:device,pipeline:pipeline)
        metalResources=resources
        return resources
    }
    init(opaque:Bool=false,fillBounds:Bool=false) throws {
        self.opaque=opaque;self.fillBounds=fillBounds
        let resources=try Self.resources()
        guard let queue=resources.device.makeCommandQueue() else {throw CocoaError(.featureUnsupported)}
        device=resources.device;pipeline=resources.pipeline;self.queue=queue
        layer.device=device;layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly=true;layer.isOpaque=false
        layer.backgroundColor=NSColor.clear.cgColor
        layer.maximumDrawableCount=2;layer.allowsNextDrawableTimeout=true
        layer.presentsWithTransaction=false
        PipelineTrace.record("presenter-config",traceRenderer,["directFrameDispatch":FrameDelivery.direct,"displaySync":layer.displaySyncEnabled])
    }
    func resize(_ bounds:NSSize,scale:Double){
        let next=CGSize(width:max(1,(bounds.width*scale).rounded()),height:max(1,(bounds.height*scale).rounded()))
        guard targetDrawableSize != next || targetScale != scale else{return}
        targetDrawableSize=next;targetScale=scale
        dirty=true;draw()
    }
    func present(_ pixels:Data,width:Int,height:Int,stride:Int?=nil,presentationID:UInt64=0){
        traceSource=""
        self.presentationID=presentationID
        external=nil;shared=nil;nativeCache=false
        self.pixels=pixels;pixelStride=stride ?? width*4;size=NSSize(width:width,height:height)
        revision &+= 1;dirty=true;draw()
    }
    func present(_ surface:GuestFrameSurface,presentationID:UInt64=0){
        traceSource=surface.traceID
        PipelineTrace.record("renderer-receive",traceSource,["renderer":traceRenderer,"presentationID":presentationID])
        self.presentationID=presentationID
        guard surface.texture.device.registryID == device.registryID else{onError?("The graphics devices do not match.");return}
        external=nil;nativeCache=false;pixels=Data();texture=nil;shared=surface
        size=NSSize(width:surface.width,height:surface.height)
        dirty=true;draw()
    }
    func present(_ frame:NativeDisplayFrame){
        traceSource=frame.traceID
        PipelineTrace.record("renderer-receive",traceSource,["renderer":traceRenderer])
        guard frame.texture.device.registryID == device.registryID else{onError?("The graphics devices do not match.");return}
        external=frame;shared=nil;pixels=Data();size=NSSize(width:frame.texture.width,height:frame.texture.height)
        dirty=true;draw()
    }
    func clear(){drawableRetry?.cancel();drawableRetry=nil;drawableFailures=0;external=nil;shared=nil;nativeCache=false;pixels=Data();size = .zero;texture=nil;dirty=false}
    func draw(){
        // Acquisition and GPU work share one slot. New arrivals only replace
        // the latest source while nextDrawable waits away from the main actor.
        guard dirty,!drawing,(shared != nil || external != nil || nativeCache || !pixels.isEmpty),size.width>0,size.height>0,
              targetDrawableSize.width>0,targetDrawableSize.height>0 else{return}
        drawableRetry?.cancel();drawableRetry=nil
        if layer.contentsScale != targetScale {layer.contentsScale=targetScale}
        if layer.drawableSize != targetDrawableSize {layer.drawableSize=targetDrawableSize}
        drawing=true
        traceDraw &+= 1
        let requestID="\(traceRenderer):\(traceDraw)"
        PipelineTrace.record("drawable-request",requestID)
        drawableAccess.request(traceID:requestID) { [weak self] drawable in
            guard let self else{return}
            guard let drawable else{
                self.drawing=false
                self.retryDrawable()
                return
            }
            self.drawableFailures=0
            self.render(drawable,requestID:requestID)
        }
    }
    private func retryDrawable(){
        guard dirty else{return}
        // A static window may never send another frame. Retry acquisition of
        // its retained image, without requesting guest repaint or more pixels.
        // Bound the retries so an unavailable layer has an explicit outcome.
        drawableFailures+=1
        guard drawableFailures<=3 else{
            if drawableFailures==4 {onError?("Metal could not obtain a display surface for this window.")}
            return
        }
        let delay=50 * (1 << (drawableFailures-1))
        drawableRetry=Task { @MainActor [weak self] in
            do {try await Task.sleep(for:.milliseconds(delay))} catch{return}
            guard let self else{return}
            self.drawableRetry=nil
            self.draw()
        }
    }
    private func render(_ drawable:any CAMetalDrawable,requestID:String){
        var submitted=false
        defer{if !submitted {drawing=false}}
        // clear/resize/new frames can run during acquisition. Select the source
        // here, retaining only the image actually submitted to this GPU command.
        guard dirty,(shared != nil || external != nil || nativeCache || !pixels.isEmpty),size.width>0,size.height>0,
              targetDrawableSize.width>0,targetDrawableSize.height>0 else{return}
        let width=Int(size.width),height=Int(size.height)
        let presentedID=presentationID,renderedScale=targetScale
        let drawableSize=CGSize(width:drawable.texture.width,height:drawable.texture.height)
        let lease=external
        let frameSurface=shared
        let nativeSurface=lease != nil || nativeCache
        let sourceKind=nativeSurface ? "native-surface":frameSurface != nil ? "shared-buffer":"cpu"
        let sourceID=traceSource
        PipelineTrace.record("render-select",requestID,["sourceID":sourceID,"sourceKind":sourceKind,"width":width,"height":height,"drawableWidth":drawable.texture.width,"drawableHeight":drawable.texture.height])
        let sampledTexture:any MTLTexture
        if let frameSurface {
            sampledTexture=frameSurface.texture
        }else{
            let storage:MTLStorageMode=nativeSurface ? .private:.shared
            if texture?.width != width || texture?.height != height || texture?.storageMode != storage {
                let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false)
                descriptor.storageMode=storage;descriptor.usage = .shaderRead
                texture=device.makeTexture(descriptor:descriptor);uploaded=0
            }
            guard let texture else{return}
            sampledTexture=texture
        }
        guard let command=queue.makeCommandBuffer() else{return}
        if let lease {
            // Keep an owned image for expose/resize. Holding the last producer
            // lease until its successor arrives deadlocks context retirement:
            // the broker must release that old budget before starting a writer.
            guard let copy=command.makeBlitCommandEncoder() else{return}
            copy.copy(from:lease.texture,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),
                      sourceSize:MTLSize(width:width,height:height,depth:1),to:sampledTexture,destinationSlice:0,
                      destinationLevel:0,destinationOrigin:MTLOrigin(x:0,y:0,z:0))
            copy.endEncoding()
        }else if frameSurface == nil && !nativeCache && uploaded != revision {
            pixels.withUnsafeBytes {bytes in
                sampledTexture.replace(region:MTLRegionMake2D(0,0,width,height),mipmapLevel:0,withBytes:bytes.baseAddress!,bytesPerRow:pixelStride)
            }
            uploaded=revision
        }
        let pass=MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture=drawable.texture
        pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
        guard let encoder=command.makeRenderCommandEncoder(descriptor:pass) else{return}
        let fit=min(drawableSize.width/size.width,drawableSize.height/size.height)
        var scale=fillBounds ? SIMD2<Float>(1,1):SIMD2<Float>(Float(size.width*fit/drawableSize.width),Float(size.height*fit/drawableSize.height))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&scale,length:MemoryLayout<SIMD2<Float>>.size,index:0)
        encoder.setFragmentTexture(sampledTexture,index:0)
        var forceOpaque:UInt32=opaque ? 1:0
        encoder.setFragmentBytes(&forceOpaque,length:MemoryLayout<UInt32>.size,index:0)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6)
        encoder.endEncoding()
        if lease != nil {nativeCache=true;external=nil}
        dirty=drawableSize != targetDrawableSize || layer.contentsScale != targetScale
        drawable.addPresentedHandler { [weak self] presented in
            PipelineTrace.record("drawable-presented",requestID,["sourceID":sourceID,"presentedTime":presented.presentedTime])
            FrameDelivery.main{[weak self] in
                guard let self,self.size == NSSize(width:width,height:height),
                      self.targetDrawableSize == drawableSize,self.targetScale == renderedScale else{return}
                self.onPresented?(presentedID)
            }
        }
        command.present(drawable)
        command.addCompletedHandler { [weak self,lease,frameSurface] buffer in
            PipelineTrace.record("render-complete",requestID,["sourceID":sourceID,"gpuStart":buffer.gpuStartTime,"gpuEnd":buffer.gpuEndTime,"status":buffer.status.rawValue])
            // The producer image has been copied into our own texture and every
            // GPU read is complete. Do not wait for Metal to release this block.
            lease?.finishReading()
            withExtendedLifetime(frameSurface){}
            let failed=buffer.status == .error
            let message=buffer.error?.localizedDescription
            FrameDelivery.main{[weak self] in
                guard let self else{return}
                self.drawing=false
                if failed {self.onError?(message ?? "The graphics device could not present this window.")}
                else if !self.reportedSources.contains(sourceKind) {
                    self.reportedSources.insert(sourceKind)
                    if ProcessInfo.processInfo.environment["PERPENDICULAR_STATE_TRACE"] == "1" {
                        let value:[String:Any]=["type":"renderer","backend":"metal","device":self.device.name,
                            "sourceWidth":width,"sourceHeight":height,"source":sourceKind,
                            "nativeGPUCopy":nativeSurface,"gpuCompleted":true]
                        if let data=try? JSONSerialization.data(withJSONObject:value){try? FileHandle.standardError.write(contentsOf:data+Data([10]))}
                    }
                }
                if self.dirty {self.draw()}
            }
        }
        submitted=true;PipelineTrace.record("render-commit",requestID,["sourceID":sourceID]);command.commit()
    }
}
