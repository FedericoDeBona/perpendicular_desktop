import AppKit
import Metal
import QuartzCore

/// Presents one window. The transport still supplies CPU BGRA pixels; this
/// renderer does not turn that transport into a shared guest/host GPU surface.
@MainActor
final class WindowRenderer {
    let layer=CAMetalLayer()
    private let device:any MTLDevice
    private let queue:any MTLCommandQueue
    private let pipeline:any MTLRenderPipelineState
    private var texture:(any MTLTexture)?
    private var pixels=Data()
    private var size=NSSize.zero
    private var revision:UInt64=0
    private var uploaded:UInt64=0
    private var drawing=false
    private var dirty=false
    private var reported=false
    var onError:((String)->Void)?

    init() throws {
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else {
            throw CocoaError(.featureUnsupported)
        }
        self.device=device;self.queue=queue
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
        fragment float4 window_fragment(Vertex in [[stage_in]],texture2d<float> image [[texture(0)]]) {
            constexpr sampler sample(filter::linear,address::clamp_to_edge);
            return image.sample(sample,in.uv);
        }
        """
        let library=try device.makeLibrary(source:source,options:nil)
        let descriptor=MTLRenderPipelineDescriptor()
        descriptor.vertexFunction=library.makeFunction(name:"window_vertex")
        descriptor.fragmentFunction=library.makeFunction(name:"window_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline=try device.makeRenderPipelineState(descriptor:descriptor)
        layer.device=device;layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly=true;layer.isOpaque=false
        layer.backgroundColor=NSColor.clear.cgColor
        layer.maximumDrawableCount=2;layer.allowsNextDrawableTimeout=true
        layer.presentsWithTransaction=false
    }
    func resize(_ bounds:NSSize,scale:Double){
        let next=CGSize(width:max(1,(bounds.width*scale).rounded()),height:max(1,(bounds.height*scale).rounded()))
        guard layer.drawableSize != next || layer.contentsScale != scale else{return}
        layer.contentsScale=scale;layer.drawableSize=next
        dirty=true;draw()
    }
    func present(_ pixels:Data,width:Int,height:Int){
        self.pixels=pixels;size=NSSize(width:width,height:height)
        revision &+= 1;dirty=true;draw()
    }
    func draw(){
        // Keep only the latest CPU frame and one GPU reader. Reusing a texture
        // waits for that reader's completion, including across resize/retirement.
        guard dirty,!drawing,!pixels.isEmpty,size.width>0,size.height>0,
              layer.drawableSize.width>0,layer.drawableSize.height>0 else{return}
        let width=Int(size.width),height=Int(size.height)
        if texture?.width != width || texture?.height != height {
            let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false)
            descriptor.storageMode = .shared;descriptor.usage = .shaderRead
            texture=device.makeTexture(descriptor:descriptor);uploaded=0
        }
        guard let texture,let drawable=layer.nextDrawable(),let command=queue.makeCommandBuffer() else{return}
        if uploaded != revision {
            pixels.withUnsafeBytes {bytes in
                texture.replace(region:MTLRegionMake2D(0,0,width,height),mipmapLevel:0,withBytes:bytes.baseAddress!,bytesPerRow:width*4)
            }
            uploaded=revision
        }
        let pass=MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture=drawable.texture
        pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
        guard let encoder=command.makeRenderCommandEncoder(descriptor:pass) else{return}
        let fit=min(layer.drawableSize.width/size.width,layer.drawableSize.height/size.height)
        var scale=SIMD2<Float>(Float(size.width*fit/layer.drawableSize.width),Float(size.height*fit/layer.drawableSize.height))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&scale,length:MemoryLayout<SIMD2<Float>>.size,index:0)
        encoder.setFragmentTexture(texture,index:0)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6)
        encoder.endEncoding()
        drawing=true;dirty=false
        command.present(drawable)
        command.addCompletedHandler { [weak self] buffer in
            let failed=buffer.status == .error
            let message=buffer.error?.localizedDescription
            Task{@MainActor [weak self] in
                guard let self else{return}
                self.drawing=false
                if failed {self.onError?(message ?? "The graphics device could not present this window.")}
                else if !self.reported {
                    self.reported=true
                    if ProcessInfo.processInfo.environment["PERPENDICULAR_STATE_TRACE"] == "1" {
                        let value:[String:Any]=["type":"renderer","backend":"metal","device":self.device.name,
                            "sourceWidth":width,"sourceHeight":height,"gpuCompleted":true]
                        if let data=try? JSONSerialization.data(withJSONObject:value){try? FileHandle.standardError.write(contentsOf:data+Data([10]))}
                    }
                }
                if self.dirty {self.draw()}
            }
        }
        command.commit()
    }
}
