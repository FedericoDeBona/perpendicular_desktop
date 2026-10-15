import AppKit
import SwiftUI

private final class WindowObservation: @unchecked Sendable {
    let tokens: [NSObjectProtocol]
    let timer: Timer
    init(_ tokens: [NSObjectProtocol], timer: Timer) { self.tokens = tokens; self.timer = timer }
    deinit { timer.invalidate(); tokens.forEach { NotificationCenter.default.removeObserver($0) } }
}

@MainActor
final class WindowPresentation: ObservableObject {
    @Published private(set) var isFullScreen = false
    private weak var window: NSWindow?
    private var observation: WindowObservation?
    var attachedWindowNumber: Int? { window?.windowNumber }

    func attach(_ window: NSWindow?) {
        guard self.window !== window else { return }
        self.window = window
        observation = nil
        trace("attach")
        reconcileWindowState()
        guard let window else { return }
        let center = NotificationCenter.default
        let notifications: [Notification.Name] = [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                                                  NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification]
        let tokens = notifications.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.trace(name.rawValue); self?.reconcileWindowState() }
            }
        }
        // SwiftUI can replace/reparent its hosting views while the native window
        // transitions. Reconcile against AppKit's state even if a notification
        // arrives during that reparenting rather than assuming the event won.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcileWindowState() }
        }
        RunLoop.main.add(timer, forMode: .common)
        observation = WindowObservation(tokens, timer: timer)
    }

    func reconcileWindowState() {
        let fullScreen = window?.styleMask.contains(.fullScreen) == true
        if isFullScreen != fullScreen { isFullScreen = fullScreen; trace("state-changed") }
    }

    func toggleFullScreen() {
        trace("toggle-before")
        window?.toggleFullScreen(nil)
        reconcileWindowState()
        trace("toggle-after")
    }

    private func trace(_ event: String) {
        guard ProcessInfo.processInfo.environment["PERPENDICULAR_WINDOW_DIAGNOSTICS"] == "1" else { return }
        let line = "WindowPresentation event=\(event) window=\(window?.windowNumber ?? -1) mask=\(window?.styleMask.rawValue ?? 0) actual=\(window?.styleMask.contains(.fullScreen) == true) model=\(isFullScreen) key=\(window?.isKeyWindow == true)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> WindowAccessorView { WindowAccessorView(onWindow: onWindow) }
    func updateNSView(_ nsView: WindowAccessorView, context: Context) {
        nsView.onWindow = onWindow
        nsView.reportWindow()
    }
}

final class WindowAccessorView: NSView {
    var onWindow: (NSWindow?) -> Void
    init(onWindow: @escaping (NSWindow?) -> Void) { self.onWindow = onWindow; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportWindow()
    }
    func reportWindow() {
        // A detached background view must not clear a newer view's attachment.
        guard let target = window else { return }
        Task { @MainActor [weak self] in
            guard let self, self.window === target else { return }
            self.onWindow(target)
        }
    }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
