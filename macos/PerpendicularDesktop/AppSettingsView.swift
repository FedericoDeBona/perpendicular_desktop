import AppKit
import SwiftUI

struct AppSettingsView: View {
    @EnvironmentObject private var library: LibraryModel
    @ViewState<String> private var tab = "general"

    init(initialTab: String = "general") { _tab = ViewState(initialValue: initialTab) }

    var body: some View {
        TabView(selection: $tab) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    PerpendicularMark(size: 54)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Perpendicular Desktop").font(.title2.bold())
                        Text("An open source home for Windows on Mac.").foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text("Virtual machine storage").font(.headline)
                Text(library.host?.dataDir ?? "Storage location is unavailable until the engine connects.").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                Button("Show in Finder") {
                    if let path = library.host?.dataDir { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                }.disabled(library.host == nil)
                Button("Show Deleted Virtual Machines") {
                    if let path = library.host?.dataDir {
                        let trash = URL(fileURLWithPath: path).appendingPathComponent("Trash")
                        if FileManager.default.fileExists(atPath: trash.path) { NSWorkspace.shared.open(trash) }
                        else { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    }
                }.disabled(library.host == nil)
                }
                Spacer()
                Text("Windows and third-party software require their own licenses. Perpendicular does not include a Windows license.").font(.caption).foregroundStyle(.secondary)
            }.padding(28).tabItem { Label("General", systemImage: "gearshape") }.tag("general")

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("System Readiness").font(.title2.bold())
                        Text("Components available on this Mac.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check Again") { Task { await library.checkHost() } }.disabled(library.isBusy)
                }
                if let host = library.host {
                    Form {
                        Section("Components") {
                        dependency("Apple Hypervisor", ready: host.hypervisorAvailable, detail: host.hypervisorAvailable ? "Available" : "Unavailable")
                        dependency("Virtualization backend", ready: host.qemuPath != nil, detail: host.qemuPath)
                        dependency("Disk tools", ready: host.qemuImgPath != nil, detail: host.qemuImgPath)
                        dependency("UEFI firmware", ready: host.firmwareCodePath != nil && host.firmwareVarsPath != nil, detail: host.firmwareCodePath)
                        dependency("TPM 2.0", ready: host.swtpmPath != nil, detail: host.swtpmPath)
                        LabeledContent("Secure Boot") {
                            Text(host.secureBootVerified == true ? "Verified" : (host.firmwareSecureBootCapable == true ? "Guest verification needed" : "Unavailable"))
                                .foregroundStyle(host.secureBootVerified == true ? Color.secondary : Color.orange)
                        }
                        }
                        if let readiness = host.windowsReadiness {
                            Section("Windows readiness") {
                                LabeledContent("Graphics") { Text(readiness.graphics).multilineTextAlignment(.trailing).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                                LabeledContent("Network") { Text(readiness.network).multilineTextAlignment(.trailing).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                                LabeledContent("TPM service", value: readiness.tpmAvailable ? "Available" : "Unavailable")
                                LabeledContent("Secure Boot evidence") { Text(readiness.secureBoot.replacingOccurrences(of: "_", with: " ").capitalized).multilineTextAlignment(.trailing).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }.formStyle(.grouped)
                    Text("\(host.architecture) · \(host.memoryGib) GB unified memory").font(.caption).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView("System Information Unavailable", systemImage: "exclamationmark.triangle", description: Text(library.hostError ?? "Check again to inspect the virtualization components."))
                }
                if library.host != nil, let hostError = library.hostError {
                    Label(hostError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }.padding(28).tabItem { Label("System", systemImage: "cpu") }.tag("system")
        }.frame(width: 640, height: 460)
    }

    private func dependency(_ name: String, ready: Bool, detail: String?) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(ready ? "Available" : "Missing").foregroundStyle(ready ? .secondary : Color.orange)
                Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(ready ? Color.green : Color.orange)
            }.help(detail ?? "This component has not been installed.")
        } label: { Text(name) }
    }
}
