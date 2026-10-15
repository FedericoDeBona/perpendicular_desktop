import AppKit
import SwiftUI

struct GuestToolsView: View {
    let vm: VirtualMachine
    @ObservedObject var tools: GuestToolsController
    @EnvironmentObject private var library: LibraryModel
    @ViewState<Bool> private var showFileTransfer = false

    private var status: GuestToolsStatus? { tools.statuses[vm.id] }
    private var connected: Bool { vm.state == "running" && library.connectionError == nil && status?.connected == true }
    private var canUseClipboard: Bool { connected && status?.capabilities.clipboard == true && !tools.isBusy && library.canControl }
    private var canSendFile: Bool { connected && status?.capabilities.fileWrite == true && !tools.isBusy && library.canControl }
    private var connectionLabel: String {
        if library.connectionError != nil { return "Guest Tools status unavailable" }
        if connected { return "Guest Tools connected" }
        if tools.checkingVMID == vm.id { return "Checking Guest Tools…" }
        return status == nil ? "Connection not checked" : "Guest Tools not connected"
    }
    private var tpmLabel: String {
        if status?.tpm?.present == .known(false) { return "Not present" }
        switch status?.tpm?.ready {
        case .known(true): return "Ready"
        case .known(false): return "Not ready"
        default: return "Unknown"
        }
    }
    private var connectionInstruction: String {
        if library.connectionError != nil { return "Check the app’s connection, then try Guest Tools again." }
        if vm.state == "paused" { return "Resume Windows, then check the connection again." }
        if vm.state != "running" { return "Start Windows to connect Guest Tools." }
        switch status?.code {
        case "guest_agent_timeout": return "Windows has not responded yet. Wait for Windows to finish starting, then check the connection again."
        case "guest_agent_unavailable": return "Install or start Perpendicular Guest Tools inside Windows, then check the connection again."
        default: return "Guest Tools are not connected. Make sure Windows is running and Guest Tools are installed, then check the connection again."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "arrow.left.arrow.right.circle.fill").font(.system(size: 36)).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Share with Windows.").font(.system(size: 21, weight: .semibold, design: .rounded))
                        Text("Copy text and send small files when you choose. Your clipboards are never shared automatically.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Circle().fill(connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                        Text(connectionLabel).font(.headline)
                        Spacer()
                        if tools.checkingVMID == vm.id { ProgressView().controlSize(.small) }
                        Button("Check Connection") { Task { await tools.checkStatus(for: vm) } }.disabled(tools.isBusy || !library.canControl)
                    }
                    if !connected {
                        Text(connectionInstruction)
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let reason = status?.reason, vm.state == "running" {
                            DisclosureGroup("Connection Details") {
                                Text(reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let version = status?.agentVersion {
                        Text("Perpendicular Guest Tools \(version)").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

                VStack(spacing: 0) {
                    actionRow(icon: "doc.on.clipboard", title: "Copy text from Windows", description: "Replace your Mac clipboard with the text copied in Windows.") {
                        Button("Copy Text") { Task { await tools.copyFromWindows(vm) } }.disabled(!canUseClipboard).accessibilityLabel("Copy text from Windows")
                    }
                    Divider().padding(.horizontal, 16)
                    actionRow(icon: "clipboard", title: "Send clipboard to Windows", description: "Send the current text on your Mac clipboard to Windows.") {
                        Button("Send Clipboard") { Task { await tools.sendClipboardToWindows(vm) } }.disabled(!canUseClipboard).accessibilityLabel("Send clipboard to Windows")
                    }
                    Divider().padding(.horizontal, 16)
                    actionRow(icon: "doc.badge.arrow.up", title: "Send a file to Windows", description: "Send a file up to 1 MB to your Windows Downloads folder.") {
                        Button("Send File…") { tools.clearFeedback(for: vm.id); showFileTransfer = true }.disabled(!canSendFile).accessibilityLabel("Send file to Windows…")
                    }
                }.background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.07), lineWidth: 1))

                if tools.busyVMID == vm.id {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Contacting Windows…").font(.callout).foregroundStyle(.secondary) }
                }
                if let feedback = tools.feedback[vm.id] {
                    Label(feedback.message, systemImage: feedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(feedback.isError ? Color.orange : Color.green).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if connected, let status {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Reported by Windows").font(.caption.bold()).foregroundStyle(.secondary)
                        HStack(spacing: 28) {
                            Label("Secure Boot: \((status.secureBoot ?? .unknown).label)", systemImage: "checkmark.shield")
                            Label("TPM: \(tpmLabel)", systemImage: "lock.shield")
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(24)
        }.background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 30).padding(.bottom, 18)
            .sheet(isPresented: $showFileTransfer) { SendFileToWindowsView(vm: vm, tools: tools).environmentObject(library) }
            .task(id: "\(vm.id)-\(vm.state)") {
                while !Task.isCancelled {
                    if library.connectionError == nil && !library.isBusy { await tools.checkStatus(for: vm) }
                    try? await Task.sleep(for: .seconds(5))
                }
            }
    }

    private func actionRow<Control: View>(icon: String, title: String, description: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(.blue).frame(width: 30)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control().frame(minWidth: 115, alignment: .trailing)
        }.padding(18)
    }
}

private struct SendFileToWindowsView: View {
    let vm: VirtualMachine
    @ObservedObject var tools: GuestToolsController
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @ViewState<URL?> private var source: URL?
    @ViewState<String> private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Send File to Windows").font(.title2.bold())
            Text("The file will be saved in your Windows Downloads folder. Choose a file up to 1 MB.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Image(systemName: "doc").font(.title).foregroundStyle(.blue)
                Text(source?.lastPathComponent ?? "No file selected").font(.callout).lineLimit(2)
                Spacer()
                Button("Choose File…", action: chooseFile).disabled(tools.isBusy)
            }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 8) {
                Text("Name in Windows").font(.headline)
                TextField("File name", text: $name).textFieldStyle(.roundedBorder)
            }
            if let feedback = tools.feedback[vm.id], feedback.isError {
                Label(feedback.message, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if tools.busyVMID == vm.id { ProgressView().controlSize(.small); Text("Sending…").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(tools.busyVMID != nil)
                Button("Send to Windows") {
                    guard let source else { return }
                    Task { if await tools.sendFile(source, name: name, to: vm) { dismiss() } }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(source == nil || name.isEmpty || tools.isBusy || !library.canControl || vm.state != "running")
            }
        }.padding(28).frame(width: 550).interactiveDismissDisabled(tools.busyVMID != nil)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a File to Send to Windows"
        panel.prompt = "Choose File"
        panel.message = "Choose a file up to 1 MB. It will be copied to Windows when you select Send to Windows."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { source = url; name = url.lastPathComponent }
    }
}
