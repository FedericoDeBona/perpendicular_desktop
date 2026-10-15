import AppKit
import Foundation
import SwiftUI

struct VirtualMachine: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var state: String
    var cpus: Int
    var memoryMib: Int
    var diskGib: Int
    var isoPath: String?
    var directory: String
    var diskPath: String
    var createdAt: String
    var backend: String
    var qmpSocket: String
    var vncSocket: String
    var lastError: String?
    var tpmEnabled: Bool?
    var secureBootState: String?
    var guestToolsIsoPath: String?
    var keyboardLayout: String?
    var audioOutput: Bool?

    var isActive: Bool { ["running", "paused", "starting", "stopping"].contains(state) }
    var isStopped: Bool { ["stopped", "crashed"].contains(state) }
    var stateLabel: String { state.capitalized }
    var memoryLabel: String { String(format: "%g GB", Double(memoryMib) / 1024) }
    var stateColor: Color {
        switch state {
        case "running": .green
        case "paused": .orange
        case "starting", "stopping": .blue
        case "crashed": .red
        default: .secondary
        }
    }
}

struct HostInfo: Decodable, Sendable {
    let architecture: String
    let memoryBytes: UInt64
    let hypervisorAvailable: Bool
    let qemuPath: String?
    let qemuImgPath: String?
    let firmwareCodePath: String?
    let firmwareVarsPath: String?
    let swtpmPath: String?
    let dataDir: String
    let firmwareSecureBootCapable: Bool?
    let secureBootVerified: Bool?
    let windowsReadiness: WindowsReadiness?
    var memoryGib: Int { Int(memoryBytes / 1_073_741_824) }
    var readyToStart: Bool { hypervisorAvailable && qemuPath != nil && firmwareCodePath != nil && firmwareVarsPath != nil }
}

struct WindowsReadiness: Decodable, Sendable {
    let graphics: String
    let network: String
    let secureBoot: String
    let tpmAvailable: Bool
}

struct VMSnapshot: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let createdAt: String
    var dateLabel: String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? createdAt
    }
}

struct VMInventoryError: Decodable, Sendable {
    struct Detail: Decodable, Sendable { let code: String; let message: String }
    let id: String
    let error: Detail
}
struct VMListResult: Decodable, Sendable { let vms: [VirtualMachine]; let errors: [VMInventoryError]? }
struct VMResult: Decodable, Sendable { let vm: VirtualMachine; let warnings: [String]? }
struct SnapshotListResult: Decodable, Sendable { let snapshots: [VMSnapshot] }
struct CommandResult: Decodable, Sendable {}
struct DiskExportResult: Decodable, Sendable { let export: ExportedDisk }
struct ExportedDisk: Decodable, Sendable {
    let vmId: String
    let path: String
    let format: String
    let virtualSizeBytes: UInt64
    let sizeBytes: UInt64
}
private struct FailureResponse: Decodable {
    struct Detail: Decodable { let code: String; let message: String }
    let error: Detail
}

struct EngineFailure: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// A serial worker owns each short-lived engine process. Polls and actions never overlap.
final class EngineClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.perpendicular.engine", qos: .userInitiated)

    static func executableURL() -> URL? {
        let files = FileManager.default
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["PERPENDICULAR_ENGINE"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("perpendicular-engine"))
        }
        let roots = [URL(fileURLWithPath: files.currentDirectoryPath),
                     URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
                     Bundle.main.bundleURL.deletingLastPathComponent()]
        for root in roots {
            candidates.append(root.appendingPathComponent("engine/target/release/perpendicular-engine"))
            candidates.append(root.appendingPathComponent("engine/target/debug/perpendicular-engine"))
        }
        return candidates.first { files.isExecutableFile(atPath: $0.path) }
    }

    func execute<T: Decodable & Sendable>(_ arguments: [String], as type: T.Type = T.self) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try Self.run(arguments, as: type)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func run<T: Decodable & Sendable>(_ arguments: [String], as type: T.Type) throws -> T {
        guard let executable = executableURL() else {
            throw EngineFailure(message: "The Perpendicular engine could not be found. Reinstall the application, or select a development engine using PERPENDICULAR_ENGINE.")
        }
        let files = FileManager.default
        let temporary = files.temporaryDirectory.appendingPathComponent("perpendicular-command-\(UUID().uuidString)")
        try files.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: temporary) }
        let outputURL = temporary.appendingPathComponent("stdout")
        let errorURL = temporary.appendingPathComponent("stderr")
        files.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        files.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: outputURL)
        let diagnostic = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? diagnostic.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = diagnostic
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Full copies can legitimately take much longer than lifecycle queries.
        let transfer = ["clone", "import-disk", "export-disk"].contains(arguments.first ?? "")
        let deadline = Date().addingTimeInterval(transfer ? 3600 : 180)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(1)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw EngineFailure(message: "The engine took too long to respond. Refresh the library to check the current state before trying again.")
        }
        process.waitUntilExit()
        try output.synchronize()
        let data = try Data(contentsOf: outputURL)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let failure = try? decoder.decode(FailureResponse.self, from: data) {
            throw EngineFailure(message: failure.error.message)
        }
        guard process.terminationStatus == 0 else {
            let stderr = (try? String(contentsOf: errorURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw EngineFailure(message: stderr?.isEmpty == false ? String(stderr!.suffix(3000)) : "The engine could not complete this action (exit \(process.terminationStatus)).")
        }
        do { return try decoder.decode(type, from: data) }
        catch { throw EngineFailure(message: "The engine returned an unreadable response. \(error.localizedDescription)") }
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var machines: [VirtualMachine] = []
    @Published private(set) var host: HostInfo?
    @Published private(set) var isBusy = false
    @Published private(set) var refreshing = false
    @Published private(set) var didLoad = false
    @Published private(set) var connectionError: String?
    @Published private(set) var hostError: String?
    @Published private(set) var inventoryWarnings: [String] = []
    @Published var selectedID: String?
    @Published var errorMessage: String?
    @Published var noticeMessage: String?
    @Published private(set) var operation = ""
    @Published private(set) var snapshots: [VMSnapshot] = []
    @Published private(set) var snapshotVMID: String?
    private let engine: EngineClient
    let guestTools: GuestToolsController
    init() {
        let engine = EngineClient()
        self.engine = engine
        self.guestTools = GuestToolsController(engine: engine)
    }
    var selectedVM: VirtualMachine? { machines.first { $0.id == selectedID } }
    var canControl: Bool { didLoad && connectionError == nil && !isBusy }

    func load() async {
        guard !isBusy else { return }
        do { host = try await engine.execute(["system-info"]); hostError = nil }
        catch { hostError = error.localizedDescription }
        await refresh()
    }

    func refresh() async {
        guard !refreshing, !isBusy else { return }
        refreshing = true
        defer { refreshing = false; didLoad = true }
        do {
            let result: VMListResult = try await engine.execute(["list"])
            machines = result.vms.sorted { $0.createdAt > $1.createdAt }
            inventoryWarnings = result.errors?.map { "Virtual machine \($0.id): \($0.error.message)" } ?? []
            connectionError = nil
            if selectedID == nil { selectedID = machines.first?.id }
            else if !machines.contains(where: { $0.id == selectedID }) { selectedID = machines.first?.id }
        } catch { connectionError = error.localizedDescription }
    }

    func action(_ arguments: [String], operation: String) async -> Bool {
        do {
            try await perform(arguments, operation: operation)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func perform(_ arguments: [String], operation: String) async throws {
        guard !isBusy else { throw EngineFailure(message: "Another action is still in progress. Wait for it to finish, then try again.") }
        isBusy = true
        self.operation = operation
        do {
            let _: CommandResult = try await engine.execute(arguments)
        } catch {
            isBusy = false
            self.operation = ""
            await refresh()
            throw error
        }
        isBusy = false
        self.operation = ""
        await refresh()
    }

    func create(name: String, iso: String, cpus: Int, memory: Int, disk: Int) async throws {
        try await createFromCommand(["create", "--name", name, "--iso", iso, "--cpus", String(cpus), "--memory-mib", String(memory), "--disk-gib", String(disk)], operation: "Creating virtual machine…")
    }

    func clone(_ vm: VirtualMachine, name: String) async throws {
        try await createFromCommand(["clone", vm.id, "--name", name], operation: "Cloning \(vm.name)…")
    }

    func importDisk(name: String, disk: String, cpus: Int, memory: Int, iso: String?) async throws {
        var arguments = ["import-disk", "--name", name, "--disk", disk, "--cpus", String(cpus), "--memory-mib", String(memory)]
        if let iso { arguments += ["--iso", iso] }
        try await createFromCommand(arguments, operation: "Importing virtual disk…")
    }

    func exportDisk(vmID: String, destination: URL, format: String) async throws -> ExportedDisk {
        guard !isBusy else { throw EngineFailure(message: "Another action is still in progress. Wait for it to finish, then try again.") }
        guard connectionError == nil, let vm = machines.first(where: { $0.id == vmID }), vm.state == "stopped" else {
            throw EngineFailure(message: "Shut down the virtual machine and refresh its status before exporting its disk.")
        }
        guard ["qcow2", "raw"].contains(format), destination.isFileURL, destination.path.hasPrefix("/") else {
            throw EngineFailure(message: "Choose a local destination and a supported disk format.")
        }
        isBusy = true
        operation = "Exporting \(vm.name)’s disk…"
        do {
            let result: DiskExportResult = try await engine.execute(["export-disk", vmID, "--destination", destination.path, "--format", format])
            let exportedURL = URL(fileURLWithPath: result.export.path)
            guard result.export.vmId == vmID, result.export.format == format,
                  result.export.virtualSizeBytes > 0, result.export.sizeBytes > 0,
                  exportedURL.resolvingSymlinksInPath().standardizedFileURL == destination.resolvingSymlinksInPath().standardizedFileURL else {
                throw EngineFailure(message: "The engine did not confirm the requested disk export. Check the destination before trying again.")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: exportedURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.uint64Value == result.export.sizeBytes else {
                throw EngineFailure(message: "The exported disk could not be verified at the selected destination.")
            }
            isBusy = false
            operation = ""
            await refresh()
            return result.export
        } catch {
            isBusy = false
            operation = ""
            await refresh()
            throw error
        }
    }

    private func createFromCommand(_ arguments: [String], operation: String) async throws {
        guard !isBusy else { throw EngineFailure(message: "Another action is still in progress. Wait for it to finish, then try again.") }
        isBusy = true
        self.operation = operation
        do {
            let result: VMResult = try await engine.execute(arguments)
            selectedID = result.vm.id
            if let warnings = result.warnings, !warnings.isEmpty { noticeMessage = warnings.joined(separator: "\n\n") }
            isBusy = false
            self.operation = ""
            await refresh()
        } catch {
            isBusy = false
            self.operation = ""
            await refresh()
            throw error
        }
    }

    func loadSnapshots(for vm: VirtualMachine) async {
        guard !isBusy else { return }
        isBusy = true
        operation = "Loading snapshots…"
        defer { isBusy = false; operation = "" }
        do {
            let result: SnapshotListResult = try await engine.execute(["snapshots", vm.id])
            snapshots = result.snapshots
            snapshotVMID = vm.id
        } catch { errorMessage = error.localizedDescription }
    }

    func snapshotAction(_ arguments: [String], for vm: VirtualMachine, operation: String) async -> Bool {
        let result = await action(arguments, operation: operation)
        if result { await loadSnapshots(for: vm) }
        return result
    }

    func checkHost() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do { host = try await engine.execute(["system-info"]); hostError = nil }
        catch { hostError = error.localizedDescription }
    }
}
