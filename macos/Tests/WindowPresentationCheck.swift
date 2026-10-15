import AppKit
import SwiftUI

@main
@MainActor
struct WindowPresentationCheck {
    static func main() async throws {
        _ = NSApplication.shared
        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
        let presentation = WindowPresentation()
        presentation.attach(first)
        precondition(!presentation.isFullScreen)
        let container = NSView(frame: first.contentView?.bounds ?? .zero)
        first.contentView = container
        let retiringAccessor = WindowAccessorView { presentation.attach($0) }
        container.addSubview(retiringAccessor)
        try await Task.sleep(for: .milliseconds(20))
        let replacementAccessor = WindowAccessorView { presentation.attach($0) }
        container.addSubview(replacementAccessor)
        retiringAccessor.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(20))
        precondition(presentation.attachedWindowNumber == first.windowNumber, "A retiring SwiftUI background view cleared its replacement's live window attachment")
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: second)
        try await Task.sleep(for: .milliseconds(20))
        precondition(!presentation.isFullScreen, "Another window changed the console mode")
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: first)
        try await Task.sleep(for: .milliseconds(20))
        precondition(!presentation.isFullScreen, "A notification must not fabricate fullscreen without AppKit's actual style bit")
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: first)
        try await Task.sleep(for: .milliseconds(20))
        precondition(!presentation.isFullScreen)
        presentation.attach(nil)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: first)
        try await Task.sleep(for: .milliseconds(20))
        precondition(!presentation.isFullScreen, "Detached window retained observers")
        let accessor = WindowAccessorView { _ in }
        precondition(!accessor.acceptsFirstResponder && accessor.hitTest(.zero) == nil)
        print("PASS: replacement accessor survives stale detach, notifications cannot fabricate fullscreen, window isolation, observer cleanup, focus safety")
    }
}
