import Foundation
import Network

struct GuestPacket: @unchecked Sendable {
    let header: [String: Any]
    let pixels: Data
}

final class GuestConnection: @unchecked Sendable {
    let id = UUID()
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "perpendicular.guest.connection")
    private let packet: @MainActor @Sendable (UUID, GuestPacket) -> Void
    private let ended: @MainActor @Sendable (UUID) -> Void
    private var closed = false
    private let lock = NSLock()
    private var frames: [String: GuestPacket] = [:]
    private var drainScheduled = false

    init(_ connection: NWConnection,
         packet: @escaping @MainActor @Sendable (UUID, GuestPacket) -> Void,
         ended: @escaping @MainActor @Sendable (UUID) -> Void) {
        self.connection = connection; self.packet = packet; self.ended = ended
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.readHeader()
            case .failed, .cancelled: self.finish()
            default: break
            }
        }
        connection.start(queue: queue)
    }
    func cancel() { connection.cancel() }
    private func finish() {
        guard !closed else { return }; closed = true
        Task { @MainActor [self] in ended(id) }
    }
    func send(_ header: [String: Any]) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: header), bytes.count <= 16384 else { return }
        var length = UInt32(bytes.count).littleEndian
        var message = withUnsafeBytes(of: &length) { Data($0) }; message.append(bytes)
        connection.send(content: message, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.connection.cancel() }
        })
    }
    private func read(_ count: Int, collected: Data = Data(), completion: @escaping @Sendable (Data) -> Void) {
        connection.receive(minimumIncompleteLength: min(count,65536), maximumLength: min(count,65536)) { [weak self] data, _, complete, error in
            guard let self else { return }
            guard error == nil, let data, !data.isEmpty else { self.connection.cancel(); return }
            var bytes = collected; bytes.append(data)
            if data.count == count { completion(bytes) }
            else if !complete { self.read(count-data.count,collected:bytes,completion:completion) }
            else { self.connection.cancel() }
        }
    }
    private func readHeader() {
        read(4) { [weak self] bytes in
            guard let self else { return }
            let count = bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
            guard count > 0, count <= 1_048_576 else { self.connection.cancel(); return }
            self.read(Int(count)) { [weak self] bytes in
                guard let self, let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      let kind = object["type"] as? String else { self?.connection.cancel(); return }
                let packet = GuestPacket(header:object,pixels:Data())
                if kind == "frame" {
                    guard let width=object["width"] as? Int, let height=object["height"] as? Int,
                          width>0, height>0, width<=4_194_304/height,
                          object["bytes"] as? Int == width*height*4,
                          let window=object["window"] as? String, window.utf8.count<192 else {
                        self.connection.cancel(); return
                    }
                    self.read(width*height*4) { [weak self] bytes in
                        guard let self else { return }
                        self.offer(window,GuestPacket(header:packet.header,pixels:bytes)); self.readHeader()
                    }
                } else {
                    Task { @MainActor [self] in self.packet(self.id,packet) }
                    self.readHeader()
                }
            }
        }
    }
    private func offer(_ window:String,_ value:GuestPacket) {
        lock.lock()
        if frames.count >= 16, frames[window] == nil { lock.unlock(); connection.cancel(); return }
        frames[window]=value
        let wake = !drainScheduled; drainScheduled=true; lock.unlock()
        if wake { Task { @MainActor [self] in drain() } }
    }
    @MainActor private func drain() {
        lock.lock(); let pending=frames; frames.removeAll(keepingCapacity:true); drainScheduled=false; lock.unlock()
        for value in pending.values { packet(id,value) }
    }
}

@MainActor
final class GuestBridge {
    private let listener: NWListener
    private let token: String
    private var clients: [UUID:GuestConnection] = [:]
    private var active: UUID?
    private var timer: Timer?
    private var lastPacket = Date.distantPast
    private var serial = 0
    private var replies: [Int:(Result<[String:Any],Error>) -> Void] = [:]
    var onPacket: ((GuestPacket) -> Void)?
    var onConnection: ((Bool) -> Void)?
    var connected: Bool { active != nil }

    init(port: UInt16, token: String) throws {
        self.token=token
        let parameters=NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!)
        listener=try NWListener(using:parameters)
        listener.newConnectionHandler = { [weak self] incoming in
            Task { @MainActor in self?.accept(incoming) }
        }
        listener.start(queue:DispatchQueue(label:"perpendicular.guest.listener"))
        timer=Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.heartbeat() }
        }
    }
    private func accept(_ incoming: NWConnection) {
        guard clients.count < 4 else { incoming.cancel(); return }
        let client=GuestConnection(incoming,packet:{ [weak self] in self?.receive($0,$1) },ended:{ [weak self] in self?.disconnected($0) })
        clients[client.id]=client
        Task { @MainActor [weak self] in
            try? await Task.sleep(for:.seconds(5))
            guard let self, self.active != client.id else { return }
            self.clients.removeValue(forKey:client.id)?.cancel()
        }
    }
    private func receive(_ id:UUID,_ packet:GuestPacket) {
        let h=packet.header
        if h["type"] as? String == "hello" {
            guard h["protocol"] as? Int == 1, h["token"] as? String == token,
                  let session=h["session"] as? Int, session>0, let sid=h["sid"] as? String, sid.hasPrefix("S-1-"),
                  let epoch=h["epoch"] as? String, epoch.utf8.count<=128 else { clients[id]?.cancel(); return }
            if let previous=active, previous != id { clients.removeValue(forKey:previous)?.cancel() }
            active=id;lastPacket=Date();onConnection?(true)
        }
        guard active==id else { return }
        lastPacket=Date()
        if h["type"] as? String == "reply", let request=h["request"] as? Int, let reply=replies.removeValue(forKey:request) {
            if h["ok"] as? Bool == true { reply(.success(["value":h["result"] ?? [:]])) }
            else { reply(.failure(NSError(domain:"Guest",code:1,userInfo:[NSLocalizedDescriptionKey:h["message"] as? String ?? "Windows could not complete this request."]))) }
        }
        onPacket?(packet)
    }
    private func disconnected(_ id:UUID) {
        clients.removeValue(forKey:id)
        guard active==id else { return }
        active=nil
        let pending=replies;replies.removeAll()
        for reply in pending.values { reply(.failure(NSError(domain:"Guest",code:2,userInfo:[NSLocalizedDescriptionKey:"Windows disconnected."]))) }
        onConnection?(false)
    }
    private func heartbeat() {
        guard let id=active else { return }
        if Date().timeIntervalSince(lastPacket)>8 { clients[id]?.cancel(); return }
        clients[id]?.send(["operation":"heartbeat"])
    }
    func command(_ operation:String,_ values:[String:Any]=[:], timeout:Duration = .seconds(12), completion:((Result<[String:Any],Error>)->Void)?=nil) {
        guard let id=active, let client=clients[id] else {
            completion?(.failure(NSError(domain:"Guest",code:2,userInfo:[NSLocalizedDescriptionKey:"Windows is not connected."])));return
        }
        serial+=1;let request=serial
        var header=values;header["operation"]=operation;header["request"]=request
        if let completion {
            guard replies.count<32 else { completion(.failure(NSError(domain:"Guest",code:3,userInfo:[NSLocalizedDescriptionKey:"Windows is busy."])));return }
            replies[request]=completion
            Task { @MainActor [weak self] in
                try? await Task.sleep(for:timeout)
                self?.replies.removeValue(forKey:request)?(.failure(NSError(domain:"Guest",code:4,userInfo:[NSLocalizedDescriptionKey:"Windows took too long to respond."])))
            }
        }
        client.send(header)
    }
}
