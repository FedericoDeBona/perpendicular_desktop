// Appended to production sources by run-display-sizing-tests.sh; no live VM.
import Combine

@MainActor
private func runDisplaySizingFixture() throws {
    precondition(CommandLine.arguments.count == 4)
    let scenario = CommandLine.arguments[1]
    let socket = CommandLine.arguments[2]
    let work = URL(fileURLWithPath: CommandLine.arguments[3])
    let files = FileManager.default
    func marker(_ name: String) -> URL { work.appendingPathComponent(name) }
    func mark(_ name: String) { precondition(files.createFile(atPath: marker(name).path, contents: Data(), attributes: [.posixPermissions: 0o600])) }
    func exists(_ name: String) -> Bool { files.fileExists(atPath: marker(name).path) }
    func commands() -> [[String: Any]] {
        let data = (try? String(contentsOf: marker("commands.ndjson"), encoding: .utf8)) ?? ""
        return data.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
    func resizeCalls() -> [[String: Any]] { commands().filter { $0["command"] as? String == "guest-display-resize" } }
    func wait(_ description: String, _ predicate: () -> Bool, timeout: Double = 8) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(predicate(), "Timed out: \(description)")
    }
    func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    _ = NSApplication.shared
    let controller = DisplaySizingController(acknowledgementTimeout: 0.45, confirmationTimeout: 1.6)
    let view = VMFramebufferView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    let window = NSWindow(contentRect: view.bounds, styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    let client = EngineClient()
    controller.configure(vmID: "fixture-vm", backendIdentity: "fixture-display", running: true, allowed: true, client: client)
    view.onDisplayEvent = { event in
        if case .viewport = event { return } // Fixtures specify physical pixels independently of the host screen.
        controller.receive(event, vmID: "fixture-vm")
    }
    let observer = controller.$request.sink { request in
        if let request { view.requestDesktopSize(request) }
    }
    defer {
        observer.cancel(); controller.stop(); view.configure(socketPath: socket, isActive: false)
        window.contentView = nil; window.close()
    }
    controller.receive(.viewport(points: scenario == "retina" ? CGSize(width: 640, height: 360) : CGSize(width: 1280, height: 720),
        backingScale: scenario == "retina" ? 2 : 1), vmID: "fixture-vm")
    view.configure(socketPath: socket, isActive: true)
    let target = GuestDisplayMode(width: 1280, height: 720)
    let original = GuestDisplayMode(width: 800, height: 600)
    if ["success", "announcement", "retina", "coalescing", "frame-timeout"].contains(scenario) {
        wait("guest confirmed while old framebuffer remains") { controller.phase == .waiting || controller.phase == .fitted(target) }
        precondition(controller.actualFramebuffer == original && controller.phase != .fitted(target),
                     "A forwarded/announced size or guest-only result was presented as applied")
        precondition(resizeCalls().count == 1)
        if scenario == "retina" {
            precondition((resizeCalls()[0]["arguments"] as! [String]).suffix(2) == ["--host-dpi", "192"],
                         "Retina viewport did not request physical pixels with a DPI hint")
        }
        if scenario == "frame-timeout" {
            wait("missing framebuffer timeout") { controller.phase == .failed }
            precondition(controller.actualFramebuffer == original && controller.request == nil)
        } else {
            if scenario == "coalescing" {
                let firstID = controller.request?.id
                for pixel in 0..<100 {
                    controller.receive(.viewport(points: CGSize(width: 1500 + pixel, height: 900), backingScale: 1), vmID: "fixture-vm")
                }
                controller.receive(.viewport(points: CGSize(width: 1600, height: 900), backingScale: 1), vmID: "fixture-vm")
                pump(0.15)
                precondition(controller.request?.id == firstID && resizeCalls().count == 1, "Resize requests overlapped instead of coalescing")
            }
            mark("allow-frame")
            if scenario == "coalescing" {
                wait("latest coalesced request") { controller.phase == .waiting && controller.request?.width == 1600 }
                precondition(controller.actualFramebuffer == target, "Second forwarded reply changed framebuffer dimensions")
                precondition(resizeCalls().count == 2)
                mark("allow-second-frame")
                wait("latest frame and guest confirmation") { controller.phase == .fitted(.init(width: 1600, height: 900)) }
                let records = resizeCalls()
                let elapsed = (records[1]["time"] as! Double) - (records[0]["time"] as! Double)
                precondition(elapsed >= 0.74, "Resize debounce/throttle interval was not respected: \(elapsed)")
            } else {
                wait("actual framebuffer confirmation") { controller.phase == .fitted(target) }
                precondition(controller.actualFramebuffer == target)
            }
        }
    } else if scenario == "stop" {
        wait("held guest CLI") { exists("resize-started") }
        controller.stop()
        view.configure(socketPath: socket, isActive: false)
        mark("release-cli")
        pump(0.4)
        precondition(controller.request == nil && controller.phase != .fitted(target), "A stale response after stop updated display state")
        precondition(resizeCalls().count == 1)
    } else if ["fixed-driver", "no-layout", "channel-unavailable"].contains(scenario) {
        wait("unsupported capability") { controller.phase == .unavailable }
        controller.receive(.viewport(points: CGSize(width: 1600, height: 900), backingScale: 1), vmID: "fixture-vm")
        pump(0.9)
        precondition(resizeCalls().isEmpty && controller.request == nil, "Unsupported backend was retried automatically")
        precondition(commands().filter { $0["command"] as? String == "guest-display-status" }.count == 1)
        if scenario == "fixed-driver" {
            controller.configure(vmID: "fixture-vm", backendIdentity: "replacement-backend", running: true, allowed: true, client: client)
            controller.receive(.connection(UUID()), vmID: "fixture-vm")
            wait("capability reset on replacement backend") {
                commands().filter { $0["command"] as? String == "guest-display-status" }.count == 2 && controller.phase == .unavailable
            }
            precondition(resizeCalls().isEmpty)
        }
    } else {
        wait("rejection or timeout") { controller.phase == .failed }
        precondition(controller.phase != .fitted(target) && controller.actualFramebuffer == original)
        controller.receive(.viewport(points: CGSize(width: 1600, height: 900), backingScale: 1), vmID: "fixture-vm")
        pump(0.9)
        let expected = ["false-success", "guest-unsupported"].contains(scenario) ? 1 : 0
        precondition(resizeCalls().count == expected && controller.request == nil, "A failed capability retried on viewport changes")
        if scenario == "ack-timeout" {
            controller.checkAgain()
            pump(0.9)
            precondition(controller.request == nil && resizeCalls().isEmpty,
                         "A timed-out acknowledgement was reused for another request")
        }
    }
    // Late events from another connection/VM are never observations of this one.
    controller.receive(.framebuffer(UUID(), width: 3333, height: 1111), vmID: "fixture-vm")
    controller.receive(.framebuffer(UUID(), width: 2222, height: 1111), vmID: "another-vm")
    precondition(controller.actualFramebuffer?.width != 3333 && controller.actualFramebuffer?.width != 2222)
    if scenario == "success" {
        let previous = commands().count
        var invalidRejected = false
        Task {
            do { _ = try await client.resizeGuestDisplay("fixture-vm", mode: .init(width: Int.max, height: Int.max), hostDpi: 192) }
            catch { invalidRejected = true }
        }
        wait("invalid geometry rejected before engine") { invalidRejected }
        precondition(commands().count == previous, "Invalid display geometry reached the engine")
    }
    print("display-sizing \(scenario): actual RFB + engine subprocess, honest confirmation, bounded requests PASS")
}

@main
private enum DisplaySizingHarness {
    @MainActor static func main() throws { try runDisplaySizingFixture() }
}
