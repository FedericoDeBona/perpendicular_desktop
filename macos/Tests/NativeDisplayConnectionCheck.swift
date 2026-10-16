import Foundation
import Darwin
import Metal

@MainActor
private final class Producer {
    let directory: URL
    let process = Process()
    let input = Pipe()
    private let output: FileHandle
    init(binary: String, mode: String?) throws {
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("pnr-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let log = directory.appendingPathComponent("producer.log")
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        output = try FileHandle(forWritingTo: log)
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = mode.map { [$0, directory.path] } ?? ["--serve", directory.path]
        process.standardInput = input; process.standardOutput = output; process.standardError = output
        try process.run()
    }
    var endpoint: NativeDisplayEndpoint {
        .init(socketPath: directory.appendingPathComponent("display.sock").path, serverPID: process.processIdentifier,
              expectedUID: geteuid(), sessionHi: 11, sessionLo: 22, epoch: 1)
    }
    var acknowledgements: Int {
        (try? String(contentsOf: directory.appendingPathComponent("acks"), encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
    }
    func end() { try? input.fileHandleForWriting.write(contentsOf: Data("E".utf8)) }
    func cleanup() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? output.close(); try? input.fileHandleForWriting.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private func waitFor(_ condition: () -> Bool, seconds: Double = 5) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while !condition() {
        precondition(ProcessInfo.processInfo.systemUptime < deadline, "Native receiver fixture timed out")
        try await Task.sleep(for: .milliseconds(3))
    }
}

@MainActor
private func target(_ device: any MTLDevice, width: Int, height: Int) -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
    return device.makeTexture(descriptor: descriptor)!
}

@MainActor
private func submit(_ state: VMDisplayPresentationQueue, _ renderer: VMMetalRenderer, target: any MTLTexture,
                    gate: (any MTLSharedEvent)? = nil) throws -> any MTLCommandBuffer {
    let item = state.next!
    guard case .external(let lease) = item.content else { fatalError("Receiver did not supply an external texture") }
    let command = renderer.queue.makeCommandBuffer()!
    if let gate { command.encodeWaitForEvent(gate, value: 1) }
    try renderer.encode(texture: lease.texture, into: target, commandBuffer: command)
    let ticket = state.begin(item)
    command.addCompletedHandler { command in
        let failed = command.status == .error
        Task { @MainActor in state.complete(ticket, failed: failed) }
    }
    command.commit(); return command
}

private func checkPixels(_ texture: any MTLTexture) -> Int {
    let width = texture.width, height = texture.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    for y in 0..<height { for x in 0..<width {
        let expected: [UInt8] = y < height / 2 ? [0, 0, 255, 255] : [255, 0, 0, 255]
        precondition(Array(bytes[((y * width + x) * 4)..<((y * width + x + 1) * 4)]) == expected,
                     "Actual receiver→Metal GPU pixel mismatch")
    } }
    return width * height
}

@main
private enum NativeDisplayConnectionCheck {
    @MainActor static func main() async throws {
        signal(SIGPIPE, SIG_IGN) // Only the fixture's stdin control pipes.
        precondition(CommandLine.arguments.count >= 3)
        let regularBinary = CommandLine.arguments[1], controlledBinary = CommandLine.arguments[2]
        guard let renderer = VMMetalRenderer() else { fatalError("Metal unavailable") }
        var pixels = 0, checks = 0
        func stage(_ name: String) { FileHandle.standardError.write(Data(("receiver-check: " + name + "\n").utf8)) }

        // Reuse the NDT owner's real two-process producer: two unique CPU-filled
        // memory FDs, actual ready pipes, exact peer PID/session and exact ACKs.
        stage("two-process GPU import and ACK")
        let regular = try Producer(binary: regularBinary, mode: nil)
        defer { regular.cleanup() }
        try await waitFor { FileManager.default.fileExists(atPath: regular.endpoint.socketPath) }
        let state = VMDisplayPresentationQueue()
        var delivered = 0, failures: [NativeDisplayFailure] = []
        var connectionStates: [NativeDisplayConnectionState] = []
        let connection = NativeDisplayConnection(endpoint: regular.endpoint, device: renderer.device,
            onLease: { precondition(connectionStates.last == .connected); delivered += 1; state.present($0) },
            onState: { connectionStates.append($0); if $0 == .disconnected { state.reset() } },
            onFailure: { failures.append($0); state.reset() })
        connection.start()
        try await waitFor { state.next != nil }
        let size = state.next!.size, image = target(renderer.device, width: Int(size.width), height: Int(size.height))
        let gate = renderer.device.makeSharedEvent()!
        let command = try submit(state, renderer, target: image, gate: gate)
        try await Task.sleep(for: .milliseconds(75))
        precondition(regular.process.isRunning && command.status != .completed && failures.isEmpty,
                     "Producer received ACK before actual GPU completion")
        checks += 1
        gate.signaledValue = 1
        try await waitFor { state.completedFrames > 0 }
        pixels += checkPixels(image); checks += 1
        if state.hasPending {
            let next = state.next!.size, changed = target(renderer.device, width: Int(next.width), height: Int(next.height))
            _ = try submit(state, renderer, target: changed)
            let completed = state.completedFrames
            try await waitFor { state.completedFrames > completed }
            pixels += checkPixels(changed); checks += 1
        }
        state.reset()
        try await waitFor { !regular.process.isRunning }
        precondition(regular.process.terminationStatus == 0 && delivered <= 2 && delivered > 0, "Two-slot producer/receiver failed")
        precondition(connectionStates.filter { $0 == .connected }.count == 1, "Connected notification duplicated or absent")
        connection.disconnect(); checks += 1

        for mode in ["withheld", "token-eof", "alignment"] {
            stage(mode)
            let producer = try Producer(binary: controlledBinary, mode: mode)
            try await waitFor { FileManager.default.fileExists(atPath: producer.endpoint.socketPath) }
            var received = 0, errors: [NativeDisplayFailure] = [], statuses: [NativeDisplayConnectionState] = []
            let receiver = NativeDisplayConnection(endpoint: producer.endpoint, device: renderer.device,
                onLease: { received += 1; $0.discard() }, onState: { statuses.append($0) }, onFailure: { errors.append($0) })
            receiver.start()
            try await waitFor { !errors.isEmpty }
            precondition(received == 0 && errors.count == 1 && statuses.last == .disconnected && producer.acknowledgements == 0,
                         "Unready/EOF/unaligned frame reached Metal or received ACK")
            if mode == "withheld" { precondition(errors[0].reason.contains("in time")) }
            if mode == "alignment" { precondition(errors[0].code == NDT_ERR_BOUNDS) }
            receiver.disconnect(); producer.end()
            try await waitFor { !producer.process.isRunning }
            precondition(producer.process.terminationStatus == 0)
            producer.cleanup(); checks += 1
        }

        // EOF while an actual GPU read is withheld: parent reset occurs, but
        // the old frame FD/mapping remains usable until the GPU drains.
        stage("EOF during GPU read")
        let oldProducer = try Producer(binary: controlledBinary, mode: "controlled")
        defer { oldProducer.cleanup() }
        try await waitFor { FileManager.default.fileExists(atPath: oldProducer.endpoint.socketPath) }
        let oldState = VMDisplayPresentationQueue()
        var oldErrors: [NativeDisplayFailure] = []
        let oldConnection = NativeDisplayConnection(endpoint: oldProducer.endpoint, device: renderer.device,
            onLease: { oldState.present($0) }, onState: { if $0 == .disconnected { oldState.reset() } },
            onFailure: { oldErrors.append($0); oldState.reset() })
        oldConnection.start(); try await waitFor { oldState.next != nil }
        let oldImage = target(renderer.device, width: 64, height: 32), oldGate = renderer.device.makeSharedEvent()!
        let oldCommand = try submit(oldState, renderer, target: oldImage, gate: oldGate)
        oldProducer.end()
        try await waitFor { !oldErrors.isEmpty && !oldProducer.process.isRunning }
        precondition(oldCommand.status != .completed && oldProducer.acknowledgements == 0, "EOF acknowledged or drained the GPU early")
        checks += 1

        // A separate new connection deliberately uses the same frame/session
        // values. Retiring the old GPU lease must never ACK this new producer.
        stage("stale connection ACK isolation")
        let fresh = try Producer(binary: controlledBinary, mode: "controlled")
        defer { fresh.cleanup() }
        try await waitFor { FileManager.default.fileExists(atPath: fresh.endpoint.socketPath) }
        let freshState = VMDisplayPresentationQueue()
        var freshErrors: [NativeDisplayFailure] = []
        let freshConnection = NativeDisplayConnection(endpoint: fresh.endpoint, device: renderer.device,
            onLease: { freshState.present($0) }, onState: { if $0 == .disconnected { freshState.reset() } },
            onFailure: { freshErrors.append($0); freshState.reset() })
        freshConnection.start(); try await waitFor { freshState.next != nil }
        oldGate.signaledValue = 1
        try await waitFor { oldCommand.status == .completed }
        try await Task.sleep(for: .milliseconds(30))
        pixels += checkPixels(oldImage)
        precondition(fresh.acknowledgements == 0 && freshErrors.isEmpty && freshState.next != nil,
                     "Old frame retirement acknowledged/mutated the new connection")
        checks += 1
        let freshImage = target(renderer.device, width: 64, height: 32)
        _ = try submit(freshState, renderer, target: freshImage)
        try await waitFor { freshState.completedFrames == 1 }
        pixels += checkPixels(freshImage)
        freshState.reset()
        try await waitFor { fresh.acknowledgements == 1 }
        freshConnection.disconnect(); fresh.end(); oldConnection.disconnect()
        try await waitFor { !fresh.process.isRunning }
        precondition(renderer.rfbUploadCount == 0, "Native receiver used Data/replace uploads")
        checks += 1

        // Exact PID rejection is performed by the actual C connection, not a
        // mocked endpoint comparison inside Swift.
        stage("exact renderer PID rejection")
        let peer = try Producer(binary: controlledBinary, mode: "controlled")
        defer { peer.cleanup() }
        try await waitFor { FileManager.default.fileExists(atPath: peer.endpoint.socketPath) }
        let wrong = NativeDisplayEndpoint(socketPath: peer.endpoint.socketPath, serverPID: peer.process.processIdentifier + 1,
            expectedUID: geteuid(), sessionHi: 11, sessionLo: 22, epoch: 1)
        var peerErrors: [NativeDisplayFailure] = [], peerFrames = 0
        let peerConnection = NativeDisplayConnection(endpoint: wrong, device: renderer.device,
            onLease: { peerFrames += 1; $0.discard() }, onState: { _ in }, onFailure: { peerErrors.append($0) })
        peerConnection.start(); try await waitFor { !peerErrors.isEmpty }
        precondition(peerFrames == 0 && peerErrors[0].code == NDT_ERR_PEER, "Incorrect renderer PID accepted")
        peerConnection.disconnect(); checks += 1

        let report: [String: Any] = ["result": "pass", "checks": checks, "device": renderer.device.name,
            "actual_GPU_pixels_verified": pixels, "zero_RFB_uploads": true,
            "verified": ["actual two-process FD transport", "exact renderer PID", "BGRA bytesNoCopy import", "GPU-before-ACK",
                         "ready timeout", "ready EOF", "Metal row alignment rejection", "EOF while GPU held", "stale connection ACK isolation"],
            "scope": "Owned CPU-filled C producers and real offscreen Metal consumer; no window, VM, Windows, producer-GPU ordering or frame-rate claim."]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 3 { try json.write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic) }
        print(String(decoding: json, as: UTF8.self))
    }
}
