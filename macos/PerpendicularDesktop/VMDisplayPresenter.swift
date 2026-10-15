import AppKit
import MetalKit

@MainActor
enum VMDisplayDiagnostics {
    static var enabled: Bool { ProcessInfo.processInfo.environment["PERPENDICULAR_DISPLAY_DIAGNOSTICS"] == "1" }
    static func fallback(width: Int, height: Int) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("display renderer=coregraphics source=rfb frame=\(width)x\(height) fallback=true\n".utf8))
    }
    static func firstMetalFrame(width: Int, height: Int, drawableWidth: Int, drawableHeight: Int) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("display first_completed=true renderer=metal source=rfb frame=\(width)x\(height) drawable=\(drawableWidth)x\(drawableHeight) fallback=false\n".utf8))
    }
}

/// One complete, immutable RFB image. Pixels are B,G,R,padding, top row first.
struct VMDisplayFrame: Sendable {
    let width: Int
    let height: Int
    let pixels: Data
    let hasReceivedPixels: Bool
    init(width: Int, height: Int, pixels: Data, hasReceivedPixels: Bool = true) {
        self.width = width; self.height = height; self.pixels = pixels; self.hasReceivedPixels = hasReceivedPixels
    }
}

enum VMDisplayGeometry {
    static func fit(source: CGSize, destination: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0, destination.width > 0, destination.height > 0 else { return .zero }
        let scale = min(destination.width / source.width, destination.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: (destination.width - size.width) / 2, y: (destination.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    static func usesNearest(source: CGSize, destination: CGSize) -> Bool {
        let rect = fit(source: source, destination: destination)
        guard source.width > 0 else { return false }
        let scale = rect.width / source.width
        return scale >= 1 && abs(scale - scale.rounded()) < 0.001
    }
}

/// The same pipeline is exercised by the offscreen GPU checks and the live drawable.
/// Callers serialize uploads: a source texture is never overwritten while the GPU reads it.
@MainActor
final class VMMetalRenderer {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let nearest: any MTLSamplerState
    private let linear: any MTLSamplerState
    private var source: (any MTLTexture)?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct Vertex { float4 position [[position]]; float2 uv; };
        vertex Vertex displayVertex(uint id [[vertex_id]]) {
            const float2 positions[3] = { float2(-1,1), float2(3,1), float2(-1,-3) };
            const float2 coordinates[3] = { float2(0,0), float2(2,0), float2(0,2) };
            Vertex out; out.position = float4(positions[id],0,1); out.uv = coordinates[id]; return out;
        }
        fragment float4 displayFragment(Vertex in [[stage_in]], texture2d<float> image [[texture(0)]],
                                         sampler filtering [[sampler(0)]]) {
            return float4(image.sample(filtering, in.uv).rgb, 1.0);
        }
        """
        do {
            let library = try device.makeLibrary(source: shader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "displayVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "displayFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            func sampler(_ filter: MTLSamplerMinMagFilter) -> (any MTLSamplerState)? {
                let state = MTLSamplerDescriptor()
                state.minFilter = filter; state.magFilter = filter
                state.sAddressMode = .clampToEdge; state.tAddressMode = .clampToEdge
                return device.makeSamplerState(descriptor: state)
            }
            guard let nearest = sampler(.nearest), let linear = sampler(.linear) else { return nil }
            self.device = device; self.queue = queue; self.pipeline = pipeline
            self.nearest = nearest; self.linear = linear
        } catch { return nil }
    }

    func encode(_ frame: VMDisplayFrame, into target: any MTLTexture,
                commandBuffer: any MTLCommandBuffer) throws {
        guard frame.width > 0, frame.height > 0, frame.width <= 16384, frame.height <= 16384,
              frame.width <= 134217728 / 4 / frame.height,
              frame.pixels.count == frame.width * frame.height * 4 else { throw PresenterError.invalidFrame }
        if source?.width != frame.width || source?.height != frame.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: frame.width, height: frame.height, mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = .shaderRead
            source = device.makeTexture(descriptor: descriptor)
        }
        guard let source else { throw PresenterError.textureUnavailable }
        frame.pixels.withUnsafeBytes { bytes in
            source.replace(region: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0,
                           withBytes: bytes.baseAddress!, bytesPerRow: frame.width * 4)
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { throw PresenterError.encoderUnavailable }
        let destination = CGSize(width: target.width, height: target.height)
        let size = CGSize(width: frame.width, height: frame.height)
        let rect = VMDisplayGeometry.fit(source: size, destination: destination)
        encoder.setViewport(MTLViewport(originX: rect.minX, originY: rect.minY,
            width: rect.width, height: rect.height, znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(VMDisplayGeometry.usesNearest(source: size, destination: destination) ? nearest : linear, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    enum PresenterError: Error { case invalidFrame, textureUnavailable, encoderUnavailable }
}

/// Presentation only: all input, focus, accessibility and guest state stay in the parent.
/// One command buffer and one replaceable pending frame bound both GPU and main-thread work.
@MainActor
final class VMMetalDisplayView: MTKView, MTKViewDelegate {
    private let renderer: VMMetalRenderer
    private var pending: VMDisplayFrame?
    private var current: VMDisplayFrame?
    private var inFlight = false
    private var redrawRequested = false
    private var stopped = false
    private var loggedFirstFrame = false
    private var presentationGeneration = 0
    var onFailure: (() -> Void)?
    private(set) var completedFrames = 0
    private(set) var coalescedFrames = 0
    private(set) var maximumInFlight = 0

    static func make() -> VMMetalDisplayView? {
        guard ProcessInfo.processInfo.environment["PERPENDICULAR_DISPLAY_RENDERER"] != "coregraphics",
              let renderer = VMMetalRenderer() else { return nil }
        return VMMetalDisplayView(renderer: renderer)
    }

    private init(renderer: VMMetalRenderer) {
        self.renderer = renderer
        super.init(frame: .zero, device: renderer.device)
        colorPixelFormat = .bgra8Unorm
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        framebufferOnly = true
        autoResizeDrawable = true
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
        setAccessibilityElement(false)
    }

    required init(coder: NSCoder) { fatalError("Use make()") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    func present(_ frame: VMDisplayFrame) {
        guard !stopped else { return }
        if pending != nil { coalescedFrames += 1 }
        pending = frame
        needsDisplay = true
    }

    func reset() {
        pending = nil; current = nil; redrawRequested = false; loggedFirstFrame = false
        presentationGeneration &+= 1
        releaseDrawables()
    }

    func stop() {
        stopped = true; pending = nil; current = nil; redrawRequested = false
        delegate = nil; onFailure = nil
        releaseDrawables()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        redrawRequested = true
        needsDisplay = true
    }

    func draw(in view: MTKView) {
        guard !stopped, !isHidden, !inFlight, let frame = pending ?? current,
              drawableSize.width > 0, drawableSize.height > 0,
              let drawable = currentDrawable, let command = renderer.queue.makeCommandBuffer() else { return }
        pending = nil
        redrawRequested = false
        do { try renderer.encode(frame, into: drawable.texture, commandBuffer: command) }
        catch { onFailure?(); return }
        current = frame
        inFlight = true; maximumInFlight = 1
        command.present(drawable)
        let drawableWidth = drawable.texture.width, drawableHeight = drawable.texture.height
        let submittedGeneration = presentationGeneration
        command.addCompletedHandler { [weak self] command in
            let failed = command.status == .error
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inFlight = false
                guard !self.stopped else { return }
                if failed { self.onFailure?(); return }
                if !self.loggedFirstFrame && frame.hasReceivedPixels && self.presentationGeneration == submittedGeneration {
                    self.loggedFirstFrame = true
                    VMDisplayDiagnostics.firstMetalFrame(width: frame.width, height: frame.height,
                        drawableWidth: drawableWidth, drawableHeight: drawableHeight)
                }
                self.completedFrames += 1
                if self.pending != nil || self.redrawRequested { self.needsDisplay = true }
            }
        }
        command.commit()
    }
}
