import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CloneVMView: View {
    let vm: VirtualMachine
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @ViewState<String> private var name = ""
    @ViewState<String?> private var localError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "square.on.square").font(.system(size: 30)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Clone Virtual Machine").font(.title2.bold())
                    Text(vm.name).font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Create an independent copy of this virtual machine, including its disk and security state. Changes to either copy will be separate.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            Label("A full disk copy may take several minutes.", systemImage: "internaldrive").font(.caption).foregroundStyle(.secondary)
            HStack {
                if library.isBusy { ProgressView().controlSize(.small); Text("Copying virtual machine…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(library.isBusy)
                Button("Clone") {
                    Task {
                        do {
                            try await library.clone(vm, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                            dismiss()
                        } catch { localError = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!library.canControl || !vm.isStopped || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 530).interactiveDismissDisabled(library.isBusy)
            .onAppear { name = "\(vm.name) Copy" }
            .alert("Couldn’t Clone Virtual Machine", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
                Button("OK", role: .cancel) { localError = nil }
            } message: { Text(localError ?? "") }
    }
}

struct ImportDiskView: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @ViewState<String> private var name = "Windows 11"
    @ViewState<String> private var disk = ""
    @ViewState<String?> private var iso: String?
    @ViewState<Int> private var cpus = 4
    @ViewState<Int> private var memory = 8192
    @ViewState<String?> private var localError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 32)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Import an Existing Disk").font(.title2.bold())
                    Text("Bring an ARM64 virtual machine into your library.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Form {
                Section("Virtual machine") {
                    TextField("Name", text: $name)
                    LabeledContent("Source disk") {
                        VStack(alignment: .trailing, spacing: 8) {
                            Text(disk.isEmpty ? "No disk selected" : URL(fileURLWithPath: disk).lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Button("Choose Disk…", action: chooseDisk)
                        }
                    }
                    Stepper("Processors: \(cpus)", value: $cpus, in: 1...max(1, ProcessInfo.processInfo.activeProcessorCount))
                    Stepper(String(format: "Memory: %g GB", Double(memory) / 1024), value: $memory, in: 4096...max(4096, (library.host?.memoryGib ?? 16) * 1024 - 4096), step: 1024)
                }
                Section("Optional installation disc") {
                    LabeledContent("Windows ARM ISO") {
                        VStack(alignment: .trailing, spacing: 8) {
                            Text(iso.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No disc attached").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            HStack {
                                if iso != nil { Button("Remove") { iso = nil } }
                                Button("Choose ISO…") { if let path = chooseWindowsISO(current: iso) { iso = path } }
                            }
                        }
                    }
                }
            }.formStyle(.grouped)
            VStack(alignment: .leading, spacing: 7) {
                Label("Supports raw and QCOW2 disks containing an ARM64 guest.", systemImage: "info.circle")
                Text("Perpendicular creates an independent copy. Your original disk stays where it is. Intel and AMD Windows installations cannot boot with hardware acceleration on this Mac.")
            }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if library.isBusy { ProgressView().controlSize(.small); Text("Importing disk…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(library.isBusy)
                Button("Import Disk") {
                    Task {
                        do {
                            try await library.importDisk(name: name.trimmingCharacters(in: .whitespacesAndNewlines), disk: disk, cpus: cpus, memory: memory, iso: iso)
                            dismiss()
                        } catch { localError = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!library.canControl || disk.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 610, height: 620).interactiveDismissDisabled(library.isBusy)
            .onAppear { cpus = min(4, ProcessInfo.processInfo.activeProcessorCount); memory = min(8192, max(4096, (library.host?.memoryGib ?? 16) * 1024 - 4096)) }
            .alert("Couldn’t Import Disk", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
                Button("OK", role: .cancel) { localError = nil }
            } message: { Text(localError ?? "") }
    }

    private func chooseDisk() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Virtual Machine Disk"
        panel.prompt = "Choose Disk"
        panel.message = "Select a raw or QCOW2 disk containing an ARM64 guest. The source disk will be copied, never modified."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { disk = url.path }
    }
}
