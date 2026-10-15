import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
func chooseWindowsISO(current: String? = nil, driverDisc: Bool = false) -> String? {
    let panel = NSOpenPanel()
    panel.title = driverDisc ? "Choose a Windows Driver Disc" : "Choose a Windows 11 ARM Installation Image"
    panel.prompt = "Choose Image"
    panel.message = driverDisc ? "Select an ISO containing independently distributed Windows ARM64 drivers." : "Select a Windows 11 ARM64 ISO image. Windows licensing is managed inside Windows."
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    if let type = UTType(filenameExtension: "iso") { panel.allowedContentTypes = [type] }
    if let current { panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent() }
    else { panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first }
    return panel.runModal() == .OK ? panel.url?.path : nil
}

struct CreateVMView: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @ViewState<String> private var name = "Windows 11"
    @ViewState<String> private var iso = ""
    @ViewState<Int> private var cpus = 4
    @ViewState<Int> private var memory = 8192
    @ViewState<Int> private var disk = 80
    @ViewState<String?> private var localError: String?

    private var maxCPUs: Int { max(1, ProcessInfo.processInfo.activeProcessorCount) }
    private var maxMemory: Int { max(4096, (library.host?.memoryGib ?? 16) * 1024 - 4096) }
    private var valid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !iso.isEmpty && FileManager.default.isReadableFile(atPath: iso) && memory >= 4096 && disk >= 64 }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                PerpendicularMark(size: 60).padding(.bottom, 30)
                Text("Make room\nfor Windows.").font(.system(size: 32, weight: .semibold, design: .rounded)).lineSpacing(3)
                Text("Your own Windows desktop,\nright alongside your Mac.").font(.callout).foregroundStyle(.secondary).lineSpacing(5).padding(.top, 16)
                Spacer()
                VStack(alignment: .leading, spacing: 18) {
                    Label("Built for Apple Silicon", systemImage: "cpu")
                    Label("Windows 11 ARM64", systemImage: "desktopcomputer")
                    Label("Storage grows as you use it", systemImage: "internaldrive")
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(32).frame(width: 265, alignment: .leading).frame(maxHeight: .infinity).background(.blue.opacity(0.045))
            VStack(alignment: .leading, spacing: 0) {
                Text("New Virtual Machine").font(.title2.bold()).padding(.bottom, 6)
                Text("Choose an installation image and allocate resources.").font(.callout).foregroundStyle(.secondary).padding(.bottom, 24)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Name").font(.headline)
                            TextField("Windows 11", text: $name).textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Installation image").font(.headline)
                            Button {
                                if let path = chooseWindowsISO(current: iso.isEmpty ? nil : iso) { iso = path }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "opticaldisc").font(.title).foregroundStyle(.blue)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(iso.isEmpty ? "Choose Windows 11 ARM ISO…" : URL(fileURLWithPath: iso).lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                                        Text(iso.isEmpty ? "Select an .iso file from your Mac" : "Click to choose a different image").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "folder").foregroundStyle(.secondary)
                                }.padding(14).frame(maxWidth: .infinity).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                            Text("Use an ARM64 image. Intel and AMD images cannot run with hardware acceleration on this Mac.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        VStack(alignment: .leading, spacing: 17) {
                            Text("Resources").font(.headline)
                            resourceRow(icon: "cpu", title: "Processors", subtitle: "\(maxCPUs) cores available on this Mac") {
                                Stepper("\(cpus) cores", value: $cpus, in: 1...maxCPUs).frame(width: 125)
                            }
                            resourceRow(icon: "memorychip", title: "Memory", subtitle: "4 GB minimum for Windows 11") {
                                Stepper(String(format: "%g GB", Double(memory) / 1024), value: $memory, in: 4096...maxMemory, step: 1024).frame(width: 125)
                            }
                            resourceRow(icon: "internaldrive", title: "Disk size", subtitle: "Uses space on your Mac as needed") {
                                Stepper("\(disk) GB", value: $disk, in: 64...2048, step: 16).frame(width: 125)
                            }
                        }
                        Label("Windows installation will begin when you start the virtual machine.", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.trailing, 3)
                }
                Divider().padding(.top, 20).padding(.bottom, 16)
                HStack {
                    if library.isBusy { ProgressView().controlSize(.small); Text("Creating…").font(.callout).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(library.isBusy)
                    Button("Create Virtual Machine") {
                        Task {
                            do {
                                try await library.create(name: name.trimmingCharacters(in: .whitespacesAndNewlines), iso: iso, cpus: cpus, memory: memory, disk: disk)
                                dismiss()
                            } catch { localError = error.localizedDescription }
                        }
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!valid || !library.canControl)
                }
            }.padding(30).frame(width: 525)
        }.frame(height: 660).interactiveDismissDisabled(library.isBusy)
            .alert("Couldn’t Create Virtual Machine", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
                Button("OK", role: .cancel) { localError = nil }
            } message: { Text(localError ?? "") }
            .onAppear {
                cpus = min(4, maxCPUs)
                memory = min(8192, maxMemory)
            }
    }

    private func resourceRow<Control: View>(icon: String, title: String, subtitle: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            control().font(.callout)
        }
    }
}

struct ConfigurationView: View {
    let vm: VirtualMachine
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @ViewState<String> private var name = ""
    @ViewState<Int> private var cpus = 4
    @ViewState<Int> private var memory = 8192
    @ViewState<String?> private var iso: String?
    @ViewState<String?> private var driverISO: String?
    @ViewState<String> private var keyboardLayout = "en-us"
    @ViewState<Bool> private var audioOutput = false
    @ViewState<String?> private var localError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Configure Virtual Machine").font(.title2.bold())
            Text("Resource changes apply the next time this virtual machine starts.").font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name)
                Stepper("Processors: \(cpus)", value: $cpus, in: 1...max(cpus, ProcessInfo.processInfo.activeProcessorCount))
                Stepper(String(format: "Memory: %g GB", Double(memory) / 1024), value: $memory, in: 4096...max(memory, (library.host?.memoryGib ?? 16) * 1024 - 2048), step: 1024)
                LabeledContent("Disk size", value: "\(vm.diskGib) GB")
                Picker("Keyboard layout", selection: $keyboardLayout) {
                    Text("U.S. English").tag("en-us")
                    Text("Italian").tag("it")
                }
                Toggle("Play Windows audio on this Mac", isOn: $audioOutput)
                if let tpm = vm.tpmEnabled { LabeledContent("TPM 2.0", value: tpm ? "Enabled" : "Disabled") }
                if let secureBoot = vm.secureBootState {
                    LabeledContent("Secure Boot", value: secureBoot == "verified" ? "Verified in guest" : "Not yet verified in guest")
                }
                LabeledContent("Installation disc") {
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(iso.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No disc attached").font(.caption).lineLimit(2)
                        Button("Choose ISO…") { if let path = chooseWindowsISO(current: iso) { iso = path } }
                    }
                }
                LabeledContent("Windows driver disc") {
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(driverISO.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No driver disc attached").font(.caption).lineLimit(2)
                        Button("Choose Driver ISO…") { if let path = chooseWindowsISO(current: driverISO, driverDisc: true) { driverISO = path } }
                    }
                }
            }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(library.isBusy)
                Button("Save Changes") {
                    Task {
                        var args = ["update", vm.id, "--name", name.trimmingCharacters(in: .whitespacesAndNewlines), "--cpus", String(cpus), "--memory-mib", String(memory)]
                        args += ["--keyboard-layout", keyboardLayout, "--audio-output", audioOutput ? "true" : "false"]
                        if let iso, iso != vm.isoPath { args += ["--iso", iso] }
                        if let driverISO, driverISO != vm.guestToolsIsoPath { args += ["--guest-tools-iso", driverISO] }
                        do {
                            try await library.perform(args, operation: "Saving configuration…")
                            dismiss()
                        } catch { localError = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !library.canControl || !vm.isStopped)
            }
        }.padding(26).frame(width: 580, height: 660).interactiveDismissDisabled(library.isBusy)
            .alert("Couldn’t Save Configuration", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
                Button("OK", role: .cancel) { localError = nil }
            } message: { Text(localError ?? "") }
            .onAppear {
                name = vm.name; cpus = vm.cpus; memory = vm.memoryMib; iso = vm.isoPath; driverISO = vm.guestToolsIsoPath
                keyboardLayout = vm.keyboardLayout ?? "en-us"; audioOutput = vm.audioOutput ?? false
            }
    }
}
