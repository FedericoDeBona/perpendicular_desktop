import AppKit
import SwiftUI

/// Shows only this test application's empty library. It never opens a VM console
/// or invokes a lifecycle command. Requires a macOS GUI session, not AX access.
/// Compile app sources with -D PERPENDICULAR_UI_RENDER and this entry point.
@main
struct FullscreenIntegrationCheck: App {
    @StateObject private var library = LibraryModel()
    @StateObject private var presentation = WindowPresentation()

    var body: some Scene {
        WindowGroup("Perpendicular Fullscreen Regression Check") {
            LibraryView(presentation: presentation)
                .environmentObject(library)
                .frame(minWidth: 1060, minHeight: 700)
                .task {
                    do { try await check() }
                    catch { print("FAIL: \(error.localizedDescription)"); fflush(stdout); exit(1) }
                }
        }.defaultSize(width: 1280, height: 820)
    }

    @MainActor
    private func check() async throws {
        // Deliberately do not load the user's library: this is a pure presentation test.
        let deadline = Date().addingTimeInterval(8)
        while presentation.attachedWindowNumber == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let number = presentation.attachedWindowNumber,
              let window = NSApp.windows.first(where: { $0.windowNumber == number }) else {
            throw EngineFailure(message: "Library background accessor did not attach to its actual native window")
        }
        print("INITIAL window=\(number) actual=\(window.styleMask.contains(.fullScreen)) model=\(presentation.isFullScreen)")
        fflush(stdout)
        window.collectionBehavior = [.fullScreenPrimary]
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await wait { window.isKeyWindow }
        try await Task.sleep(for: .seconds(1))
        guard let split = splitViews(in: window.contentView).first(where: { $0.isVertical && $0.arrangedSubviews.count == 2 }) else {
            throw EngineFailure(message: "Test could not identify the real two-pane sidebar split view")
        }
        let tokens = [NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification, NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { notification in
                print("EVENT \(notification.name.rawValue)"); fflush(stdout)
            }
        }
        defer { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
        presentation.toggleFullScreen()
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(250))
            print("TRANSITION actual=\(window.styleMask.contains(.fullScreen)) mask=\(window.styleMask.rawValue) model=\(presentation.isFullScreen) attached=\(presentation.attachedWindowNumber.map(String.init) ?? "nil") original=\(window.windowNumber) visible=\(window.isVisible) key=\(window.isKeyWindow)")
            fflush(stdout)
        }
        try await wait { window.styleMask.contains(.fullScreen) && presentation.isFullScreen }
        try await Task.sleep(for: .seconds(1))
        let visible = split.arrangedSubviews.filter { !$0.isHidden && !split.isSubviewCollapsed($0) && $0.frame.width > 2 }
        print("PANES arranged=\(split.arrangedSubviews.count) visible=\(visible.count) frames=\(split.arrangedSubviews.map { NSStringFromRect($0.frame) })")
        guard visible.count == 1 else {
            presentation.toggleFullScreen()
            throw EngineFailure(message: "Window entered native fullscreen but its sidebar is still visible")
        }
        print("ENTER actual=\(window.styleMask.contains(.fullScreen)) model=\(presentation.isFullScreen)")
        fflush(stdout)
        presentation.toggleFullScreen()
        try await wait { !window.styleMask.contains(.fullScreen) && !presentation.isFullScreen }
        try await Task.sleep(for: .seconds(1))
        let restored = split.arrangedSubviews.filter { !$0.isHidden && !split.isSubviewCollapsed($0) && $0.frame.width > 2 }
        guard restored.count == 2 else { throw EngineFailure(message: "Exiting fullscreen did not restore the library sidebar") }
        print("EXIT actual=\(window.styleMask.contains(.fullScreen)) model=\(presentation.isFullScreen)")
        print("PASS: actual native fullscreen transition, model reconciliation, sidebar collapse and exit")
        fflush(stdout)
        exit(0)
    }

    @MainActor
    private func wait(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard predicate() else { throw EngineFailure(message: "Native fullscreen transition did not reconcile within 12 seconds") }
    }

    @MainActor
    private func splitViews(in view: NSView?) -> [NSSplitView] {
        guard let view else { return [] }
        return ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap { splitViews(in: $0) }
    }
}
