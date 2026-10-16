import AppKit
import MetalKit
import Darwin

struct VMNativeDisplayTiming: Sendable {
    let received: Double
    let ready: Double
    let delivered: Double?
}

/// Opt-in metadata only. One private, bounded report per process; no frame,
/// endpoint, VM identity, key, pointer position or clipboard content is stored.
/// All file writes run on the serial writer, never a Metal/main-actor callback.
final class VMDisplayTelemetry: @unchecked Sendable {
    static let shared: VMDisplayTelemetry? = {
        guard let directory = ProcessInfo.processInfo.environment["PERPENDICULAR_DISPLAY_TELEMETRY_DIR"] else { return nil }
        return try? VMDisplayTelemetry(directory: directory)
    }()
    static let recordLimit = 128
    static let metricLimit = 256
    static let byteLimit = 131_072
    struct Event: Encodable, Sendable {
        let kind: String
        let submission: UInt64
        let stream: UInt64
        let generation: UInt64
        let atMs: Double
        let stale: Bool
        let values: [String: Double]
    }
    struct Metric: Encodable, Sendable {
        let totalSamples: UInt64
        let recentSamples: Int
        let medianMs: Double
        let p95Ms: Double
        let minimumMs: Double
        let maximumMs: Double
    }
    struct Report: Encodable, Sendable {
        let schema = 1
        let scope = "Host native-display pipeline only; drawable presentation is not input-to-photon latency or guest FPS."
        let clock = "Host monotonic clock; event times relative to recorder start; durations in milliseconds."
        let sampleWindow = "Each metric uses its latest 256 valid samples; events use the latest 128 records."
        let counters: [String: UInt64]
        let metrics: [String: Metric]
        let events: [Event]
    }
    private struct Stream { var generation: UInt64; var previousPresented: Double? }
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "org.perpendicular.display-telemetry", qos: .utility)
    private let descriptor: Int32
    private let started = CACurrentMediaTime()
    let outputPath: String
    private var counters: [String: UInt64] = [:]
    private var metrics: [String: [Double]] = [:]
    private var metricCounts: [String: UInt64] = [:]
    private var events: [Event] = []
    private var streams: [UInt64: Stream] = [:]
    private var nextStream: UInt64 = 0
    private var nextSubmission: UInt64 = 0
    private var flushScheduled = false

    init(directory: String) throws {
        guard directory.hasPrefix("/"), !directory.utf8.contains(0) else { throw CocoaError(.fileWriteInvalidFileName) }
        var normalized = directory
        while normalized.count > 1, normalized.last == "/" { normalized.removeLast() }
        let parent = open(normalized, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let name = "native-presentation-\(getpid())-\(UUID().uuidString).json"
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        descriptor = fd
        outputPath = URL(fileURLWithPath: directory).appendingPathComponent(name).path
    }
    deinit { close(descriptor) }

    func count(_ key: String) { update { self.increment(key) } }
    func beginStream() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        nextStream &+= 1
        if streams.count == 8, let oldest = streams.keys.min() { streams.removeValue(forKey: oldest); increment("stream_history_evicted") }
        streams[nextStream] = .init(generation: 0)
        increment("streams_started")
        return nextStream
    }
    func reset(stream: UInt64, generation: UInt64) {
        update {
            guard self.streams[stream] != nil else { return }
            self.streams[stream] = .init(generation: generation)
            self.increment("resets")
        }
    }
    func endStream(_ stream: UInt64) {
        update { if self.streams.removeValue(forKey: stream) != nil { self.increment("streams_stopped") } }
    }
    func delivered(_ timing: VMNativeDisplayTiming) {
        update {
            self.increment("frames_delivered")
            self.metric("receive_to_ready", timing.ready - timing.received)
            if let delivered = timing.delivered { self.metric("ready_to_main_delivery", delivered - timing.ready) }
        }
    }
    func submission(stream: UInt64, generation: UInt64, timing: VMNativeDisplayTiming?, firstDraw: Bool,
                    width: Int = 0, height: Int = 0, drawableWidth: Int = 0, drawableHeight: Int = 0,
                    displayContext: [String: Double] = [:]) -> Submission {
        lock.lock(); nextSubmission &+= 1; let number = nextSubmission; lock.unlock()
        return Submission(owner: self, number: number, stream: stream, generation: generation,
                          timing: timing, firstDraw: firstDraw,
                          geometry: ["source_width": Double(width), "source_height": Double(height),
                                     "drawable_width": Double(drawableWidth), "drawable_height": Double(drawableHeight)]
                              .merging(displayContext) { original, _ in original })
    }
    private func increment(_ key: String) {
        guard counters[key] != nil || counters.count < 32 else { return }
        counters[key, default: 0] &+= 1
    }
    private func metric(_ key: String, _ seconds: Double) {
        let milliseconds = seconds * 1000
        guard milliseconds.isFinite, milliseconds >= 0 else { increment("invalid_timestamps"); return }
        guard metrics[key] != nil || metrics.count < 16 else { return }
        if metrics[key, default: []].count == Self.metricLimit { metrics[key]?.removeFirst() }
        metrics[key, default: []].append(milliseconds)
        metricCounts[key, default: 0] &+= 1
    }
    private func update(_ change: () -> Void) {
        lock.lock(); change()
        let schedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        if schedule { writer.asyncAfter(deadline: .now() + 1) { [self] in writeReport() } }
    }
    private func record(_ sample: Submission, kind: String, time: Double, values: [String: Double],
                        metrics change: (Bool) -> Void) {
        update {
            let stale = self.streams[sample.stream]?.generation != sample.generation
            self.increment(kind)
            if stale { self.increment("stale_callbacks") }
            change(stale)
            let relative = (time - self.started) * 1000
            guard relative.isFinite, values.values.allSatisfy(\.isFinite) else { self.increment("invalid_timestamps"); return }
            if self.events.count == Self.recordLimit { self.events.removeFirst() }
            self.events.append(.init(kind: kind, submission: sample.number, stream: sample.stream,
                generation: sample.generation, atMs: relative, stale: stale, values: values))
        }
    }
    func snapshot() -> Report {
        lock.lock(); defer { lock.unlock() }
        let summaries = Dictionary(uniqueKeysWithValues: metrics.map { key, samples in
            let values = samples.sorted()
            // Nearest-rank quantiles describe this bounded recent sample window.
            return (key, Metric(totalSamples: metricCounts[key] ?? 0, recentSamples: values.count,
                medianMs: values[max(0, Int(ceil(Double(values.count) * 0.5)) - 1)],
                p95Ms: values[max(0, Int(ceil(Double(values.count) * 0.95)) - 1)],
                minimumMs: values[0], maximumMs: values[values.count - 1]))
        })
        return .init(counters: counters, metrics: summaries, events: events)
    }
    /// Tests/capture tools may explicitly checkpoint; production callbacks only
    /// schedule one coalesced asynchronous write, at most once per second.
    func checkpoint() { writer.sync { writeReport() } }
    private func writeReport() {
        lock.lock(); flushScheduled = false; lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot()), data.count <= Self.byteLimit else { return }
        let success = data.withUnsafeBytes { bytes -> Bool in
            var offset = 0
            for _ in 0..<8 where offset < bytes.count {
                let written = pwrite(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, off_t(offset))
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return offset == bytes.count && ftruncate(descriptor, off_t(bytes.count)) == 0
        }
        if !success { lock.lock(); increment("report_write_failures"); lock.unlock() }
    }

    /// Contains only timestamps/ordinals: delayed drawable callbacks cannot
    /// retain a lease/texture or interfere with GPU-drained retirement/ACK.
    final class Submission: @unchecked Sendable {
        private let owner: VMDisplayTelemetry
        fileprivate let number: UInt64
        fileprivate let stream: UInt64
        fileprivate let generation: UInt64
        private let timing: VMNativeDisplayTiming?
        private let firstDraw: Bool
        private let geometry: [String: Double]
        private let lock = NSLock()
        private var committed: Double?
        private var gpuRecorded = false
        private var presentedRecorded = false
        private var mainRecorded = false
        fileprivate init(owner: VMDisplayTelemetry, number: UInt64, stream: UInt64, generation: UInt64,
                         timing: VMNativeDisplayTiming?, firstDraw: Bool, geometry: [String: Double]) {
            self.owner = owner; self.number = number; self.stream = stream; self.generation = generation
            self.timing = timing; self.firstDraw = firstDraw
            self.geometry = geometry
        }
        func commit(at time: Double = CACurrentMediaTime()) {
            lock.lock(); guard committed == nil else { lock.unlock(); return }; committed = time; lock.unlock()
            var values = geometry; values["first_draw"] = firstDraw ? 1 : 0
            owner.record(self, kind: "gpu_submitted", time: time, values: values) { _ in
                if self.firstDraw, let timing = self.timing { self.owner.metric("receive_to_commit", time - timing.received) }
                if !self.firstDraw { self.owner.increment("redraws_submitted") }
            }
        }
        func gpuCompleted(start: Double, end: Double, failed: Bool, callback: Double = CACurrentMediaTime()) {
            lock.lock(); guard !gpuRecorded, let committed else { lock.unlock(); return }; gpuRecorded = true; lock.unlock()
            let available = start.isFinite && end.isFinite && start > 0 && end >= start
            let values = available ? ["gpu_start_ms": (start - owner.started) * 1000, "gpu_end_ms": (end - owner.started) * 1000] : [:]
            owner.record(self, kind: failed ? "gpu_failed" : "gpu_completed", time: callback,
                values: values) { _ in
                guard !failed, available else { self.owner.increment("gpu_timing_unavailable"); return }
                self.owner.metric("commit_to_gpu_start", start - committed)
                self.owner.metric("gpu_execution", end - start)
                self.owner.metric("gpu_end_to_callback", callback - end)
            }
        }
        func mainCallback(after gpuCallback: Double, at time: Double = CACurrentMediaTime()) {
            lock.lock(); guard !mainRecorded else { lock.unlock(); return }; mainRecorded = true; lock.unlock()
            owner.record(self, kind: "main_completion_callbacks", time: time, values: [:]) { _ in
                self.owner.metric("gpu_callback_to_main", time - gpuCallback)
            }
        }
        func drawablePresented(at time: Double, callback: Double = CACurrentMediaTime()) {
            lock.lock(); guard !presentedRecorded, let committed else { lock.unlock(); return }; presentedRecorded = true; lock.unlock()
            owner.record(self, kind: time > 0 ? "drawable_presented" : "drawable_skipped", time: callback,
                values: ["presented_ms": time > 0 ? (time - owner.started) * 1000 : 0]) { stale in
                guard !stale, time.isFinite, time >= committed else { return }
                self.owner.metric("commit_to_presented", time - committed)
                if self.firstDraw, let timing = self.timing { self.owner.metric("receive_to_presented", time - timing.received) }
                if let previous = self.owner.streams[self.stream]?.previousPresented, time > previous {
                    self.owner.metric("drawable_interval", time - previous)
                }
                // Delayed/out-of-order callbacks never regress interval history.
                if time > (self.owner.streams[self.stream]?.previousPresented ?? 0) {
                    self.owner.streams[self.stream]?.previousPresented = time
                }
            }
        }
    }
}

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
    let timing: VMNativeDisplayTiming?
    private var completion: (@MainActor (VMDisplayLeaseResult) -> Void)?
    private var submitted = false
    private var readers = 0
    private var retirement: VMDisplayLeaseResult?
    private(set) var hasPresented = false

    init(texture: any MTLTexture, region: VMDisplayTextureRegion? = nil, verticallyFlipped: Bool = false,
         timing: VMNativeDisplayTiming? = nil,
         completion: @escaping @MainActor (VMDisplayLeaseResult) -> Void) {
        self.texture = texture; self.region = region; self.verticallyFlipped = verticallyFlipped
        self.timing = timing
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
    fileprivate var telemetryDraws = 0
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
    private let telemetry: VMDisplayTelemetry?
    private let telemetryStream: UInt64?
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
        telemetry = VMDisplayTelemetry.shared
        telemetryStream = telemetry?.beginStream()
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
        if let telemetryStream { telemetry?.endStream(telemetryStream) }
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
        let previousCoalesced = presentation.coalescedFrames
        let accepted = presentation.present(lease,
            validationFailure: renderer.externalTextureFailure(lease.texture, region: lease.region))
        telemetry?.count(accepted ? "presenter_accepted" : "presenter_rejected")
        if presentation.coalescedFrames > previousCoalesced { telemetry?.count("presenter_pending_replaced") }
        if accepted { needsDisplay = true }
        return accepted
    }

    func reset() {
        redrawRequested = false; loggedFirstFrame = false
        releaseDrawables()
        presentation.reset()
        if let telemetryStream { telemetry?.reset(stream: telemetryStream, generation: presentation.generation) }
    }

    func stop() {
        redrawRequested = false
        delegate = nil; onFailure = nil
        releaseDrawables()
        presentation.stop()
        if let telemetryStream { telemetry?.endStream(telemetryStream) }
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
            if let telemetryStream { telemetry?.reset(stream: telemetryStream, generation: presentation.generation) }
            if presentation.failure == .encodingFailed { onFailure?() }
            return
        }
        let ticket = presentation.begin(item)
        let measurement: VMDisplayTelemetry.Submission?
        if let lease = item.lease, let telemetryStream {
            measurement = telemetry?.submission(stream: telemetryStream, generation: ticket.generation,
                timing: lease.timing, firstDraw: item.telemetryDraws == 0,
                width: Int(item.size.width), height: Int(item.size.height),
                drawableWidth: drawable.texture.width, drawableHeight: drawable.texture.height,
                displayContext: [
                    "window_visible": window?.isVisible == true ? 1 : 0,
                    "window_unoccluded": window?.occlusionState.contains(.visible) == true ? 1 : 0,
                    "window_key": window?.isKeyWindow == true ? 1 : 0,
                    "app_active": NSApp.isActive ? 1 : 0,
                    "view_hidden": isHiddenOrHasHiddenAncestor ? 1 : 0,
                    "view_transaction": presentsWithTransaction ? 1 : 0,
                    "layer_transaction": (layer as? CAMetalLayer).map { $0.presentsWithTransaction ? 1 : 0 } ?? -1,
                    "display_sync": (layer as? CAMetalLayer).map { $0.displaySyncEnabled ? 1 : 0 } ?? -1
                ])
            item.telemetryDraws += 1
        } else { measurement = nil }
        if let measurement {
            drawable.addPresentedHandler { drawable in measurement.drawablePresented(at: drawable.presentedTime) }
        }
        command.present(drawable)
        let drawableWidth = drawable.texture.width, drawableHeight = drawable.texture.height
        let presentation = presentation
        command.addCompletedHandler { [weak self, presentation, ticket] command in
            let failed = command.status == .error
            let callbackTime = measurement == nil ? 0 : CACurrentMediaTime()
            measurement?.gpuCompleted(start: command.gpuStartTime, end: command.gpuEndTime, failed: failed, callback: callbackTime)
            Task { @MainActor [weak self] in
                measurement?.mainCallback(after: callbackTime)
                if self == nil { presentation.stop(reason: .presenterReleased) }
                let notifyFailure = presentation.complete(ticket, failed: failed)
                guard let self, !presentation.stopped else { return }
                if notifyFailure {
                    if let telemetryStream = self.telemetryStream {
                        self.telemetry?.reset(stream: telemetryStream, generation: presentation.generation)
                    }
                    self.onFailure?(); return
                }
                if !self.loggedFirstFrame && item.hasPixels && presentation.generation == ticket.generation && !failed {
                    self.loggedFirstFrame = true
                    VMDisplayDiagnostics.firstMetalFrame(width: Int(item.size.width), height: Int(item.size.height),
                        drawableWidth: drawableWidth, drawableHeight: drawableHeight, source: item.sourceName)
                }
                if presentation.hasPending || self.redrawRequested { self.needsDisplay = true }
            }
        }
        measurement?.commit()
        command.commit()
    }
}
