// Compile with NativeDisplay.swift and native-transport.o, importing bridge.h.
// Real NDT sockets/readiness/Metal import: delayed readiness, exact ACK, idle
// without polling, disconnect and cancellation. No Windows/VM is started.
import Foundation
import Darwin
import Metal

enum FrameDelivery {
    static func main(_ work:@escaping @MainActor @Sendable ()->Void){DispatchQueue.main.async{work()}}
}
final class WakeCount:@unchecked Sendable {
    let lock=NSLock();var value=0
    func increment(){lock.lock();value+=1;lock.unlock()}
    func read()->Int{lock.lock();defer{lock.unlock()};return value}
}
enum PipelineTrace {
    static let wakes=WakeCount()
    static let taken=DispatchSemaphore(value:0)
    static func record(_ event:String,_ id:String,_ fields:[String:Any]=[:]){
        if event == "desktop-reader-wake" {wakes.increment()}
        if event == "desktop-take" {taken.signal()}
    }
}
final class Producer:@unchecked Sendable {
    var listener=ndt_listener()
    let directory:String
    let acknowledged=DispatchSemaphore(value:0)
    let disconnect=DispatchSemaphore(value:0)
    func waitForAck()->Bool{acknowledged.wait(timeout:.now()+5) == .success}
    init()throws {
        directory="/tmp/perp-reader-"+UUID().uuidString
        try FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        precondition(directory.withCString{ndt_listen(&listener,$0,"display")} == NDT_OK)
    }
    func start(){DispatchQueue(label:"reader-check.producer").async{[self] in
        var p=pollfd(fd:listener.fd,events:Int16(POLLIN),revents:0)
        precondition(poll(&p,1,5000)>0)
        var connection=ndt_connection()
        precondition(ndt_server_accept(&listener,&connection,getuid(),1,2,3) == NDT_OK)
        defer{ndt_close(&connection);ndt_listener_close(&listener);try? FileManager.default.removeItem(atPath:directory)}
        let path=directory+"/image"
        let memory=Darwin.open(path,O_RDWR|O_CREAT|O_EXCL,0o600)
        precondition(memory>=0 && ftruncate(memory,off_t(getpagesize()))==0)
        defer{Darwin.close(memory)}
        var ready:[Int32]=[-1,-1]
        precondition(socketpair(AF_UNIX,SOCK_STREAM,0,&ready)==0)
        defer{Darwin.close(ready[0]);Darwin.close(ready[1])}
        var metadata=ndt_metadata()
        metadata.id=ndt_identity(session_hi:1,session_lo:2,epoch:3,frame:1)
        metadata.width=64;metadata.height=32;metadata.pitch=256;metadata.format=87;metadata.size=8192
        precondition(ndt_queue_frame(&connection,&metadata,memory,ready[0]) == NDT_OK)
        precondition(ndt_pump(&connection) == NDT_OK)
        // Reader must wait on the readiness descriptor, then cancel its watch.
        precondition(PipelineTrace.taken.wait(timeout:.now()+5) == .success)
        Thread.sleep(forTimeInterval:0.1)
        var byte:UInt8=1;precondition(write(ready[1],&byte,1)==1)
        let until=ProcessInfo.processInfo.systemUptime+5
        while ProcessInfo.processInfo.systemUptime<until {
            p=pollfd(fd:ndt_socket_fd(&connection),events:ndt_poll_events(&connection),revents:0)
            precondition(poll(&p,1,100)>=0)
            let result=ndt_pump(&connection)
            precondition(result == NDT_OK || result == NDT_AGAIN)
            var event=ndt_event()
            if ndt_next_event(&connection,&event) == NDT_OK {
                precondition(event.kind == NDT_EVENT_ACK && event.id.frame==1)
                acknowledged.signal()
                precondition(disconnect.wait(timeout:.now()+5) == .success)
                return
            }
        }
        preconditionFailure("Missing frame ACK")
    }}
}
@main struct Check {
    @MainActor static func main()async throws {
        guard let device=MTLCreateSystemDefaultDevice() else{fatalError("Metal unavailable")}
        let producer=try Producer();producer.start()
        var count=0,ended=false
        let reader=NativeDisplayReader(endpoint:NativeDisplayEndpoint(socketPath:producer.directory+"/display",serverPID:getpid(),expectedUID:getuid(),sessionHi:1,sessionLo:2,epoch:3),device:device,receive:{frame in
            count+=1
            precondition(frame.texture.width==64 && frame.texture.height==32)
            frame.finishReading()
        },failed:{_ in ended=true})
        reader.start()
        for _ in 0..<100 where count==0 {try await Task.sleep(for:.milliseconds(10))}
        precondition(count==1)
        let ack=await Task.detached{producer.waitForAck()}.value
        precondition(ack)
        // Let already queued handlers drain, then prove a static connection
        // has no recurring 5 ms timer (including readiness's sticky byte).
        try await Task.sleep(for:.milliseconds(100))
        let before=PipelineTrace.wakes.read()
        try await Task.sleep(for:.milliseconds(600))
        precondition(PipelineTrace.wakes.read()==before && !ended)
        producer.disconnect.signal()
        for _ in 0..<100 where !ended {try await Task.sleep(for:.milliseconds(10))}
        precondition(ended)
        reader.stop()
        print("PASS: delayed readiness, one Metal image, exact ACK, zero idle polls, disconnect")
    }
}
