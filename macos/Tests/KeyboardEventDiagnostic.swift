import AppKit
import Darwin

/// A disposable, VM-free window for intentionally typed keyboard fixtures.
/// It has no global event monitor, clipboard access or engine connection.
@MainActor
private final class KeyboardDiagnosticView: NSView {
    private let output: FileHandle
    private var lastEvent = "Waiting for a known test fixture."
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    init(frame: NSRect, output: FileHandle) {
        self.output = output
        super.init(frame: frame)
        setAccessibilityLabel("Keyboard event diagnostic, no virtual machine")
    }
    required init?(coder: NSCoder) { nil }

    private func normalized(_ value: String?) -> Any {
        value.map { $0.unicodeScalars.map { String(format: "U+%04X", $0.value) } } ?? NSNull()
    }

    func record(_ event: NSEvent, stage: String) {
        let isKey = event.type == .keyDown || event.type == .keyUp
        let fields: [String: Any] = [
            "stage": stage, "kind": String(describing: event.type), "flags": event.modifierFlags.rawValue,
            "keyCode": event.keyCode, "characters": normalized(isKey ? event.characters : nil),
            "charactersIgnoringModifiers": normalized(isKey ? event.charactersIgnoringModifiers : nil),
            "repeat": isKey ? event.isARepeat : false, "timestamp": event.timestamp,
            "eventHasWindow": event.window != nil,
            "sourceStateID": event.cgEvent?.getIntegerValueField(.eventSourceStateID) ?? -1,
            "sourcePID": event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let line = String(data: json, encoding: .utf8) else { return }
        var record = json
        record.append(10)
        try? output.write(contentsOf: record)
        FileHandle.standardOutput.write(record)
        lastEvent = line
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) { record(event, stage: "responder") }
    override func keyUp(with event: NSEvent) { record(event, stage: "responder") }
    override func flagsChanged(with event: NSEvent) { record(event, stage: "responder") }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else { return false }
        record(event, stage: "key-equivalent")
        return true
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let title = "Keyboard diagnostic — no VM"
        title.draw(at: NSPoint(x: 28, y: 26), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 23), .foregroundColor: NSColor.labelColor])
        let instructions = "Type only known test fixtures in this window. Events are recorded only while this view receives them. No clipboard, global keyboard monitor or virtual machine is used.\n\nClose the window to stop."
        instructions.draw(in: NSRect(x: 28, y: 78, width: bounds.width - 56, height: 125), withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.secondaryLabelColor])
        lastEvent.draw(in: NSRect(x: 28, y: 230, width: bounds.width - 56, height: bounds.height - 255), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor])
    }
}

@MainActor
private final class KeyboardDiagnosticDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var eventMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard #filePath.hasPrefix("/") else { NSApp.terminate(nil); return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tools/keyboard-event-diagnostic")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let path = directory.appendingPathComponent("events.ndjson").path
            let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { NSApp.terminate(nil); return }
            _ = fchmod(descriptor, S_IRUSR | S_IWUSR)
            let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            let view = KeyboardDiagnosticView(frame: NSRect(x: 0, y: 0, width: 760, height: 390), output: output)
            let window = NSWindow(contentRect: view.bounds, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Perpendicular Keyboard Diagnostic — No VM"
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.center()
            self.window = window
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak window, weak view] event in
                if let window, let view, window.firstResponder === view,
                   event.window === window || (event.window == nil && NSApp.keyWindow === window) {
                    view.record(event, stage: "application")
                }
                return event
            }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            NSApp.activate(ignoringOtherApps: true)
        } catch { NSApp.terminate(nil) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
private enum KeyboardEventDiagnostic {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = KeyboardDiagnosticDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
