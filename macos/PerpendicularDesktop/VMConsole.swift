import AppKit
import Darwin
import IOKit.hidsystem
import SwiftUI

struct VMConsoleResizeRequest: Equatable, Sendable {
    let id: UUID
    let connectionID: UUID
    let width: Int
    let height: Int
    let screenID: UInt32
}

enum VMConsoleDisplayEvent: Sendable {
    case connection(UUID?)
    case layout(UUID, RFBDesktopLayout)
    case framebuffer(UUID, width: Int, height: Int)
    case viewport(points: CGSize, backingScale: CGFloat)
    case requestQueued(UUID, accepted: Bool)
}

/// An embedded framebuffer for the engine's private Unix-domain VNC socket.
/// VM lifecycle belongs to the engine; attaching this view never starts a VM.
struct VMConsoleView: NSViewRepresentable {
    let socketPath: String
    let isActive: Bool
    let keyboardLayout: String
    let resizeRequest: VMConsoleResizeRequest?
    let onDisplayEvent: (@MainActor (VMConsoleDisplayEvent) -> Void)?
    private var nativeDisplayEndpoint: NativeDisplayEndpoint?

    func withNativeDisplay(_ endpoint: NativeDisplayEndpoint?) -> VMConsoleView {
        var result = self
        result.nativeDisplayEndpoint = endpoint
        return result
    }

    init(socketPath: String, isActive: Bool, keyboardLayout: String = "en-us", resizeRequest: VMConsoleResizeRequest? = nil,
         onDisplayEvent: (@MainActor (VMConsoleDisplayEvent) -> Void)? = nil) {
        self.socketPath = socketPath
        self.isActive = isActive
        self.keyboardLayout = keyboardLayout
        self.resizeRequest = resizeRequest
        self.onDisplayEvent = onDisplayEvent
    }

    func makeNSView(context: Context) -> VMFramebufferView {
        let view = VMFramebufferView()
        view.onDisplayEvent = onDisplayEvent
        view.configureKeyboardLayout(keyboardLayout)
#if PERPENDICULAR_NATIVE_DISPLAY
        view.configureNativeDisplay(nativeDisplayEndpoint)
#endif
        view.configure(socketPath: socketPath, isActive: isActive)
        view.requestDesktopSize(resizeRequest)
        return view
    }

    func updateNSView(_ nsView: VMFramebufferView, context: Context) {
        nsView.onDisplayEvent = onDisplayEvent
        nsView.configureKeyboardLayout(keyboardLayout)
#if PERPENDICULAR_NATIVE_DISPLAY
        nsView.configureNativeDisplay(nativeDisplayEndpoint)
#endif
        nsView.configure(socketPath: socketPath, isActive: isActive)
        nsView.requestDesktopSize(resizeRequest)
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
    private var connectionID: UUID?
    private var lastResizeRequestID: UUID?
    private var latestLayout: RFBDesktopLayout?
    var onDisplayEvent: (@MainActor (VMConsoleDisplayEvent) -> Void)?
    private var reconnectWork: DispatchWorkItem?
    private var framebuffer: CGImage?
    private var latestFrame: RFBFrame?
    private var metalDisplay: VMMetalDisplayView?
#if PERPENDICULAR_NATIVE_DISPLAY
    private var nativeEndpoint: NativeDisplayEndpoint?
    private var nativeConnection: NativeDisplayConnection?
    private var nativeReconnect: DispatchWorkItem?
    private var nativeHasActivated = false
    private var nativeHasPixels = false
    private var nativeGeneration = 0
#endif
    private var localCursor: RFBCursor?
    private var framebufferSize = CGSize.zero {
        didSet { if oldValue != framebufferSize { invalidateLocalCursor() } }
    }
    private var status = "Console is stopped" {
        didSet { if oldValue.isEmpty != status.isEmpty { invalidateLocalCursor() } }
    }
    private var tracking: NSTrackingArea?
    private var focusObservers: [RFBFocusObserver] = []
    private var keyReleaseMonitor: RFBKeyReleaseMonitor?
    private let inputDiagnosticsEnabled = ProcessInfo.processInfo.environment["PERPENDICULAR_INPUT_DIAGNOSTICS"] == "1"
    private var inputDiagnostics: RFBInputDiagnostics?
    private var pressedKeys: [UInt16: [UInt32]] = [:]
    private var pressedModifiers: [UInt16: UInt32] = [:]
    private var physicalModifiers: [UInt16: UInt32] = [:]
    private var synthesizedModifiers: Set<UInt16> = []
    private var textStrokes: [UInt16: VMKeyboardTextStroke] = [:]
    private var textStrokeOrder: [UInt16] = []
    private var guestKeyboardLayout = "en-us"
    private enum OptionIntent { case none, pending, text, shortcut }
    private var optionIntent = OptionIntent.none
    private var pointerButtons: UInt8 = 0
    private var lastPointer = (x: UInt16(0), y: UInt16(0))

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 800, height: 600) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel("Virtual machine display")
        setAccessibilityHelp("Click the display to send keyboard and mouse input to the virtual machine.")
        installMetalPresenter()
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { super.init(coder: coder); installMetalPresenter() }

    deinit { connection?.stop() }

    func configure(socketPath: String, isActive: Bool) {
        guard socketPath != configuredPath || isActive != active else { return }
        disconnect()
        configuredPath = socketPath
        active = isActive
        updateKeyReleaseMonitor()
        framebuffer = nil
        latestFrame = nil
        framebufferSize = .zero
        status = isActive ? "Connecting to display…" : "Console is stopped"
        needsDisplay = true
        updatePresenterVisibility()
        if isActive && !socketPath.isEmpty { connect() }
#if PERPENDICULAR_NATIVE_DISPLAY
        if isActive { connectNativeDisplay() }
#endif
    }

    func disconnect() {
        active = false
#if PERPENDICULAR_NATIVE_DISPLAY
        nativeGeneration &+= 1
        nativeReconnect?.cancel(); nativeReconnect = nil
        nativeConnection?.disconnect(); nativeConnection = nil
        nativeHasActivated = false; nativeHasPixels = false
#endif
        keyReleaseMonitor = nil
        generation &+= 1
        reconnectWork?.cancel()
        reconnectWork = nil
        releaseInput()
        connection?.stop()
        connection = nil
        inputDiagnostics = nil
        localCursor = nil
        invalidateLocalCursor()
        metalDisplay?.reset()
        connectionID = nil
        latestLayout = nil
        lastResizeRequestID = nil
        onDisplayEvent?(.connection(nil))
    }

    private func connect() {
        guard active, connection == nil else { return }
        generation &+= 1
        let currentGeneration = generation
        let currentConnectionID = UUID()
        let diagnostics = inputDiagnosticsEnabled ? RFBInputDiagnostics(generation: currentGeneration) : nil
        inputDiagnostics = diagnostics
        connectionID = currentConnectionID
        // Coalesce frames if the server outpaces the main thread. Keep only the newest
        // pending image instead of retaining an unbounded queue of framebuffer copies.
        let frameRelay = RFBValueRelay<RFBFrame> { [weak self] frame in
            guard let self, self.generation == currentGeneration, self.active else { return }
            self.present(frame)
        }
        let cursorRelay = RFBValueRelay<RFBCursor> { [weak self] cursor in
            guard let self, self.generation == currentGeneration, self.active,
                  self.connectionID == currentConnectionID else { return }
            self.localCursor = cursor
            self.invalidateLocalCursor()
        }
        let client = RFBConnection(
            socketPath: configuredPath,
            onFrame: { frameRelay.offer($0) },
            onReady: { [weak self] name in
                Task { @MainActor in
                    guard let self, self.generation == currentGeneration, self.active else { return }
#if PERPENDICULAR_NATIVE_DISPLAY
                    if !self.nativeHasActivated { self.status = "Waiting for display…" }
#else
                    self.status = "Waiting for display…"
#endif
                    self.onDisplayEvent?(.connection(currentConnectionID))
                    self.reportViewport()
                    self.setAccessibilityHelp("\(name). Click to send keyboard and mouse input to the virtual machine.")
                    self.needsDisplay = true
                    self.updatePresenterVisibility()
                }
            },
            // ServerCutText is unsolicited guest input. Clipboard access belongs
            // to the explicit Guest Tools actions, so display traffic cannot
            // replace the Mac user's clipboard.
            onCutText: { _ in },
            onCursor: { cursorRelay.offer($0) },
            onLayout: { [weak self] layout in
                Task { @MainActor in
                    guard let self, self.generation == currentGeneration, self.active else { return }
                    self.latestLayout = layout
                    self.onDisplayEvent?(.layout(currentConnectionID, layout))
                }
            },
            inputDiagnostics: diagnostics,
            onFailure: { [weak self] message in
                Task { @MainActor in
                    guard let self, self.generation == currentGeneration, self.active else { return }
                    self.localCursor = nil
                    self.invalidateLocalCursor()
                    self.connection = nil
                    self.connectionID = nil
                    self.latestLayout = nil
                    self.lastResizeRequestID = nil
                    self.onDisplayEvent?(.connection(nil))
                    self.pressedKeys.removeAll()
                    self.pressedModifiers.removeAll()
                    self.physicalModifiers.removeAll()
                    self.synthesizedModifiers.removeAll()
                    self.textStrokes.removeAll(); self.textStrokeOrder.removeAll(); self.optionIntent = .none
                    self.pointerButtons = 0
#if PERPENDICULAR_NATIVE_DISPLAY
                    if !self.nativeHasActivated { self.status = "\(message)\nReconnecting…" }
#else
                    self.status = "\(message)\nReconnecting…"
#endif
                    self.needsDisplay = true
                    self.updatePresenterVisibility()
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

#if PERPENDICULAR_NATIVE_DISPLAY
    func configureNativeDisplay(_ endpoint: NativeDisplayEndpoint?) {
        guard endpoint != nativeEndpoint else { return }
        let wasActive = active, path = configuredPath
        disconnect()
        nativeEndpoint = endpoint
        if wasActive { configure(socketPath: path, isActive: true) }
    }

    private func connectNativeDisplay() {
        guard active, let endpoint = nativeEndpoint, nativeConnection == nil else { return }
        if metalDisplay == nil { installMetalPresenter() }
        guard let presenter = metalDisplay, let device = presenter.device else {
            status = "The 3D display needs Metal. Reopen the console to try again."
            needsDisplay = true
            return
        }
        nativeGeneration &+= 1
        let current = nativeGeneration
        let client = NativeDisplayConnection(endpoint: endpoint, device: device,
            onLease: { [weak self] lease in
                guard let self, self.active, self.nativeGeneration == current,
                      let presenter = self.metalDisplay else { lease.discard(); return }
                guard presenter.present(lease) else { return }
                self.nativeHasActivated = true; self.nativeHasPixels = true
                self.latestFrame = nil; self.framebuffer = nil
                self.framebufferSize = CGSize(width: lease.texture.width, height: lease.texture.height)
                self.status = ""
                self.updatePresenterVisibility(); self.needsDisplay = true
                if let connectionID = self.connectionID {
                    self.onDisplayEvent?(.framebuffer(connectionID, width: lease.texture.width, height: lease.texture.height))
                }
            },
            onState: { [weak self] state in
                guard state == .disconnected else { return }
                self?.nativeDisplayDisconnected(generation: current)
            },
            onFailure: { [weak self] _ in self?.nativeDisplayDisconnected(generation: current) })
        nativeConnection = client
        client.start()
    }

    private func nativeDisplayDisconnected(generation expected: Int) {
        guard active, nativeEndpoint != nil, nativeGeneration == expected else { return }
        nativeHasPixels = false
        metalDisplay?.reset()
        latestFrame = nil; framebuffer = nil
        status = "The 3D display disconnected. Reconnecting…"
        updatePresenterVisibility(); needsDisplay = true
        let previous = nativeConnection
        nativeConnection = nil
        previous?.disconnect()
        guard nativeReconnect == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active, self.nativeGeneration == expected else { return }
            self.nativeReconnect = nil
            self.connectNativeDisplay()
        }
        nativeReconnect = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
#endif

    private func present(_ frame: RFBFrame) {
#if PERPENDICULAR_NATIVE_DISPLAY
        // Once native output has activated, RFB supplies input/layout only.
        // A broken native channel must not show a placeholder as current 3D.
        guard !nativeHasActivated else { return }
#endif
        latestFrame = frame
        framebufferSize = CGSize(width: frame.width, height: frame.height)
        status = ""
        if let metalDisplay, window != nil {
            framebuffer = nil
            metalDisplay.present(VMDisplayFrame(width: frame.width, height: frame.height, pixels: frame.pixels,
                hasReceivedPixels: frame.hasReceivedPixels))
        } else { framebuffer = Self.makeImage(frame) }
        updatePresenterVisibility()
        needsDisplay = true
        if frame.hasReceivedPixels, let connectionID {
            onDisplayEvent?(.framebuffer(connectionID, width: frame.width, height: frame.height))
        }
    }

    func requestDesktopSize(_ request: VMConsoleResizeRequest?) {
        guard let request, request.id != lastResizeRequestID else { return }
        lastResizeRequestID = request.id
        let accepted: Bool
        if active, request.connectionID == connectionID, latestLayout?.singleScreenID == request.screenID {
            accepted = connection?.requestDesktopSize(width: request.width, height: request.height, screenID: request.screenID) ?? false
        } else { accepted = false }
        Task { @MainActor [weak self] in self?.onDisplayEvent?(.requestQueued(request.id, accepted: accepted)) }
    }

    override func layout() { super.layout(); reportViewport(); invalidateLocalCursor() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); reportViewport(); invalidateLocalCursor() }
    private func reportViewport() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        onDisplayEvent?(.viewport(points: bounds.size, backingScale: window?.backingScaleFactor ?? 1))
    }

    private static func makeImage(_ frame: RFBFrame) -> CGImage? {
        guard let provider = CGDataProvider(data: frame.pixels as CFData),
              let image = CGImage(width: frame.width, height: frame.height,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: frame.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
                                    .union(.byteOrder32Little),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }
        return image
    }

    private func installMetalPresenter() {
        guard let presenter = VMMetalDisplayView.make() else { VMDisplayDiagnostics.fallback(width: 0, height: 0); return }
        presenter.frame = bounds
        presenter.autoresizingMask = [.width, .height]
        presenter.isHidden = true
        presenter.onFailure = { [weak self] in
            guard let self else { return }
            self.metalDisplay?.stop()
            self.metalDisplay?.removeFromSuperview()
            self.metalDisplay = nil
#if PERPENDICULAR_NATIVE_DISPLAY
            if self.nativeHasActivated {
                self.nativeDisplayDisconnected(generation: self.nativeGeneration)
                return
            }
#endif
            self.framebuffer = self.latestFrame.flatMap(Self.makeImage)
            VMDisplayDiagnostics.fallback(width: Int(self.framebufferSize.width), height: Int(self.framebufferSize.height))
            self.needsDisplay = true
        }
        addSubview(presenter)
        metalDisplay = presenter
    }

    private func updatePresenterVisibility() {
        var hasPixels = latestFrame != nil
#if PERPENDICULAR_NATIVE_DISPLAY
        hasPixels = hasPixels || nativeHasPixels
#endif
        metalDisplay?.isHidden = window == nil || !status.isEmpty || !hasPixels
        if metalDisplay?.isHidden != false, framebuffer == nil, let latestFrame {
            framebuffer = Self.makeImage(latestFrame)
        }
    }

    private var displayRect: CGRect {
        VMDisplayGeometry.fit(source: framebufferSize, destination: bounds.size).offsetBy(dx: bounds.minX, dy: bounds.minY)
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
            context.interpolationQuality = VMDisplayGeometry.usesNearest(source: framebufferSize,
                destination: convertToBacking(bounds).size) ? .none : .low
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

    private func invalidateLocalCursor() {
        window?.invalidateCursorRects(for: self)
    }

    // AppKit owns pointer motion. Only shape/hotspot updates cross RFB, so
    // moving the local cursor never waits for a framebuffer or guest round trip.
    // Cursor rectangles scope hidden shapes to this active view; never change
    // process/global cursor visibility or warp the user's pointer.
    private var localCursorPresentation: RFBCursorPresentation? {
        guard active, connectionID != nil, window?.isKeyWindow == true,
              status.isEmpty, let localCursor else { return nil }
        return RFBCursorPresentation.make(localCursor, framebufferSize: framebufferSize, viewBounds: bounds)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if let presentation = localCursorPresentation {
            addCursorRect(presentation.rect, cursor: presentation.cursor)
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
        updateKeyReleaseMonitor()
        reportViewport()
        updatePresenterVisibility()
        invalidateLocalCursor()
        if let latestFrame, window != nil {
            metalDisplay?.present(VMDisplayFrame(width: latestFrame.width, height: latestFrame.height, pixels: latestFrame.pixels,
                hasReceivedPixels: latestFrame.hasReceivedPixels))
        }
        focusObservers.removeAll()
        if let window {
            window.acceptsMouseMovedEvents = true
            let observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.releaseInput(); self?.invalidateLocalCursor() }
            }
            let becameKey = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.invalidateLocalCursor() }
            }
            focusObservers = [RFBFocusObserver(observer), RFBFocusObserver(becameKey)]
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
        physicalModifiers.removeAll()
        synthesizedModifiers.removeAll()
        textStrokes.removeAll(); textStrokeOrder.removeAll(); optionIntent = .none
        if pointerButtons != 0 {
            connection?.sendPointer(x: lastPointer.x, y: lastPointer.y, buttons: 0)
            pointerButtons = 0
        }
    }

    override func keyDown(with event: NSEvent) {
        guard active else { return }
        inputDiagnostics?.record("responder_down")
        if event.isARepeat { inputDiagnostics?.record("responder_repeat") }
        let stroke = VMKeyboardTextStroke.resolve(event, layout: guestKeyboardLayout)
        textStrokes[event.keyCode] = stroke
        textStrokeOrder.removeAll { $0 == event.keyCode }
        if stroke != nil { textStrokeOrder.append(event.keyCode) }
        if event.modifierFlags.contains(.option) { optionIntent = stroke == nil ? .shortcut : .text }
        synchronizeModifiers(with: event)
        let keysyms = pressedKeys[event.keyCode] ?? stroke.map { [$0.base] } ?? Self.keysyms(for: event)
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
        inputDiagnostics?.record("responder_up")
        guard let keysyms = pressedKeys.removeValue(forKey: event.keyCode) else {
            inputDiagnostics?.record("unmatched_up")
            synchronizeModifiers(with: event)
            return
        }
        for keysym in keysyms { connection?.sendKey(keysym, down: false) }
        textStrokes[event.keyCode] = nil
        textStrokeOrder.removeAll { $0 == event.keyCode }
        synchronizeModifiers(with: event)
    }

    func configureKeyboardLayout(_ layout: String) {
        guard guestKeyboardLayout != layout else { return }
        releaseInput()
        guestKeyboardLayout = layout
    }

    private func updateKeyReleaseMonitor() {
        keyReleaseMonitor = nil
        guard active, let window else { return }
        let mask: NSEvent.EventTypeMask = inputDiagnosticsEnabled ? [.keyDown, .keyUp, .flagsChanged] : [.keyDown, .keyUp]
        let token = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self, weak window] event in
            guard let self, let window, self.active, event.window === window,
                  window.firstResponder === self else { return event }
            if let diagnostics = self.inputDiagnostics {
                switch event.type {
                case .keyDown: diagnostics.record("application_down", nativeKey: true)
                case .keyUp: diagnostics.record("application_up", nativeKey: true)
                case .flagsChanged: diagnostics.record("application_flags")
                default: break
                }
            }
            // AppKit can consume Escape (including Control-Escape) to leave
            // native full screen before ordinary responder routing. While
            // this console owns keyboard focus, deliver it to Windows first.
            if event.type == .keyDown, event.keyCode == 53 {
                self.keyDown(with: event)
                return nil
            }
            guard event.type == .keyUp, self.pressedKeys[event.keyCode] != nil else { return event }
            // AppKit routes key equivalents separately from ordinary keys. See
            // the actual release before later routing can consume it. Returning
            // nil prevents a second release through the responder chain.
            self.keyUp(with: event)
            return nil
        }
        if let token { keyReleaseMonitor = RFBKeyReleaseMonitor(token) }
    }

    override func flagsChanged(with event: NSEvent) {
        guard active else { return }
        inputDiagnostics?.record("responder_flags")
        if !event.modifierFlags.contains(.option) {
            if optionIntent == .pending { sendGuestModifier(58, down: true) }
            optionIntent = .none
        } else if event.keyCode == 0, optionIntent == .none,
                  event.modifierFlags.rawValue & (Self.modifierKeys[58]!.sideMask | Self.modifierKeys[61]!.sideMask) == 0,
                  Set(physicalModifiers.keys).intersection([58, 61]).isSubset(of: synthesizedModifiers) {
            // The recorded automation events use keyCode 0 and aggregate flags.
            // Wait for the base key to distinguish printable AltGr text from an
            // Alt shortcut. Real left/right Option events retain their timing.
            optionIntent = .pending
        } else if [58, 61].contains(event.keyCode), optionIntent == .pending { optionIntent = .none }
        synchronizeModifiers(with: event)
        if event.keyCode == 57 { // Caps Lock is a toggle, not a held modifier.
            connection?.sendKey(0xffe5, down: true)
            connection?.sendKey(0xffe5, down: false)
        }
    }

    private func synchronizeModifiers(with event: NSEvent) {
        for group in Self.modifierGroups {
            let keys: Set<UInt16> = [group.left, group.right]
            let held = keys.intersection(physicalModifiers.keys)
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
                physicalModifiers[key] = keysym
                if textStrokes.isEmpty && !(group.flag == .option && [.pending, .text].contains(optionIntent)) {
                    sendGuestModifier(key, down: true)
                }
            }
            for key in held.subtracting(desired).sorted() {
                if physicalModifiers.removeValue(forKey: key) != nil,
                   textStrokes.isEmpty && !(group.flag == .option && [.pending, .text].contains(optionIntent)) {
                    sendGuestModifier(key, down: false)
                }
            }
        }
        reconcileGuestModifiers()
    }

    private func sendGuestModifier(_ key: UInt16, down: Bool) {
        guard let keysym = Self.modifierKeys[key]?.keysym else { return }
        if down {
            guard pressedModifiers[key] == nil else { return }
            pressedModifiers[key] = keysym
        } else { guard pressedModifiers.removeValue(forKey: key) != nil else { return } }
        connection?.sendKey(keysym, down: down)
    }

    private func reconcileGuestModifiers() {
        var desired = Set(physicalModifiers.keys)
        if [.pending, .text].contains(optionIntent) { desired.subtract([58, 61]) }
        if let last = textStrokeOrder.last, let stroke = textStrokes[last] {
            desired.subtract([56, 60, 58, 61])
            if stroke.shift {
                let physicalShift = Set(physicalModifiers.keys).intersection([56, 60])
                desired.formUnion(physicalShift.isEmpty ? [56] : physicalShift)
            }
            if stroke.altGr { desired.insert(61) }
        }
        let current = Set(pressedModifiers.keys)
        for key in desired.subtracting(current).sorted() { sendGuestModifier(key, down: true) }
        for key in current.subtracting(desired).sorted() { sendGuestModifier(key, down: false) }
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
    let hasReceivedPixels: Bool
    init(width: Int, height: Int, pixels: Data, hasReceivedPixels: Bool = true) {
        self.width = width; self.height = height; self.pixels = pixels
        self.hasReceivedPixels = hasReceivedPixels
    }
}

private final class RFBFocusObserver: @unchecked Sendable {
    let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

private final class RFBKeyReleaseMonitor: @unchecked Sendable {
    let token: Any
    init(_ token: Any) { self.token = token }
    deinit { NSEvent.removeMonitor(token) }
}

private final class RFBValueRelay<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Value?
    private var scheduled = false
    private let deliver: @MainActor @Sendable (Value) -> Void

    init(deliver: @escaping @MainActor @Sendable (Value) -> Void) { self.deliver = deliver }

    func offer(_ frame: Value) {
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

    private func take() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        let frame = pending
        pending = nil
        scheduled = false
        return frame
    }
}

/// Opt-in burst summaries contain only counts and timing. Never retain key
/// codes, keysyms, characters, modifier values, clipboard contents or VM paths.
private final class RFBInputDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private let generation: Int
    private var fields: [String: UInt64] = [:]
    private var firstActivity: UInt64 = 0
    private var lastActivity: UInt64 = 0
    private var lastNativeKey: UInt64 = 0
    private var lastWireKey: UInt64 = 0
    private var scheduled = false
    private static let idleNanoseconds: UInt64 = 250_000_000

    init(generation: Int) { self.generation = generation }

    func record(_ counter: String, nativeKey: Bool = false) {
        update { fields, now in
            fields[counter, default: 0] += 1
            if nativeKey {
                Self.gap(now, previous: &lastNativeKey, prefix: "application", fields: &fields)
            }
        }
    }

    func accepted(down: Bool, messages: Int, bytes: Int) {
        update { fields, _ in
            fields[down ? "accepted_down" : "accepted_up", default: 0] += 1
            fields["queue_peak_messages"] = max(fields["queue_peak_messages", default: 0], UInt64(messages))
            fields["queue_peak_bytes"] = max(fields["queue_peak_bytes", default: 0], UInt64(bytes))
        }
    }

    func written(down: Bool, queuedAt: UInt64) {
        update { fields, now in
            fields[down ? "written_down" : "written_up", default: 0] += 1
            fields["queue_max_wait_us"] = max(fields["queue_max_wait_us", default: 0], (now - queuedAt) / 1_000)
            Self.gap(now, previous: &lastWireKey, prefix: "wire", fields: &fields)
        }
    }

    private static func gap(_ now: UInt64, previous: inout UInt64, prefix: String, fields: inout [String: UInt64]) {
        if previous != 0 {
            let value = (now - previous) / 1_000
            fields[prefix + "_min_gap_us"] = min(fields[prefix + "_min_gap_us"] ?? UInt64.max, value)
            fields[prefix + "_max_gap_us"] = max(fields[prefix + "_max_gap_us", default: 0], value)
        }
        previous = now
    }

    private func update(_ change: (inout [String: UInt64], UInt64) -> Void) {
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        if firstActivity == 0 { firstActivity = now }
        lastActivity = now
        change(&fields, now)
        let needsTimer = !scheduled
        scheduled = true
        lock.unlock()
        if needsTimer { schedule(after: Self.idleNanoseconds) }
    }

    private func schedule(after nanoseconds: UInt64) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) { [self] in
            flushWhenIdle()
        }
    }

    private func flushWhenIdle() {
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        let idle = now - lastActivity
        if idle < Self.idleNanoseconds {
            lock.unlock()
            schedule(after: Self.idleNanoseconds - idle)
            return
        }
        var report = fields
        report["generation"] = UInt64(bitPattern: Int64(generation))
        report["duration_ms"] = (lastActivity - firstActivity) / 1_000_000
        fields.removeAll(keepingCapacity: true)
        firstActivity = 0; lastNativeKey = 0; lastWireKey = 0; scheduled = false
        lock.unlock()
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            var line = Data("input_diagnostics ".utf8)
            line.append(data); line.append(0x0a)
            FileHandle.standardError.write(line)
        }
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
    private let onCursor: @Sendable (RFBCursor) -> Void
    private let onLayout: @Sendable (RFBDesktopLayout) -> Void
    private let onFailure: @Sendable (String) -> Void
    private let inputDiagnostics: RFBInputDiagnostics?
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private let writer = DispatchQueue(label: "app.perpendicular.rfb.input", qos: .userInteractive)
    private var descriptor: Int32 = -1
    private var cancelled = false
    private var ready = false
    // Protected by stateLock; reservations include the in-flight write. Close
    // on overflow instead of dropping an individual key/button release.
    private var queuedInputMessages = 0
    private var queuedInputBytes = 0
    // Only an unsent run of absolute motion can change in place. A button
    // transition, wheel pulse or any other message ends the run. The writer
    // takes its immutable bytes under stateLock before touching the socket.
    private final class PendingMotion: @unchecked Sendable {
        var bytes: Data
        init(_ bytes: Data) { self.bytes = bytes }
    }
    private var pendingMotion: PendingMotion?
    private var lastPointerButtons: UInt8 = 0
    private var inputFailure: String?
    private static let maximumQueuedInputMessages = 1_024
    private static let maximumQueuedInputBytes = 2 * 1024 * 1024
    // Only the serial input writer touches this clock.
    private var lastKeyWrite: UInt64 = 0
    // QEMU's VNC keyboard defaults to a 10 ms delay per transition. Its finite
    // delayed-input queue silently drops events once full, including releases.
    // Rate only bursts on this background writer; ordinary slower input pays
    // no extra wait, and modifiers/presses/releases remain strictly ordered.
    private static let minimumKeyInterval: UInt64 = 10_000_000
    private var width = 0
    private var height = 0
    private var pixels = Data()
    private static let maximumFramebufferBytes = 128 * 1024 * 1024
    private static let maximumTextBytes = 1024 * 1024

    init(socketPath: String,
         onFrame: @escaping @Sendable (RFBFrame) -> Void,
         onReady: @escaping @Sendable (String) -> Void,
         onCutText: @escaping @Sendable (String) -> Void,
         onCursor: @escaping @Sendable (RFBCursor) -> Void = { _ in },
         onLayout: @escaping @Sendable (RFBDesktopLayout) -> Void = { _ in },
         inputDiagnostics: RFBInputDiagnostics? = nil,
         onFailure: @escaping @Sendable (String) -> Void) {
        self.socketPath = socketPath
        self.onFrame = onFrame
        self.onReady = onReady
        self.onCutText = onCutText
        self.onCursor = onCursor
        self.onLayout = onLayout
        self.onFailure = onFailure
        self.inputDiagnostics = inputDiagnostics
    }

    func start() {
        DispatchQueue.global(qos: .userInteractive).async { [self] in
            defer { finish() }
            do {
                try openSocket()
                try handshake()
                try receiveMessages()
            } catch {
                stateLock.lock()
                let message = cancelled ? nil : inputFailure ?? error.localizedDescription
                stateLock.unlock()
                if let message { onFailure(message) }
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
        var encodings = Data([2, 0, 0, 5])
        encodings.appendUInt32(UInt32(bitPattern: RFBCursor.encoding))
        encodings.appendUInt32(0) // Raw
        encodings.appendUInt32(UInt32(bitPattern: Int32(-223))) // DesktopSize
        encodings.appendUInt32(UInt32(bitPattern: Int32(-224))) // LastRect
        encodings.appendUInt32(UInt32(bitPattern: RFBDesktopResize.encoding))
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
                var receivedRawPixels = false
                var resized = false
                for _ in 0..<count {
                    let rect = try read(count: 12)
                    let x = Int(rect.uint16(at: 0)), y = Int(rect.uint16(at: 2))
                    let w = Int(rect.uint16(at: 4)), h = Int(rect.uint16(at: 6))
                    let encoding = Int32(bitPattern: rect.uint32(at: 8))
                    if encoding == -224 { break }
                    if encoding == RFBCursor.encoding {
                        // x/y are the hotspot, not framebuffer coordinates.
                        // Validate before allocating or blocking on payload bytes.
                        do {
                            let length = try RFBCursor.payloadLength(width: w, height: h, hotspotX: x, hotspotY: y)
                            let cursor = try RFBCursor.decode(width: w, height: h, hotspotX: x, hotspotY: y,
                                                              payload: read(count: length))
                            onCursor(cursor)
                        } catch is RFBCursorError { throw RFBError.protocolError("Invalid display cursor") }
                    } else if encoding == RFBDesktopResize.encoding {
                        let layout: RFBDesktopLayout
                        do {
                            let layoutHeader = try read(count: 4)
                            let length = try RFBDesktopResize.payloadLength(header: layoutHeader)
                            var payload = layoutHeader
                            payload.append(try read(count: length - 4))
                            layout = try RFBDesktopResize.decode(width: w, height: h,
                                reason: UInt16(x), status: UInt16(y), payload: payload)
                        } catch is RFBDesktopResizeError { throw RFBError.protocolError("Invalid display layout") }
                        onLayout(layout)
                        // Only an announcement describes the server's actual layout.
                        // Forwarded/rejected hints must never allocate a new framebuffer.
                        if layout.acknowledgement == .announcement, w != width || h != height {
                            try resize(width: w, height: h)
                            receivedRawPixels = false
                            resized = true
                        }
                    } else if encoding == -223 {
                        guard x == 0, y == 0 else { throw RFBError.protocolError("Invalid display resize") }
                        try resize(width: w, height: h)
                        receivedRawPixels = false
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
                            receivedRawPixels = true
                        }
                    } else {
                        throw RFBError.protocolError("Unsupported framebuffer encoding \(encoding)")
                    }
                }
                if receivedPixels {
                    onFrame(RFBFrame(width: width, height: height, pixels: pixels, hasReceivedPixels: receivedRawPixels))
                }
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
        enqueue(event, paceKey: true)
    }

    func requestDesktopSize(width: Int, height: Int, screenID: UInt32) -> Bool {
        guard let bytes = try? RFBDesktopResize.request(width: width, height: height, screenID: screenID) else { return false }
        return enqueue(bytes)
    }

    func sendPointer(x: UInt16, y: UInt16, buttons: UInt8) {
        var event = Data([5, buttons])
        event.appendUInt16(x)
        event.appendUInt16(y)
        enqueue(event, pointerButtons: buttons)
    }

    func sendCutText(_ text: String) {
        // Classic RFB uses ISO-8859-1, so do not falsely label UTF-8 as Latin-1.
        guard let payload = text.data(using: .isoLatin1), payload.count <= Self.maximumTextBytes else { return }
        var event = Data([6, 0, 0, 0])
        event.appendUInt32(UInt32(payload.count))
        event.append(payload)
        enqueue(event)
    }

    @discardableResult
    private func enqueue(_ bytes: Data, paceKey: Bool = false, pointerButtons: UInt8? = nil) -> Bool {
        stateLock.lock()
        guard ready && !cancelled else { stateLock.unlock(); return false }
        let isMotion = pointerButtons.map { $0 == lastPointerButtons && $0 & ~UInt8(7) == 0 } ?? false
        if isMotion, let pendingMotion {
            pendingMotion.bytes = bytes
            inputDiagnostics?.record("pointer_coalesced")
            stateLock.unlock()
            return true
        }
        guard queuedInputMessages < Self.maximumQueuedInputMessages,
              bytes.count <= Self.maximumQueuedInputBytes - queuedInputBytes else {
            inputFailure = "Too much input arrived at once. Try a shorter input."
            inputDiagnostics?.record("queue_overflow")
            ready = false
            if descriptor >= 0 { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
            stateLock.unlock()
            return false
        }
        queuedInputMessages += 1
        queuedInputBytes += bytes.count
        let motion = isMotion ? PendingMotion(bytes) : nil
        pendingMotion = motion
        if let pointerButtons { lastPointerButtons = pointerButtons }
        let queuedAt = inputDiagnostics == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        if paceKey { inputDiagnostics?.accepted(down: bytes[1] != 0, messages: queuedInputMessages, bytes: queuedInputBytes) }
        // Reserve and submit while holding the same lock, so concurrent callers
        // cannot reorder accepted presses/releases around each other.
        writer.async { [self] in
            defer {
                stateLock.lock()
                queuedInputMessages -= 1
                queuedInputBytes -= bytes.count
                stateLock.unlock()
            }
            stateLock.lock()
            let stillReady = ready && !cancelled && descriptor >= 0
            let payload = motion?.bytes ?? bytes
            if let motion, pendingMotion === motion { pendingMotion = nil }
            stateLock.unlock()
            guard stillReady else { return }
            if paceKey, lastKeyWrite != 0 {
                let deadline = lastKeyWrite + Self.minimumKeyInterval
                var now = DispatchTime.now().uptimeNanoseconds
                while now < deadline {
                    Thread.sleep(forTimeInterval: Double(deadline - now) / 1_000_000_000)
                    now = DispatchTime.now().uptimeNanoseconds
                }
            }
            do {
                try send(payload)
                if paceKey { inputDiagnostics?.written(down: bytes[1] != 0, queuedAt: queuedAt) }
            }
            catch {
                // Wake the reader so it reports the transport failure and the view can
                // reconnect. User cancellation is the only path that suppresses errors.
                stateLock.lock()
                ready = false
                if descriptor >= 0 { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
                stateLock.unlock()
            }
            if paceKey { lastKeyWrite = DispatchTime.now().uptimeNanoseconds }
        }
        stateLock.unlock()
        return true
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
