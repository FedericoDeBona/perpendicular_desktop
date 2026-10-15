import AppKit
import Darwin
import IOKit.hidsystem
import SwiftUI

/// An embedded framebuffer for the engine's private Unix-domain VNC socket.
/// VM lifecycle belongs to the engine; attaching this view never starts a VM.
struct VMConsoleView: NSViewRepresentable {
    let socketPath: String
    let isActive: Bool

    init(socketPath: String, isActive: Bool) {
        self.socketPath = socketPath
        self.isActive = isActive
    }

    func makeNSView(context: Context) -> VMFramebufferView {
        let view = VMFramebufferView()
        view.configure(socketPath: socketPath, isActive: isActive)
        return view
    }

    func updateNSView(_ nsView: VMFramebufferView, context: Context) {
        nsView.configure(socketPath: socketPath, isActive: isActive)
    }

    static func dismantleNSView(_ nsView: VMFramebufferView, coordinator: ()) {
        nsView.disconnect()
    }
}

@MainActor
final class VMFramebufferView: NSView {
    private var connection: RFBConnection?
    private var configuredPath = ""
    private var active = false
    private var generation = 0
    private var reconnectWork: DispatchWorkItem?
    private var framebuffer: CGImage?
    private var framebufferSize = CGSize.zero
    private var status = "Console is stopped"
    private var tracking: NSTrackingArea?
    private var focusObserver: RFBFocusObserver?
    private var pressedKeys: [UInt16: [UInt32]] = [:]
    private var pressedModifiers: [UInt16: UInt32] = [:]
    private var synthesizedModifiers: Set<UInt16> = []
    private var pointerButtons: UInt8 = 0
    private var lastPointer = (x: UInt16(0), y: UInt16(0))

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 800, height: 600) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel("Virtual machine display")
        setAccessibilityHelp("Click the display to send keyboard and mouse input to the virtual machine.")
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    deinit { connection?.stop() }

    func configure(socketPath: String, isActive: Bool) {
        guard socketPath != configuredPath || isActive != active else { return }
        disconnect()
        configuredPath = socketPath
        active = isActive
        framebuffer = nil
        framebufferSize = .zero
        status = isActive ? "Connecting to display…" : "Console is stopped"
        needsDisplay = true
        if isActive && !socketPath.isEmpty { connect() }
    }

    func disconnect() {
        active = false
        generation &+= 1
        reconnectWork?.cancel()
        reconnectWork = nil
        releaseInput()
        connection?.stop()
        connection = nil
    }

    private func connect() {
        guard active, connection == nil else { return }
        generation &+= 1
        let currentGeneration = generation
        // Coalesce frames if the server outpaces the main thread. Keep only the newest
        // pending image instead of retaining an unbounded queue of framebuffer copies.
        let frameRelay = RFBFrameRelay { [weak self] frame in
            guard let self, self.generation == currentGeneration, self.active else { return }
            self.present(frame)
        }
        let client = RFBConnection(
            socketPath: configuredPath,
            onFrame: { frameRelay.offer($0) },
            onReady: { [weak self] name in
                Task { @MainActor in
                    guard let self, self.generation == currentGeneration, self.active else { return }
                    self.status = "Waiting for display…"
                    self.setAccessibilityHelp("\(name). Click to send keyboard and mouse input to the virtual machine.")
                    self.needsDisplay = true
                }
            },
            // ServerCutText is unsolicited guest input. Clipboard access belongs
            // to the explicit Guest Tools actions, so display traffic cannot
            // replace the Mac user's clipboard.
            onCutText: { _ in },
            onFailure: { [weak self] message in
                Task { @MainActor in
                    guard let self, self.generation == currentGeneration, self.active else { return }
                    self.connection = nil
                    self.pressedKeys.removeAll()
                    self.pressedModifiers.removeAll()
                    self.synthesizedModifiers.removeAll()
                    self.pointerButtons = 0
                    self.status = "\(message)\nReconnecting…"
                    self.needsDisplay = true
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, self.generation == currentGeneration, self.active else { return }
                        self.connect()
                    }
                    self.reconnectWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
                }
            })
        connection = client
        client.start()
    }

    private func present(_ frame: RFBFrame) {
        guard let provider = CGDataProvider(data: frame.pixels as CFData),
              let image = CGImage(width: frame.width, height: frame.height,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: frame.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
                                    .union(.byteOrder32Little),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return }
        framebuffer = image
        framebufferSize = CGSize(width: frame.width, height: frame.height)
        status = ""
        needsDisplay = true
    }

    private var displayRect: CGRect {
        guard framebufferSize.width > 0, framebufferSize.height > 0 else { return .zero }
        let scale = min(bounds.width / framebufferSize.width, bounds.height / framebufferSize.height)
        let size = CGSize(width: framebufferSize.width * scale, height: framebufferSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        if let framebuffer, let context = NSGraphicsContext.current?.cgContext {
            let rect = displayRect
            context.saveGState()
            // Core Graphics images have a bottom-left origin, while input uses a top-left origin.
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .none
            context.draw(framebuffer, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
        if !status.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let message = NSAttributedString(string: status, attributes: [
                .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
                .backgroundColor: NSColor.black.withAlphaComponent(0.7)
            ])
            let height = message.boundingRect(with: CGSize(width: max(1, bounds.width - 40), height: 200),
                                              options: [.usesLineFragmentOrigin]).height
            message.draw(in: CGRect(x: 20, y: bounds.midY - height / 2,
                                    width: max(1, bounds.width - 40), height: height + 4))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusObserver = nil
        if let window {
            window.acceptsMouseMovedEvents = true
            let observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.releaseInput() }
            }
            focusObserver = RFBFocusObserver(observer)
        } else {
            releaseInput()
        }
    }

    override func resignFirstResponder() -> Bool {
        releaseInput()
        return super.resignFirstResponder()
    }

    private func releaseInput() {
        for keysyms in pressedKeys.values {
            for keysym in keysyms { connection?.sendKey(keysym, down: false) }
        }
        for keysym in pressedModifiers.values { connection?.sendKey(keysym, down: false) }
        pressedKeys.removeAll()
        pressedModifiers.removeAll()
        synthesizedModifiers.removeAll()
        if pointerButtons != 0 {
            connection?.sendPointer(x: lastPointer.x, y: lastPointer.y, buttons: 0)
            pointerButtons = 0
        }
    }

    override func keyDown(with event: NSEvent) {
        guard active else { return }
        synchronizeModifiers(with: event)
        let keysyms = pressedKeys[event.keyCode] ?? Self.keysyms(for: event)
        pressedKeys[event.keyCode] = keysyms
        for keysym in keysyms { connection?.sendKey(keysym, down: true) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Let Command act as the guest's Windows key while the console has focus.
        // System-reserved combinations such as Command-Tab remain under macOS control.
        guard active, window?.firstResponder === self, event.type == .keyDown,
              event.modifierFlags.contains(.command) else { return false }
        keyDown(with: event)
        return true
    }

    override func keyUp(with event: NSEvent) {
        guard active else { return }
        let keysyms = pressedKeys.removeValue(forKey: event.keyCode) ?? Self.keysyms(for: event)
        for keysym in keysyms { connection?.sendKey(keysym, down: false) }
        synchronizeModifiers(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard active else { return }
        synchronizeModifiers(with: event)
        if event.keyCode == 57 { // Caps Lock is a toggle, not a held modifier.
            connection?.sendKey(0xffe5, down: true)
            connection?.sendKey(0xffe5, down: false)
        }
    }

    private func synchronizeModifiers(with event: NSEvent) {
        for group in Self.modifierGroups {
            let keys: Set<UInt16> = [group.left, group.right]
            let held = keys.intersection(pressedModifiers.keys)
            var desired: Set<UInt16> = []
            let sideMask = Self.modifierKeys[group.left]!.sideMask | Self.modifierKeys[group.right]!.sideMask
            if event.modifierFlags.contains(group.flag) {
                if event.modifierFlags.rawValue & sideMask != 0 {
                    // Native events include device-side bits. These distinguish
                    // releasing one Control/Shift/etc. while the other stays down.
                    desired = Set(keys.filter { event.modifierFlags.rawValue & Self.modifierKeys[$0]!.sideMask != 0 })
                    synthesizedModifiers.subtract(keys)
                } else if event.type == .flagsChanged, keys.contains(event.keyCode) {
                    // Aggregate-only events cannot distinguish a duplicate from
                    // a side release while its sibling is held. Keep real keys
                    // down until side information or a cleared group flag arrives.
                    desired = held.subtracting(synthesizedModifiers)
                    desired.insert(event.keyCode)
                    synthesizedModifiers.subtract(keys)
                } else {
                    desired = held
                    if desired.isEmpty {
                        // Some injected events carry modifier flags without a
                        // preceding flagsChanged. Recover the missing press.
                        desired.insert(group.left)
                        synthesizedModifiers.insert(group.left)
                    }
                }
            } else { synthesizedModifiers.subtract(keys) }
            // Press the replacement side before releasing a synthetic fallback,
            // so the guest never observes a transient unmodified state.
            for key in desired.subtracting(held).sorted() {
                let keysym = Self.modifierKeys[key]!.keysym
                pressedModifiers[key] = keysym
                connection?.sendKey(keysym, down: true)
            }
            for key in held.subtracting(desired).sorted() {
                if let keysym = pressedModifiers.removeValue(forKey: key) { connection?.sendKey(keysym, down: false) }
            }
        }
    }

    /// Standard RFB text clipboard. A guest agent is needed for Windows clipboard integration.
    @objc func paste(_ sender: Any?) {
        guard active, let text = NSPasteboard.general.string(forType: .string) else { return }
        connection?.sendCutText(text)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pointerButtons |= 1
        forwardPointer(event)
    }
    override func mouseUp(with event: NSEvent) { pointerButtons &= ~1; forwardPointer(event) }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pointerButtons |= 4
        forwardPointer(event)
    }
    override func rightMouseUp(with event: NSEvent) { pointerButtons &= ~4; forwardPointer(event) }
    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pointerButtons |= 2
        forwardPointer(event)
    }
    override func otherMouseUp(with event: NSEvent) { pointerButtons &= ~2; forwardPointer(event) }
    override func mouseMoved(with event: NSEvent) { forwardPointer(event) }
    override func mouseDragged(with event: NSEvent) { forwardPointer(event) }
    override func rightMouseDragged(with event: NSEvent) { forwardPointer(event) }
    override func otherMouseDragged(with event: NSEvent) { forwardPointer(event) }

    override func scrollWheel(with event: NSEvent) {
        guard updatePointerPosition(event) else { return }
        func wheel(_ mask: UInt8, count: Int) {
            for _ in 0..<count {
                connection?.sendPointer(x: lastPointer.x, y: lastPointer.y, buttons: pointerButtons | mask)
                connection?.sendPointer(x: lastPointer.x, y: lastPointer.y, buttons: pointerButtons)
            }
        }
        if event.scrollingDeltaY != 0 {
            wheel(event.scrollingDeltaY > 0 ? 8 : 16,
                  count: min(8, max(1, Int(abs(event.scrollingDeltaY) / (event.hasPreciseScrollingDeltas ? 10 : 1)))))
        }
        if event.scrollingDeltaX != 0 {
            wheel(event.scrollingDeltaX > 0 ? 32 : 64,
                  count: min(8, max(1, Int(abs(event.scrollingDeltaX) / (event.hasPreciseScrollingDeltas ? 10 : 1)))))
        }
    }

    private func forwardPointer(_ event: NSEvent) {
        guard updatePointerPosition(event) else { return }
        connection?.sendPointer(x: lastPointer.x, y: lastPointer.y, buttons: pointerButtons)
    }

    private func updatePointerPosition(_ event: NSEvent) -> Bool {
        let rect = displayRect
        guard active, rect.width > 0, rect.height > 0 else { return false }
        let point = convert(event.locationInWindow, from: nil)
        lastPointer = (
            UInt16(max(0, min(framebufferSize.width - 1, (point.x - rect.minX) * framebufferSize.width / rect.width))),
            UInt16(max(0, min(framebufferSize.height - 1, (point.y - rect.minY) * framebufferSize.height / rect.height)))
        )
        return true
    }

    private static let modifierGroups: [(flag: NSEvent.ModifierFlags, left: UInt16, right: UInt16)] = [
        (.shift, 56, 60), (.control, 59, 62), (.option, 58, 61), (.command, 55, 54)
    ]

    // Public device-side masks from IOKit/hidsystem/IOLLEvent.h.
    private static let modifierKeys: [UInt16: (keysym: UInt32, sideMask: UInt)] = [
        56: (0xffe1, UInt(NX_DEVICELSHIFTKEYMASK)), 60: (0xffe2, UInt(NX_DEVICERSHIFTKEYMASK)),
        59: (0xffe3, UInt(NX_DEVICELCTLKEYMASK)), 62: (0xffe4, UInt(NX_DEVICERCTLKEYMASK)),
        58: (0xffe9, UInt(NX_DEVICELALTKEYMASK)), 61: (0xffea, UInt(NX_DEVICERALTKEYMASK)),
        55: (0xffeb, UInt(NX_DEVICELCMDKEYMASK)), 54: (0xffec, UInt(NX_DEVICERCMDKEYMASK))
    ]

    private static func keysyms(for event: NSEvent) -> [UInt32] {
        let special: [UInt16: UInt32] = [
            36: 0xff0d, 48: 0xff09, 51: 0xff08, 53: 0xff1b, 76: 0xff8d,
            114: 0xff63, 115: 0xff50, 116: 0xff55, 117: 0xffff, 119: 0xff57, 121: 0xff56,
            123: 0xff51, 124: 0xff53, 125: 0xff54, 126: 0xff52,
            122: 0xffbe, 120: 0xffbf, 99: 0xffc0, 118: 0xffc1, 96: 0xffc2,
            97: 0xffc3, 98: 0xffc4, 100: 0xffc5, 101: 0xffc6, 109: 0xffc7,
            103: 0xffc8, 111: 0xffc9, 105: 0xffca, 107: 0xffcb, 113: 0xffcc,
            106: 0xffcd, 64: 0xffce, 79: 0xffcf, 80: 0xffd0, 90: 0xffd1
        ]
        if let keysym = special[event.keyCode] { return [keysym] }
        // Keep Control/Option/Command out of the text; transmit those as modifier keysyms.
        // Shift is preserved by charactersIgnoringModifiers, including the active keyboard layout.
        return (event.charactersIgnoringModifiers ?? "").unicodeScalars.compactMap { scalar in
            let value = scalar.value
            guard value >= 0x20, value != 0x7f else { return nil }
            return value <= 0xff ? value : 0x01000000 | value
        }
    }
}

private struct RFBFrame: Sendable {
    let width: Int
    let height: Int
    let pixels: Data
}

private final class RFBFocusObserver: @unchecked Sendable {
    let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

private final class RFBFrameRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: RFBFrame?
    private var scheduled = false
    private let deliver: @MainActor @Sendable (RFBFrame) -> Void

    init(deliver: @escaping @MainActor @Sendable (RFBFrame) -> Void) { self.deliver = deliver }

    func offer(_ frame: RFBFrame) {
        lock.lock()
        pending = frame
        let shouldSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if shouldSchedule {
            Task { @MainActor [self] in
                if let latest = take() { deliver(latest) }
            }
        }
    }

    private func take() -> RFBFrame? {
        lock.lock()
        defer { lock.unlock() }
        let frame = pending
        pending = nil
        scheduled = false
        return frame
    }
}

private enum RFBError: LocalizedError {
    case protocolError(String)
    case socketError(String)
    case disconnected
    case cancelled

    var errorDescription: String? {
        switch self {
        case .protocolError(let message), .socketError(let message): return message
        case .disconnected: return "Display disconnected"
        case .cancelled: return "Display connection closed"
        }
    }
}

/// One connection owns one descriptor. Shutdown interrupts blocking reads; only the reader
/// closes the descriptor, avoiding a close/reuse race with queued keyboard writes.
private final class RFBConnection: @unchecked Sendable {
    private let socketPath: String
    private let onFrame: @Sendable (RFBFrame) -> Void
    private let onReady: @Sendable (String) -> Void
    private let onCutText: @Sendable (String) -> Void
    private let onFailure: @Sendable (String) -> Void
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private let writer = DispatchQueue(label: "app.perpendicular.rfb.input", qos: .userInteractive)
    private var descriptor: Int32 = -1
    private var cancelled = false
    private var ready = false
    private var width = 0
    private var height = 0
    private var pixels = Data()
    private static let maximumFramebufferBytes = 128 * 1024 * 1024
    private static let maximumTextBytes = 1024 * 1024

    init(socketPath: String,
         onFrame: @escaping @Sendable (RFBFrame) -> Void,
         onReady: @escaping @Sendable (String) -> Void,
         onCutText: @escaping @Sendable (String) -> Void,
         onFailure: @escaping @Sendable (String) -> Void) {
        self.socketPath = socketPath
        self.onFrame = onFrame
        self.onReady = onReady
        self.onCutText = onCutText
        self.onFailure = onFailure
    }

    func start() {
        DispatchQueue.global(qos: .userInteractive).async { [self] in
            defer { finish() }
            do {
                try openSocket()
                try handshake()
                try receiveMessages()
            } catch {
                if !isCancelled { onFailure(error.localizedDescription) }
            }
        }
    }

    func stop() {
        stateLock.lock()
        cancelled = true
        ready = false
        if descriptor >= 0 { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
        stateLock.unlock()
    }

    private var isCancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }

    private func finish() {
        // A writer holds writeLock through send(). Shutdown releases a blocked send first.
        stateLock.lock()
        ready = false
        if descriptor >= 0 { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
        stateLock.unlock()
        writeLock.lock()
        stateLock.lock()
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
        stateLock.unlock()
        writeLock.unlock()
    }

    private func openSocket() throws {
        guard !socketPath.utf8.contains(0) else { throw RFBError.protocolError("Invalid display socket path") }
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let path = Array(socketPath.utf8)
        guard path.count < capacity, socketPath.hasPrefix("/") else {
            throw RFBError.protocolError("Display requires a valid local Unix socket path")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { storage in
            storage.initializeMemory(as: UInt8.self, repeating: 0)
            storage.copyBytes(from: path)
        }
        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw RFBError.socketError("Cannot create display socket: \(String(cString: strerror(errno)))") }
        stateLock.lock()
        if cancelled {
            stateLock.unlock()
            Darwin.close(socketFD)
            throw RFBError.cancelled
        }
        descriptor = socketFD
        stateLock.unlock()
        var noSignal: Int32 = 1
        _ = setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw RFBError.socketError("Display unavailable: \(String(cString: strerror(errno)))") }
    }

    private func handshake() throws {
        let banner = try read(count: 12)
        guard let version = String(data: banner, encoding: .ascii),
              version.hasPrefix("RFB 003."), version.hasSuffix("\n"),
              let minor = Int(version.dropFirst(8).prefix(3)), minor >= 3 else {
            throw RFBError.protocolError("Unsupported display protocol")
        }
        let selected = minor >= 8 ? 8 : minor >= 7 ? 7 : 3
        try send(Data(String(format: "RFB 003.%03d\n", selected).utf8))
        if selected == 3 {
            let security = try readUInt32()
            if security == 0 { throw RFBError.protocolError(try readReason()) }
            guard security == 1 else { throw RFBError.protocolError("Display requires unsupported authentication") }
        } else {
            let count = Int(try readByte())
            guard count > 0 else { throw RFBError.protocolError(try readReason()) }
            let security = try read(count: count)
            guard security.contains(1) else { throw RFBError.protocolError("Display does not offer local no-auth access") }
            try send(Data([1]))
            // RFB 3.3/3.7 omit SecurityResult for None authentication; 3.8 requires it.
            if selected >= 8, try readUInt32() != 0 {
                throw RFBError.protocolError(try readReason())
            }
        }
        try send(Data([1])) // Shared ClientInit.
        let serverInit = try read(count: 24)
        try resize(width: Int(serverInit.uint16(at: 0)), height: Int(serverInit.uint16(at: 2)))
        let nameLength = Int(serverInit.uint32(at: 20))
        guard nameLength <= 64 * 1024 else { throw RFBError.protocolError("Display name exceeds protocol limit") }
        let name = String(decoding: try read(count: nameLength), as: UTF8.self)
        // SetPixelFormat: 32 bits, depth 24, little endian, RGB888, shifts 16/8/0.
        try send(Data([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]))
        var encodings = Data([2, 0, 0, 3])
        encodings.appendUInt32(0) // Raw
        encodings.appendUInt32(UInt32(bitPattern: Int32(-223))) // DesktopSize
        encodings.appendUInt32(UInt32(bitPattern: Int32(-224))) // LastRect
        try send(encodings)
        stateLock.lock()
        ready = !cancelled
        stateLock.unlock()
        onReady(name.isEmpty ? "Virtual machine display" : name)
        try requestUpdate(incremental: false)
    }

    private func receiveMessages() throws {
        while !isCancelled {
            switch try readByte() {
            case 0:
                let header = try read(count: 3)
                let count = Int(header.uint16(at: 1))
                var receivedPixels = false
                var resized = false
                for _ in 0..<count {
                    let rect = try read(count: 12)
                    let x = Int(rect.uint16(at: 0)), y = Int(rect.uint16(at: 2))
                    let w = Int(rect.uint16(at: 4)), h = Int(rect.uint16(at: 6))
                    let encoding = Int32(bitPattern: rect.uint32(at: 8))
                    if encoding == -224 { break }
                    if encoding == -223 {
                        guard x == 0, y == 0 else { throw RFBError.protocolError("Invalid display resize") }
                        try resize(width: w, height: h)
                        resized = true
                        receivedPixels = true
                    } else if encoding == 0 {
                        guard x <= width, y <= height, w <= width - x, h <= height - y else {
                            throw RFBError.protocolError("Framebuffer rectangle exceeds display bounds")
                        }
                        if w > 0 && h > 0 {
                            try pixels.withUnsafeMutableBytes { destination in
                                if x == 0 && w == width {
                                    // Full-width rectangles occupy one contiguous region.
                                    // Avoid a recv/lock cycle per scanline on full updates.
                                    let start = y * width * 4
                                    try read(into: UnsafeMutableRawBufferPointer(
                                        rebasing: destination[start..<(start + w * h * 4)]))
                                } else {
                                    for row in 0..<h {
                                        let start = ((y + row) * width + x) * 4
                                        try read(into: UnsafeMutableRawBufferPointer(
                                            rebasing: destination[start..<(start + w * 4)]))
                                    }
                                }
                            }
                            receivedPixels = true
                        }
                    } else {
                        throw RFBError.protocolError("Unsupported framebuffer encoding \(encoding)")
                    }
                }
                if receivedPixels { onFrame(RFBFrame(width: width, height: height, pixels: pixels)) }
                try requestUpdate(incremental: !resized)
            case 1: // SetColourMapEntries is legal even though this client requests true colour.
                let header = try read(count: 5)
                _ = try read(count: Int(header.uint16(at: 3)) * 6)
            case 2: // Bell; keep the guest from causing host alert sounds.
                break
            case 3:
                let header = try read(count: 7)
                let count = Int(header.uint32(at: 3))
                guard count <= Self.maximumTextBytes else { throw RFBError.protocolError("Guest clipboard exceeds 1 MiB") }
                let data = try read(count: count)
                onCutText(String(data: data, encoding: .isoLatin1) ?? "")
            default:
                throw RFBError.protocolError("Unknown display server message")
            }
        }
        throw RFBError.cancelled
    }

    private func resize(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              width <= Self.maximumFramebufferBytes / 4 / height else {
            throw RFBError.protocolError("Invalid display dimensions (maximum framebuffer: 128 MiB)")
        }
        self.width = width
        self.height = height
        pixels = Data(count: width * height * 4)
    }

    private func requestUpdate(incremental: Bool) throws {
        var request = Data([3, incremental ? 1 : 0, 0, 0, 0, 0])
        request.appendUInt16(UInt16(width))
        request.appendUInt16(UInt16(height))
        try send(request)
    }

    func sendKey(_ keysym: UInt32, down: Bool) {
        var event = Data([4, down ? 1 : 0, 0, 0])
        event.appendUInt32(keysym)
        enqueue(event)
    }

    func sendPointer(x: UInt16, y: UInt16, buttons: UInt8) {
        var event = Data([5, buttons])
        event.appendUInt16(x)
        event.appendUInt16(y)
        enqueue(event)
    }

    func sendCutText(_ text: String) {
        // Classic RFB uses ISO-8859-1, so do not falsely label UTF-8 as Latin-1.
        guard let payload = text.data(using: .isoLatin1), payload.count <= Self.maximumTextBytes else { return }
        var event = Data([6, 0, 0, 0])
        event.appendUInt32(UInt32(payload.count))
        event.append(payload)
        enqueue(event)
    }

    private func enqueue(_ bytes: Data) {
        stateLock.lock()
        let canSend = ready && !cancelled
        stateLock.unlock()
        guard canSend else { return }
        writer.async { [self] in
            do { try send(bytes) }
            catch {
                // Wake the reader so it reports the transport failure and the view can
                // reconnect. User cancellation is the only path that suppresses errors.
                stateLock.lock()
                ready = false
                if descriptor >= 0 { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
                stateLock.unlock()
            }
        }
    }

    private func send(_ bytes: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        stateLock.lock()
        let socketFD = descriptor
        let stopped = cancelled
        stateLock.unlock()
        guard socketFD >= 0, !stopped else { throw RFBError.cancelled }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.send(socketFD, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw RFBError.socketError("Display write failed: \(String(cString: strerror(errno)))")
                }
                guard written > 0 else { throw RFBError.disconnected }
                offset += written
            }
        }
    }

    private func read(count: Int) throws -> Data {
        guard count >= 0, count <= Self.maximumFramebufferBytes else { throw RFBError.protocolError("Oversized display message") }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { try read(into: $0) }
        return data
    }

    private func read(into buffer: UnsafeMutableRawBufferPointer) throws {
        var offset = 0
        while offset < buffer.count {
            if isCancelled { throw RFBError.cancelled }
            let count = Darwin.recv(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
            if count < 0 {
                if errno == EINTR { continue }
                throw RFBError.socketError("Display read failed: \(String(cString: strerror(errno)))")
            }
            guard count > 0 else { throw RFBError.disconnected }
            offset += count
        }
    }

    private func readByte() throws -> UInt8 { try read(count: 1)[0] }
    private func readUInt32() throws -> UInt32 { try read(count: 4).uint32(at: 0) }

    private func readReason() throws -> String {
        let count = Int(try readUInt32())
        guard count <= 16 * 1024 else { return "Display server rejected the connection" }
        return String(decoding: try read(count: count), as: UTF8.self)
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }
    func uint32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16 |
            UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
