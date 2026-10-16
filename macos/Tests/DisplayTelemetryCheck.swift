import AppKit
import Metal
import Darwin

@MainActor
private func waitTelemetry(_ ready: () -> Bool) async throws {
    let until = CACurrentMediaTime() + 5
    while !ready() {
        precondition(CACurrentMediaTime() < until, "Telemetry GPU fixture timed out")
        try await Task.sleep(for: .milliseconds(2))
    }
}

@MainActor
private func telemetryTexture(_ renderer: VMMetalRenderer) -> any MTLTexture {
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 32, mipmapped: false)
    desc.usage = [.shaderRead, .renderTarget]; desc.storageMode = .shared
    return renderer.device.makeTexture(descriptor: desc)!
}

@MainActor
private func checkViewHooks() async throws {
    _ = NSApplication.shared
    let view = VMMetalDisplayView.make()!, renderer = VMMetalRenderer()!
    let image = telemetryTexture(renderer)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view; view.frame = window.contentView!.bounds
    // Never ordered on screen. Exercise actual production submission callbacks,
    // without asserting a hidden drawable was visible on the physical display.
    for _ in 0..<100 { view.present(VMExternalDisplayLease(texture: image) { _ in }) }
    view.draw(in: view)
    try await waitTelemetry { view.completedFrames >= 1 }
    let before = view.completedFrames
    view.draw(in: view)
    try await waitTelemetry { view.completedFrames > before }
    view.reset(); view.stop(); window.contentView = nil; window.close()
    let recorder = VMDisplayTelemetry.shared!
    recorder.checkpoint()
    let report = recorder.snapshot()
    precondition(report.counters["presenter_accepted"] == 100 && report.counters["presenter_pending_replaced"] == 99)
    precondition((report.counters["gpu_completed"] ?? 0) >= 2 && report.counters["redraws_submitted"] == 1)
    precondition(report.counters["streams_stopped"] == 1 && report.metrics["gpu_execution"] != nil)
    print("hidden native-view telemetry hooks PASS (no on-screen latency claim)")
}

@main
private enum DisplayTelemetryCheck {
    @MainActor static func main() async throws {
        if CommandLine.arguments.dropFirst().contains("--view-hooks") { try await checkViewHooks(); return }
        precondition(VMDisplayTelemetry.shared == nil, "Default telemetry unexpectedly enabled")
        let files = FileManager.default
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("pnt-" + UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: root) }
        var checks = 1
        let insecure = root.appendingPathComponent("insecure")
        try files.createDirectory(at: insecure, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let linked = root.appendingPathComponent("linked")
        try files.createSymbolicLink(atPath: linked.path, withDestinationPath: root.path)
        for invalid in [insecure.path, linked.path, linked.path + "/", "relative-path", root.path + "\0ignored"] {
            do { _ = try VMDisplayTelemetry(directory: invalid); preconditionFailure("Non-private telemetry directory accepted") }
            catch { checks += 1 }
        }
        let recorder = try VMDisplayTelemetry(directory: root.path)
        let stream = recorder.beginStream()
        guard let renderer = VMMetalRenderer() else { fatalError("Real Metal unavailable") }
        let source = telemetryTexture(renderer), target = telemetryTexture(renderer)
        let frame = VMDisplayFrame(width: 64, height: 32, pixels: Data(repeating: 127, count: 64 * 32 * 4))
        let gate = renderer.device.makeSharedEvent()!
        let began = CACurrentMediaTime()
        let timing = VMNativeDisplayTiming(received: began, ready: began, delivered: began)
        recorder.delivered(timing)
        let held = recorder.submission(stream: stream, generation: 0, timing: timing, firstDraw: true)
        let command = renderer.queue.makeCommandBuffer()!
        command.encodeWaitForEvent(gate, value: 1)
        try renderer.encode(frame, into: target, commandBuffer: command)
        command.addCompletedHandler { command in
            let callback = CACurrentMediaTime()
            held.gpuCompleted(start: command.gpuStartTime, end: command.gpuEndTime, failed: command.status == .error, callback: callback)
            Task { @MainActor in held.mainCallback(after: callback) }
        }
        held.commit(); command.commit()
        try await Task.sleep(for: .milliseconds(30))
        precondition(recorder.snapshot().counters["gpu_completed"] == nil && recorder.snapshot().counters["drawable_presented"] == nil,
                     "GPU submission/elapsed time was falsely counted as completion/presentation")
        gate.signaledValue = 1
        try await waitTelemetry { recorder.snapshot().counters["gpu_completed"] == 1 }
        precondition(command.status == .completed && recorder.snapshot().metrics["gpu_execution"] != nil)
        precondition(recorder.snapshot().counters["drawable_presented"] == nil && recorder.snapshot().metrics["receive_to_presented"] == nil,
                     "GPU completion falsely implied drawable presentation")
        checks += 3
        for _ in 0..<32 {
            let observation = recorder.submission(stream: stream, generation: 0, timing: nil, firstDraw: false)
            let sample = renderer.queue.makeCommandBuffer()!
            try renderer.encode(texture: source, into: target, commandBuffer: sample)
            sample.addCompletedHandler { sample in
                observation.gpuCompleted(start: sample.gpuStartTime, end: sample.gpuEndTime, failed: sample.status == .error)
            }
            observation.commit(); sample.commit()
            try await waitTelemetry { sample.status == .completed }
        }
        try await waitTelemetry { recorder.snapshot().counters["gpu_completed"] == 33 }
        recorder.checkpoint()
        let realReport = recorder.snapshot()
        precondition(realReport.metrics["gpu_execution"]?.recentSamples == 33 && realReport.counters["drawable_presented"] == nil)
        checks += 1

        // Controlled compositor timestamps are synthetic, separate from real
        // Metal evidence. They causally distinguish completion, presentation,
        // skipped/duplicate callbacks and reset/out-of-order history.
        let synthetic = try VMDisplayTelemetry(directory: root.path)
        let s = synthetic.beginStream(), base = CACurrentMediaTime()
        let a = synthetic.submission(stream: s, generation: 0, timing: nil, firstDraw: true)
        a.commit(at: base); a.gpuCompleted(start: base, end: base + 0.001, failed: false, callback: base + 0.002)
        precondition(synthetic.snapshot().metrics["commit_to_presented"] == nil)
        synthetic.reset(stream: s, generation: 1)
        let first = synthetic.submission(stream: s, generation: 1,
            timing: .init(received: base, ready: base + 0.001, delivered: base + 0.002), firstDraw: true)
        first.commit(at: base + 0.010)
        first.gpuCompleted(start: base + 0.010, end: base + 0.011, failed: false, callback: base + 0.012)
        first.drawablePresented(at: base + 0.050, callback: base + 0.060)
        let measured = synthetic.snapshot()
        precondition(abs(measured.metrics["commit_to_presented"]!.medianMs - 40) < 0.01 &&
                     abs(measured.metrics["gpu_execution"]!.medianMs - 1) < 0.01,
                     "Actual presented timestamp replaced with GPU completion/callback time")
        a.drawablePresented(at: base + 10, callback: base + 11) // stale; must not move active pacing history
        let redraw = synthetic.submission(stream: s, generation: 1, timing: timing, firstDraw: false)
        redraw.commit(at: base + 0.051); redraw.drawablePresented(at: base + 0.066, callback: base + 0.070)
        redraw.drawablePresented(at: base + 100); redraw.commit(at: base + 100)
        precondition(abs(synthetic.snapshot().metrics["drawable_interval"]!.medianMs - 16) < 0.01)
        precondition(synthetic.snapshot().metrics["receive_to_presented"]!.totalSamples == 1,
                     "Redraw counted as a freshly received frame")
        let skipped = synthetic.submission(stream: s, generation: 1, timing: nil, firstDraw: false)
        skipped.commit(at: base + 0.067); skipped.drawablePresented(at: 0)
        precondition(synthetic.snapshot().counters["drawable_skipped"] == 1 && synthetic.snapshot().counters["drawable_presented"] == 3)
        checks += 6

        for index in 0..<2048 {
            let item = synthetic.submission(stream: s, generation: 1, timing: nil, firstDraw: false)
            let timestamp = base + 12 + Double(index) / 60
            item.commit(at: timestamp)
            item.gpuCompleted(start: timestamp, end: timestamp + 0.001, failed: false, callback: timestamp + 0.002)
            item.drawablePresented(at: timestamp + 0.010)
        }
        synthetic.checkpoint()
        let bounded = synthetic.snapshot()
        let data = try Data(contentsOf: URL(fileURLWithPath: synthetic.outputPath))
        _ = try JSONSerialization.jsonObject(with: data)
        let attrs = try files.attributesOfItem(atPath: synthetic.outputPath)
        precondition(bounded.events.count == VMDisplayTelemetry.recordLimit && bounded.metrics.values.allSatisfy { $0.recentSamples <= VMDisplayTelemetry.metricLimit })
        precondition(data.count <= VMDisplayTelemetry.byteLimit && (attrs[.posixPermissions] as! NSNumber).intValue == 0o600)
        precondition(bounded.metrics["gpu_execution"]!.totalSamples == 2050 && bounded.metrics["gpu_execution"]!.recentSamples == 256)
        synthetic.endStream(s)
        let ended = synthetic.submission(stream: s, generation: 1, timing: nil, firstDraw: false)
        ended.commit(at: base + 100); ended.drawablePresented(at: base + 101)
        precondition(synthetic.snapshot().metrics["drawable_interval"]!.totalSamples == bounded.metrics["drawable_interval"]!.totalSamples)
        checks += 4

        let viewDirectory = root.appendingPathComponent("view")
        try files.createDirectory(at: viewDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let child = Process(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); child.arguments = ["--view-hooks"]
        var env = ProcessInfo.processInfo.environment
        env["PERPENDICULAR_DISPLAY_TELEMETRY_DIR"] = viewDirectory.path
        env.removeValue(forKey: "PERPENDICULAR_DISPLAY_RENDERER")
        child.environment = env; child.standardOutput = output; child.standardError = output
        try child.run(); child.waitUntilExit()
        let childLog = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        precondition(child.terminationStatus == 0, "Actual view telemetry hooks failed: \(childLog)")
        checks += 1
        let report: [String: Any] = ["result": "pass", "checks": checks, "device": renderer.device.name,
            "real_offscreen_gpu": try JSONSerialization.jsonObject(with: JSONEncoder().encode(realReport)),
            "controlled_timestamp_checks": "Synthetic compositor callbacks validate 40ms presentation vs 1ms GPU, stale generation, skipped frame, duplicate, redraw, bounded storage.",
            "bounded_report_bytes": data.count, "production_hidden_view": childLog.trimmingCharacters(in: .whitespacesAndNewlines),
            "scope": "Owned fixtures only; no VM, Windows, input latency or visible compositor pacing measured."]
        let result = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 1 {
            precondition(files.createFile(atPath: CommandLine.arguments[1], contents: result, attributes: [.posixPermissions: 0o600]))
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["result": "pass", "checks": checks,
            "real_gpu_samples": realReport.metrics["gpu_execution"]!.recentSamples,
            "gpu_median_ms": realReport.metrics["gpu_execution"]!.medianMs,
            "gpu_p95_ms": realReport.metrics["gpu_execution"]!.p95Ms,
            "offscreen_drawable_presented": realReport.counters["drawable_presented"] ?? 0,
            "bounded_report_bytes": data.count, "hidden_view_hooks": "pass"], options: [.sortedKeys]), as: UTF8.self))
    }
}
