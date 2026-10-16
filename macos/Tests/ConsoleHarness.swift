
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

private extension RFBConnection {
    func holdTestWriter(started: DispatchSemaphore, release: DispatchSemaphore) {
        writer.async { started.signal(); release.wait() }
    }
    func signalTestWriterDrained(_ signal: DispatchSemaphore) {
        writer.async { signal.signal() }
    }
    var testInputReservations: (messages: Int, bytes: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (queuedInputMessages, queuedInputBytes)
    }
}

@MainActor
private extension VMFramebufferView {
    var testFramebufferWidth: Int { Int(framebufferSize.width) }
    var testHasLocalCursor: Bool { localCursor != nil }
    var testHeldInputCount: Int { pressedKeys.count + pressedModifiers.count + Int(pointerButtons) }
    var testUsesMetal: Bool { metalDisplay != nil }
    var testHasFallbackFrame: Bool { framebuffer != nil }
    func injectPresenterFailure() { metalDisplay?.onFailure?() }
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

private final class CursorTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var shapes: [RFBCursor] = []
    let received = DispatchSemaphore(value: 0)
    func offer(_ cursor: RFBCursor) {
        lock.lock(); shapes.append(cursor); lock.unlock(); received.signal()
    }
    func snapshot() -> [RFBCursor] { lock.lock(); defer { lock.unlock() }; return shapes }
}

private func runCursorProtocolTest(socket: String) {
    let state = ConsoleTestState(), cursors = CursorTestState()
    let client = RFBConnection(socketPath: socket, onFrame: { state.frame($0) },
        onReady: { _ in state.ready.signal() }, onCutText: { state.cut($0) },
        onCursor: { cursors.offer($0) }, onFailure: { state.failed($0) })
    client.start()
    precondition(cursors.received.wait(timeout: .now() + 5) == .success)
    // Peer withholds all pixels until we confirm the dedicated cursor callback.
    precondition(state.snapshot().frames.isEmpty, "Cursor shape submitted a framebuffer")
    let shape = cursors.snapshot()[0]
    precondition(shape.width == 3 && shape.height == 2 && shape.hotspotX == 2 && shape.hotspotY == 1)
    precondition(shape.pixelsBGRA == Data([1,2,3,255, 0,0,0,0, 9,10,11,255,
        0,0,0,0, 17,18,19,255, 0,0,0,0]), "Fragmented cursor mask/color mismatch")
    client.sendCutText("shape received")
    precondition(state.changed.wait(timeout: .now() + 5) == .success)
    precondition(cursors.received.wait(timeout: .now() + 5) == .success)
    precondition(state.clipboardReceived.wait(timeout: .now() + 5) == .success)
    let frames = state.snapshot().frames
    precondition(frames.count == 1 && frames[0].width == 2 && frames[0].height == 2,
        "Cursor hotspot/shape modified framebuffer geometry")
    precondition(cursors.snapshot().count == 2 && cursors.snapshot()[1].isHidden)
    precondition(state.snapshot().error == nil)
    client.stop()
    print("dedicated cursor updates, oversized-to-frame shape, hotspot, alpha, hide and raw stream alignment PASS")
}

@MainActor
private final class CursorFixtureWindow: NSWindow {
    var fixtureKey = false
    override var isKeyWindow: Bool { fixtureKey }
}

@MainActor
private extension VMFramebufferView {
static func runCursorViewTest() {
    _ = NSApplication.shared
    let raw = Data([0, 0, 255, 0, 0, 255, 0, 0, 0xc0])
    let shape = try! RFBCursor.decode(width: 2, height: 1, hotspotX: 1, hotspotY: 0, payload: raw)
    let window = CursorFixtureWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 200),
        styleMask: [.titled], backing: .buffered, defer: false)
    let view = VMFramebufferView(frame: window.contentView!.bounds)
    window.contentView!.addSubview(view)
    view.active = true; view.connectionID = UUID(); view.framebufferSize = CGSize(width: 2, height: 2)
    view.status = ""; view.localCursor = shape
    // Constructing a native shape must not depend on a GPU or guest.
    let p = RFBCursorPresentation.make(shape, framebufferSize: view.framebufferSize, viewBounds: view.bounds)!
    precondition(p.rect == CGRect(x: 20, y: 0, width: 200, height: 200))
    precondition(p.cursor.image.size == CGSize(width: 200, height: 100) && p.cursor.hotSpot == CGPoint(x: 100, y: 0))
    let image = p.cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    precondition(image.width == 2 && image.height == 1, "Cursor backing pixels were resampled to view points")
    precondition(view.localCursorPresentation == nil, "Inactive window installed a guest cursor")
    window.fixtureKey = true
    precondition(view.localCursorPresentation != nil, "Key console has no local cursor")
    view.status = "Reconnecting…"
    precondition(view.localCursorPresentation == nil, "Disconnected display kept a guest cursor")
    view.status = ""; view.connectionID = nil
    precondition(view.localCursorPresentation == nil, "Disconnected RFB kept a guest cursor")
    view.connectionID = UUID(); view.localCursor = try! RFBCursor.decode(width: 0, height: 0, hotspotX: 0, hotspotY: 0, payload: Data())
    let hiddenPresentation = view.localCursorPresentation!
    let hiddenImage = hiddenPresentation.cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    precondition(hiddenImage.width == 1 && hiddenImage.height == 1)
    precondition((hiddenImage.dataProvider!.data! as Data).allSatisfy { $0 == 0 }, "Hidden cursor backing is opaque")
    window.fixtureKey = false
    precondition(view.localCursorPresentation == nil, "Focus loss retained a guest cursor rect")
    window.fixtureKey = true
    view.disconnect()
    precondition(view.localCursor == nil && view.localCursorPresentation == nil)
    window.contentView = nil
    // A stalled main loop holds one newest shape and one delivery task.
    var delivered: [RFBCursor] = []
    let relay = RFBValueRelay<RFBCursor> { delivered.append($0) }
    for _ in 0..<500 { relay.offer(shape) }
    let hidden = try! RFBCursor.decode(width: 0, height: 0, hotspotX: 0, hotspotY: 0, payload: Data())
    relay.offer(hidden)
    waitForView { !delivered.isEmpty }
    precondition(delivered == [hidden], "Cursor relay retained stale queued shapes")
    relay.offer(shape)
    waitForView { delivered.count == 2 }
    precondition(delivered.last == shape)
    print("AppKit point scaling/hotspot, scoped hide, focus/status/disconnect guards and latest-shape relay PASS")
}

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
private func runPresenterFallbackTest() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 200),
        styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = VMFramebufferView(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
    window.contentView = view
    view.injectTestFrame()
    // A missing device uses this same fallback without requiring a simulated GPU.
    view.injectPresenterFailure()
    precondition(!view.testUsesMetal, "Failed Metal presenter was not removed")
    precondition(view.testHasFallbackFrame, "Metal failure discarded the real frame")
    view.displayIfNeeded()
    CATransaction.flush()
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let color = bitmap.colorAt(x: 60 * bitmap.pixelsWide / 240,
                               y: 50 * bitmap.pixelsHigh / 200)!.usingColorSpace(.deviceRGB)!
    // A real window's HDR/profile conversion differs from an unattached bitmap;
    // require red dominance, detecting a black/stale frame or swapped channels.
    precondition(color.redComponent > 0.7 && color.redComponent - color.greenComponent > 0.4 &&
                 color.redComponent - color.blueComponent > 0.4,
                 "Metal failure lost the last real framebuffer")
    precondition(window.makeFirstResponder(view) && window.firstResponder === view,
                 "Renderer failure changed the console input owner")
    view.disconnect()
    window.contentView = nil
    window.close()
    print("Metal failure preserves real frame, Core Graphics drawing and parent input focus PASS")
}

@MainActor
private func runReconnectTest(socket: String) {
    _ = NSApplication.shared
    let view = VMFramebufferView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
    view.configure(socketPath: socket, isActive: true)
    // The mock removes the first listener, waits through a failed retry, and
    // creates a new Unix listener at the same path with a different framebuffer.
    waitForView { view.testHasLocalCursor }
    waitForView { view.testFramebufferWidth == 3 }
    precondition(!view.testHasLocalCursor, "Replacement connection retained an old cursor shape")
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

@MainActor
private func runModifierTest(socket: String, scenario: String) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let view = VMFramebufferView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
    window.contentView = view
    view.configure(socketPath: socket, isActive: true)
    waitForView { view.testFramebufferWidth == 4 }
    precondition(window.makeFirstResponder(view))
    func event(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags, _ code: UInt16 = 8, _ text: String = "c") -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
    func flags(_ code: UInt16, _ flags: NSEvent.ModifierFlags) { view.flagsChanged(with: event(.flagsChanged, flags, code, "")) }
    func down(_ flags: NSEvent.ModifierFlags, _ code: UInt16 = 8, _ text: String = "c") { view.keyDown(with: event(.keyDown, flags, code, text)) }
    func up(_ flags: NSEvent.ModifierFlags, _ code: UInt16 = 8, _ text: String = "c") { view.keyUp(with: event(.keyUp, flags, code, text)) }
    switch scenario {
    case "missing-control":
        down(.control); up([])
    case "missing-release":
        down(.control); up(.control); down([], 7, "x"); up([], 7, "x")
    case "normal-duplicate":
        flags(59, .control); flags(59, .control)
        down(.control); up(.control)
        flags(59, []); flags(59, [])
    case "late-flags":
        down(.control)
        flags(59, .control); flags(59, .control)
        up(.control); flags(59, [])
    case "left-right":
        let left = NSEvent.ModifierFlags(rawValue: 0x00000001)
        let right = NSEvent.ModifierFlags(rawValue: 0x00002000)
        flags(59, [.control, left]); flags(62, [.control, left, right]); flags(62, [.control, left, right])
        flags(59, [.control, right]); flags(59, [.control, right])
        down([.control, right]); up([.control, right]); flags(62, [])
    case "right-without-flags":
        down([.control, NSEvent.ModifierFlags(rawValue: 0x00002000)]); up([])
    case "handoff-right":
        down(.control); flags(62, .control); up(.control); flags(62, [])
    case "aggregate-both-duplicate":
        flags(59, .control); flags(62, .control); flags(59, .control); flags(62, .control)
        down(.control); up(.control); flags(59, [])
    case "all-sides":
        let groups: [(NSEvent.ModifierFlags, UInt16, UInt16, UInt, UInt)] = [
            (.shift, 56, 60, 0x2, 0x4), (.control, 59, 62, 0x1, 0x2000),
            (.option, 58, 61, 0x20, 0x40), (.command, 55, 54, 0x8, 0x10)
        ]
        for (group, leftKey, rightKey, leftMask, rightMask) in groups {
            let both: NSEvent.ModifierFlags = [group, NSEvent.ModifierFlags(rawValue: leftMask | rightMask)]
            let right: NSEvent.ModifierFlags = [group, NSEvent.ModifierFlags(rawValue: rightMask)]
            flags(leftKey, [group, NSEvent.ModifierFlags(rawValue: leftMask)])
            flags(rightKey, both); flags(leftKey, both)
            flags(leftKey, right); flags(leftKey, right)
            down(right, 7, "x"); up(right, 7, "x")
            flags(rightKey, []); flags(rightKey, [])
        }
    case "focus-fallback":
        down(.control)
        precondition(window.makeFirstResponder(nil))
    case "all-modifiers":
        for modifier: NSEvent.ModifierFlags in [.control, .shift, .option, .command] {
            let text = modifier == .shift ? "X" : "x"
            if modifier == .command {
                precondition(view.performKeyEquivalent(with: event(.keyDown, modifier, 7, text)))
            } else { down(modifier, 7, text) }
            up([], 7, text)
        }
    case "synthetic-option-shortcut":
        flags(0, .option); flags(0, .option)
        down(.option, 3, "f"); up(.option, 3, "f"); flags(0, [])
    case "synthetic-option-tap":
        flags(0, .option); flags(0, .option); flags(0, [])
    case "control-symbol":
        view.configureKeyboardLayout("it")
        down(.control, 75, "/"); up([], 75, "/")
    case "right-shift-symbol":
        view.configureKeyboardLayout("it")
        let right: NSEvent.ModifierFlags = [.shift, NSEvent.ModifierFlags(rawValue: 0x4)]
        flags(60, right); flags(60, right)
        down(right, 75, "/"); flags(60, right)
        up(right, 75, "/"); flags(60, [])
    default: preconditionFailure("Unknown modifier scenario")
    }
    precondition(view.testHeldInputCount == 0, "Completed modifier sequence left guest input held")
    // The local peer checks exact RFB event order, rejects duplicates and only
    // acknowledges with a resize once the complete expected sequence arrived.
    waitForView { view.testFramebufferWidth == 3 }
    view.configure(socketPath: socket, isActive: false)
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    print("modifier \(scenario) exact wire order and release PASS")
}

@MainActor
private func runApplicationReleaseTest(socket: String, scenario: String) {
    let app = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
        styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = VMFramebufferView(frame: window.contentLayoutRect)
    window.contentView = view
    view.configure(socketPath: socket, isActive: true)
    waitForView { view.testFramebufferWidth == 4 }
    precondition(window.makeFirstResponder(view))
    func event(_ type: NSEvent.EventType, code: UInt16, text: String,
               flags: NSEvent.ModifierFlags = [], windowNumber: Int? = nil) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber ?? window.windowNumber,
            context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
    if scenario.hasPrefix("escape-") {
        let flags: NSEvent.ModifierFlags = scenario == "escape-control" ? .control : []
        let other = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100),
            styleMask: [], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        app.sendEvent(event(.keyDown, code: 53, text: "\u{1b}", windowNumber: other.windowNumber))
        precondition(view.testHeldInputCount == 0,
                     "Another window's Escape reached the console")
        other.close()
        app.sendEvent(event(.keyDown, code: 53, text: "\u{1b}", flags: flags))
        precondition(view.testHeldInputCount == (flags.isEmpty ? 1 : 2))
        app.sendEvent(event(.keyUp, code: 53, text: "\u{1b}"))
        precondition(view.testHeldInputCount == 0, "Escape left a guest key or modifier held")
        precondition(window.makeFirstResponder(nil))
        app.sendEvent(event(.keyDown, code: 53, text: "\u{1b}"))
        precondition(view.testHeldInputCount == 0,
                     "The console captured Escape without keyboard focus")
        precondition(window.makeFirstResponder(view))
    } else if scenario == "duplicate-release" {
        let down = event(.keyDown, code: 15, text: "r")
        let up = event(.keyUp, code: 15, text: "r")
        view.keyDown(with: down)
        app.sendEvent(up)
        precondition(view.testHeldInputCount == 0, "Application key release never reached the focused console")
        view.keyUp(with: up) // Duplicate responder delivery must not emit another key-up.
    } else {
        precondition(view.performKeyEquivalent(with: event(.keyDown, code: 15, text: "r", flags: .command)))
        if scenario == "window-scope" {
            let other = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100),
                styleMask: [], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            app.sendEvent(event(.keyUp, code: 15, text: "r", flags: .command, windowNumber: other.windowNumber))
            precondition(view.testHeldInputCount == 2, "Another window released this console's key")
            other.close()
        }
        // Exercise NSApplication's real local-monitor stage before native
        // responder routing. No window is ordered and no system input is posted.
        app.sendEvent(event(.keyUp, code: 15, text: "r", flags: .command))
        precondition(view.testHeldInputCount == 1, "Command key-equivalent release never reached the focused console")
        view.flagsChanged(with: event(.flagsChanged, code: 55, text: ""))
        precondition(view.testHeldInputCount == 0, "Command+R left a key held")
        if scenario == "text-burst" {
            let codes: [Character: UInt16] = ["p": 35, "o": 31, "w": 13, "e": 14, "r": 15, "s": 1,
                "h": 4, "l": 37, ".": 47, "x": 7, " ": 49, "-": 27, "n": 45, "f": 3, "i": 34]
            for character in "powershell.exe -NoProfile" {
                let text = String(character)
                let code = codes[text.lowercased().first!]!
                let flags: NSEvent.ModifierFlags = text == text.uppercased() && text != text.lowercased() ? .shift : []
                view.keyDown(with: event(.keyDown, code: code, text: text, flags: flags))
                app.sendEvent(event(.keyUp, code: code, text: text))
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            }
            view.keyDown(with: event(.keyDown, code: 36, text: "\r", flags: [.control, .shift]))
            app.sendEvent(event(.keyUp, code: 36, text: "\r"))
            precondition(view.testHeldInputCount == 0, "Text/Control+Shift+Return left held input")
        }
    }
    waitForView { view.testFramebufferWidth == 3 }
    view.configure(socketPath: socket, isActive: false)
    app.sendEvent(event(.keyUp, code: 15, text: "r")) // Safe after monitor teardown.
    window.contentView = nil
    window.close()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    print("application key release \(scenario), exact text wire sequence and held-state cleanup PASS")
}

@MainActor
private func runRecordedKeyboardTest(socket: String, fixture: String, layout: String) throws {
    struct Recording: Decodable {
        struct Event: Decodable {
            let kind: UInt; let code: UInt16; let flags: UInt
            let characters: String?; let ignoring: String?; let `repeat`: Bool
        }
        let events: [Event]
    }
    let recording = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: URL(fileURLWithPath: fixture)))
    let app = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = VMFramebufferView(frame: window.contentLayoutRect)
    window.contentView = view
    view.configureKeyboardLayout(layout)
    view.configure(socketPath: socket, isActive: true)
    waitForView { view.testFramebufferWidth == 4 }
    precondition(window.makeFirstResponder(view))
    for item in recording.events {
        let type = NSEvent.EventType(rawValue: item.kind)!
        let event = NSEvent.keyEvent(with: type, location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: item.flags), timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: item.characters ?? "",
            charactersIgnoringModifiers: item.ignoring ?? "", isARepeat: item.repeat, keyCode: item.code)!
        if type == .flagsChanged { view.flagsChanged(with: event) }
        else if type == .keyUp { app.sendEvent(event) }
        else if event.modifierFlags.contains(.command) { precondition(view.performKeyEquivalent(with: event)) }
        else { view.keyDown(with: event) }
    }
    precondition(view.testHeldInputCount == 0, "Recorded CUA events left guest keys or modifiers held")
    waitForView { view.testFramebufferWidth == 3 }
    view.configure(socketPath: socket, isActive: false)
    window.contentView = nil; window.close()
    if ProcessInfo.processInfo.environment["PERPENDICULAR_INPUT_DIAGNOSTICS"] == "1" {
        // An unordered window may leave no run-loop sources. run(until:)
        // may return early; keep the process alive through the idle flush.
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline { RunLoop.current.run(until: deadline) }
    }
    print("recorded CUA keyboard \(layout): exact Windows key locations/modifiers and matching releases PASS")
}

private func runRapidKeyboardTest(socket: String) {
    let state = ConsoleTestState()
    let client = RFBConnection(socketPath: socket, onFrame: { state.frame($0) },
        onReady: { _ in state.ready.signal() }, onCutText: { _ in state.clipboardReceived.signal() },
        onFailure: { state.failed($0) })
    client.start()
    precondition(state.ready.wait(timeout: .now() + 5) == .success)
    // Deliberately enqueue a long paste-sized burst instantly, with no sleeps
    // in the caller. Only the production serial writer can protect the guest.
    for _ in 0..<220 { client.sendKey(0x35, down: true); client.sendKey(0x35, down: false) }
    precondition(state.clipboardReceived.wait(timeout: .now() + 12) == .success, "Paced input peer did not acknowledge every transition")
    precondition(state.snapshot().error == nil)
    client.stop()
    print("rapid 440-transition burst: ordered writer pacing and final release PASS")
}

private func runPointerCoalescingTest(socket: String) {
    let state = ConsoleTestState()
    let client = RFBConnection(socketPath: socket, onFrame: { _ in },
        onReady: { _ in state.ready.signal() }, onCutText: { state.cut($0) },
        onFailure: { state.failed($0) })
    client.start()
    precondition(state.ready.wait(timeout: .now() + 5) == .success)
    precondition(state.clipboardReceived.wait(timeout: .now() + 2) == .success)
    let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    client.holdTestWriter(started: started, release: release)
    precondition(started.wait(timeout: .now() + 2) == .success)
    for x in 0..<10_000 { client.sendPointer(x: UInt16(x), y: 10, buttons: 0) }
    client.sendPointer(x: 100, y: 20, buttons: 1)
    for x in 0..<10_000 { client.sendPointer(x: UInt16(x), y: 30, buttons: 1) }
    client.sendKey(65, down: true); client.sendKey(65, down: false)
    for x in 400..<500 { client.sendPointer(x: UInt16(x), y: 40, buttons: 1) }
    client.sendPointer(x: 500, y: 50, buttons: 0)
    for x in 600..<700 { client.sendPointer(x: UInt16(x), y: 60, buttons: 0) }
    client.sendCutText("barrier")
    for x in 700..<800 { client.sendPointer(x: UInt16(x), y: 70, buttons: 0) }
    // Equal wheel masks still represent two pulses, never replaceable motion.
    client.sendPointer(x: 800, y: 80, buttons: 8)
    client.sendPointer(x: 800, y: 80, buttons: 8)
    client.sendPointer(x: 800, y: 80, buttons: 0)
    for x in 801..<900 { client.sendPointer(x: UInt16(x), y: 90, buttons: 0) }
    client.sendPointer(x: 900, y: 100, buttons: 2)
    for x in 901..<1_000 { client.sendPointer(x: UInt16(x), y: 110, buttons: 2) }
    client.sendPointer(x: 1_000, y: 120, buttons: 0)
    let held = client.testInputReservations
    precondition(held.messages == 17 && held.bytes == 115,
                 "Absolute motion accumulated, crossed a barrier or lost a button/wheel edge")
    release.signal()
    precondition(state.clipboardReceived.wait(timeout: .now() + 5) == .success,
                 "Peer did not confirm the exact ordered pointer/key/clipboard bytes")
    let drained = DispatchSemaphore(value: 0)
    client.signalTestWriterDrained(drained)
    precondition(drained.wait(timeout: .now() + 2) == .success)
    let empty = client.testInputReservations
    precondition(empty.messages == 0 && empty.bytes == 0 && state.snapshot().error == nil)
    // A new run after the previous writer drained must also be sent.
    client.sendPointer(x: 1_001, y: 121, buttons: 0)
    precondition(state.clipboardReceived.wait(timeout: .now() + 2) == .success)
    client.stop()
    print("absolute pointer burst: latest unsent motion, exact click/drag/wheel/key barriers and drained-writer reuse PASS")
}

private func runInputOverflowTest(socket: String, scenario: String) {
    let state = ConsoleTestState()
    let failed = DispatchSemaphore(value: 0)
    let client = RFBConnection(socketPath: socket, onFrame: { _ in },
        onReady: { _ in state.ready.signal() }, onCutText: { _ in state.clipboardReceived.signal() },
        onFailure: { state.failed($0); failed.signal() })
    client.start()
    precondition(state.ready.wait(timeout: .now() + 5) == .success)
    precondition(state.clipboardReceived.wait(timeout: .now() + 2) == .success,
        "Peer did not acknowledge the initial framebuffer request")
    // Hold only this disposable connection's background writer. The queue
    // reaches its exact limit deterministically, independent of CPU scheduling.
    let writerStarted = DispatchSemaphore(value: 0)
    let releaseWriter = DispatchSemaphore(value: 0)
    client.holdTestWriter(started: writerStarted, release: releaseWriter)
    precondition(writerStarted.wait(timeout: .now() + 2) == .success)
    let expectedMessages: Int
    let expectedBytes: Int
    if scenario == "messages" {
        for index in 0..<1_024 { client.sendKey(0x35, down: index % 2 == 0) }
        expectedMessages = 1_024; expectedBytes = 1_024 * 8
        client.sendPointer(x: 1, y: 1, buttons: 1) // The next message must close, not skip.
    } else {
        let knownText = String(repeating: "x", count: 1024 * 1024)
        client.sendCutText(knownText)
        expectedMessages = 1; expectedBytes = 1024 * 1024 + 8
        client.sendCutText(knownText) // Header bytes count towards the memory limit.
    }
    let reserved = client.testInputReservations
    let bounded = reserved.messages == expectedMessages && reserved.bytes == expectedBytes
    let reported = failed.wait(timeout: .now() + 1) == .success
    let reason = state.snapshot().error
    // Failure must reject everything after overflow, including a release or a
    // desktop resize, rather than letting later messages overtake the backlog.
    client.sendKey(0x35, down: false)
    let resizeAccepted = client.requestDesktopSize(width: 800, height: 600, screenID: 0)
    releaseWriter.signal()
    let cleaned = DispatchSemaphore(value: 0)
    client.signalTestWriterDrained(cleaned)
    precondition(cleaned.wait(timeout: .now() + 1) == .success, "Overflow retained a paced input backlog")
    let remaining = client.testInputReservations
    let empty = remaining.messages == 0 && remaining.bytes == 0
    client.stop()
    precondition(bounded, "Input queue exceeded its declared bound")
    precondition(reported && reason == "Too much input arrived at once. Try a shorter input.", "Overflow did not report the actual input error")
    precondition(!resizeAccepted && empty, "Failed input connection accepted more work or retained its backlog")
    precondition(failed.wait(timeout: .now() + 0.05) == .timedOut, "Overflow was reported more than once")
    print("input \(scenario) overflow: bounded reservation, explicit connection failure, rejected later input and complete cleanup PASS")
}

precondition(CommandLine.arguments.count >= 2, "Expected console test mode")
switch CommandLine.arguments[1] {
case "protocol": runProtocolTest(socket: CommandLine.arguments[2])
case "cursor-protocol": runCursorProtocolTest(socket: CommandLine.arguments[2])
case "cursor-view": VMFramebufferView.runCursorViewTest()
case "bad": runBadMessageTest(socket: CommandLine.arguments[2], expected: CommandLine.arguments[3])
case "drawing": runDrawingTest()
case "presenter-fallback": runPresenterFallbackTest()
case "reconnect": runReconnectTest(socket: CommandLine.arguments[2])
case "focus": runFocusTest(socket: CommandLine.arguments[2])
case "modifiers": runModifierTest(socket: CommandLine.arguments[2], scenario: CommandLine.arguments[3])
case "application-release": runApplicationReleaseTest(socket: CommandLine.arguments[2], scenario: CommandLine.arguments[3])
case "recorded-keyboard": try runRecordedKeyboardTest(socket: CommandLine.arguments[2], fixture: CommandLine.arguments[3], layout: CommandLine.arguments[4])
case "rapid-keyboard": runRapidKeyboardTest(socket: CommandLine.arguments[2])
case "pointer-coalescing": runPointerCoalescingTest(socket: CommandLine.arguments[2])
case "input-overflow": runInputOverflowTest(socket: CommandLine.arguments[2], scenario: CommandLine.arguments[3])
default: preconditionFailure("Unknown console test mode")
}
