import AppKit
import SwiftUI

struct GuestDisplayMode: Codable, Hashable, Sendable {
    let width: Int
    let height: Int
}
struct GuestDisplayActual: Decodable, Sendable {
    let width: Int
    let height: Int
    let dpi: Int?
    let deviceName: String
    let adapter: String
    var mode: GuestDisplayMode { .init(width: width, height: height) }
}
struct GuestDisplayLimits: Decodable, Sendable {
    let minWidth: Int
    let minHeight: Int
    let maxWidth: Int
    let maxHeight: Int
    let maxPixels: Int
    let minHostDpi: Int
    let maxHostDpi: Int
    let minIntervalMs: Int
}
struct GuestDisplayStatus: Decodable, Sendable {
    let connected: Bool
    let canResize: Bool
    let code: String?
    let reason: String?
    let current: GuestDisplayActual?
    let modes: [GuestDisplayMode]
    let dpiChangeSupported: Bool
    let limits: GuestDisplayLimits
}
struct GuestDisplayStatusEnvelope: Decodable, Sendable { let display: GuestDisplayStatus }
struct GuestDisplayResizeResult: Decodable, Sendable {
    struct Requested: Decodable, Sendable { let width: Int; let height: Int; let hostDpi: Int }
    let applied: Bool
    let changed: Bool
    let code: String
    let reason: String?
    let requested: Requested
    let actual: GuestDisplayActual?
    let dpiChanged: Bool
    let retryAfterMs: Int
}
struct GuestDisplayResizeEnvelope: Decodable, Sendable { let display: GuestDisplayResizeResult }

protocol GuestDisplayClient: Sendable {
    func guestDisplayStatus(_ vmID: String) async throws -> GuestDisplayStatus
    func resizeGuestDisplay(_ vmID: String, mode: GuestDisplayMode, hostDpi: Int) async throws -> GuestDisplayResizeResult
}

extension EngineClient: GuestDisplayClient {
    func guestDisplayStatus(_ vmID: String) async throws -> GuestDisplayStatus {
        let result: GuestDisplayStatusEnvelope = try await execute(["guest-display-status", vmID])
        return result.display
    }
    func resizeGuestDisplay(_ vmID: String, mode: GuestDisplayMode, hostDpi: Int) async throws -> GuestDisplayResizeResult {
        guard (640...3840).contains(mode.width), (480...2160).contains(mode.height),
              Int64(mode.width) * Int64(mode.height) <= 8_294_400, (96...288).contains(hostDpi) else {
            throw EngineFailure(message: "Choose a supported Windows display size.")
        }
        let result: GuestDisplayResizeEnvelope = try await execute(["guest-display-resize", vmID,
            "--width", String(mode.width), "--height", String(mode.height), "--host-dpi", String(hostDpi)])
        return result.display
    }
}

/// A forwarded RFB hint is pending, never success. Only independent guest and
/// received-framebuffer dimensions can complete one serialized resize attempt.
@MainActor
final class DisplaySizingController: ObservableObject {
    enum Phase: Equatable { case off, checking, ready, adjusting, waiting, fitted(GuestDisplayMode), unavailable, failed }
    @Published var enabled = true { didSet { if oldValue != enabled { preferenceChanged() } } }
    @Published private(set) var phase: Phase = .checking
    @Published private(set) var request: VMConsoleResizeRequest?
    @Published private(set) var message = "Checking automatic display sizing…"
    @Published private(set) var details: String?
    private(set) var capabilities: GuestDisplayStatus?
    private(set) var actualFramebuffer: GuestDisplayMode?
    private var actualGuest: GuestDisplayMode?
    private var client: (any GuestDisplayClient)?
    private var vmID: String?
    private var backendIdentity = ""
    private var active = false
    private var generation = 0
    private var connectionID: UUID?
    private var layout: RFBDesktopLayout?
    private var retiredAcknowledgement: UUID?
    private var viewport: (points: CGSize, scale: CGFloat)?
    private var statusAttempted = false
    private var wantsStatus = false
    @Published private var engineBusy = false
    private var debounce: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var lastAttempt = -Double.infinity
    private let acknowledgementTimeout: Double
    private let confirmationTimeout: Double
    private struct Pending {
        enum Stage { case acknowledgement, guest, framebuffer }
        let request: VMConsoleResizeRequest
        let mode: GuestDisplayMode
        let hostDpi: Int
        var stage: Stage = .acknowledgement
        var guestConfirmed = false
    }
    private var pending: Pending?

    init(acknowledgementTimeout: Double = 3, confirmationTimeout: Double = 8) {
        self.acknowledgementTimeout = acknowledgementTimeout
        self.confirmationTimeout = confirmationTimeout
    }

    var isWorking: Bool { engineBusy || pending != nil }
    var canCheckAgain: Bool { enabled && active && !isWorking }

    func configure(vmID: String, backendIdentity: String, running: Bool, allowed: Bool,
                   client: any GuestDisplayClient) {
        let changedBackend = self.vmID != vmID || self.backendIdentity != backendIdentity
        let changedActive = active != (running && allowed)
        self.vmID = vmID; self.backendIdentity = backendIdentity; self.client = client
        active = running && allowed
        guard changedBackend || changedActive else { return }
        invalidate(clearCapabilities: true)
        if changedBackend {
            connectionID = nil; layout = nil; actualFramebuffer = nil; viewport = nil
            retiredAcknowledgement = nil; lastAttempt = -Double.infinity
        }
        if !enabled { set(.off, "Windows keeps its current resolution.") }
        else if !running { set(.unavailable, "Start or resume Windows to adjust its display.") }
        else if !allowed { set(.unavailable, "Automatic sizing will continue when the current action finishes.") }
        else { ensureStatus() }
    }

    func stop() {
        active = false
        invalidate(clearCapabilities: true)
        connectionID = nil; layout = nil; actualFramebuffer = nil; viewport = nil
        retiredAcknowledgement = nil
        set(.unavailable, "Start Windows to adjust its display.")
    }

    func receive(_ event: VMConsoleDisplayEvent, vmID: String) {
        guard self.vmID == vmID else { return }
        switch event {
        case .connection(let id):
            guard id != connectionID else { return }
            invalidate(clearCapabilities: true)
            connectionID = id; layout = nil; actualFramebuffer = nil
            retiredAcknowledgement = nil; lastAttempt = -Double.infinity
            if enabled && active { ensureStatus() }
        case .viewport(let points, let scale):
            guard points.width.isFinite, points.height.isFinite, scale.isFinite,
                  points.width > 0, points.height > 0, scale > 0 else { return }
            if let viewport, viewport.points == points, viewport.scale == scale { return }
            viewport = (points, scale)
            schedule()
        case .framebuffer(let id, let width, let height):
            guard id == connectionID, width > 0, height > 0 else { return }
            actualFramebuffer = .init(width: width, height: height)
            finishIfConfirmed()
        case .layout(let id, let announcement):
            guard id == connectionID else { return }
            layout = announcement
            if retiredAcknowledgement == id, announcement.reason == 1 {
                // A timed-out/disabled request has no wire ID. Drain its reply
                // before another request can be correlated on this connection.
                retiredAcknowledgement = nil
                schedule()
                return
            }
            if let pending, pending.stage == .acknowledgement {
                switch announcement.acknowledgement {
                case .forwarded: beginGuestResize()
                case .announcement where announcement.reason == 1: beginGuestResize()
                case .rejected: fail("Windows could not accept automatic display sizing.", detail: "The display server rejected the size request.")
                case .unknown where announcement.reason == 1: fail("Automatic sizing is not available with this display.", detail: "The display server returned an unsupported acknowledgement.")
                default: break // An unsolicited layout is never a resize acknowledgement.
                }
            } else { schedule() }
        case .requestQueued(let id, let accepted):
            guard pending?.request.id == id else { return }
            if !accepted { fail("The display is reconnecting. Check Display when it is ready.", detail: "The size hint was not queued on the current display connection.") }
        }
    }

    func checkAgain() {
        guard canCheckAgain else { return }
        invalidate(clearCapabilities: true)
        ensureStatus()
    }

    private func preferenceChanged() {
        invalidate(clearCapabilities: true)
        if enabled { ensureStatus() }
        else { set(.off, "Windows keeps its current resolution.") }
    }

    private func invalidate(clearCapabilities: Bool) {
        generation &+= 1
        debounce?.cancel(); debounce = nil
        timeout?.cancel(); timeout = nil
        if pending?.stage == .acknowledgement { retiredAcknowledgement = connectionID }
        pending = nil; request = nil; wantsStatus = false
        if clearCapabilities {
            capabilities = nil; actualGuest = nil; statusAttempted = false; details = nil
        }
    }

    private func ensureStatus() {
        guard enabled, active, connectionID != nil, let vmID, let client else {
            if enabled && active { set(.checking, "Waiting for the Windows display…") }
            return
        }
        guard !statusAttempted else { schedule(); return }
        guard !engineBusy else { wantsStatus = true; return }
        statusAttempted = true; engineBusy = true; wantsStatus = false
        let currentGeneration = generation
        set(.checking, "Checking automatic display sizing…")
        Task { [weak self] in
            let result: Result<GuestDisplayStatus, Error>
            do { result = .success(try await client.guestDisplayStatus(vmID)) }
            catch { result = .failure(error) }
            guard let self else { return }
            self.engineBusy = false
            if currentGeneration == self.generation, self.active, self.enabled {
                switch result {
                case .success(let status):
                    self.capabilities = status
                    self.actualGuest = status.current?.mode
                    if !status.connected {
                        self.set(.unavailable, "Install or reconnect Guest Tools to fit Windows to the window.", detail: status.reason)
                    } else if !status.canResize || !Self.valid(status) {
                        self.set(.unavailable, "This Windows display cannot change resolution yet.", detail: status.reason)
                    } else { self.schedule() }
                case .failure(let error):
                    self.set(.unavailable, "Automatic display sizing is unavailable. Check Guest Tools, then try again.", detail: error.localizedDescription)
                }
            }
            self.afterEngineOperation()
        }
    }

    private func afterEngineOperation() {
        if wantsStatus && active && enabled { ensureStatus() }
    }

    private func schedule() {
        guard enabled, active, pending == nil, let capabilities,
              capabilities.connected, capabilities.canResize, Self.valid(capabilities) else { return }
        guard retiredAcknowledgement == nil else {
            set(.unavailable, "The display has not replied yet. Automatic sizing will wait for it to reconnect.")
            return
        }
        guard layout?.singleScreenID != nil else {
            set(.unavailable, "Automatic sizing is not available with this display.")
            return
        }
        guard let target = targetMode() else { return }
        if actualFramebuffer == target.mode, actualGuest == target.mode {
            debounce?.cancel(); debounce = nil
            set(.fitted(target.mode), "Windows display: \(target.mode.width) × \(target.mode.height)")
            return
        }
        debounce?.cancel()
        set(.ready, "Windows will adjust after you finish resizing the window.")
        let currentGeneration = generation
        let interval = max(0.75, Double(capabilities.limits.minIntervalMs) / 1000)
        let delay = max(0.75, lastAttempt + interval - ProcessInfo.processInfo.systemUptime)
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.generation == currentGeneration else { return }
            self.beginRequest()
        }
    }

    private func targetMode() -> (mode: GuestDisplayMode, dpi: Int)? {
        guard let capabilities, let viewport else { return nil }
        let scale = min(3, max(1, Double(viewport.scale)))
        let width = min(3840, max(1, Int(min(3840, Double(viewport.points.width) * scale))))
        let height = min(2160, max(1, Int(min(2160, Double(viewport.points.height) * scale))))
        guard let mode = Self.fittingMode(in: capabilities, width: width, height: height) else { return nil }
        let dpi = min(capabilities.limits.maxHostDpi, max(capabilities.limits.minHostDpi, Int((96 * scale).rounded())))
        return (mode, dpi)
    }

    static func fittingMode(in status: GuestDisplayStatus, width: Int, height: Int) -> GuestDisplayMode? {
        guard valid(status) else { return nil }
        let modes = status.modes.filter { valid($0, limits: status.limits) }
        let fitting = modes.filter { $0.width <= width && $0.height <= height }
        func area(_ mode: GuestDisplayMode) -> Int64 { Int64(mode.width) * Int64(mode.height) }
        func aspectError(_ mode: GuestDisplayMode) -> Double { abs(Double(mode.width) / Double(mode.height) - Double(width) / Double(max(1, height))) }
        if !fitting.isEmpty {
            return fitting.sorted { area($0) == area($1) ? aspectError($0) < aspectError($1) : area($0) > area($1) }.first
        }
        return modes.sorted { area($0) == area($1) ? aspectError($0) < aspectError($1) : area($0) < area($1) }.first
    }

    private static func valid(_ status: GuestDisplayStatus) -> Bool {
        let limits = status.limits
        return !status.dpiChangeSupported && !status.modes.isEmpty && status.modes.count <= 128 &&
            Set(status.modes).count == status.modes.count && limits.minWidth >= 640 && limits.minHeight >= 480 &&
            limits.maxWidth <= 3840 && limits.maxHeight <= 2160 && limits.maxWidth >= limits.minWidth && limits.maxHeight >= limits.minHeight &&
            (1...8_294_400).contains(limits.maxPixels) && limits.minHostDpi >= 96 && limits.maxHostDpi <= 288 &&
            limits.maxHostDpi >= limits.minHostDpi && (750...60_000).contains(limits.minIntervalMs) &&
            status.modes.allSatisfy { valid($0, limits: limits) }
    }
    private static func valid(_ mode: GuestDisplayMode, limits: GuestDisplayLimits) -> Bool {
        mode.width >= limits.minWidth && mode.width <= limits.maxWidth && mode.height >= limits.minHeight &&
            mode.height <= limits.maxHeight && Int64(mode.width) * Int64(mode.height) <= Int64(limits.maxPixels)
    }

    private func beginRequest() {
        debounce = nil
        guard enabled, active, !engineBusy, pending == nil, retiredAcknowledgement == nil,
              let connectionID, let screenID = layout?.singleScreenID, let target = targetMode() else { return }
        if actualFramebuffer == target.mode, actualGuest == target.mode { schedule(); return }
        let wire = VMConsoleResizeRequest(id: UUID(), connectionID: connectionID,
            width: target.mode.width, height: target.mode.height, screenID: screenID)
        pending = Pending(request: wire, mode: target.mode, hostDpi: target.dpi)
        lastAttempt = ProcessInfo.processInfo.systemUptime
        set(.adjusting, "Adjusting the Windows display…")
        request = wire
        armTimeout(seconds: acknowledgementTimeout, requestID: wire.id, waitingForAcknowledgement: true)
    }

    private func beginGuestResize() {
        guard var attempt = pending, attempt.stage == .acknowledgement,
              !engineBusy, let client, let vmID else { return }
        attempt.stage = .guest; pending = attempt
        engineBusy = true
        armTimeout(seconds: confirmationTimeout, requestID: attempt.request.id, waitingForAcknowledgement: false)
        let currentGeneration = generation
        Task { [weak self] in
            let result: Result<GuestDisplayResizeResult, Error>
            do { result = .success(try await client.resizeGuestDisplay(vmID, mode: attempt.mode, hostDpi: attempt.hostDpi)) }
            catch { result = .failure(error) }
            guard let self else { return }
            self.engineBusy = false
            if currentGeneration == self.generation, self.pending?.request.id == attempt.request.id, self.active, self.enabled {
                switch result {
                case .success(let response):
                    guard response.applied, !response.dpiChanged, response.actual?.mode == attempt.mode,
                          response.requested.width == attempt.mode.width, response.requested.height == attempt.mode.height,
                          response.requested.hostDpi == attempt.hostDpi else {
                        self.fail("Windows could not adjust the display. Check Display to try again.", detail: response.reason ?? response.code)
                        self.afterEngineOperation()
                        return
                    }
                    self.actualGuest = response.actual?.mode
                    self.pending?.guestConfirmed = true
                    self.pending?.stage = .framebuffer
                    self.set(.waiting, "Waiting for Windows to update the display…")
                    self.finishIfConfirmed()
                case .failure(let error): self.fail("Windows could not adjust the display. Check Guest Tools, then try again.", detail: error.localizedDescription)
                }
            }
            self.afterEngineOperation()
        }
    }

    private func finishIfConfirmed() {
        guard let attempt = pending, attempt.guestConfirmed, actualFramebuffer == attempt.mode else { return }
        timeout?.cancel(); timeout = nil
        pending = nil; request = nil
        set(.fitted(attempt.mode), "Windows display: \(attempt.mode.width) × \(attempt.mode.height)")
        if targetMode()?.mode != attempt.mode { schedule() }
    }

    private func armTimeout(seconds: Double, requestID: UUID, waitingForAcknowledgement: Bool) {
        timeout?.cancel()
        let currentGeneration = generation
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.generation == currentGeneration, self.pending?.request.id == requestID else { return }
            if waitingForAcknowledgement { self.retiredAcknowledgement = self.connectionID }
            self.fail("Windows has not confirmed the new display size. Check Display to try again.",
                detail: waitingForAcknowledgement ? "The display size hint timed out." : "Guest and framebuffer dimensions did not both confirm the requested mode.")
        }
    }

    private func fail(_ message: String, detail: String?) {
        timeout?.cancel(); timeout = nil; debounce?.cancel(); debounce = nil
        pending = nil; request = nil
        // Stop automatic attempts until an explicit capability check or a new
        // VM/backend connection. Further viewport notifications cannot retry.
        capabilities = nil; statusAttempted = true
        set(.failed, message, detail: detail)
    }
    private func set(_ phase: Phase, _ message: String, detail: String? = nil) {
        self.phase = phase; self.message = message; self.details = detail
    }
}
