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
    func commandNames() -> [String] { commands().compactMap { $0["command"] as? String } }
    func wait(_ description: String, _ predicate: () -> Bool, timeout: Double = 8) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(predicate(), "Timed out: \(description)")
    }
    func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    _ = NSApplication.shared
    let lateAgent = scenario == "bootstrap-slow-ready"
    precondition(DisplaySizingController.defaultBootstrapWindow == 180 &&
        DisplaySizingController.defaultBootstrapDelays.count + 1 == 12 &&
        DisplaySizingController.defaultBootstrapDelays.reduce(0, +) < DisplaySizingController.defaultBootstrapWindow,
        "Startup admission lost its absolute deadline or observation bound")
    // Leave enough wall time for two real Python engine subprocesses to start.
    // Expiry is still tested while the second result is explicitly held,
    // rather than accidentally expiring before the fixture reaches that gate.
    let controller = DisplaySizingController(acknowledgementTimeout: 0.45, confirmationTimeout: 1.6,
        bootstrapDelays: lateAgent ? DisplaySizingController.defaultBootstrapDelays.map { $0 / 50 } :
            (scenario.hasPrefix("bootstrap-") ? [0.08, 0.08, 0.08, 0.08] : DisplaySizingController.defaultBootstrapDelays),
        bootstrapWindow: lateAgent ? DisplaySizingController.defaultBootstrapWindow / 50 :
            (scenario == "bootstrap-deadline" ? 2.0 : DisplaySizingController.defaultBootstrapWindow))
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
    if scenario.hasPrefix("bootstrap-") {
        let status = "guest-display-status"
        if ["bootstrap-ready", "bootstrap-exhausted", "bootstrap-slow-ready"].contains(scenario) {
            if scenario == "bootstrap-exhausted" {
                wait("bootstrap status budget exhausted") { controller.phase == .unavailable && commandNames().count == 5 }
                precondition(commandNames() == Array(repeating: status, count: 5) && controller.request == nil)
                for width in 1300..<1340 {
                    controller.receive(.viewport(points: CGSize(width: width, height: 800), backingScale: 1), vmID: "fixture-vm")
                }
                controller.configure(vmID: "fixture-vm", backendIdentity: "fixture-display", running: true, allowed: false, client: client)
                controller.configure(vmID: "fixture-vm", backendIdentity: "fixture-display", running: true, allowed: true, client: client)
                controller.enabled = false; controller.enabled = true
                pump(0.35)
                precondition(commandNames().count == 5 && controller.request == nil, "Viewport/tab/preference changes refilled the bootstrap budget")
                controller.receive(.viewport(points: CGSize(width: 1280, height: 720), backingScale: 1), vmID: "fixture-vm")
                mark("agent-ready")
                controller.checkAgain() // A deliberate user check still works after exhaustion.
            }
            wait("guest ready before normal resize confirmation") { controller.phase == .waiting }
            let expectedStatuses = lateAgent ? commands().filter { $0["command"] as? String == status }.count :
                (scenario == "bootstrap-ready" ? 3 : 6)
            if lateAgent {
                let observations = commands().filter { $0["command"] as? String == status }
                let elapsed = (observations.last!["time"] as! Double) - (observations.first!["time"] as! Double)
                precondition(expectedStatuses >= 2 && expectedStatuses <= 12 && elapsed >= 2.7,
                    "Slow-start fixture did not outlast the old startup budget")
            }
            precondition(commandNames() == Array(repeating: status, count: expectedStatuses) + ["guest-display-resize"], "Bootstrap mutated Windows before readiness or looped")
            precondition(controller.actualFramebuffer == original && controller.phase != .fitted(target))
            mark("allow-frame")
            wait("bootstrap success still requires received pixels") { controller.phase == .fitted(target) }
            if lateAgent {
                pump(0.35)
                precondition(commandNames() == Array(repeating: status, count: expectedStatuses) + ["guest-display-resize"],
                    "Successful startup kept polling or mutated Windows again")
            }
        } else if ["bootstrap-deadline", "bootstrap-hidden"].contains(scenario) {
            wait("held bootstrap status") { exists("bootstrap-held") }
            if scenario == "bootstrap-hidden" {
                controller.configure(vmID: "fixture-vm", backendIdentity: "fixture-display", running: true, allowed: false, client: client)
            } else {
                wait("absolute bootstrap expiry") { controller.phase == .unavailable }
            }
            mark("release-bootstrap")
            wait("late readiness result drained") { !controller.isWorking }
            pump(0.35)
            precondition(commandNames() == [status, status] && controller.request == nil && controller.phase != .fitted(target), "Expired/hidden bootstrap readiness mutated Windows")
        } else {
            if scenario == "bootstrap-cancelled" {
                wait("bootstrap retry scheduled") { commandNames() == [status] && controller.phase == .checking && !controller.isWorking }
                controller.stop(); view.configure(socketPath: socket, isActive: false)
            } else { wait("non-transient bootstrap failure") { controller.phase == .unavailable } }
            pump(0.35)
            precondition(commandNames() == [status] && controller.request == nil, "Cancelled or non-transient bootstrap status was polled again")
        }
    } else if scenario.hasPrefix("recover-") {
        let observed = ["guest-display-status", "guest-display-resize", "guest-display-status"]
        let retried = observed + ["guest-display-resize"]
        let successfulRetry = ["recover-retry", "recover-unavailable"].contains(scenario)
        if successfulRetry || scenario == "recover-applied" {
            wait("recovered measured guest while old framebuffer remains") { controller.phase == .waiting }
            precondition(commandNames() == (successfulRetry ? retried : observed), "Recovery was not one status before at most one mutation")
            precondition(controller.actualFramebuffer == original && controller.phase != .fitted(target), "Recovered guest-only result was shown as fitted")
            if successfulRetry {
                let calls = resizeCalls()
                let interval = (calls[1]["time"] as! Double) - (calls[0]["time"] as! Double)
                precondition(interval >= 0.74, "Recovery mutation bypassed the guest throttle: \(interval)")
            }
            mark("allow-frame")
            wait("recovered guest and received pixels") { controller.phase == .fitted(target) }
            precondition(controller.actualFramebuffer == target)
        } else if scenario == "recover-frame-first" {
            wait("held recovery status") { exists("status-held") }
            mark("allow-frame")
            wait("new framebuffer before authoritative status") { controller.actualFramebuffer == target }
            precondition(controller.phase != .fitted(target), "Framebuffer-only recovery was shown as fitted")
            mark("release-status")
            wait("authoritative measurement completed recovery") { controller.phase == .fitted(target) }
            precondition(commandNames() == observed, "An already-applied mode was mutated again")
        } else if scenario.hasPrefix("recover-queued-") {
            wait("held recovery status before queue blocker") { exists("status-held") }
            var blockerCompleted = false
            Task {
                do { let _: CommandResult = try await client.execute(["hold-queue"]); blockerCompleted = true }
                catch { preconditionFailure("Queue fixture failed: \(error)") }
            }
            pump(0.05) // Admit the blocker behind the still-held status command.
            mark("release-status")
            wait("shared engine queue occupied") { exists("queue-held") }
            wait("retry admitted by controller") { controller.phase == .adjusting }
            pump(0.8) // Pass the 750ms throttle while the subprocess queue stays held.
            if scenario == "recover-queued-deadline" {
                wait("queued retry retained original deadline", { controller.phase == .failed }, timeout: 1.1)
            } else if scenario == "recover-queued-hidden" {
                controller.configure(vmID: "fixture-vm", backendIdentity: "fixture-display", running: true, allowed: false, client: client)
            } else {
                controller.receive(.viewport(points: CGSize(width: 1600, height: 900), backingScale: 1), vmID: "fixture-vm")
                precondition(controller.phase == .failed)
            }
            mark("release-queue")
            wait("queued mutation rejected before subprocess execution") { blockerCompleted && !controller.isWorking }
            precondition(commandNames() == observed + ["hold-queue"], "Expired or revoked queued mutation reached the guest subprocess")
            precondition(controller.request == nil && controller.phase != .fitted(target))
            controller.receive(.viewport(points: CGSize(width: 1600, height: 900), backingScale: 1), vmID: "fixture-vm")
            pump(0.85)
            precondition(commandNames() == observed + ["hold-queue"], "Revoked queued retry restarted automatically")
        } else if ["recover-stop", "recover-disable", "recover-hidden", "recover-reconnect"].contains(scenario) {
            wait("held recovery status before invalidation") { exists("status-held") }
            if scenario == "recover-stop" {
                controller.stop(); view.configure(socketPath: socket, isActive: false)
            } else if scenario == "recover-disable" {
                controller.enabled = false
            } else if scenario == "recover-hidden" {
                controller.configure(vmID: "fixture-vm", backendIdentity: "fixture-display", running: true, allowed: false, client: client)
            } else {
                view.configure(socketPath: socket, isActive: false)
                view.configure(socketPath: socket, isActive: true)
                wait("new real RFB connection") { exists("rfb-reconnected") }
            }
            mark("release-status")
            wait("stale status process drained") { !controller.isWorking }
            pump(0.85)
            precondition(controller.request == nil && controller.phase != .fitted(target), "A stale status completed or retried an invalidated resize")
            let expected = scenario == "recover-reconnect" ? observed + ["guest-display-status"] : observed
            precondition(commandNames() == expected && resizeCalls().count == 1, "Invalidated recovery sent another mutation")
            if scenario == "recover-disable" { precondition(controller.phase == .off) }
            if scenario == "recover-reconnect" { precondition(controller.phase == .unavailable && controller.actualFramebuffer == original) }
        } else {
            if scenario == "recover-target-changed" {
                wait("held status before target change") { exists("status-held") }
                controller.receive(.viewport(points: CGSize(width: 1600, height: 900), backingScale: 1), vmID: "fixture-vm")
                mark("release-status")
            } else if scenario == "recover-deadline" {
                wait("held status spanning original deadline") { exists("status-held") }
                wait("original confirmation deadline, not a new recovery deadline", { controller.phase == .failed }, timeout: 1.35)
                mark("release-status")
                wait("expired status drained") { !controller.isWorking }
            } else if scenario == "recover-retry-deadline" {
                wait("held second mutation") { exists("retry-held") }
                wait("retry did not extend original confirmation deadline", { controller.phase == .failed }, timeout: 1.15)
                mark("release-retry")
                wait("expired mutation drained") { !controller.isWorking }
                mark("allow-frame")
                wait("late pixels after expired guest response") { controller.actualFramebuffer == target }
                precondition(controller.phase == .failed, "Late guest+framebuffer results escaped the original deadline")
            }
            wait("bounded recovery failure") { controller.phase == .failed }
            let withoutRecovery = ["recover-protocol-error", "recover-ownership-error", "recover-message-only"].contains(scenario)
            let expected = withoutRecovery ? Array(observed.prefix(2)) :
                (["recover-second-timeout", "recover-retry-deadline"].contains(scenario) ? retried : observed)
            precondition(commandNames() == expected && controller.request == nil, "Recovery exceeded its query/mutation budget")
            controller.receive(.viewport(points: CGSize(width: 1600, height: 900), backingScale: 1), vmID: "fixture-vm")
            pump(0.9)
            precondition(commandNames() == expected && controller.phase == .failed, "Failed recovery looped on viewport changes")
        }
    } else if ["success", "announcement", "retina", "coalescing", "frame-timeout"].contains(scenario) {
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
