import AppKit
import Foundation
import SwiftUI

enum GuestReportedBoolean: Decodable, Sendable, Equatable {
    case known(Bool)
    case unknown

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let boolean = try? value.decode(Bool.self) { self = .known(boolean) }
        else if let string = try? value.decode(String.self), string == "unknown" { self = .unknown }
        else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Expected a reported boolean or unknown") }
    }

    var label: String {
        switch self { case .known(true): "On"; case .known(false): "Off"; case .unknown: "Unknown" }
    }
}

struct GuestCapabilities: Decodable, Sendable {
    let clipboard: Bool?
    let fileWrite: Bool?
    let maxClipboardBytes: Int?
    let maxFileBytes: Int?
}

struct GuestTPMStatus: Decodable, Sendable {
    let present: GuestReportedBoolean?
    let ready: GuestReportedBoolean?
}

struct GuestToolsStatus: Decodable, Sendable {
    let connected: Bool
    let agentVersion: String?
    let code: String?
    let reason: String?
    let capabilities: GuestCapabilities
    let secureBoot: GuestReportedBoolean?
    let tpm: GuestTPMStatus?

    static func unavailable(_ reason: String) -> Self {
        Self(connected: false, agentVersion: nil, code: nil, reason: reason,
             capabilities: GuestCapabilities(clipboard: false, fileWrite: false, maxClipboardBytes: nil, maxFileBytes: nil),
             secureBoot: nil, tpm: nil)
    }
}

struct GuestStatusResult: Decodable, Sendable { let status: GuestToolsStatus }
struct GuestClipboardResult: Decodable, Sendable { let text: String }
struct GuestWriteResult: Decodable, Sendable { let written: Bool }
struct GuestFileResult: Decodable, Sendable { let name: String; let bytesWritten: Int; let path: String }

struct GuestTransferFeedback: Sendable {
    let message: String
    let isError: Bool
}

@MainActor
protocol GuestClipboard {
    func readText() -> String?
    func replaceText(_ text: String) throws
}

@MainActor
struct SystemGuestClipboard: GuestClipboard {
    func readText() -> String? { NSPasteboard.general.string(forType: .string) }
    func replaceText(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw EngineFailure(message: "macOS could not update the clipboard. Try copying the text again.")
        }
    }
}

/// Readiness never reads or writes clipboard contents. Each transfer is an
/// explicit user action over the same serial engine transport as VM lifecycle.
@MainActor
final class GuestToolsController: ObservableObject {
    @Published private(set) var statuses: [String: GuestToolsStatus] = [:]
    @Published private(set) var checkingVMID: String?
    @Published private(set) var busyVMID: String?
    @Published private(set) var feedback: [String: GuestTransferFeedback] = [:]
    private let engine: EngineClient
    private let clipboard: any GuestClipboard

    init(engine: EngineClient, clipboard: (any GuestClipboard)? = nil) {
        self.engine = engine
        self.clipboard = clipboard ?? SystemGuestClipboard()
    }

    var isBusy: Bool { busyVMID != nil || checkingVMID != nil }
    func clearFeedback(for vmID: String) { feedback[vmID] = nil }

    func checkStatus(for vm: VirtualMachine) async {
        guard !isBusy else { return }
        guard vm.state == "running" else {
            statuses[vm.id] = .unavailable(vm.state == "paused" ? "Resume Windows to connect Guest Tools." : "Start Windows to connect Guest Tools.")
            return
        }
        checkingVMID = vm.id
        defer { checkingVMID = nil }
        do {
            let result: GuestStatusResult = try await engine.execute(["guest-status", vm.id])
            statuses[vm.id] = result.status
        } catch { statuses[vm.id] = .unavailable(error.localizedDescription) }
    }

    func copyFromWindows(_ vm: VirtualMachine) async {
        guard begin(vm, capability: .clipboard) else { return }
        defer { busyVMID = nil }
        do {
            let result: GuestClipboardResult = try await engine.execute(["guest-clipboard-read", vm.id])
            guard result.text.utf8.count <= clipboardLimit(for: vm.id) else {
                throw EngineFailure(message: "The text from Windows exceeds the supported clipboard size.")
            }
            try clipboard.replaceText(result.text)
            feedback[vm.id] = GuestTransferFeedback(message: "Text from Windows is now on your Mac clipboard.", isError: false)
        } catch { failure(error, for: vm.id) }
    }

    func sendClipboardToWindows(_ vm: VirtualMachine) async {
        guard begin(vm, capability: .clipboard) else { return }
        defer { busyVMID = nil }
        do {
            guard let text = clipboard.readText() else {
                throw EngineFailure(message: "Your Mac clipboard does not contain text.")
            }
            guard text.utf8.count <= clipboardLimit(for: vm.id) else {
                throw EngineFailure(message: "The clipboard text is too large. Send a smaller selection (up to 256 KB).")
            }
            // Keep explicitly shared text out of process arguments and diagnostics.
            let files = FileManager.default
            let temporary = files.temporaryDirectory.appendingPathComponent("perpendicular-clipboard-\(UUID().uuidString)")
            try files.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? files.removeItem(at: temporary) }
            let payload = temporary.appendingPathComponent("text.utf8")
            guard files.createFile(atPath: payload.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw EngineFailure(message: "macOS could not prepare the clipboard text for transfer.")
            }
            let result: GuestWriteResult = try await engine.execute(["guest-clipboard-write", vm.id, "--text-file", payload.path])
            guard result.written else { throw EngineFailure(message: "Windows did not confirm that its clipboard was updated.") }
            feedback[vm.id] = GuestTransferFeedback(message: "Your Mac clipboard text was sent to Windows.", isError: false)
        } catch { failure(error, for: vm.id) }
    }

    @discardableResult
    func sendFile(_ source: URL, name: String, to vm: VirtualMachine) async -> Bool {
        guard begin(vm, capability: .file) else { return false }
        defer { busyVMID = nil }
        do {
            let resource = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard resource.isRegularFile == true, let size = resource.fileSize else {
                throw EngineFailure(message: "Choose a regular file to send to Windows.")
            }
            let limit = min(statuses[vm.id]?.capabilities.maxFileBytes ?? 1_048_576, 1_048_576)
            guard size <= limit else { throw EngineFailure(message: "This file is too large. Choose a file up to 1 MB.") }
            let result: GuestFileResult = try await engine.execute(["guest-file-push", vm.id, "--source", source.path, "--name", name])
            guard result.bytesWritten == size else {
                throw EngineFailure(message: "Windows did not confirm the complete file transfer. Check Downloads before trying again.")
            }
            // A guest path is text only. It must never be opened as a host path.
            feedback[vm.id] = GuestTransferFeedback(message: "Sent “\(result.name)” to Windows Downloads.", isError: false)
            return true
        } catch { failure(error, for: vm.id); return false }
    }

    private enum Capability { case clipboard, file }

    private func begin(_ vm: VirtualMachine, capability: Capability) -> Bool {
        guard !isBusy else { return false }
        guard vm.state == "running", let status = statuses[vm.id], status.connected else {
            feedback[vm.id] = GuestTransferFeedback(message: "Guest Tools are not connected. Start Windows and install Guest Tools, then check the connection again.", isError: true)
            return false
        }
        let supported = capability == .clipboard ? status.capabilities.clipboard == true : status.capabilities.fileWrite == true
        guard supported else {
            feedback[vm.id] = GuestTransferFeedback(message: "The connected Guest Tools do not support this action.", isError: true)
            return false
        }
        feedback[vm.id] = nil
        busyVMID = vm.id
        return true
    }

    private func clipboardLimit(for id: String) -> Int { min(statuses[id]?.capabilities.maxClipboardBytes ?? 262_144, 262_144) }
    private func failure(_ error: Error, for id: String) { feedback[id] = GuestTransferFeedback(message: error.localizedDescription, isError: true) }
}
