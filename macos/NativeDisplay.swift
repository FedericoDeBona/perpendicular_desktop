import Foundation
import Darwin
import Metal

struct NativeDisplayEndpoint:Codable,Sendable {
    let socketPath:String
    let serverPID:Int32
    let expectedUID:UInt32
    let sessionHi:UInt64
    let sessionLo:UInt64
    let epoch:UInt64
}

/// The mapping and producer identity outlive every Metal command that reads it.
/// Complete the read explicitly; an undrawn frame also retires when dropped.
final class NativeDisplayFrame:@unchecked Sendable {
    let texture:any MTLTexture
    let traceID:String
    private let backing:any MTLBuffer
    private let retirementLock=NSLock()
    private var retirement:(@Sendable ()->Void)?
    init(texture:any MTLTexture,backing:any MTLBuffer,traceID:String,retired:@escaping @Sendable ()->Void){
        self.texture=texture;self.backing=backing;self.traceID=traceID;self.retirement=retired
    }
    /// Call only after the last GPU read. Metal may retain a completed command's
    /// handler, so object deallocation is not a timely producer acknowledgement.
    func finishReading(){
        retirementLock.lock();let callback=retirement;retirement=nil;retirementLock.unlock()
        callback?()
    }
    deinit {finishReading()}
}

/// One queue, one connection lifetime and at most two outstanding frames.
/// The matching C transport is retained from the reference graphics component.
final class NativeDisplayReader:@unchecked Sendable {
    private final class Entry {
        var frame:ndt_frame
        var delivered=false
        var retired=false
        var readySource:DispatchSourceRead?
        let deadline=ProcessInfo.processInfo.systemUptime+3
        init(_ frame:ndt_frame){self.frame=frame}
    }
    private let endpoint:NativeDisplayEndpoint
    private let device:any MTLDevice
    private let queue=DispatchQueue(label:"perpendicular.native-display",qos:.userInteractive)
    private let receive:@MainActor @Sendable (NativeDisplayFrame)->Void
    private let failed:@MainActor @Sendable (String)->Void
    private var connection=ndt_connection()
    private var active=false
    private var started=false
    private var deadline=0.0
    private var timer:DispatchSourceTimer?
    private var socketRead:DispatchSourceRead?
    private var socketWrite:DispatchSourceWrite?
    private var frames:[UInt64:Entry]=[:]

    init(endpoint:NativeDisplayEndpoint,device:any MTLDevice,
         receive:@escaping @MainActor @Sendable (NativeDisplayFrame)->Void,
         failed:@escaping @MainActor @Sendable (String)->Void){
        self.endpoint=endpoint;self.device=device;self.receive=receive;self.failed=failed
    }
    func start(){queue.async{[self] in begin()}}
    func stop(){queue.async{[self] in close(nil)}}
    private func begin(){
        guard !started else{return};started=true;active=true
        deadline=ProcessInfo.processInfo.systemUptime+3
        let result=endpoint.socketPath.withCString{
            ndt_client_start(&connection,$0,endpoint.expectedUID,endpoint.serverPID,endpoint.sessionHi,endpoint.sessionLo,endpoint.epoch)
        }
        guard result == NDT_OK || result == NDT_AGAIN else{close("Cannot connect to the Windows graphics display (\(result)).");return}
        socketRead=readSource(ndt_socket_fd(&connection)){[weak self] in self?.step()}
        guard socketRead != nil else{close("Cannot observe the graphics display.");return}
        step()
    }
    // Watch duplicated descriptors, closing each only in its cancellation
    // handler. ndt_close/frame_close can then release their own descriptors
    // without racing Dispatch's asynchronous removal from kqueue.
    private func readSource(_ descriptor:Int32,_ event:@escaping @Sendable ()->Void)->DispatchSourceRead? {
        let fd=fcntl(descriptor,F_DUPFD_CLOEXEC,0)
        guard fd>=0 else{return nil}
        let source=DispatchSource.makeReadSource(fileDescriptor:fd,queue:queue)
        source.setEventHandler(handler:event)
        source.setCancelHandler{Darwin.close(fd)}
        source.resume();return source
    }
    private func refreshSources(){
        guard active else{return}
        let wantsWrite=ndt_poll_events(&connection)&Int16(POLLOUT) != 0
        if wantsWrite,socketWrite == nil {
            let fd=fcntl(ndt_socket_fd(&connection),F_DUPFD_CLOEXEC,0)
            guard fd>=0 else{close("Cannot observe graphics acknowledgements.");return}
            let source=DispatchSource.makeWriteSource(fileDescriptor:fd,queue:queue)
            source.setEventHandler{[weak self] in self?.step()}
            source.setCancelHandler{Darwin.close(fd)}
            socketWrite=source;source.resume()
        }else if !wantsWrite {
            socketWrite?.cancel();socketWrite=nil
        }
        // The timer checks deadlines only while connecting or waiting for GPU
        // readiness. Static/delivered frames require no periodic polling.
        let waiting=ndt_status(&connection) != NDT_OK || frames.values.contains{!$0.delivered && !$0.retired}
        if waiting,timer == nil {
            let source=DispatchSource.makeTimerSource(queue:queue)
            source.schedule(deadline:.now() + .milliseconds(250),repeating:.milliseconds(250),leeway:.milliseconds(25))
            source.setEventHandler{[weak self] in self?.step()}
            timer=source;source.resume()
        }else if !waiting {timer?.cancel();timer=nil}
    }
    private func step(){
        guard active else{return}
        defer{refreshSources()}
        PipelineTrace.record("desktop-reader-wake","desktop:\(endpoint.epoch)")
        var descriptor=pollfd(fd:ndt_socket_fd(&connection),events:ndt_poll_events(&connection),revents:0)
        let available=Darwin.poll(&descriptor,1,0)
        if available<0 && errno != EINTR {close("The graphics display disconnected.");return}
        if available>0 {
            let result=ndt_pump(&connection)
            guard result == NDT_OK || result == NDT_AGAIN else{close("The graphics display ended (\(result)).");return}
        }
        if ndt_status(&connection) != NDT_OK && ProcessInfo.processInfo.systemUptime>deadline {
            close("The graphics display did not respond.");return
        }
        for _ in 0..<2 where frames.count<2 {
            var frame=ndt_frame();let result=ndt_take_frame(&connection,&frame)
            if result == NDT_AGAIN {break}
            guard result == NDT_OK else{close("Invalid graphics frame (\(result)).");return}
            let number=frame.metadata.id.frame
            PipelineTrace.record("desktop-take","desktop:\(endpoint.epoch):\(number)",["width":frame.metadata.width,"height":frame.metadata.height])
            guard frames[number] == nil else{ndt_frame_close(&frame);close("Repeated graphics frame.");return}
            frames[number]=Entry(frame)
        }
        for number in frames.keys.sorted() {
            guard active,let entry=frames[number] else{continue}
            if entry.retired {acknowledge(number);continue}
            if entry.delivered {continue}
            let ready=ndt_ready(entry.frame.ready_fd)
            if ready == NDT_AGAIN {
                if entry.readySource == nil {
                    entry.readySource=readSource(entry.frame.ready_fd){[weak self] in self?.step()}
                    guard entry.readySource != nil else{close("Cannot observe graphics readiness.");return}
                }
                if ProcessInfo.processInfo.systemUptime>entry.deadline {close("Windows did not finish a graphics frame.")}
                break
            }
            guard ready == NDT_OK else{close("Unsupported graphics frame.");return}
            PipelineTrace.record("desktop-ready","desktop:\(endpoint.epoch):\(number)")
            guard let frame=importFrame(entry.frame,number:number) else{close("Unsupported graphics frame.");return}
            entry.readySource?.cancel();entry.readySource=nil
            PipelineTrace.record("desktop-imported",frame.traceID)
            entry.delivered=true
            PipelineTrace.record("desktop-main-enqueued",frame.traceID)
            FrameDelivery.main{[receive] in receive(frame)}
        }
    }
    private func importFrame(_ frame:ndt_frame,number:UInt64)->NativeDisplayFrame?{
        let value=frame.metadata
        let width=UInt64(value.width),height=UInt64(value.height),pitch=UInt64(value.pitch)
        let alignment=device.minimumLinearTextureAlignment(for:.bgra8Unorm)
        var extent:UInt64=0
        guard value.id.session_hi == endpoint.sessionHi,value.id.session_lo == endpoint.sessionLo,value.id.epoch == endpoint.epoch,
              width>0,height>0,width<=4096,height<=4096,width*height<=8_388_608,
              value.format == 87,value.offset == 0,pitch>=width*4,alignment>0,pitch%UInt64(alignment) == 0,
              value.size == pitch*height,ndt_memory_extent(frame.memory_fd,&extent) == NDT_OK,
              extent == frame.memory_extent,extent>=value.size,extent<=64*1024*1024,extent%UInt64(getpagesize()) == 0 else{return nil}
        let length=Int(extent)
        guard let pointer=mmap(nil,length,PROT_READ|PROT_WRITE,MAP_SHARED,frame.memory_fd,0),pointer != MAP_FAILED else{return nil}
        guard let backing=device.makeBuffer(bytesNoCopy:pointer,length:length,options:.storageModeShared,
            deallocator:{pointer,length in _=munmap(pointer,length)}) else{munmap(pointer,length);return nil}
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:Int(width),height:Int(height),mipmapped:false)
        descriptor.storageMode = .shared;descriptor.usage = .shaderRead
        guard let texture=backing.makeTexture(descriptor:descriptor,offset:0,bytesPerRow:Int(pitch)) else{return nil}
        return NativeDisplayFrame(texture:texture,backing:backing,traceID:"desktop:\(endpoint.epoch):\(number)"){[self] in queue.async{[self] in retire(number)}}
    }
    private func retire(_ number:UInt64){
        guard let entry=frames[number],!entry.retired else{return}
        entry.retired=true;acknowledge(number)
        step()
    }
    private func acknowledge(_ number:UInt64){
        guard let entry=frames[number],entry.retired else{return}
        if active {
            let result=ndt_queue_ack(&connection,&entry.frame.metadata.id)
            if result == NDT_AGAIN {return}
            if result != NDT_OK {close("Cannot retire a graphics frame.")}
            PipelineTrace.record("desktop-ack-queued","desktop:\(endpoint.epoch):\(number)",["result":result])
        }
        ndt_frame_close(&entry.frame);frames.removeValue(forKey:number)
    }
    private func close(_ reason:String?){
        guard active else{return};active=false
        timer?.setEventHandler{};timer?.cancel();timer=nil
        socketRead?.cancel();socketRead=nil
        socketWrite?.cancel();socketWrite=nil
        for entry in frames.values {entry.readySource?.cancel();entry.readySource=nil}
        ndt_close(&connection)
        for number in Array(frames.keys) {
            guard let entry=frames[number] else{continue}
            if !entry.delivered || entry.retired {ndt_frame_close(&entry.frame);frames.removeValue(forKey:number)}
        }
        if let reason {Task{@MainActor [failed] in failed(reason)}}
    }
}
