import AppKit
import SwiftUI

/// Renders only this application's own view hierarchy. No Accessibility or Screen
/// Recording permission is needed. The model reads the real engine library.
/// Compile the app sources and this file with -D PERPENDICULAR_UI_RENDER.
@main
@MainActor
struct RenderLibrary {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("Usage: render-library /absolute/output.png [--create|--import|--clone|--system|--configure|--display-only]")
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let model = LibraryModel()
        await model.load()
        let creation = args.contains("--create")
        let importing = args.contains("--import")
        let cloning = args.contains("--clone")
        let system = args.contains("--system")
        let configure = args.contains("--configure")
        let displayOnly = args.contains("--display-only")
        let size = NSSize(width: creation ? 790 : importing ? 610 : cloning ? 530 : system ? 640 : configure ? 580 : 1280,
                          height: creation ? 660 : importing ? 620 : cloning ? 300 : system ? 460 : configure ? 590 : 820)
        let root: AnyView
        if creation { root = AnyView(CreateVMView().environmentObject(model)) }
        else if importing { root = AnyView(ImportDiskView().environmentObject(model)) }
        else if cloning, let vm = model.selectedVM { root = AnyView(CloneVMView(vm: vm).environmentObject(model)) }
        else if system { root = AnyView(AppSettingsView(initialTab: "system").environmentObject(model)) }
        else if configure, let vm = model.selectedVM { root = AnyView(ConfigurationView(vm: vm).environmentObject(model)) }
        else if displayOnly, let vm = model.selectedVM { root = AnyView(VMDetailView(vm: vm, immersive: true).environmentObject(model)) }
        else { root = AnyView(LibraryView().environmentObject(model)) }
        let host = NSHostingView(rootView: root.frame(width: size.width, height: size.height).tint(.blue).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw EngineFailure(message: "Could not allocate a bitmap for the app view.")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw EngineFailure(message: "Could not encode the rendered app view.")
        }
        try data.write(to: URL(fileURLWithPath: args[1]))
        print("Rendered \(creation ? "creation sheet" : "real library") to \(args[1])")
    }
}
