import Foundation

#if PERPENDICULAR_NATIVE_DISPLAY
import Darwin
import Metal
import QuartzCore

enum NativeDisplayConnectionState: Equatable, Sendable {
    case connecting, connected, disconnected
}

struct NativeDisplayFailure: Error, Equatable, Sendable {
    let code: Int32
    let systemError: Int32
    let reason: String
}

/// One endpoint/connection lifetime. Construct a new instance to reconnect.
/// Producer frames must be unique immutable allocations; disconnect never
/// authorizes producer reuse of a backing still held by a GPU lease.
@MainActor
final class NativeDisplayConnection {
    private let endpoint: NativeDisplayEndpoint
    private let device: any MTLDevice
    private let onLease: @MainActor (VMExternalDisplayLease) -> Void
    private let onState: @MainActor (NativeDisplayConnectionState) -> Void
    private let onFailure: @MainActor (NativeDisplayFailure) -> Void
    private var worker: NativeDisplayWorker?
    private var mailbox: NativeDisplayMailbox?
    private var started = false
    private var disconnected = false
    private var connectedNotified = false

    init(endpoint: NativeDisplayEndpoint, device: any MTLDevice,
         onLease: @escaping @MainActor (VMExternalDisplayLease) -> Void,
         onState: @escaping @MainActor (NativeDisplayConnectionState) -> Void,
         onFailure: @escaping @MainActor (NativeDisplayFailure) -> Void) {
        self.endpoint = endpoint; self.device = device
        self.onLease = onLease; self.onState = onState; self.onFailure = onFailure
    }

    func start() {
        guard !started, !disconnected else { return }
        started = true
        onState(.connecting)
        guard !disconnected else { return }
        let mailbox = NativeDisplayMailbox { [weak self] delivery in
            guard let self, !self.disconnected else { delivery.retire(); return }
            // Separate actor wakeups need not execute FIFO. A verified frame
            // must never reach the parent before its connected notification.
            self.didConnect()
            guard !self.disconnected else { delivery.retire(); return }
            let timing = delivery.timing.map { VMNativeDisplayTiming(received: $0.received, ready: $0.ready,
                delivered: CACurrentMediaTime()) }
            if let timing { VMDisplayTelemetry.shared?.delivered(timing) }
            let lease = VMExternalDisplayLease(texture: delivery.texture, timing: timing) { _ in delivery.retire() }
            self.onLease(lease)
        }
        self.mailbox = mailbox
        let worker = NativeDisplayWorker(endpoint: endpoint, device: device, mailbox: mailbox) { [weak self] notice in
            Task { @MainActor [weak self] in self?.receive(notice) }
        }
        self.worker = worker
        worker.start()
    }

    func disconnect() {
        guard !disconnected else { return }
        disconnected = true
        // The parent resets its presenter here, before pending deliveries are
        // retired. In-flight lease callbacks still wait for their GPU reads.
        onState(.disconnected)
        mailbox?.cancelPending()
        worker?.stop()
    }

    private func receive(_ notice: NativeDisplayWorkerNotice) {
        guard !disconnected else { return }
        switch notice {
        case .connected: didConnect()
        case .failed(let failure):
            disconnected = true
            onFailure(failure)
            onState(.disconnected)
            mailbox?.cancelPending()
        }
    }

    private func didConnect() {
        guard !disconnected, !connectedNotified else { return }
        connectedNotified = true
        onState(.connected)
    }

    deinit {
        mailbox?.cancelPending()
        worker?.stop()
    }
}

private enum NativeDisplayWorkerNotice: Sendable {
    case connected
    case failed(NativeDisplayFailure)
}

/// Immutable Metal resources may cross queues. Only retire() mutates, under
/// its lock; the C connection/owned frame descriptors stay on the worker queue.
private final class NativeDisplayDelivery: @unchecked Sendable {
    let texture: any MTLTexture
    let timing: VMNativeDisplayTiming?
    private let backing: any MTLBuffer
    private let lock = NSLock()
    private var retirement: (@Sendable () -> Void)?
    init(texture: any MTLTexture, backing: any MTLBuffer, timing: VMNativeDisplayTiming?, retirement: @escaping @Sendable () -> Void) {
        self.texture = texture; self.backing = backing; self.timing = timing; self.retirement = retirement
    }
    func retire() {
        lock.lock(); let callback = retirement; retirement = nil; lock.unlock()
        callback?()
    }
    deinit { retire() }
}

/// Exactly one replaceable not-yet-delivered frame and one queued MainActor
/// wakeup. Retired/coalesced frames never acquire a GPU read.
private final class NativeDisplayMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: NativeDisplayDelivery?
    private var scheduled = false
    private var cancelled = false
    private let consume: @MainActor @Sendable (NativeDisplayDelivery) -> Void
    init(consume: @escaping @MainActor @Sendable (NativeDisplayDelivery) -> Void) { self.consume = consume }
    func offer(_ delivery: NativeDisplayDelivery) {
        lock.lock()
        if cancelled { lock.unlock(); delivery.retire(); return }
        let old = pending; pending = delivery
        let wake = !scheduled; scheduled = true
        lock.unlock()
        if old != nil { VMDisplayTelemetry.shared?.count("mailbox_replaced") }
        old?.retire()
        if wake { Task { @MainActor [self] in drain() } }
    }
    @MainActor private func drain() {
        lock.lock(); let delivery = pending; pending = nil; scheduled = false; lock.unlock()
        if let delivery { consume(delivery) }
    }
    func cancelPending() {
        lock.lock(); cancelled = true; let delivery = pending; pending = nil; lock.unlock()
        delivery?.retire()
    }
}

/// @unchecked is confined to the dispatch boundary: all mutable state and all
/// ndt_connection operations below execute solely on queue. Frames handed to
/// the main actor retain this worker until retirement, including after stop.
private final class NativeDisplayWorker: @unchecked Sendable {
    private final class Frame {
        var value: ndt_frame
        let deadline: Double
        let received: Double?
        var dispatched = false
        var retired = false
        init(_ value: ndt_frame, received: Double?) {
            self.value = value
            self.received = received
            deadline = ProcessInfo.processInfo.systemUptime + 1
        }
    }
    private let queue = DispatchQueue(label: "org.perpendicular.native-display", qos: .userInteractive)
    private let endpoint: NativeDisplayEndpoint
    private let device: any MTLDevice
    private let telemetry = VMDisplayTelemetry.shared
    private let mailbox: NativeDisplayMailbox
    private let notice: @Sendable (NativeDisplayWorkerNotice) -> Void
    private var connection = ndt_connection()
    private var initialized = false
    private var active = false
    private var connected = false
    private var connectionDeadline = 0.0
    private var timer: (any DispatchSourceTimer)?
    private var frames: [UInt64: Frame] = [:]

    init(endpoint: NativeDisplayEndpoint, device: any MTLDevice, mailbox: NativeDisplayMailbox,
         notice: @escaping @Sendable (NativeDisplayWorkerNotice) -> Void) {
        self.endpoint = endpoint; self.device = device; self.mailbox = mailbox; self.notice = notice
    }
    func start() { queue.async { [self] in begin() } }
    func stop() { queue.async { [self] in close(failure: nil) } }

    private func begin() {
        guard !initialized else { return }
        initialized = true
        active = true
        connectionDeadline = ProcessInfo.processInfo.systemUptime + 1
        let result = endpoint.socketPath.withCString {
            ndt_client_start(&connection, $0, endpoint.expectedUID, endpoint.serverPID,
                             endpoint.sessionHi, endpoint.sessionLo, endpoint.epoch)
        }
        guard result == NDT_OK || result == NDT_AGAIN else { close(code: result); return }
        if ndt_status(&connection) == NDT_OK { connected = true; notice(.connected) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.step() }
        self.timer = timer
        timer.resume()
    }

    private func step() {
        guard active else { return }
        var descriptor = pollfd(fd: ndt_socket_fd(&connection), events: ndt_poll_events(&connection), revents: 0)
        let available = Darwin.poll(&descriptor, 1, 0)
        if available < 0 && errno != EINTR { close(code: Int32(NDT_ERR_SYSTEM), systemError: errno); return }
        if available > 0 {
            let result = ndt_pump(&connection)
            guard result == NDT_OK || result == NDT_AGAIN else { close(code: result); return }
        }
        if !connected && ndt_status(&connection) == NDT_OK { connected = true; notice(.connected) }
        if !connected && ProcessInfo.processInfo.systemUptime >= connectionDeadline {
            close(code: Int32(NDT_ERR_SYSTEM), systemError: ETIMEDOUT, reason: "The graphics renderer did not respond in time.")
            return
        }
        for _ in 0..<2 where frames.count < 2 {
            var frame = ndt_frame()
            let result = ndt_take_frame(&connection, &frame)
            if result == NDT_AGAIN { break }
            guard result == NDT_OK else { close(code: result); return }
            let number = frame.metadata.id.frame
            guard frames[number] == nil else { ndt_frame_close(&frame); close(code: Int32(NDT_ERR_IDENTITY)); return }
            let received = telemetry == nil ? nil : CACurrentMediaTime()
            telemetry?.count("frames_received")
            frames[number] = Frame(frame, received: received)
        }
        for number in frames.keys.sorted() {
            guard active, let frame = frames[number] else { continue }
            if frame.retired { acknowledge(number); continue }
            if frame.dispatched { continue }
            let ready = ndt_ready(frame.value.ready_fd)
            if ready == NDT_AGAIN {
                if ProcessInfo.processInfo.systemUptime >= frame.deadline {
                    close(code: Int32(NDT_ERR_TOKEN), reason: "The graphics renderer did not finish a frame in time.")
                    return
                }
                // Never deliver a later ready frame, then regress to this
                // older frame when its producer notification finally arrives.
                break
            }
            guard ready == NDT_OK else { close(code: ready); return }
            let timing = frame.received.map { VMNativeDisplayTiming(received: $0, ready: CACurrentMediaTime(), delivered: nil) }
            guard let delivery = importFrame(frame.value, number: number, timing: timing) else {
                close(code: Int32(NDT_ERR_BOUNDS), reason: "The graphics renderer sent an unsupported frame."); return
            }
            frame.dispatched = true
            telemetry?.count("frames_ready_imported")
            mailbox.offer(delivery)
        }
    }

    private func importFrame(_ frame: ndt_frame, number: UInt64, timing: VMNativeDisplayTiming?) -> NativeDisplayDelivery? {
        let m = frame.metadata
        let width = UInt64(m.width), height = UInt64(m.height), pitch = UInt64(m.pitch)
        var extent: UInt64 = 0
        let alignment = device.minimumLinearTextureAlignment(for: .bgra8Unorm)
        guard m.id.session_hi == endpoint.sessionHi, m.id.session_lo == endpoint.sessionLo, m.id.epoch == endpoint.epoch,
              width > 0, height > 0, width <= 4096, height <= 4096, width * height <= 8 * 1024 * 1024,
              m.format == 87, m.offset == 0, pitch >= width * 4, alignment > 0, pitch % UInt64(alignment) == 0,
              m.size == pitch * height, ndt_memory_extent(frame.memory_fd, &extent) == NDT_OK,
              extent == frame.memory_extent, extent >= m.size, extent <= 64 * 1024 * 1024,
              extent % UInt64(getpagesize()) == 0 else { return nil }
        let length = Int(extent)
        guard let pointer = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_SHARED, frame.memory_fd, 0), pointer != MAP_FAILED else { return nil }
        guard let backing = device.makeBuffer(bytesNoCopy: pointer, length: length, options: .storageModeShared,
            deallocator: { pointer, length in _ = munmap(pointer, length) }) else { munmap(pointer, length); return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(width), height: Int(height), mipmapped: false)
        desc.storageMode = .shared; desc.usage = .shaderRead
        guard let texture = backing.makeTexture(descriptor: desc, offset: 0, bytesPerRow: Int(pitch)) else { return nil }
        return NativeDisplayDelivery(texture: texture, backing: backing, timing: timing) { [self] in
            queue.async { [self] in retire(number) }
        }
    }

    private func retire(_ number: UInt64) {
        guard let frame = frames[number], !frame.retired else { return }
        frame.retired = true
        acknowledge(number)
    }
    private func acknowledge(_ number: UInt64) {
        guard let frame = frames[number], frame.retired else { return }
        if active {
            let result = ndt_queue_ack(&connection, &frame.value.metadata.id)
            if result == NDT_AGAIN { return }
            if result != NDT_OK { close(code: result) }
        }
        // The exact old connection is never reinitialized. On disconnect this
        // is descriptor cleanup only; it cannot ACK another connection/epoch.
        ndt_frame_close(&frame.value)
        frames.removeValue(forKey: number)
    }
    private func close(code: Int32, systemError: Int32? = nil, reason: String = "The graphics connection ended.") {
        close(failure: .init(code: code, systemError: systemError ?? connection.system_error, reason: reason))
    }
    private func close(failure: NativeDisplayFailure?) {
        guard active else { return }
        active = false
        telemetry?.count(failure == nil ? "connections_closed" : "connection_failures")
        if let failure {
            telemetry?.count("connection_code_\(failure.code)")
            telemetry?.count("connection_errno_\(failure.systemError)")
        }
        timer?.setEventHandler {}; timer?.cancel(); timer = nil
        ndt_close(&connection)
        var event = ndt_event()
        for _ in 0..<2 { if ndt_next_event(&connection, &event) != NDT_OK { break } }
        for number in frames.keys.sorted() {
            guard let frame = frames[number] else { continue }
            if !frame.dispatched || frame.retired {
                ndt_frame_close(&frame.value); frames.removeValue(forKey: number)
            }
        }
        // Dispatched frames remain owned until their lease drains the GPU.
        // Closing transport does not close those caller-owned frame FDs.
        if let failure { notice(.failed(failure)) }
    }
}
#endif
