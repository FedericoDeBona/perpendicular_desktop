import AppKit
import Metal

@MainActor
private final class Checks {
    var count = 0
    func require(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        count += 1
    }
}

@MainActor
private func makeTexture(_ renderer: VMMetalRenderer, width: Int = 4, height: Int = 4,
                         format: MTLPixelFormat = .bgra8Unorm, usage: MTLTextureUsage = [.shaderRead, .renderTarget],
                         storage: MTLStorageMode = .shared) -> any MTLTexture {
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
    desc.storageMode = storage; desc.usage = usage
    return renderer.device.makeTexture(descriptor: desc)!
}

/// A real GPU blit initializes private textures. The presenter cannot read these
/// pixels on the CPU and must sample the external Metal resource directly.
@MainActor
private func privateTexture(_ renderer: VMMetalRenderer, width: Int, height: Int,
                            bytes: [UInt8], format: MTLPixelFormat = .bgra8Unorm) -> any MTLTexture {
    let seed = makeTexture(renderer, width: width, height: height, format: format)
    bytes.withUnsafeBytes { seed.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
        withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
    let output = makeTexture(renderer, width: width, height: height, format: format, storage: .private)
    let command = renderer.queue.makeCommandBuffer()!, blit = command.makeBlitCommandEncoder()!
    blit.copy(from: seed, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
              sourceSize: .init(width: width, height: height, depth: 1), to: output, destinationSlice: 0,
              destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
    blit.endEncoding(); command.commit(); command.waitUntilCompleted()
    precondition(command.status == .completed)
    return output
}

private func rgba(_ texture: any MTLTexture, _ x: Int, _ y: Int) -> [UInt8] {
    var pixel = [UInt8](repeating: 0, count: 4)
    texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
    return [pixel[2], pixel[1], pixel[0], pixel[3]]
}

@MainActor
private func waitFor(_ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !condition() {
        precondition(ProcessInfo.processInfo.systemUptime < deadline, "GPU/main-actor completion timed out")
        try await Task.sleep(for: .milliseconds(2))
    }
}

@MainActor
private func direct(_ renderer: VMMetalRenderer, _ source: any MTLTexture,
                    width: Int, height: Int, region: VMDisplayTextureRegion? = nil,
                    flipped: Bool = false) throws -> any MTLTexture {
    let target = makeTexture(renderer, width: width, height: height)
    let command = renderer.queue.makeCommandBuffer()!
    try renderer.encode(texture: source, region: region, verticallyFlipped: flipped, into: target, commandBuffer: command)
    command.commit(); command.waitUntilCompleted()
    precondition(command.status == .completed)
    return target
}

/// The real view uses this same queue and renderer. A shared-event wait lets
/// the test hold actual GPU completion without blocking the main actor.
@MainActor
private func submit(_ state: VMDisplayPresentationQueue, _ renderer: VMMetalRenderer,
                    target: any MTLTexture, waitEvent: (any MTLSharedEvent)? = nil,
                    injectCompletionFailure: Bool = false) throws -> any MTLCommandBuffer {
    let item = state.next!
    let command = renderer.queue.makeCommandBuffer()!
    if let waitEvent { command.encodeWaitForEvent(waitEvent, value: 1) }
    switch item.content {
    case .rfb(let frame): try renderer.encode(frame, into: target, commandBuffer: command)
    case .external(let lease):
        try renderer.encode(texture: lease.texture, region: lease.region, verticallyFlipped: lease.verticallyFlipped,
                            into: target, commandBuffer: command)
    }
    let ticket = state.begin(item)
    command.addCompletedHandler { command in
        let failed = command.status == .error || injectCompletionFailure
        Task { @MainActor in state.complete(ticket, failed: failed) }
    }
    command.commit()
    return command
}

@main
private enum ExternalPresenterCheck {
    @MainActor static func main() async throws {
        let checks = Checks()
        guard let renderer = VMMetalRenderer() else { fatalError("Real Metal device/pipeline unavailable") }
        let red: [UInt8] = [0, 0, 255, 0], green: [UInt8] = [0, 255, 0, 0]
        let blue: [UInt8] = [255, 0, 0, 0], white: [UInt8] = [255, 255, 255, 0], magenta: [UInt8] = [255, 0, 255, 0]
        var pixels = [UInt8]()
        for y in 0..<4 { for x in 0..<4 {
            pixels += (1...2).contains(x) && (1...2).contains(y) ? [red, green, blue, white][(y - 1) * 2 + x - 1] : magenta
        } }
        let source = privateTexture(renderer, width: 4, height: 4, bytes: pixels)
        let crop = VMDisplayTextureRegion(x: 1, y: 1, width: 2, height: 2)
        let ordinary = try direct(renderer, source, width: 16, height: 8, region: crop)
        checks.require(rgba(ordinary, 5, 1) == [255, 0, 0, 255], "Native red/top origin/opaque alpha")
        checks.require(rgba(ordinary, 10, 1) == [0, 255, 0, 255], "Native green")
        checks.require(rgba(ordinary, 5, 6) == [0, 0, 255, 255], "Native blue/bottom origin")
        checks.require(rgba(ordinary, 10, 6) == [255, 255, 255, 255], "Native white")
        checks.require(rgba(ordinary, 0, 4) == [0, 0, 0, 255], "Native letterbox")
        let flipped = try direct(renderer, source, width: 8, height: 8, region: crop, flipped: true)
        checks.require(rgba(flipped, 1, 1) == [0, 0, 255, 255] && rgba(flipped, 1, 6) == [255, 0, 0, 255], "Native vertical flip")
        let rgbaSource = privateTexture(renderer, width: 2, height: 1, bytes: [255, 0, 0, 0, 0, 255, 0, 0], format: .rgba8Unorm)
        let rgbaImage = try direct(renderer, rgbaSource, width: 8, height: 4)
        checks.require(rgba(rgbaImage, 1, 1) == [255, 0, 0, 255] && rgba(rgbaImage, 6, 1) == [0, 255, 0, 255], "RGBA source channels")
        let edge = privateTexture(renderer, width: 4, height: 1, bytes: magenta + [0, 0, 0, 0] + white + magenta)
        let edgeCrop = VMDisplayTextureRegion(x: 1, y: 0, width: 2, height: 1)
        let fractional = try direct(renderer, edge, width: 7, height: 4, region: edgeCrop)
        checks.require(rgba(fractional, 0, 1) == [0, 0, 0, 255] && rgba(fractional, 6, 1) == [255, 255, 255, 255], "Fractional crop leaked surrounding texels")
        checks.require((100...155).contains(Int(rgba(fractional, 3, 1)[0])), "Native fractional filtering")
        checks.require(renderer.rfbUploadCount == 0, "External textures reached the RFB Data/upload path")

        var invalidResults: [VMDisplayLeaseResult] = []
        let view = VMMetalDisplayView.make()!
        for region in [VMDisplayTextureRegion(x: -1, y: 0, width: 1, height: 1),
                       .init(x: 0, y: 0, width: 0, height: 1), .init(x: 3, y: 0, width: 2, height: 1),
                       .init(x: Int.max, y: Int.max, width: 1, height: 1)] {
            let lease = VMExternalDisplayLease(texture: source, region: region) { invalidResults.append($0) }
            checks.require(!view.present(lease), "Invalid crop admitted")
        }
        let floatTexture = makeTexture(renderer, format: .rgba16Float)
        checks.require(!view.present(VMExternalDisplayLease(texture: floatTexture) { invalidResults.append($0) }), "Unsupported native format admitted")
        let noShaderRead = makeTexture(renderer, usage: .renderTarget)
        checks.require(!view.present(VMExternalDisplayLease(texture: noShaderRead) { invalidResults.append($0) }), "Non-readable native texture admitted")
        let arrayDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 4, height: 4, mipmapped: false)
        arrayDesc.textureType = .type2DArray; arrayDesc.arrayLength = 2; arrayDesc.usage = .shaderRead
        checks.require(!view.present(VMExternalDisplayLease(texture: renderer.device.makeTexture(descriptor: arrayDesc)!) { invalidResults.append($0) }), "Array native texture admitted")
        checks.require(invalidResults.count == 7 && invalidResults.allSatisfy { $0 == .failed(.invalidTexture) }, "Invalid submissions did not complete exactly once")
        var discardedResults: [VMDisplayLeaseResult] = []
        let discarded = VMExternalDisplayLease(texture: source) { discardedResults.append($0) }
        discarded.discard(.reset); discarded.discard(.stopped)
        checks.require(discardedResults == [.cancelled(.reset)] && !view.present(discarded), "Unsubmitted discard duplicated its callback or allowed later submission")
        view.stop()

        let target = makeTexture(renderer, width: 16, height: 16)
        let state = VMDisplayPresentationQueue()
        var outcomes: [String: [VMDisplayLeaseResult]] = [:]
        func lease(_ name: String, texture: (any MTLTexture)? = nil) -> VMExternalDisplayLease {
            VMExternalDisplayLease(texture: texture ?? source, region: texture == nil ? crop : nil) { outcomes[name, default: []].append($0) }
        }
        let a = lease("a"), b = lease("b", texture: rgbaSource)
        checks.require(state.present(a) && !state.present(a), "Duplicate pending lease was accepted")
        let first = try submit(state, renderer, target: target)
        a.discard(.stopped)
        checks.require(outcomes["a"] == nil, "External discard cancelled a presenter-owned in-flight lease")
        checks.require(!state.present(a), "Duplicate in-flight lease was accepted")
        try await waitFor { state.completedFrames == 1 }
        checks.require(first.status == .completed && outcomes["a"] == nil, "Current lease released after its first draw")
        let resizedTarget = makeTexture(renderer, width: 28, height: 12)
        let redraw = try submit(state, renderer, target: resizedTarget)
        try await waitFor { state.completedFrames == 2 }
        checks.require(redraw.status == .completed && outcomes["a"] == nil, "Current external lease was not retained across redraw")
        checks.require(rgba(resizedTarget, 10, 2) == [255, 0, 0, 255] && rgba(resizedTarget, 0, 2) == [0, 0, 0, 255], "External resize redraw lost the current image/geometry")
        checks.require(state.present(b) && outcomes["a"] == nil, "Queueing a replacement retired the current image early")
        _ = try submit(state, renderer, target: target)
        checks.require(outcomes["a"] == [.presented], "Retired completed lease missing exactly-once presented callback")
        try await waitFor { state.completedFrames == 3 }
        checks.require(state.next?.lease === b && outcomes["b"] == nil, "Replacement did not remain current")
        // After retirement the producer may overwrite/reuse the old backing.
        // A redraw of current must never sample the acknowledged source again.
        let overwrite = renderer.queue.makeCommandBuffer()!, pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = source; pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store; pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 1, 1)
        overwrite.makeRenderCommandEncoder(descriptor: pass)!.endEncoding()
        overwrite.commit()
        try await waitFor { overwrite.status == .completed || overwrite.status == .error }
        precondition(overwrite.status == .completed)
        _ = try submit(state, renderer, target: target)
        try await waitFor { state.completedFrames == 4 }
        checks.require(rgba(target, 2, 5) == [255, 0, 0, 255] && rgba(target, 14, 5) == [0, 255, 0, 255], "Redraw sampled the retired producer backing")
        let c = lease("c"), d = lease("d")
        state.present(c); state.present(d)
        checks.require(outcomes["c"] == [.cancelled(.superseded)] && state.hasPending, "Pending replacement was not cancelled immediately")
        state.reset(); state.reset()
        checks.require(outcomes["d"] == [.cancelled(.reset)] && outcomes["b"] == [.cancelled(.reset)], "Reset callbacks duplicated or lost")

        let burst = VMDisplayPresentationQueue()
        for index in 0..<128 { burst.present(lease("burst\(index)")) }
        checks.require(burst.coalescedFrames == 127 && (0..<127).allSatisfy { outcomes["burst\($0)"] == [.cancelled(.superseded)] }, "Native pending queue grew or lost coalesced callbacks")
        burst.stop()
        checks.require(outcomes["burst127"] == [.cancelled(.stopped)], "Final bounded pending lease leaked")

        // Hold an actual GPU read; old completion must not clear a new pending
        // generation, acknowledge early, count as current or poison its state.
        let resetState = VMDisplayPresentationQueue(), gate = renderer.device.makeSharedEvent()!
        let old = lease("old"), fresh = lease("fresh")
        resetState.present(old)
        let held = try submit(resetState, renderer, target: target, waitEvent: gate, injectCompletionFailure: true)
        resetState.reset(); resetState.present(fresh)
        checks.require(outcomes["old"] == nil && resetState.next == nil && resetState.hasPending, "Reset acknowledged an unfinished GPU read or started overlap")
        gate.signaledValue = 1
        try await waitFor { outcomes["old"] != nil }
        checks.require(held.status == .completed && outcomes["old"] == [.cancelled(.reset)], "Reset callback did not wait for actual GPU completion")
        checks.require(resetState.completedFrames == 0 && resetState.failure == nil && resetState.next?.lease === fresh, "Stale failed completion mutated the new generation")
        _ = try submit(resetState, renderer, target: target)
        try await waitFor { resetState.completedFrames == 1 }
        resetState.stop()
        checks.require(outcomes["fresh"] == [.cancelled(.stopped)], "Fresh current lease lost after stale completion")

        let stopState = VMDisplayPresentationQueue(), stopGate = renderer.device.makeSharedEvent()!
        stopState.present(lease("stopCurrent"))
        let heldStop = try submit(stopState, renderer, target: target, waitEvent: stopGate)
        stopState.present(lease("stopPending")); stopState.stop(); stopState.stop()
        checks.require(outcomes["stopCurrent"] == nil && outcomes["stopPending"] == [.cancelled(.stopped)], "Stop retired in-flight backing before GPU completion")
        checks.require(!stopState.present(lease("afterStop")) && outcomes["afterStop"] == [.cancelled(.stopped)], "Stopped presenter accepted a new lease")
        stopGate.signaledValue = 1
        try await waitFor { outcomes["stopCurrent"] != nil }
        checks.require(heldStop.status == .completed && outcomes["stopCurrent"] == [.cancelled(.stopped)], "Stop completion duplicated or preceded the GPU")

        let failureState = VMDisplayPresentationQueue(), failureGate = renderer.device.makeSharedEvent()!
        failureState.present(lease("encodingCurrent"))
        let failureCommand = try submit(failureState, renderer, target: target, waitEvent: failureGate)
        failureState.present(lease("encodingPending")); failureState.fail(.encodingFailed)
        checks.require(outcomes["encodingCurrent"] == nil && outcomes["encodingPending"] == [.failed(.encodingFailed)], "Encoding failure failed to preserve an outstanding GPU read")
        failureGate.signaledValue = 1
        try await waitFor { outcomes["encodingCurrent"] != nil }
        checks.require(failureCommand.status == .completed && outcomes["encodingCurrent"] == [.failed(.encodingFailed)], "Failure retired in-flight lease too early")
        checks.require(!failureState.present(lease("failedSubmission")) && outcomes["failedSubmission"] == [.failed(.encodingFailed)], "Failed presenter accepted a new lease")
        failureState.reset(); failureState.present(lease("recovered"))
        _ = try submit(failureState, renderer, target: target, injectCompletionFailure: true)
        try await waitFor { outcomes["recovered"] != nil }
        checks.require(outcomes["recovered"] == [.failed(.gpuFailed)] && failureState.failure == .gpuFailed, "GPU failure decision lost the callback/state")
        failureState.stop()

        let mixed = VMDisplayPresentationQueue()
        mixed.present(lease("mixPending"))
        mixed.present(VMDisplayFrame(width: 1, height: 1, pixels: Data(red)))
        checks.require(outcomes["mixPending"] == [.cancelled(.superseded)], "RFB did not retire a replaced pending native lease")
        _ = try submit(mixed, renderer, target: target)
        try await waitFor { mixed.completedFrames == 1 }
        mixed.present(lease("mixCurrent")); _ = try submit(mixed, renderer, target: target)
        try await waitFor { mixed.completedFrames == 2 }
        mixed.present(VMDisplayFrame(width: 1, height: 1, pixels: Data(green)))
        _ = try submit(mixed, renderer, target: target)
        try await waitFor { mixed.completedFrames == 3 }
        checks.require(outcomes["mixCurrent"] == [.presented] && rgba(target, 8, 8) == [0, 255, 0, 255], "Native-to-RFB transition reused a retired texture")
        checks.require(renderer.rfbUploadCount == 2, "External input performed an RFB upload")
        checks.require([state, resetState, stopState, failureState, mixed].allSatisfy { $0.maximumInFlight == 1 }, "Presentation had overlapping GPU reads")
        mixed.stop(); state.stop()

        var deallocatedResults: [VMDisplayLeaseResult] = []
        weak var releasedView: VMMetalDisplayView?
        autoreleasepool {
            let temporary = VMMetalDisplayView.make()!
            releasedView = temporary
            temporary.present(VMExternalDisplayLease(texture: source) { deallocatedResults.append($0) })
        }
        try await waitFor { !deallocatedResults.isEmpty }
        checks.require(releasedView == nil && deallocatedResults == [.cancelled(.presenterReleased)], "Deallocated view lost or duplicated its pending lease callback")
        checks.require(outcomes.values.allSatisfy { $0.count == 1 }, "A lease received more than one completion")

        let report: [String: Any] = ["result": "pass", "checks": checks.count, "device": renderer.device.name,
            "verified": ["private external textures", "BGRA/RGBA", "crop and vertical flip", "letterbox and fractional crop clamping",
                         "zero external RFB uploads", "hold current across redraw", "exactly-once retirement", "actual GPU shared-event delay",
                         "pending replacement", "reset/stop before GPU completion", "stale generation isolation", "RFB/native transitions", "view release"],
            "scope": "Real offscreen Metal; no window, VM, IPC, guest frame rate or producer-readiness qualification. GPU-error decisions are injected only after actual GPU command completion."]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 1 { try json.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic) }
        print(String(decoding: json, as: UTF8.self))
    }
}
