// Explicit visible fixture only. Never include in the ordinary test suite.
// Uses the unchanged production presenter and its normal needsDisplay policy.
import AppKit
import Metal
import Darwin

private struct PresentationProbeConfiguration {
    enum Mode: String { case standalone, parentFlipped = "parent-flipped" }
    let mode: Mode
    let invalidateParent: Bool
    let assignHidden: Bool
    init(environment: [String: String]) throws {
        guard let mode = Mode(rawValue: environment["PERPENDICULAR_PRESENTATION_PROBE_MODE"] ?? "standalone") else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        func flag(_ name: String) throws -> Bool {
            switch environment[name] ?? "0" {
            case "0": return false
            case "1": return true
            default: throw CocoaError(.validationMissingMandatoryProperty)
            }
        }
        self.mode = mode
        invalidateParent = try flag("PERPENDICULAR_PRESENTATION_PROBE_PARENT_INVALIDATION")
        assignHidden = try flag("PERPENDICULAR_PRESENTATION_PROBE_HIDDEN_ASSIGNMENT")
        guard mode == .parentFlipped || !invalidateParent else { throw CocoaError(.validationMissingMandatoryProperty) }
    }
    var report: [String: Any] {
        ["host_mode": mode.rawValue, "parent_invalidation_per_lease": invalidateParent,
         "hidden_assignment_per_lease": assignHidden, "swiftui_hosted": false]
    }
}

/// The production console's relevant parent behavior, without sockets/input.
/// The same parent exists in both A/B variants; only its per-lease dirty flag
/// differs. No layer/transaction/renderer policy is changed here.
@MainActor
private final class PresentationProbeParent: NSView {
    private(set) var draws: UInt64 = 0
    private(set) var invalidations: UInt64 = 0
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 800, height: 600) }
    override func draw(_ dirtyRect: NSRect) {
        draws += 1
        NSColor.black.setFill()
        bounds.fill()
    }
    func invalidateForLease() { invalidations += 1; needsDisplay = true }
}

@MainActor
private final class VisiblePresentationProbe: NSObject, NSWindowDelegate {
    @MainActor private final class Slot {
        let backing: any MTLBuffer
        let texture: any MTLTexture
        let producer: any MTLTexture
        var occupied = false
        var frame: UInt64 = 0
        init(device: any MTLDevice) throws {
            let width = 1920, height = 1440
            let alignment = device.minimumLinearTextureAlignment(for: .bgra8Unorm)
            guard alignment > 0 else { throw CocoaError(.featureUnsupported) }
            let pitch = (width * 4 + alignment - 1) / alignment * alignment
            guard let backing = device.makeBuffer(length: pitch * height, options: .storageModeShared) else {
                throw CocoaError(.featureUnsupported)
            }
            self.backing = backing
            let shared = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            shared.storageMode = .shared; shared.usage = .shaderRead
            guard let texture = backing.makeTexture(descriptor: shared, offset: 0, bytesPerRow: pitch) else {
                throw CocoaError(.featureUnsupported)
            }
            self.texture = texture
            let rendered = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            rendered.storageMode = .private; rendered.usage = .renderTarget
            guard let producer = device.makeTexture(descriptor: rendered) else { throw CocoaError(.featureUnsupported) }
            self.producer = producer
        }
    }

    private let view: VMMetalDisplayView
    private let window: NSWindow
    private let producerQueue: any MTLCommandQueue
    private let recorder: VMDisplayTelemetry
    private let output: Int32
    private let slots: [Slot]
    private let configuration: PresentationProbeConfiguration
    private let parent: PresentationProbeParent?
    private var timer: (any DispatchSourceTimer)?
    private var started = 0.0
    private var draining: Double?
    private var finished = false
    private var failure: String?
    private var counters: [String: UInt64] = [:]
    private struct Observation {
        let elapsed: Double
        let host: [String: UInt64]
        let producer: [String: UInt64]
        let context: [String: Bool]
        var report: [String: Any] {
            ["elapsed_seconds": elapsed, "host_counters": host, "producer_counters": producer, "context": context]
        }
    }
    private var samples: [Observation] = []
    private var nextSample = 0.0
    private var continuouslyVisibleSince: Double?
    private var steadyStart: Observation?
    private var steadyEnd: Observation?
    private var steadyInterrupted = false
    private(set) var exitCode: Int32 = 1

    init(directory: String, configuration: PresentationProbeConfiguration) throws {
        self.configuration = configuration
        // Pin the owned private output directory before any UI/Metal creation.
        let directoryDescriptor = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(directoryDescriptor) }
        var attributes = stat()
        guard fstat(directoryDescriptor, &attributes) == 0, attributes.st_uid == geteuid(), attributes.st_mode & 0o777 == 0o700 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let result = openat(directoryDescriptor, "visible-probe-result.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard result >= 0 else { throw CocoaError(.fileWriteFileExists) }
        // Every later failure leaves a private, inspectable JSON error through
        // the runner; the source never overwrites another run's result.
        output = result
        guard let recorder = VMDisplayTelemetry.shared, let view = VMMetalDisplayView.make(),
              let device = view.device, let queue = device.makeCommandQueue() else {
            close(result); throw CocoaError(.featureUnsupported)
        }
        self.recorder = recorder; self.view = view; producerQueue = queue
        do { slots = try [Slot(device: device), Slot(device: device)] }
        catch { close(result); throw error }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 900)
        let size = NSSize(width: max(400, min(1640, screen.width - 80)), height: max(300, min(737, screen.height - 100)))
        parent = configuration.mode == .parentFlipped ? PresentationProbeParent(frame: NSRect(origin: .zero, size: size)) : nil
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = configuration.mode == .standalone ? "Perpendicular Presentation Probe" :
            "Perpendicular Presentation Probe — Parent \(configuration.invalidateParent ? "Dirty" : "Clean")"
        window.isReleasedWhenClosed = false; window.delegate = self
        if let parent { parent.addSubview(view); window.contentView = parent }
        else { window.contentView = view }
        view.frame = NSRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        view.onFailure = { [weak self] in self?.fail("presenter_failed") }
    }
    deinit { close(output) }

    func start() {
        started = CACurrentMediaTime()
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        self.timer = timer; timer.resume()
    }
    func windowWillClose(_ notification: Notification) { fail("window_closed_early") }
    private func count(_ name: String) { counters[name, default: 0] += 1 }
    private func fail(_ reason: String) { if failure == nil { failure = reason }; drain() }
    private func drain() {
        guard draining == nil else { return }
        draining = CACurrentMediaTime()
        view.stop() // Pending cancelled now; GPU readers retire only on completion.
    }
    private func tick() {
        guard !finished else { return }
        let now = CACurrentMediaTime()
        observe(now)
        if now - started >= 12 { drain() }
        if let draining {
            if slots.allSatisfy({ !$0.occupied }), now - draining >= 0.25 { finish(); return }
            if now - started >= 14.5 { failure = failure ?? "gpu_drain_timeout"; finish() }
            return
        }
        count("timer_ticks")
        guard (counters["producer_started"] ?? 0) < 720 else { drain(); return }
        guard let slot = slots.first(where: { !$0.occupied }) else { count("producer_no_free_slot"); return }
        guard let command = producerQueue.makeCommandBuffer() else { fail("producer_command_unavailable"); return }
        let pass = MTLRenderPassDescriptor()
        let phase = (now - started) * 2.0
        pass.colorAttachments[0].texture = slot.producer
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake((sin(phase) + 1) / 2, (sin(phase + 2) + 1) / 2, (sin(phase + 4) + 1) / 2, 1)
        guard let render = command.makeRenderCommandEncoder(descriptor: pass) else { fail("producer_render_unavailable"); return }
        render.endEncoding()
        guard let copy = command.makeBlitCommandEncoder() else { fail("producer_blit_unavailable"); return }
        copy.copy(from: slot.producer, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
            sourceSize: .init(width: 1920, height: 1440, depth: 1), to: slot.texture, destinationSlice: 0,
            destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
        copy.endEncoding()
        count("producer_started"); slot.occupied = true; slot.frame = counters["producer_started"]!
        let identity = slot.frame
        // Exactly two reservations include producer GPU, pending and current
        // leases. The same shared backing is never rewritten before retirement.
        command.addCompletedHandler { [weak self, slot] completed in
            let success = completed.status == .completed && completed.error == nil
            DispatchQueue.main.async { [weak self, slot] in self?.produced(slot, identity: identity, success: success) }
        }
        command.commit()
    }
    private func produced(_ slot: Slot, identity: UInt64, success: Bool) {
        guard !finished else { return }
        guard slot.occupied, slot.frame == identity else { fail("reservation_identity_changed"); return }
        if !success { slot.occupied = false; fail("producer_gpu_failed"); return }
        count("producer_gpu_completed")
        guard draining == nil else { slot.occupied = false; count("producer_cancelled_before_lease"); return }
        count("leases_created")
        // No synthetic receive timestamp: this fixture has no transport/guest.
        let lease = VMExternalDisplayLease(texture: slot.texture) { [weak self, slot] result in
            guard let self, !self.finished else { return }
            guard slot.occupied, slot.frame == identity else { self.fail("duplicate_retirement"); return }
            slot.occupied = false; self.count("leases_retired")
            switch result {
            case .presented: self.count("leases_retired_after_gpu")
            case .cancelled: self.count("leases_cancelled")
            case .failed: self.count("leases_failed"); self.fail("presenter_lease_failed")
            }
        }
        if view.present(lease) {
            count("leases_accepted")
            if configuration.assignHidden { view.isHidden = false; count("hidden_assignments") }
            if configuration.invalidateParent { parent?.invalidateForLease() }
        }
        else { fail("presenter_rejected_lease") }
    }
    private func observation(at time: Double) -> Observation {
        var producer = counters
        producer["parent_draws"] = parent?.draws ?? 0
        producer["parent_invalidations"] = parent?.invalidations ?? 0
        return .init(elapsed: time - started, host: recorder.snapshot().counters, producer: producer,
            context: ["app_active": NSApp.isActive, "window_visible": window.isVisible,
                      "window_unoccluded": window.occlusionState.contains(.visible), "window_key": window.isKeyWindow,
                      "view_hidden": view.isHiddenOrHasHiddenAncestor])
    }
    private func observe(_ time: Double) {
        let elapsed = time - started
        let visible = NSApp.isActive && window.isVisible && window.isKeyWindow &&
            window.occlusionState.contains(.visible) && !view.isHiddenOrHasHiddenAncestor
        if visible { if continuouslyVisibleSince == nil { continuouslyVisibleSince = time } }
        else {
            continuouslyVisibleSince = nil
            if steadyStart != nil && steadyEnd == nil { steadyInterrupted = true }
        }
        // Admission is contextual, never inferred from total_count / 12 sec.
        // The fixed 11-second end also excludes stop/close-induced callbacks.
        if steadyStart == nil, elapsed >= 4, elapsed < 11, visible,
           let continuouslyVisibleSince, time - continuouslyVisibleSince >= 1 {
            steadyStart = observation(at: time)
        }
        if steadyStart != nil, steadyEnd == nil, elapsed >= 11 { steadyEnd = observation(at: time) }
        if elapsed >= nextSample, samples.count < 16 {
            samples.append(observation(at: time)); nextSample = floor(elapsed) + 1
        }
    }
    private func windowReport() -> [String: Any] {
        var report: [String: Any] = [
            "admission": "Elapsed >=4s and active/key/visible/unoccluded continuously >=1s; end at first tick >=11s.",
            "startup_end_seconds": steadyStart?.elapsed as Any? ?? NSNull(),
            "samples": samples.map(\.report), "sample_limit": 16,
            "scope": "Cumulative counter observations; callback times may cross boundaries. Latest-256 telemetry metrics are not recomputed for this window. No input-to-photon or physical refresh rate is measured."]
        guard let begin = steadyStart, let end = steadyEnd, end.elapsed > begin.elapsed else {
            report["steady"] = ["admitted": false, "reason": "No complete central observation window met visibility admission."]
            return report
        }
        func delta(_ after: [String: UInt64], _ before: [String: UInt64]) -> [String: UInt64] {
            Dictionary(uniqueKeysWithValues: Set(before.keys).union(after.keys).map { key in
                (key, (after[key] ?? 0) >= (before[key] ?? 0) ? (after[key] ?? 0) - (before[key] ?? 0) : 0)
            })
        }
        report["steady"] = ["admitted": true, "begin_seconds": begin.elapsed, "end_seconds": end.elapsed,
            "duration_seconds": end.elapsed - begin.elapsed, "visibility_interrupted": steadyInterrupted,
            "host_counter_deltas": delta(end.host, begin.host), "producer_counter_deltas": delta(end.producer, begin.producer),
            "begin_context": begin.context, "end_context": end.context]
        return report
    }
    private func finish() {
        guard !finished else { return }; finished = true
        timer?.setEventHandler {}; timer?.cancel(); timer = nil
        recorder.checkpoint()
        let telemetry = recorder.snapshot()
        let reserved = slots.filter(\.occupied).count
        if reserved != 0 || counters["leases_created"] != counters["leases_retired"] { failure = failure ?? "leases_not_drained" }
        if (telemetry.counters["gpu_completed"] ?? 0) == 0 { failure = failure ?? "no_presenter_gpu_completion" }
        let reportedCallbacks = (telemetry.counters["drawable_presented"] ?? 0) + (telemetry.counters["drawable_skipped"] ?? 0)
        do {
            let report: [String: Any] = ["schema": 1, "probe": "perpendicular-visible-host-presentation",
                "status": failure == nil ? "completed" : "failed", "failure": failure as Any? ?? NSNull(),
                "requested_seconds": 12, "elapsed_seconds": CACurrentMediaTime() - started, "requested_source_hz": 60,
                "source_width": 1920, "source_height": 1440, "slot_limit": 2, "reserved_at_finish": reserved,
                "configuration": configuration.report, "observation_windows": windowReport(),
                "parent_draws": parent?.draws ?? 0, "parent_invalidations": parent?.invalidations ?? 0,
                "producer": counters, "drawable_callbacks_pending_at_capture": max(0, Int64(telemetry.counters["gpu_completed"] ?? 0) - Int64(reportedCallbacks)),
                "telemetry": try JSONSerialization.jsonObject(with: JSONEncoder().encode(telemetry)),
                "scope": "Visible own window, host-generated GPU colour snapshots and production presenter. No guest, IPC, input, changes to rendering policy or claim of physical photon latency. Timer request is not measured FPS."]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            guard data.count <= 262_144 else { throw CocoaError(.fileWriteOutOfSpace) }
            let written = data.withUnsafeBytes { write(output, $0.baseAddress!, $0.count) }
            guard written == data.count else { throw CocoaError(.fileWriteUnknown) }
            exitCode = failure == nil ? 0 : 1
        } catch { exitCode = 1 }
        window.delegate = nil; window.orderOut(nil); window.close()
        NSApp.stop(nil)
    }
}

@main
private enum VisiblePresentationProbeMain {
    @MainActor static func main() {
        let environment = ProcessInfo.processInfo.environment
        let directory: String
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--run-visible" {
            directory = CommandLine.arguments[2]
        } else if CommandLine.arguments.count == 1,
                  environment["PERPENDICULAR_PRESENTATION_PROBE_RUN_VISIBLE"] == "1",
                  let requested = environment["PERPENDICULAR_PRESENTATION_PROBE_OUTPUT_DIR"] {
            directory = requested // Explicit private bundle LSEnvironment, no implicit launch.
        } else {
            FileHandle.standardError.write(Data("{\"status\":\"refused\",\"reason\":\"explicit_run_visible_and_private_directory_required\"}\n".utf8))
            exit(2)
        }
        guard directory.hasPrefix("/"), !directory.utf8.contains(0), directory.last != "/",
              environment["PERPENDICULAR_DISPLAY_TELEMETRY_DIR"] == directory else { exit(2) }
        do {
            let application = NSApplication.shared
            let probe = try VisiblePresentationProbe(directory: directory,
                configuration: PresentationProbeConfiguration(environment: environment))
            // Bundle launches have no shell watchdog. This terminates only this
            // dedicated process if its own main thread/GPU teardown stalls.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { _exit(124) }
            application.setActivationPolicy(.regular)
            probe.start()
            withExtendedLifetime(probe) { application.run() }
            exit(probe.exitCode)
        } catch {
            FileHandle.standardError.write(Data("{\"status\":\"failed\",\"reason\":\"probe_initialization_failed\"}\n".utf8))
            exit(1)
        }
    }
}
