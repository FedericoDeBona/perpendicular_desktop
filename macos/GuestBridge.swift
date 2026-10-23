import Foundation
import Network

struct GuestPacket: @unchecked Sendable {
    let header: [String: Any]
    let pixels: Data
    let surface:GuestFrameSurface?
    init(header:[String:Any],pixels:Data=Data(),surface:GuestFrameSurface?=nil){
        self.header=header;self.pixels=pixels;self.surface=surface
    }
}

// Owned by one connection's serial receive queue. Keeping the accumulator in
// this reference avoids copying all preceding chunks on every recursive read.
private final class GuestReadBuffer:@unchecked Sendable {
    let count:Int
    var bytes=Data()
    init(_ count:Int){self.count=count;bytes.reserveCapacity(count)}
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
    private var frameOnly=false // Owned by the connection queue.
    private var helloSeen=false
    private var authorized=false

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
    func authorize(frames:Bool){
        queue.async{[weak self] in
            guard let self,!self.authorized else{return}
            self.authorized=true;self.frameOnly=frames;self.readHeader()
        }
    }
    private func finish() {
        guard !closed else { return }; closed = true
        Task { @MainActor [self] in ended(id) }
    }
    func send(_ header: [String: Any]) {
        let limit=header["operation"] as? String == "clipboard" ? 1_048_576:16384
        guard let bytes = try? JSONSerialization.data(withJSONObject: header), bytes.count <= limit else { return }
        var length = UInt32(bytes.count).littleEndian
        var message = withUnsafeBytes(of: &length) { Data($0) }; message.append(bytes)
        connection.send(content: message, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.connection.cancel() }
        })
    }
    private func read(_ count:Int,completion:@escaping @Sendable (Data)->Void){
        read(GuestReadBuffer(count),completion:completion)
    }
    private func read(_ buffer:GuestReadBuffer,completion:@escaping @Sendable (Data)->Void){
        let remaining=buffer.count-buffer.bytes.count
        connection.receive(minimumIncompleteLength:min(remaining,65536),maximumLength:min(remaining,65536)) { [weak self] data, _, complete, error in
            guard let self else { return }
            guard error == nil,let data,!data.isEmpty,data.count<=remaining else { self.connection.cancel(); return }
            buffer.bytes.append(data)
            if buffer.bytes.count == buffer.count {completion(buffer.bytes)}
            else if !complete {self.read(buffer,completion:completion)}
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
                if !self.helloSeen {
                    guard kind == "hello" else{self.connection.cancel();return}
                    self.helloSeen=true
                }else if kind == "hello" {self.connection.cancel();return}
                if kind == "frame" {
                    guard let width=object["width"] as? Int, let height=object["height"] as? Int,
                          width>0,height>0,width<=16_384,height<=16_384,width<=8_388_608/height,
                          let window=object["window"] as? String, window.utf8.count<192 else {
                        self.connection.cancel(); return
                    }
                    let stride=object["stride"] as? Int ?? width*4
                    guard stride>=width*4,stride<=width*4+255,stride<=34*1024*1024/height,
                          object["bytes"] as? Int == stride*height else {
                        self.connection.cancel();return
                    }
                    let received=ProcessInfo.processInfo.systemUptime
                    let complete:@Sendable (Data,GuestFrameSurface?,Int,Double)->Void = {[weak self] bytes,surface,callbacks,decodeMilliseconds in
                        guard let self else{return}
                        var header=packet.header
                        let completed=ProcessInfo.processInfo.systemUptime
                        header["hostReceiveMilliseconds"]=max(0,(completed-received)*1000-decodeMilliseconds)
                        header["hostReceivedAt"]=completed
                        header["hostDecodeMilliseconds"]=decodeMilliseconds
                        if callbacks>0 {header["hostReadCallbacks"]=Double(callbacks)}
                        self.offer(window,GuestPacket(header:header,pixels:bytes,surface:surface))
                        // This retires only the independent CPU/network copy.
                        // The shared Metal buffer stays immutable through GPU completion.
                        if self.frameOnly {self.connection.send(content:Data([1]),completion:.contentProcessed{[weak self] error in
                            if error != nil {self?.connection.cancel()}
                        })}
                        self.readHeader()
                    }
                    let encoding=object["encoding"] as? String ?? "raw"
                    if encoding == "lz4-block" {
                        guard self.frameOnly,let count=object["encodedBytes"] as? Int,count>0,count<stride*height else {
                            self.connection.cancel();return
                        }
                        self.read(count){[weak self] encoded in
                            guard let self else{return}
                            let started=ProcessInfo.processInfo.systemUptime
                            let surface=GuestFrameSurface.allocate(width:width,height:height,stride:stride,decodeGuard:true)
                            if let surface {
                                guard GuestFrameCodec.decodeLZ4(encoded,into:UnsafeMutableRawBufferPointer(start:surface.contents,count:surface.byteCount+1),expected:surface.byteCount) else {
                                    self.connection.cancel();return
                                }
                                complete(Data(),surface,0,(ProcessInfo.processInfo.systemUptime-started)*1000)
                            }else{
                                var pixels=Data(count:stride*height+1)
                                let valid=pixels.withUnsafeMutableBytes { GuestFrameCodec.decodeLZ4(encoded,into:$0,expected:stride*height) }
                                guard valid else{self.connection.cancel();return}
                                pixels.removeLast()
                                complete(pixels,nil,0,(ProcessInfo.processInfo.systemUptime-started)*1000)
                            }
                        }
                    }else if encoding == "raw",object["encodedBytes"] == nil {
                        if let surface=GuestFrameSurface.allocate(width:width,height:height,stride:stride) {
                            self.readSurface(surface,offset:0,callbacks:0){complete(Data(),surface,$0,0)}
                        } else {self.read(stride*height){complete($0,nil,0,0)}}
                    }else{self.connection.cancel();return}
                } else {
                    Task { @MainActor [self] in self.packet(self.id,packet) }
                    // Authentication is decided on the main actor. Do not
                    // allocate pixels or acknowledge a peer before it succeeds.
                    if kind != "hello" {self.readHeader()}
                }
            }
        }
    }
    private func readSurface(_ surface:GuestFrameSurface,offset:Int,callbacks:Int,completion:@escaping @Sendable (Int)->Void){
        let remaining=surface.byteCount-offset
        // One bounded chunk per callback, copied directly into the final Metal
        // buffer. Larger pixel reads reduce callbacks without queuing more frames.
        let chunk=min(remaining,256*1024)
        connection.receive(minimumIncompleteLength:chunk,maximumLength:chunk){[weak self] data,_,complete,error in
            guard let self else{return}
            guard error == nil,let data,!data.isEmpty,data.count<=remaining else{self.connection.cancel();return}
            data.withUnsafeBytes{if let bytes=$0.baseAddress{surface.contents.advanced(by:offset).copyMemory(from:bytes,byteCount:data.count)}}
            let next=offset+data.count
            if next == surface.byteCount{completion(callbacks+1)}
            else if !complete{self.readSurface(surface,offset:next,callbacks:callbacks+1,completion:completion)}
            else{self.connection.cancel()}
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
        for value in pending.values {
            var header=value.header
            if let received=header.removeValue(forKey:"hostReceivedAt") as? Double {
                header["hostDispatchMilliseconds"]=max(0,(ProcessInfo.processInfo.systemUptime-received)*1000)
            }
            packet(id,GuestPacket(header:header,pixels:value.pixels,surface:value.surface))
        }
    }
}

@MainActor
final class GuestBridge {
    private let listener: NWListener
    private let token: String
    private var clients: [UUID:GuestConnection] = [:]
    private var active: UUID?
    private var activeFrames:UUID?
    private var identity:String?
    private var frameChannel:String?
    private var timer: Timer?
    private var lastPacket = Date.distantPast
    private var serial = 0
    private var replies: [Int:(Result<[String:Any],Error>) -> Void] = [:]
    private var sentAt:[Int:Double]=[:]
    private(set) var lastRoundTripMilliseconds=0.0
    private(set) var frameReceiveMilliseconds=0.0
    private(set) var lastFrameTimings:[String:Double]=[:]
    private var nextFrameTrace=0.0
    var separateFrames:Bool {activeFrames != nil}
    var onPacket: ((GuestPacket) -> Void)?
    var onConnection: ((Bool) -> Void)?
    var connected: Bool { active != nil }

    init(port: UInt16, token: String) throws {
        self.token=token
        let tcp=NWProtocolTCP.Options();tcp.noDelay=true
        let parameters=NWParameters(tls:nil,tcp:tcp)
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
            guard let self, self.active != client.id,self.activeFrames != client.id else { return }
            self.clients.removeValue(forKey:client.id)?.cancel()
        }
    }
    private func receive(_ id:UUID,_ packet:GuestPacket) {
        guard clients[id] != nil else{return}
        let h=packet.header
        if h["type"] as? String == "hello" {
            guard h["protocol"] as? Int == 1, h["token"] as? String == token,
                  let session=h["session"] as? Int, session>0, let sid=h["sid"] as? String, sid.hasPrefix("S-1-"),
                  let epoch=h["epoch"] as? String, epoch.utf8.count<=128 else { clients[id]?.cancel(); return }
            let incomingIdentity="\(sid)|\(session)|\(epoch)"
            if h["role"] as? String == "frames" {
                guard active != nil,identity == incomingIdentity,let frameChannel,h["channel"] as? String == frameChannel,
                      activeFrames == nil else{clients[id]?.cancel();return}
                activeFrames=id;clients[id]?.authorize(frames:true);return
            }
            guard h["role"] == nil || h["role"] as? String == "control" else{clients[id]?.cancel();return}
            if let previous=active,previous != id {
                clients.removeValue(forKey:previous)?.cancel()
                let pending=replies;replies.removeAll();sentAt.removeAll()
                for reply in pending.values {reply(.failure(NSError(domain:"Guest",code:2,userInfo:[NSLocalizedDescriptionKey:"Windows reconnected."])))}
            }
            if let previous=activeFrames {clients.removeValue(forKey:previous)?.cancel()}
            activeFrames=nil;frameChannel=nil;identity=incomingIdentity
            lastFrameTimings=[:];frameReceiveMilliseconds=0
            clients[id]?.authorize(frames:false)
            active=id;lastPacket=Date();onConnection?(true)
            if (h["capabilities"] as? [String:Any])?["frameChannel"] as? Bool == true {
                let channel=UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
                frameChannel=channel
                var options:[String:Any]=["channel":channel,"rowAlignment":256]
                if ((h["capabilities"] as? [String:Any])?["frameEncodings"] as? [String])?.contains("lz4-block") == true {options["encoding"]="lz4-block"}
                command("frame_channel",options,timeout:.seconds(5)){[weak self] result in
                    if case .failure=result,self?.active == id {self?.clients[id]?.cancel()}
                }
            }
        }
        if activeFrames == id {
            guard h["type"] as? String == "frame" else{clients[id]?.cancel();return}
            recordFrameTimings(h)
            onPacket?(packet);return
        }
        guard active==id else { return }
        lastPacket=Date()
        if h["type"] as? String == "frame" {recordFrameTimings(h)}
        if h["type"] as? String == "reply", let request=h["request"] as? Int, let reply=replies.removeValue(forKey:request) {
            if let started=sentAt.removeValue(forKey:request){lastRoundTripMilliseconds=(ProcessInfo.processInfo.systemUptime-started)*1000}
            if h["ok"] as? Bool == true { reply(.success(["value":h["result"] ?? [:]])) }
            else { reply(.failure(NSError(domain:"Guest",code:1,userInfo:[NSLocalizedDescriptionKey:h["message"] as? String ?? "Windows could not complete this request."]))) }
        }
        onPacket?(packet)
    }
    private func recordFrameTimings(_ header:[String:Any]) {
        let keys=["guestReadbackSlots","guestReadbackBands","guestBufferReused","guestCopySubmitMilliseconds","guestMapMilliseconds","guestPixelCopyMilliseconds","guestUnmapMilliseconds",
                  "guestFrameAgeAtSendMilliseconds","guestReadbackMilliseconds","guestBackpressureMilliseconds","guestQueueMilliseconds",
                  "hostReceiveMilliseconds","hostDispatchMilliseconds","hostReadCallbacks","guestEncodeMilliseconds","hostDecodeMilliseconds","wireBytes","bytes"]
        lastFrameTimings=keys.reduce(into:[:]) {value,key in
            if let number=header[key] as? Double,number.isFinite,number>=0,number <= ((key == "wireBytes" || key == "bytes") ? 34*1024*1024:60000) {value[key]=number}
        }
        frameReceiveMilliseconds=lastFrameTimings["hostReceiveMilliseconds"] ?? 0
        guard ProcessInfo.processInfo.environment["PERPENDICULAR_STATE_TRACE"] == "1" else{return}
        let now=ProcessInfo.processInfo.systemUptime
        guard now>=nextFrameTrace else{return};nextFrameTrace=now+1
        var value:[String:Any]=["type":"frame_pipeline","timings":lastFrameTimings]
        for key in ["window","sequence","width","height","bytes"] {value[key]=header[key]}
        if let data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]){try? FileHandle.standardError.write(contentsOf:data+Data([10]))}
    }
    func disconnect(){
        let previous=Array(clients.values)
        if let active {disconnected(active)}
        clients.removeAll()
        for client in previous {client.cancel()}
    }
    private func disconnected(_ id:UUID) {
        clients.removeValue(forKey:id)
        if activeFrames == id {activeFrames=nil;if let active{clients[active]?.cancel()}}
        guard active==id else { return }
        active=nil;identity=nil;frameChannel=nil;lastFrameTimings=[:];frameReceiveMilliseconds=0
        if let frame=activeFrames {activeFrames=nil;clients.removeValue(forKey:frame)?.cancel()}
        let pending=replies;replies.removeAll()
        sentAt.removeAll()
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
            sentAt[request]=ProcessInfo.processInfo.systemUptime
            Task { @MainActor [weak self] in
                try? await Task.sleep(for:timeout)
                self?.sentAt.removeValue(forKey:request)
                self?.replies.removeValue(forKey:request)?(.failure(NSError(domain:"Guest",code:4,userInfo:[NSLocalizedDescriptionKey:"Windows took too long to respond."])))
            }
        }
        client.send(header)
    }
}
