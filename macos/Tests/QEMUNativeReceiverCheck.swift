import Foundation
import Darwin
import Metal

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The production receiver, lease queue and renderer, driven without a window.
/// Per-held-frame queues deliberately extend retirement so an independent
/// producer update can test the old source texture's immutability.
@MainActor
private final class QEMUNativeReceiver {
    struct Held {
        let queue: VMDisplayPresentationQueue
        let ticket: VMDisplayPresentationTicket
        let lease: VMExternalDisplayLease
    }
    let endpoint: NativeDisplayEndpoint
    let renderer: VMMetalRenderer
    var connection: NativeDisplayConnection?
    var incoming: [VMExternalDisplayLease] = []
    var held: [Int: Held] = [:]
    var failures: [String] = []
    var connected = false
    var connections = 0
    var totalPixels = 0
    var GPUReads = 0

    init(endpoint: NativeDisplayEndpoint) throws {
        self.endpoint = endpoint
        guard let renderer = VMMetalRenderer() else { throw CheckFailure("Metal renderer unavailable") }
        self.renderer = renderer
    }
    func require(_ value: Bool, _ message: String) throws {
        if !value { throw CheckFailure(message) }
    }
    func waitFor(_ condition: () -> Bool, timeout: Double = 10) async throws {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            try require(failures.isEmpty, failures.joined(separator: "; "))
            try require(ProcessInfo.processInfo.systemUptime < end, "native frame timeout")
            try await Task.sleep(for: .milliseconds(2))
        }
        try require(failures.isEmpty, failures.joined(separator: "; "))
    }
    func connect() async throws {
        try require(connection == nil, "already connected")
        connected = false
        connection = NativeDisplayConnection(endpoint: endpoint, device: renderer.device,
            onLease: { [self] lease in
                if !connected { failures.append("lease before connected notification") }
                incoming.append(lease)
                if incoming.count > 2 { failures.append("receiver exceeded producer lease budget") }
            }, onState: { [self] state in
                if state == .connected { connected = true }
            }, onFailure: { [self] in failures.append($0.reason) })
        connection!.start()
        try await waitFor { connected }
        connections += 1
    }
    func disconnect() {
        // Same reset-before-disconnect relationship used by the app. Held
        // tickets retain their real GPU-read lease until explicit completion.
        for value in held.values { value.queue.reset() }
        connection?.disconnect(); connection = nil; connected = false
        for lease in incoming { lease.discard() }
        incoming.removeAll()
    }
    func retire(_ value: Held) {
        value.queue.complete(value.ticket, failed: false)
        value.queue.reset()
    }
    func render(_ lease: VMExternalDisplayLease, width: Int, height: Int, color: String) async throws -> Bool {
        guard lease.texture.width == width, lease.texture.height == height else { return false }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        desc.storageMode = .shared; desc.usage = [.renderTarget, .shaderRead]
        guard let target = renderer.device.makeTexture(descriptor: desc),
              let command = renderer.queue.makeCommandBuffer() else { throw CheckFailure("GPU allocation") }
        try renderer.encode(texture: lease.texture, region: lease.region, verticallyFlipped: lease.verticallyFlipped,
                            into: target, commandBuffer: command)
        command.commit()
        try await waitFor { command.status == .completed || command.status == .error }
        try require(command.status == .completed, "consumer GPU completion")
        GPUReads += 1
        let expected: [UInt8]
        switch color {
        case "R": expected = [0, 0, 255, 255]
        case "G": expected = [0, 255, 0, 255]
        case "B": expected = [255, 0, 0, 255]
        case "M": expected = [255, 0, 255, 255]
        default: throw CheckFailure("unknown color")
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            if bytes[index] != expected[0] || bytes[index+1] != expected[1] ||
                bytes[index+2] != expected[2] || bytes[index+3] != expected[3] { return false }
        }
        return true
    }
    func command(_ line: String) async throws -> [String: Any] {
        let fields = line.split(separator: " ").map(String.init)
        guard let verb = fields.first else { throw CheckFailure("empty command") }
        switch verb {
        case "connect": try await connect()
        case "disconnect": disconnect()
        case "frame", "recheck":
            guard fields.count == 5, let slot = Int(fields[1]), (0..<3).contains(slot),
                let width = Int(fields[3]), let height = Int(fields[4]), width > 0, height > 0,
                width <= 4096, height <= 4096 else { throw CheckFailure("frame arguments") }
            let color = fields[2]
            if verb == "recheck" {
                guard let value = held[slot] else { throw CheckFailure("missing held frame") }
                let matched = try await render(value.lease, width: width, height: height, color: color)
                try require(matched, "held snapshot changed")
            } else {
                try require(held[slot] == nil, "occupied slot")
                var skipped = 0
                while true {
                    try await waitFor { !incoming.isEmpty }
                    let lease = incoming.removeFirst()
                    let queue = VMDisplayPresentationQueue()
                    try require(queue.present(lease), "production queue rejected lease")
                    guard let item = queue.next else { throw CheckFailure("production queue missing frame") }
                    let value = Held(queue: queue, ticket: queue.begin(item), lease: lease)
                    if try await render(lease, width: width, height: height, color: color) {
                        held[slot] = value; totalPixels += width * height
                        return ["ok": true, "skipped": skipped]
                    }
                    retire(value); skipped += 1
                    try require(skipped < 16, "expected updated pixels did not arrive")
                }
            }
            totalPixels += width * height
        case "ack", "drop":
            guard fields.count == 2, let slot = Int(fields[1]), let value = held.removeValue(forKey: slot) else {
                throw CheckFailure("retire arguments")
            }
            retire(value)
        case "quit":
            try require(held.isEmpty, "reader leases remain held")
            disconnect()
            try require(renderer.rfbUploadCount == 0 && failures.isEmpty, "fallback upload or receiver failure")
            return ["ok": true, "connections": connections, "exact_pixels": totalPixels,
                "active_frames": held.count + incoming.count, "GPU_reads": GPUReads, "RFB_uploads": renderer.rfbUploadCount,
                "production_Swift_receiver": true, "production_renderer": true, "visible_presentation": false]
        default: throw CheckFailure("unknown command")
        }
        return ["ok": true]
    }
}

@main
private enum QEMUNativeReceiverCheck {
    @MainActor static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count == 4, let pid = Int32(args[2]), args[3].count == 32,
                let hi = UInt64(args[3].prefix(16), radix: 16), let lo = UInt64(args[3].suffix(16), radix: 16) else {
                throw CheckFailure("arguments: socket PID session-hex")
            }
            let harness = try QEMUNativeReceiver(endpoint: .init(socketPath: args[1], serverPID: pid,
                expectedUID: geteuid(), sessionHi: hi, sessionLo: lo, epoch: 1))
            while let line = await Task.detached(operation: { readLine() }).value {
                let result = try await harness.command(line)
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
                if line == "quit" { return }
            }
            throw CheckFailure("unexpected control EOF")
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("QEMU Swift receiver: \(error)\n".utf8))
            exit(1)
        }
    }
}
