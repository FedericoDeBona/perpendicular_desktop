import AppKit
import SwiftUI

// Disambiguate the stable property wrapper from the SDK 27 State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

#if !PERPENDICULAR_UI_RENDER
@main
#endif
struct PerpendicularDesktopApp: App {
    @StateObject private var library = LibraryModel()

    var body: some Scene {
        WindowGroup("Perpendicular Desktop") {
            LibraryView()
                .environmentObject(library)
                .frame(minWidth: 1060, minHeight: 700)
                .tint(.blue)
                .task { await library.load() }
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { return }
                        await library.refresh()
                    }
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Virtual Machine…") { NotificationCenter.default.post(name: .createVirtualMachine, object: nil) }
                    .keyboardShortcut("n").disabled(library.isBusy)
                Button("Import Existing Disk…") { NotificationCenter.default.post(name: .importVirtualDisk, object: nil) }
                    .keyboardShortcut("o").disabled(library.isBusy)
            }
            CommandMenu("Virtual Machine") {
                Button("Start") { if let vm = library.selectedVM { Task { await library.action(["start", vm.id], operation: "Starting \(vm.name)…") } } }
                    .disabled(library.selectedVM?.isStopped != true || !library.canControl)
                Button("Pause") { if let vm = library.selectedVM { Task { await library.action(["pause", vm.id], operation: "Pausing…") } } }
                    .disabled(library.selectedVM?.state != "running" || !library.canControl)
                Button("Resume") { if let vm = library.selectedVM { Task { await library.action(["resume", vm.id], operation: "Resuming…") } } }
                    .disabled(library.selectedVM?.state != "paused" || !library.canControl)
                Divider()
                Button("Shut Down") { if let vm = library.selectedVM { Task { await library.action(["stop", vm.id], operation: "Requesting shutdown…") } } }
                    .disabled(library.selectedVM?.isActive != true || !library.canControl)
                Divider()
                Button("Clone…") { NotificationCenter.default.post(name: .cloneVirtualMachine, object: nil) }
                    .disabled(library.selectedVM?.isStopped != true || !library.canControl)
                Button("Export Disk…") { NotificationCenter.default.post(name: .exportVirtualDisk, object: nil) }
                    .disabled(library.selectedVM?.state != "stopped" || !library.canControl)
                Divider()
                Button("Refresh Library") { Task { await library.refresh() } }
                    .keyboardShortcut("r").disabled(library.isBusy)
            }
        }
        Settings {
            AppSettingsView().environmentObject(library)
        }
    }
}

extension Notification.Name {
    static let createVirtualMachine = Notification.Name("PerpendicularCreateVirtualMachine")
    static let importVirtualDisk = Notification.Name("PerpendicularImportVirtualDisk")
    static let cloneVirtualMachine = Notification.Name("PerpendicularCloneVirtualMachine")
    static let exportVirtualDisk = Notification.Name("PerpendicularExportVirtualDisk")
}

struct PerpendicularMark: View {
    var size: CGFloat = 44
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25).fill(LinearGradient(colors: [Color(red: 0.22, green: 0.52, blue: 0.98), Color(red: 0.18, green: 0.32, blue: 0.78)], startPoint: .topLeading, endPoint: .bottomTrailing))
            HStack(spacing: size * 0.12) {
                RoundedRectangle(cornerRadius: size * 0.035).frame(width: size * 0.12, height: size * 0.52)
                RoundedRectangle(cornerRadius: size * 0.035).frame(width: size * 0.12, height: size * 0.52)
            }.foregroundStyle(.white).rotationEffect(.degrees(90))
        }.frame(width: size, height: size)
    }
}
