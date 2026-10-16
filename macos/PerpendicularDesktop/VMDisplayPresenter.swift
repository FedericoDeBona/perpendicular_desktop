import AppKit
import MetalKit

@MainActor
enum VMDisplayDiagnostics {
    static var enabled: Bool { ProcessInfo.processInfo.environment["PERPENDICULAR_DISPLAY_DIAGNOSTICS"] == "1" }
    static func fallback(width: Int, height: Int) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("display renderer=coregraphics source=rfb frame=\(width)x\(height) fallback=true\n".utf8))
    }
    static func firstMetalFrame(width: Int, height: Int, drawableWidth: Int, drawableHeight: Int, source: String = "rfb") {
        guard enabled else { return }
        FileHandle.standardError.write(Data("display first_completed=true renderer=metal source=\(source) frame=\(width)x\(height) drawable=\(drawableWidth)x\(drawableHeight) fallback=false\n".utf8))
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

struct VMDisplayTextureRegion: Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

enum VMDisplayLeaseCancellation: String, Equatable, Sendable {
    case superseded, reset, stopped, presenterReleased
}

enum VMDisplayLeaseFailure: String, Equatable, Sendable {
    case invalidTexture, incompatibleDevice, encodingFailed, gpuFailed
}

enum VMDisplayLeaseResult: Equatable, Sendable {
    /// Retired after a completed presentation; this is not the first-draw notification.
    case presented
    case cancelled(VMDisplayLeaseCancellation)
    case failed(VMDisplayLeaseFailure)
}

/// The caller proves producer readiness before submission and keeps the backing
/// immutable until completion. A displayed lease stays current for redraws;
/// completion permits unmapping/reuse and therefore happens only on retirement.
@MainActor
final class VMExternalDisplayLease {
    let texture: any MTLTexture
    let region: VMDisplayTextureRegion?
    let verticallyFlipped: Bool
    private var completion: (@MainActor (VMDisplayLeaseResult) -> Void)?
    private var submitted = false
    private var readers = 0
    private var retirement: VMDisplayLeaseResult?
    private(set) var hasPresented = false

    init(texture: any MTLTexture, region: VMDisplayTextureRegion? = nil, verticallyFlipped: Bool = false,
         completion: @escaping @MainActor (VMDisplayLeaseResult) -> Void) {
        self.texture = texture; self.region = region; self.verticallyFlipped = verticallyFlipped
        self.completion = completion
    }

    fileprivate var resolvedRegion: VMDisplayTextureRegion {
        region ?? .init(x: 0, y: 0, width: texture.width, height: texture.height)
    }
    fileprivate func claim() -> Bool {
        guard !submitted else { return false }
        submitted = true
        return true
    }
    /// Reject an unsubmitted delivery, for example after a connection changes.
    /// Once a presenter owns it, only that presenter may retire/drain the lease.
    func discard(_ reason: VMDisplayLeaseCancellation = .stopped) {
        guard claim() else { return }
        retire(.cancelled(reason))
    }
    fileprivate func beginRead() {
        precondition(submitted && retirement == nil && readers == 0)
        readers = 1
    }
    fileprivate func endRead(success: Bool) {
        precondition(readers == 1)
        readers = 0
        if success { hasPresented = true }
        else if retirement == nil { retirement = .failed(.gpuFailed) }
        finishIfRetired()
    }
    fileprivate func retire(_ result: VMDisplayLeaseResult) {
        if retirement == nil { retirement = result }
        finishIfRetired()
    }
    private func finishIfRetired() {
        guard readers == 0, let result = retirement, let callback = completion else { return }
        completion = nil
        callback(result)
    }
}

@MainActor
final class VMDisplayPresentationItem {
    enum Content { case rfb(VMDisplayFrame), external(VMExternalDisplayLease) }
    let content: Content
    init(_ content: Content) { self.content = content }
    var lease: VMExternalDisplayLease? { if case .external(let lease) = content { lease } else { nil } }
    var size: CGSize {
        switch content {
        case .rfb(let frame): CGSize(width: frame.width, height: frame.height)
        case .external(let lease): CGSize(width: lease.resolvedRegion.width, height: lease.resolvedRegion.height)
        }
    }
    var hasPixels: Bool { if case .rfb(let frame) = content { frame.hasReceivedPixels } else { true } }
    var sourceName: String { if case .rfb = content { "rfb" } else { "native" } }
    func retire(_ result: VMDisplayLeaseResult) { lease?.retire(result) }
}

@MainActor
final class VMDisplayPresentationTicket {
    let item: VMDisplayPresentationItem
    let generation: UInt64
    fileprivate var completed = false
    fileprivate init(item: VMDisplayPresentationItem, generation: UInt64) {
        self.item = item; self.generation = generation
    }
}

/// Shared by the real drawable and offscreen GPU tests. There is one current
/// image, one replaceable pending image, and at most one GPU read of current.
@MainActor
final class VMDisplayPresentationQueue {
    private var pending: VMDisplayPresentationItem?
    private var current: VMDisplayPresentationItem?
    private var inFlight: VMDisplayPresentationTicket?
    private(set) var stopped = false
    private(set) var failure: VMDisplayLeaseFailure?
    private(set) var generation: UInt64 = 0
    private(set) var completedFrames = 0
    private(set) var coalescedFrames = 0
    private(set) var maximumInFlight = 0
    var next: VMDisplayPresentationItem? { stopped || failure != nil || inFlight != nil ? nil : pending ?? current }
    var hasPending: Bool { pending != nil }

    func present(_ frame: VMDisplayFrame) {
        guard !stopped, failure == nil else { return }
        replacePending(with: .init(.rfb(frame)))
    }
    @discardableResult
    func present(_ lease: VMExternalDisplayLease, validationFailure: VMDisplayLeaseFailure? = nil) -> Bool {
        guard lease.claim() else { return false }
        if stopped { lease.retire(.cancelled(.stopped)); return false }
        if let failure = failure ?? validationFailure { lease.retire(.failed(failure)); return false }
        replacePending(with: .init(.external(lease)))
        return true
    }
    private func replacePending(with item: VMDisplayPresentationItem) {
        let previous = pending
        pending = item
        if previous != nil { coalescedFrames += 1 }
        previous?.retire(.cancelled(.superseded))
    }
    func begin(_ item: VMDisplayPresentationItem) -> VMDisplayPresentationTicket {
        precondition(next === item)
        let previous = current
        if pending === item { pending = nil }
        current = item
        let ticket = VMDisplayPresentationTicket(item: item, generation: generation)
        inFlight = ticket; maximumInFlight = 1
        item.lease?.beginRead()
        if let previous, previous !== item {
            previous.retire(previous.lease?.hasPresented == true ? .presented : .cancelled(.superseded))
        }
        return ticket
    }
    /// Must be called only by a completed GPU command, including the error path.
    /// Retiring an in-flight item cannot invoke its callback before this point.
    @discardableResult
    func complete(_ ticket: VMDisplayPresentationTicket, failed: Bool) -> Bool {
        guard !ticket.completed else { return false }
        ticket.completed = true
        if inFlight === ticket { inFlight = nil }
        let active = generation == ticket.generation && !stopped && failure == nil
        if active && failed {
            fail(.gpuFailed)
        } else if active { completedFrames += 1 }
        ticket.item.lease?.endRead(success: !failed)
        return active && failed && failure != nil
    }
    func fail(_ reason: VMDisplayLeaseFailure) {
        failure = reason
        retireAll(.failed(reason))
    }
    func reset() {
        failure = nil
        retireAll(.cancelled(.reset))
    }
    func stop(reason: VMDisplayLeaseCancellation = .stopped) {
        stopped = true
        retireAll(.cancelled(reason))
    }
    private func retireAll(_ result: VMDisplayLeaseResult) {
        generation &+= 1
        let oldPending = pending, oldCurrent = current
        pending = nil; current = nil
        oldPending?.retire(result)
        oldCurrent?.retire(result)
        // Keep the outstanding ticket until its GPU callback. A new generation
        // may enqueue now, but cannot start a second command before it finishes.
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
    private(set) var rfbUploadCount = 0

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct Vertex { float4 position [[position]]; float2 uv; };
        vertex Vertex displayVertex(uint id [[vertex_id]], constant float4 &mapping [[buffer(0)]]) {
            const float2 positions[3] = { float2(-1,1), float2(3,1), float2(-1,-3) };
            const float2 coordinates[3] = { float2(0,0), float2(2,0), float2(0,2) };
            Vertex out; out.position = float4(positions[id],0,1);
            out.uv = mapping.xy + coordinates[id] * mapping.zw; return out;
        }
        fragment float4 displayFragment(Vertex in [[stage_in]], texture2d<float> image [[texture(0)]],
                                         sampler filtering [[sampler(0)]], constant float4 &bounds [[buffer(0)]]) {
            return float4(image.sample(filtering, clamp(in.uv, bounds.xy, bounds.zw)).rgb, 1.0);
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
        rfbUploadCount += 1
        try encode(texture: source, region: .init(x: 0, y: 0, width: frame.width, height: frame.height),
                   into: target, commandBuffer: commandBuffer)
    }

    func externalTextureFailure(_ texture: any MTLTexture, region: VMDisplayTextureRegion? = nil) -> VMDisplayLeaseFailure? {
        guard texture.device.registryID == device.registryID else { return .incompatibleDevice }
        let region = region ?? .init(x: 0, y: 0, width: texture.width, height: texture.height)
        guard texture.textureType == .type2D, texture.sampleCount == 1,
              texture.pixelFormat == .bgra8Unorm || texture.pixelFormat == .rgba8Unorm,
              texture.usage.contains(.shaderRead), texture.width > 0, texture.height > 0,
              texture.width <= 16384, texture.height <= 16384,
              texture.width <= 134217728 / 4 / texture.height,
              region.x >= 0, region.y >= 0, region.width > 0, region.height > 0,
              region.width <= texture.width, region.height <= texture.height,
              region.x <= texture.width - region.width, region.y <= texture.height - region.height else { return .invalidTexture }
        return nil
    }

    /// Direct GPU sampling. This path neither creates Data nor uploads/copies the source.
    func encode(texture: any MTLTexture, region: VMDisplayTextureRegion? = nil, verticallyFlipped: Bool = false,
                into target: any MTLTexture, commandBuffer: any MTLCommandBuffer) throws {
        guard externalTextureFailure(texture, region: region) == nil,
              target.device.registryID == device.registryID, commandBuffer.device.registryID == device.registryID,
              target.textureType == .type2D, target.sampleCount == 1,
              target.pixelFormat == .bgra8Unorm, target.usage.contains(.renderTarget),
              target !== texture else { throw PresenterError.invalidTexture }
        let region = region ?? .init(x: 0, y: 0, width: texture.width, height: texture.height)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { throw PresenterError.encoderUnavailable }
        let destination = CGSize(width: target.width, height: target.height)
        let size = CGSize(width: region.width, height: region.height)
        let rect = VMDisplayGeometry.fit(source: size, destination: destination)
        encoder.setViewport(MTLViewport(originX: rect.minX, originY: rect.minY,
            width: rect.width, height: rect.height, znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        let width = Float(texture.width), height = Float(texture.height)
        var mapping = SIMD4<Float>(Float(region.x) / width,
            Float(verticallyFlipped ? region.y + region.height : region.y) / height,
            Float(region.width) / width, Float(region.height) / height * (verticallyFlipped ? -1 : 1))
        var bounds = SIMD4<Float>((Float(region.x) + 0.5) / width, (Float(region.y) + 0.5) / height,
            (Float(region.x + region.width) - 0.5) / width, (Float(region.y + region.height) - 0.5) / height)
        encoder.setVertexBytes(&mapping, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&bounds, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(VMDisplayGeometry.usesNearest(source: size, destination: destination) ? nearest : linear, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    enum PresenterError: Error { case invalidFrame, invalidTexture, textureUnavailable, encoderUnavailable }
}

/// Presentation only: all input, focus, accessibility and guest state stay in the parent.
/// One command buffer and one replaceable pending frame bound both GPU and main-thread work.
@MainActor
final class VMMetalDisplayView: MTKView, MTKViewDelegate {
    private let renderer: VMMetalRenderer
    private let presentation = VMDisplayPresentationQueue()
    private var redrawRequested = false
    private var loggedFirstFrame = false
    var onFailure: (() -> Void)?
    var completedFrames: Int { presentation.completedFrames }
    var coalescedFrames: Int { presentation.coalescedFrames }
    var maximumInFlight: Int { presentation.maximumInFlight }

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
    deinit {
        let presentation = presentation
        Task { @MainActor in presentation.stop(reason: .presenterReleased) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    func present(_ frame: VMDisplayFrame) {
        presentation.present(frame)
        needsDisplay = true
    }

    /// A successful submission keeps the lease current until replacement or
    /// reset/stop. The callback, not the return value, permits backing reuse.
    @discardableResult
    func present(_ lease: VMExternalDisplayLease) -> Bool {
        let accepted = presentation.present(lease,
            validationFailure: renderer.externalTextureFailure(lease.texture, region: lease.region))
        if accepted { needsDisplay = true }
        return accepted
    }

    func reset() {
        redrawRequested = false; loggedFirstFrame = false
        releaseDrawables()
        presentation.reset()
    }

    func stop() {
        redrawRequested = false
        delegate = nil; onFailure = nil
        releaseDrawables()
        presentation.stop()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        redrawRequested = true
        needsDisplay = true
    }

    func draw(in view: MTKView) {
        guard !isHidden, let item = presentation.next,
              drawableSize.width > 0, drawableSize.height > 0,
              let drawable = currentDrawable, let command = renderer.queue.makeCommandBuffer() else { return }
        redrawRequested = false
        do {
            switch item.content {
            case .rfb(let frame): try renderer.encode(frame, into: drawable.texture, commandBuffer: command)
            case .external(let lease):
                try renderer.encode(texture: lease.texture, region: lease.region, verticallyFlipped: lease.verticallyFlipped,
                                    into: drawable.texture, commandBuffer: command)
            }
        } catch {
            presentation.fail(.encodingFailed)
            if presentation.failure == .encodingFailed { onFailure?() }
            return
        }
        let ticket = presentation.begin(item)
        command.present(drawable)
        let drawableWidth = drawable.texture.width, drawableHeight = drawable.texture.height
        let presentation = presentation
        command.addCompletedHandler { [weak self, presentation, ticket] command in
            let failed = command.status == .error
            Task { @MainActor [weak self] in
                if self == nil { presentation.stop(reason: .presenterReleased) }
                let notifyFailure = presentation.complete(ticket, failed: failed)
                guard let self, !presentation.stopped else { return }
                if notifyFailure { self.onFailure?(); return }
                if !self.loggedFirstFrame && item.hasPixels && presentation.generation == ticket.generation && !failed {
                    self.loggedFirstFrame = true
                    VMDisplayDiagnostics.firstMetalFrame(width: Int(item.size.width), height: Int(item.size.height),
                        drawableWidth: drawableWidth, drawableHeight: drawableHeight, source: item.sourceName)
                }
                if presentation.hasPending || self.redrawRequested { self.needsDisplay = true }
            }
        }
        command.commit()
    }
}
