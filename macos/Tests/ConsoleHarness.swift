
// Appended to VMConsole.swift by run-console-tests.sh, never compiled into the app.
private final class ConsoleTestState: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    let changed = DispatchSemaphore(value: 0)
    let clipboardReceived = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var frames: [RFBFrame] = []
    private var error: String?
    private var clipboard: String?

    func frame(_ frame: RFBFrame) {
        lock.lock(); frames.append(frame); lock.unlock()
        changed.signal()
    }
    func failed(_ message: String) {
        lock.lock(); error = message; lock.unlock()
        changed.signal()
    }
    func cut(_ text: String) {
        lock.lock(); clipboard = text; lock.unlock()
        clipboardReceived.signal()
    }
    func snapshot() -> (frames: [RFBFrame], error: String?, clipboard: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (frames, error, clipboard)
    }
}

@MainActor
private extension VMFramebufferView {
    var testFramebufferWidth: Int { Int(framebufferSize.width) }
    var testHeldInputCount: Int { pressedKeys.count + pressedModifiers.count + Int(pointerButtons) }
    func injectTestFrame() {
        present(RFBFrame(width: 2, height: 2, pixels: Data([
            0, 0, 255, 0, 0, 255, 0, 0,
            255, 0, 0, 0, 255, 255, 255, 0
        ])))
    }
}

@MainActor
private func waitForView(_ timeout: TimeInterval = 8, condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    precondition(condition(), "Console UI condition timed out")
}

private func runProtocolTest(socket: String) {
    let state = ConsoleTestState()
    let client = RFBConnection(socketPath: socket, onFrame: { state.frame($0) },
        onReady: { _ in state.ready.signal() }, onCutText: { state.cut($0) },
        onFailure: { state.failed($0) })
    client.start()
    precondition(state.ready.wait(timeout: .now() + 5) == .success, "Handshake timed out")
    client.sendKey(0xff0d, down: true)
    client.sendKey(0xff0d, down: false)
    client.sendPointer(x: 1, y: 1, buttons: 1)
    client.sendPointer(x: 1, y: 1, buttons: 0)
    client.sendCutText("hello")
    precondition(state.changed.wait(timeout: .now() + 5) == .success, "Raw frame timed out")
    precondition(state.changed.wait(timeout: .now() + 5) == .success, "Resize timed out")
    precondition(state.clipboardReceived.wait(timeout: .now() + 5) == .success, "Clipboard timed out")
    let result = state.snapshot()
    precondition(result.error == nil && result.frames.count == 2, "Unexpected framebuffer or error")
    precondition(result.frames[0].width == 2 && result.frames[0].height == 2)
    precondition(result.frames[0].pixels == Data([
        0, 0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0
    ]), "Raw RGB888 framebuffer mismatch")
    precondition(result.frames[1].width == 3 && result.frames[1].height == 1)
    precondition(result.frames[1].pixels == Data([
        0, 0, 0, 0, 7, 8, 9, 0, 0, 0, 0, 0
    ]), "DesktopSize and partial update mismatch")
    precondition(result.clipboard == "guest", "ServerCutText mismatch")
    client.stop()
    print("raw framebuffer, resize, keyboard, pointer and clipboard PASS")
}

private func runBadMessageTest(socket: String, expected: String) {
    let state = ConsoleTestState()
    let client = RFBConnection(socketPath: socket,
        onFrame: { _ in preconditionFailure("Malformed server published a frame") },
        onReady: { _ in state.ready.signal() }, onCutText: { _ in },
        onFailure: { state.failed($0) })
    client.start()
    if expected == "cancel" {
        precondition(state.ready.wait(timeout: .now() + 5) == .success)
        client.stop()
        precondition(state.changed.wait(timeout: .now() + 0.25) == .timedOut,
                     "User cancellation must suppress the reconnect callback")
        print("clean shutdown PASS")
    } else {
        precondition(state.changed.wait(timeout: .now() + 5) == .success, "Rejection timed out")
        precondition(state.snapshot().error?.contains(expected) == true, "Wrong protocol error")
        print("bounded \(expected) rejection PASS")
    }
    client.stop()
}

@MainActor
private func runDrawingTest() {
    _ = NSApplication.shared
    let view = VMFramebufferView(frame: CGRect(x: 0, y: 0, width: 240, height: 200))
    view.injectTestFrame()
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let samples: [(Int, Int, CGFloat, CGFloat, CGFloat)] = [
        (60, 50, 1, 0, 0), (160, 50, 0, 1, 0), (60, 150, 0, 0, 1),
        (160, 150, 1, 1, 1), (5, 50, 0, 0, 0)
    ]
    for (x, y, red, green, blue) in samples {
        let color = bitmap.colorAt(x: x * bitmap.pixelsWide / 240,
                                   y: y * bitmap.pixelsHigh / 200)!.usingColorSpace(.deviceRGB)!
        // Allow macOS display-profile/HDR conversion while detecting channel swaps,
        // vertical inversion, and drawing into the aspect-fit letterbox.
        precondition(abs(color.redComponent - red) < 0.2 &&
                     abs(color.greenComponent - green) < 0.2 &&
                     abs(color.blueComponent - blue) < 0.2, "Framebuffer drawing mismatch")
    }
    print("native drawing, colour channels, orientation and aspect fit PASS")
}

@MainActor
private func runReconnectTest(socket: String) {
    _ = NSApplication.shared
    let view = VMFramebufferView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
    view.configure(socketPath: socket, isActive: true)
    // The mock removes the first listener, waits through a failed retry, and
    // creates a new Unix listener at the same path with a different framebuffer.
    waitForView { view.testFramebufferWidth == 3 }
    view.configure(socketPath: socket, isActive: false)
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    print("Unix listener stop/start reconnect and inactive shutdown PASS")
}

@MainActor
private func runFocusTest(socket: String) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let view = VMFramebufferView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
    window.contentView = view
    view.configure(socketPath: socket, isActive: true)
    waitForView { view.testFramebufferWidth == 4 }
    precondition(window.makeFirstResponder(nil))
    precondition(window.firstResponder !== view)
    let control = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .control,
        timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 59)!
    let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
        timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "\u{1}", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
    let mouse = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 90, y: 150),
        modifierFlags: .control, timestamp: 0, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    view.mouseDown(with: mouse)
    precondition(window.firstResponder === view, "Click did not acquire keyboard focus")
    view.flagsChanged(with: control)
    view.keyDown(with: key)
    precondition(view.testHeldInputCount == 3, "Input state was not held")
    precondition(window.makeFirstResponder(nil), "Window refused to release focus")
    precondition(view.testHeldInputCount == 0, "Focus loss left keys or buttons held")
    // The mock acknowledges all three key/button releases by sending a resize.
    waitForView { view.testFramebufferWidth == 3 }
    view.configure(socketPath: socket, isActive: false)
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    print("focus release, Ctrl mapping, pointer coordinates and resize request PASS")
}

precondition(CommandLine.arguments.count >= 2, "Expected console test mode")
switch CommandLine.arguments[1] {
case "protocol": runProtocolTest(socket: CommandLine.arguments[2])
case "bad": runBadMessageTest(socket: CommandLine.arguments[2], expected: CommandLine.arguments[3])
case "drawing": runDrawingTest()
case "reconnect": runReconnectTest(socket: CommandLine.arguments[2])
case "focus": runFocusTest(socket: CommandLine.arguments[2])
default: preconditionFailure("Unknown console test mode")
}
