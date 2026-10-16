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

/// The shared engine queue may be occupied after a resize is scheduled. Recheck
/// admission immediately before process launch; an already-started request cannot
/// be revoked, and its eventual reply must still pass the controller's guards.
final class GuestDisplayMutationPermit: @unchecked Sendable {
    private let lock = NSLock()
    private let deadline: Double
    private var revoked = false
    init(deadline: Double) { self.deadline = deadline }
    func revoke() { lock.lock(); defer { lock.unlock() }; revoked = true }
    func validate() throws {
        lock.lock(); defer { lock.unlock() }
        guard !revoked, ProcessInfo.processInfo.systemUptime < deadline else {
            throw EngineFailure(message: "The display adjustment is no longer current. Check Display to try again.", code: "display_attempt_expired")
        }
    }
}

protocol GuestDisplayClient: Sendable {
    func guestDisplayStatus(_ vmID: String) async throws -> GuestDisplayStatus
    func resizeGuestDisplay(_ vmID: String, mode: GuestDisplayMode, hostDpi: Int,
                            permit: GuestDisplayMutationPermit?) async throws -> GuestDisplayResizeResult
}

extension EngineClient: GuestDisplayClient {
    func guestDisplayStatus(_ vmID: String) async throws -> GuestDisplayStatus {
        let result: GuestDisplayStatusEnvelope = try await execute(["guest-display-status", vmID])
        return result.display
    }
    func resizeGuestDisplay(_ vmID: String, mode: GuestDisplayMode, hostDpi: Int,
                            permit: GuestDisplayMutationPermit? = nil) async throws -> GuestDisplayResizeResult {
        guard (640...3840).contains(mode.width), (480...2160).contains(mode.height),
              Int64(mode.width) * Int64(mode.height) <= 8_294_400, (96...288).contains(hostDpi) else {
            throw EngineFailure(message: "Choose a supported Windows display size.")
        }
        let result: GuestDisplayResizeEnvelope = try await execute(["guest-display-resize", vmID,
            "--width", String(mode.width), "--height", String(mode.height), "--host-dpi", String(hostDpi)],
            beforeExecution: { try permit?.validate() })
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
    private var wasRunning = false
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
    private let bootstrapDelays: [Double]
    private let bootstrapWindow: Double
    private struct Bootstrap {
        enum State { case waiting, connected, exhausted }
        let deadline: Double
        var attempts = 0
        var state: State = .waiting
    }
    private var bootstrap: Bootstrap?
    private var bootstrapRetry: Task<Void, Never>?
    private var bootstrapExpiry: Task<Void, Never>?
    private struct Pending {
        enum Stage { case acknowledgement, guest, recovery, framebuffer }
        let request: VMConsoleResizeRequest
        let mode: GuestDisplayMode
        let hostDpi: Int
        var stage: Stage = .acknowledgement
        var guestConfirmed = false
        var recoveryUsed = false
        var confirmationDeadline: Double?
        var permit: GuestDisplayMutationPermit?
    }
    private var pending: Pending?

    // Windows cold boot can outlast a minute before the interactive Guest Tools
    // task starts. This is admission for startup transport failures only: at
    // most 12 observations within one absolute three-minute window, never a
    // refreshed budget on viewport/tab changes or retries of terminal errors.
    nonisolated static let defaultBootstrapDelays: [Double] = [2, 5, 10, 20, 20, 20, 20, 20, 20, 20, 20]
    nonisolated static let defaultBootstrapWindow: Double = 180

    init(acknowledgementTimeout: Double = 3, confirmationTimeout: Double = 8,
         bootstrapDelays: [Double] = DisplaySizingController.defaultBootstrapDelays,
         bootstrapWindow: Double = DisplaySizingController.defaultBootstrapWindow) {
        self.acknowledgementTimeout = acknowledgementTimeout
        self.confirmationTimeout = confirmationTimeout
        self.bootstrapDelays = bootstrapDelays
        self.bootstrapWindow = bootstrapWindow
    }

    var isWorking: Bool { engineBusy || pending != nil }
    var canCheckAgain: Bool { enabled && active && !isWorking }

    func configure(vmID: String, backendIdentity: String, running: Bool, allowed: Bool,
                   client: any GuestDisplayClient) {
        let changedBackend = self.vmID != vmID || self.backendIdentity != backendIdentity
        let changedActive = active != (running && allowed)
        let beganRunning = running && !wasRunning
        wasRunning = running
        self.vmID = vmID; self.backendIdentity = backendIdentity; self.client = client
        active = running && allowed
        guard changedBackend || changedActive || beganRunning else { return }
        invalidate(clearCapabilities: true)
        if changedBackend || beganRunning { bootstrap = nil }
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
            if let attempt = pending, attempt.recoveryUsed, !retryTargetIsCurrent(attempt) { failChangedRecoveryTarget() }
            else { schedule() }
        case .framebuffer(let id, let width, let height):
            guard id == connectionID, width > 0, height > 0 else { return }
            actualFramebuffer = .init(width: width, height: height)
            finishIfConfirmed()
        case .layout(let id, let announcement):
            guard id == connectionID else { return }
            layout = announcement
            if let attempt = pending, attempt.recoveryUsed, !retryTargetIsCurrent(attempt) {
                failChangedRecoveryTarget()
                return
            }
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
        finishBootstrap(connected: false)
        invalidate(clearCapabilities: true)
        ensureStatus(manual: true)
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
        bootstrapRetry?.cancel(); bootstrapRetry = nil
        bootstrapExpiry?.cancel(); bootstrapExpiry = nil
        if pending?.stage == .acknowledgement { retiredAcknowledgement = connectionID }
        pending?.permit?.revoke()
        pending = nil; request = nil; wantsStatus = false
        if clearCapabilities {
            capabilities = nil; actualGuest = nil; statusAttempted = false; details = nil
        }
    }

    private func ensureStatus(manual: Bool = false) {
        guard enabled, active, connectionID != nil, let vmID, let client else {
            if enabled && active { set(.checking, "Waiting for the Windows display…") }
            return
        }
        guard !statusAttempted else { schedule(); return }
        guard !engineBusy else { wantsStatus = true; return }
        if !manual {
            if bootstrap == nil { bootstrap = Bootstrap(deadline: ProcessInfo.processInfo.systemUptime + bootstrapWindow) }
            if bootstrap?.state == .exhausted {
                set(.unavailable, "Check Guest Tools, then Check Display to try again.")
                return
            }
            if bootstrap?.state == .waiting {
                guard let budget = bootstrap, budget.attempts <= bootstrapDelays.count,
                      ProcessInfo.processInfo.systemUptime < budget.deadline else {
                    finishBootstrap(connected: false)
                    set(.unavailable, "Check Guest Tools, then Check Display to try again.")
                    return
                }
                bootstrap?.attempts += 1
                armBootstrapExpiry()
            }
        }
        let checkingBootstrap = bootstrap?.state == .waiting
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
                if checkingBootstrap, self.bootstrap?.state != .waiting ||
                    (checkingBootstrap && ProcessInfo.processInfo.systemUptime >= (self.bootstrap?.deadline ?? -.infinity)) {
                    self.finishBootstrap(connected: false)
                    self.set(.unavailable, "Check Guest Tools, then Check Display to try again.")
                    self.afterEngineOperation()
                    return
                }
                switch result {
                case .success(let status):
                    self.capabilities = status
                    self.actualGuest = status.current?.mode
                    if !status.connected {
                        if !self.retryBootstrap(code: status.code) {
                            self.set(.unavailable, "Install or reconnect Guest Tools to fit Windows to the window.", detail: status.reason)
                        }
                    } else if !status.canResize || !Self.valid(status) {
                        self.finishBootstrap(connected: true)
                        self.set(.unavailable, "This Windows display cannot change resolution yet.", detail: status.reason)
                    } else { self.finishBootstrap(connected: true); self.schedule() }
                case .failure(let error):
                    if !self.retryBootstrap(code: (error as? EngineFailure)?.code) {
                        self.set(.unavailable, "Automatic display sizing is unavailable. Check Guest Tools, then try again.", detail: error.localizedDescription)
                    }
                }
            }
            self.afterEngineOperation()
        }
    }

    private func finishBootstrap(connected: Bool) {
        bootstrapRetry?.cancel(); bootstrapRetry = nil
        bootstrapExpiry?.cancel(); bootstrapExpiry = nil
        if connected { bootstrap?.state = .connected }
        else if bootstrap?.state == .waiting { bootstrap?.state = .exhausted }
    }

    private func armBootstrapExpiry() {
        guard bootstrapExpiry == nil, let budget = bootstrap, budget.state == .waiting else { return }
        let currentGeneration = generation
        bootstrapExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, budget.deadline - ProcessInfo.processInfo.systemUptime))) } catch { return }
            guard let self, self.generation == currentGeneration, self.active, self.enabled,
                  self.bootstrap?.state == .waiting else { return }
            self.finishBootstrap(connected: false)
            self.capabilities = nil; self.actualGuest = nil; self.statusAttempted = true
            self.set(.unavailable, "Check Guest Tools, then Check Display to try again.")
        }
    }

    private func retryBootstrap(code: String?) -> Bool {
        guard ["guest_agent_timeout", "guest_agent_unavailable"].contains(code ?? ""),
              let budget = bootstrap, budget.state == .waiting, budget.attempts > 0,
              budget.attempts <= bootstrapDelays.count else {
            finishBootstrap(connected: false)
            return false
        }
        let delay = bootstrapDelays[budget.attempts - 1]
        guard ProcessInfo.processInfo.systemUptime + delay < budget.deadline else {
            finishBootstrap(connected: false)
            return false
        }
        let currentGeneration = generation
        set(.checking, "Waiting for Guest Tools to start…")
        bootstrapRetry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.generation == currentGeneration, self.active, self.enabled,
                  self.bootstrap?.state == .waiting else { return }
            self.bootstrapRetry = nil; self.statusAttempted = false
            self.ensureStatus()
        }
        return true
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
              !engineBusy else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + confirmationTimeout
        attempt.confirmationDeadline = deadline
        attempt.permit = GuestDisplayMutationPermit(deadline: deadline)
        attempt.stage = .guest; pending = attempt
        armTimeout(seconds: confirmationTimeout, requestID: attempt.request.id, waitingForAcknowledgement: false)
        sendGuestResize(attempt)
    }

    private func isCurrent(_ attempt: Pending, generation: Int) -> Bool {
        generation == self.generation && active && enabled && connectionID == attempt.request.connectionID &&
            pending?.request.id == attempt.request.id &&
            ProcessInfo.processInfo.systemUptime < (attempt.confirmationDeadline ?? -.infinity)
    }

    private func sendGuestResize(_ attempt: Pending) {
        let currentGeneration = generation
        guard isCurrent(attempt, generation: currentGeneration), !engineBusy, let client, let vmID else { return }
        pending?.stage = .guest
        engineBusy = true
        lastAttempt = ProcessInfo.processInfo.systemUptime
        Task { [weak self] in
            let result: Result<GuestDisplayResizeResult, Error>
            do { result = .success(try await client.resizeGuestDisplay(vmID, mode: attempt.mode, hostDpi: attempt.hostDpi, permit: attempt.permit)) }
            catch { result = .failure(error) }
            guard let self else { return }
            self.engineBusy = false
            if self.isCurrent(attempt, generation: currentGeneration) {
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
                case .failure(let error):
                    if let failure = error as? EngineFailure, !attempt.recoveryUsed,
                       ["guest_agent_timeout", "guest_agent_unavailable"].contains(failure.code ?? "") {
                        self.recoverGuestResize(attempt, after: failure)
                    } else {
                        self.fail("Windows could not adjust the display. Check Guest Tools, then try again.", detail: error.localizedDescription)
                    }
                }
            }
            self.afterEngineOperation()
        }
    }

    private func recoverGuestResize(_ attempt: Pending, after failure: EngineFailure) {
        let currentGeneration = generation
        guard isCurrent(attempt, generation: currentGeneration), !engineBusy, let client, let vmID else { return }
        var recovery = attempt
        recovery.recoveryUsed = true; recovery.stage = .recovery
        pending = recovery
        // A shared-queue delay can separate admission from actual execution.
        // Throttle the retry from completion of the failed command as well.
        lastAttempt = ProcessInfo.processInfo.systemUptime
        engineBusy = true
        set(.checking, "Checking the Windows display after a connection problem…", detail: failure.localizedDescription)
        // Keep the original confirmation timer. A transport error grants one
        // status observation and at most one retry, never more time or RFB hints.
        Task { [weak self] in
            let result: Result<GuestDisplayStatus, Error>
            do { result = .success(try await client.guestDisplayStatus(vmID)) }
            catch { result = .failure(error) }
            guard let self else { return }
            self.engineBusy = false
            if self.isCurrent(recovery, generation: currentGeneration) {
                switch result {
                case .success(let status):
                    guard status.connected, status.canResize, Self.valid(status), let measured = status.current?.mode else {
                        self.fail("Windows could not confirm its display. Check Guest Tools, then try again.", detail: status.reason ?? status.code)
                        self.afterEngineOperation()
                        return
                    }
                    self.capabilities = status; self.actualGuest = measured
                    if measured == recovery.mode {
                        self.pending?.guestConfirmed = true; self.pending?.stage = .framebuffer
                        self.set(.waiting, "Waiting for Windows to update the display…")
                        self.finishIfConfirmed()
                    } else if self.retryTargetIsCurrent(recovery) {
                        let interval = max(0.75, Double(status.limits.minIntervalMs) / 1000)
                        let delay = max(0, self.lastAttempt + interval - ProcessInfo.processInfo.systemUptime)
                        self.set(.adjusting, "Retrying the Windows display adjustment…", detail: failure.localizedDescription)
                        self.debounce = Task { [weak self] in
                            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                            guard let self, self.isCurrent(recovery, generation: currentGeneration) else { return }
                            self.debounce = nil
                            if self.retryTargetIsCurrent(recovery) { self.sendGuestResize(recovery) }
                            else { self.failChangedRecoveryTarget() }
                        }
                    } else { self.failChangedRecoveryTarget() }
                case .failure(let error):
                    self.fail("Windows could not confirm its display. Check Guest Tools, then try again.", detail: error.localizedDescription)
                }
            }
            self.afterEngineOperation()
        }
    }

    private func retryTargetIsCurrent(_ attempt: Pending) -> Bool {
        guard let capabilities, capabilities.modes.contains(attempt.mode), let target = targetMode() else { return false }
        return target.mode == attempt.mode && target.dpi == attempt.hostDpi && layout?.singleScreenID == attempt.request.screenID
    }

    private func failChangedRecoveryTarget() {
        fail("The window or display changed during recovery. Check Display to try again.", detail: nil)
    }

    private func finishIfConfirmed() {
        guard let attempt = pending, isCurrent(attempt, generation: generation),
              attempt.guestConfirmed, actualFramebuffer == attempt.mode else { return }
        timeout?.cancel(); timeout = nil
        attempt.permit?.revoke()
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
        pending?.permit?.revoke()
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
