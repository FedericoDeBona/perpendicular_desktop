import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum DiskExportFormat: String, CaseIterable, Sendable {
    case qcow2
    case raw
    var fileExtension: String { self == .qcow2 ? "qcow2" : "img" }
    var label: String { self == .qcow2 ? "QCOW2 disk (.qcow2)" : "Raw disk image (.img)" }
    var contentType: UTType { UTType(filenameExtension: fileExtension, conformingTo: .data) ?? .data }

    func filename(_ proposed: String) -> String {
        let url = URL(fileURLWithPath: proposed)
        let oldExtension = url.pathExtension.lowercased()
        let base = ["qcow2", "img", "raw"].contains(oldExtension) ? url.deletingPathExtension().lastPathComponent : proposed
        return "\(base).\(fileExtension)"
    }
}

struct DiskExportRequest: Identifiable {
    let id = UUID()
    let vm: VirtualMachine
    let destination: URL
    let format: DiskExportFormat
}

@MainActor
final class DiskExportSavePanelController: NSObject, NSOpenSavePanelDelegate {
    private weak var savePanel: NSSavePanel?
    private(set) var format: DiskExportFormat = .qcow2

    init(panel: NSSavePanel, proposedName: String) {
        self.savePanel = panel
        super.init()
        panel.title = "Export Virtual Machine Disk"
        panel.prompt = "Export Disk"
        panel.message = "Export an independent disk copy. Firmware (EFI), TPM state and snapshots are not included. Choose a new file; existing files will not be replaced."
        panel.allowedContentTypes = [format.contentType]
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false
        panel.canSelectHiddenExtension = false
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = format.filename(proposedName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-"))
        let label = NSTextField(labelWithString: "Disk format:")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 235, height: 28), pullsDown: false)
        popup.addItems(withTitles: DiskExportFormat.allCases.map(\.label))
        popup.target = self
        popup.action = #selector(formatChanged(_:))
        let accessory = NSStackView(views: [label, popup])
        accessory.orientation = .horizontal
        accessory.spacing = 10
        accessory.frame = NSRect(x: 0, y: 0, width: 330, height: 32)
        panel.accessoryView = accessory
        panel.delegate = self
    }

    @objc func formatChanged(_ sender: NSPopUpButton) {
        guard DiskExportFormat.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        format = DiskExportFormat.allCases[sender.indexOfSelectedItem]
        guard let savePanel else { return }
        savePanel.allowedContentTypes = [format.contentType]
        savePanel.nameFieldStringValue = format.filename(savePanel.nameFieldStringValue)
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard url.pathExtension.lowercased() == format.fileExtension else {
            throw EngineFailure(message: "Use the .\(format.fileExtension) extension for the selected disk format.")
        }
        guard !Self.destinationExists(url) else {
            throw EngineFailure(message: "An item already exists at this destination. Choose a new file name; disk exports never replace existing files.")
        }
    }

    func panel(_ sender: Any, userEnteredFilename filename: String, confirmed okFlag: Bool) -> String? {
        guard okFlag, let directory = savePanel?.directoryURL else { return filename }
        let extensionAlreadyMatches = URL(fileURLWithPath: filename).pathExtension.lowercased() == format.fileExtension
        let candidate = directory.appendingPathComponent(extensionAlreadyMatches ? filename : format.filename(filename))
        if Self.destinationExists(candidate) {
            let alert = NSAlert()
            alert.messageText = "Choose a New File Name"
            alert.informativeText = "An item already exists at this destination. Disk exports never replace existing files."
            alert.addButton(withTitle: "Choose Another Name")
            alert.runModal()
            return nil
        }
        return filename
    }

    static func destinationExists(_ url: URL) -> Bool {
        // attributesOfItem also detects dangling symbolic links, unlike fileExists.
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}

@MainActor
func chooseDiskExport(for vm: VirtualMachine) -> DiskExportRequest? {
    let panel = NSSavePanel()
    let controller = DiskExportSavePanelController(panel: panel, proposedName: vm.name)
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return DiskExportRequest(vm: vm, destination: url, format: controller.format)
}

struct DiskExportProgressView: View {
    let request: DiskExportRequest
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @ViewState<ExportedDisk?> private var exported: ExportedDisk?
    @ViewState<String?> private var localError: String?
    private var finished: Bool { exported != nil || localError != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: exported != nil ? "checkmark.circle.fill" : "square.and.arrow.up")
                    .font(.system(size: 34)).foregroundStyle(exported != nil ? Color.green : Color.blue)
                VStack(alignment: .leading, spacing: 5) {
                    Text(exported != nil ? "Disk Exported" : (localError != nil ? "Disk Export Failed" : "Exporting Disk…")).font(.title2.bold())
                    Text(request.vm.name).font(.callout).foregroundStyle(.secondary)
                }
            }
            if !finished {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Creating an independent disk copy. Large disks may take a while.").font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(request.destination.lastPathComponent).font(.headline).textSelection(.enabled)
                Text(request.destination.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                Text(request.format.label).font(.caption).foregroundStyle(.secondary)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            Text("This export contains the disk only. Firmware (EFI), TPM state and snapshots are not included.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let localError {
                Label(localError, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if let exported {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: exported.path)]) }
                }
                Button(finished ? "Done" : "Exporting…") { dismiss() }.keyboardShortcut(.defaultAction).disabled(!finished)
            }
        }.padding(28).frame(width: 560).interactiveDismissDisabled(!finished)
            .task(id: request.id) {
                do { exported = try await library.exportDisk(vmID: request.vm.id, destination: request.destination, format: request.format.rawValue) }
                catch { localError = error.localizedDescription }
            }
    }
}
