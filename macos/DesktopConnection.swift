import Foundation
import Darwin

struct DesktopScreen:Sendable {
    let id:UInt32
    let x:Int
    let y:Int
    let width:Int
    let height:Int
}

/// RFB 3.8 on a private Unix socket: boot/recovery pixels and device input.
/// Accelerated scanout uses NativeDisplayReader; this connection then stops
/// requesting CPU framebuffer updates while retaining keyboard and mouse input.
final class DesktopConnection:@unchecked Sendable {
    private let path:String
    private let queue=DispatchQueue(label:"perpendicular.desktop.read",qos:.userInteractive)
    private let writes=DispatchQueue(label:"perpendicular.desktop.write",qos:.userInteractive)
    private let state=NSLock()
    private let writeLock=NSLock()
    private var fd:Int32 = -1
    private var stopped=false
    private var ready=false
    private var updates=true
    private var pendingLayout:[DesktopScreen]?
    private var screen=DesktopScreen(id:0,x:0,y:0,width:800,height:600)
    private var framebufferWidth=800
    private var framebufferHeight=600
    private var pixels=Data()
    // Read-queue state. RAMFB can stop satisfying incremental requests even
    // while Windows accepts input; recovery must not keep showing that image.
    private var lastReadAt=ProcessInfo.processInfo.systemUptime
    private var lastRefreshAt=0.0
    // Only the serial writer touches this clock. QEMU delays ordinary RFB key
    // transitions by 10 ms and drops events, including releases, on queue overflow.
    private var lastKeyWrite=0.0
    private let receive:@MainActor @Sendable (Data,Int,Int)->Void
    private let layout:@MainActor @Sendable (DesktopScreen)->Void
    private let failed:@MainActor @Sendable (String)->Void

    init(path:String,receive:@escaping @MainActor @Sendable (Data,Int,Int)->Void,
         layout:@escaping @MainActor @Sendable (DesktopScreen)->Void,
         failed:@escaping @MainActor @Sendable (String)->Void){
        self.path=path;self.receive=receive;self.layout=layout;self.failed=failed
    }
    func start(){queue.async{[self] in run()}}
    func stop(){
        // Ordered after releaseInput's key/button releases on the same queue.
        writes.async{[self] in
            state.lock();stopped=true;state.unlock()
            writeLock.lock();if fd>=0 {_=shutdown(fd,SHUT_RDWR)};writeLock.unlock()
        }
    }
    func requestPixels(_ enabled:Bool){
        state.lock();let changed=updates != enabled;updates=enabled;let connected=ready;state.unlock()
        if changed && enabled && connected {writes.async{[self] in try? request(incremental:false)}}
    }
    func pointer(x:Int,y:Int,buttons:UInt8){
        let px=UInt16(clamping:x),py=UInt16(clamping:y)
        send([5,buttons,UInt8(px>>8),UInt8(px&255),UInt8(py>>8),UInt8(py&255)])
    }
    func key(_ symbol:UInt32,down:Bool){
        send([4,down ? 1:0,0,0,UInt8(symbol>>24),UInt8((symbol>>16)&255),UInt8((symbol>>8)&255),UInt8(symbol&255)])
    }
    func setScreens(_ screens:[DesktopScreen]){
        guard !screens.isEmpty,screens.count<=16 else{return}
        let width=screens.map{$0.x+$0.width}.max() ?? 0,height=screens.map{$0.y+$0.height}.max() ?? 0
        guard width>0,height>0,width<=16384,height<=16384,
              screens.allSatisfy({$0.x>=0 && $0.y>=0 && $0.width>=640 && $0.height>=480 && $0.width<=4096 && $0.height<=4096}) else{return}
        state.lock()
        if !ready {pendingLayout=screens;state.unlock();return}
        state.unlock()
        var message:[UInt8]=[251,0,UInt8(width>>8),UInt8(width&255),UInt8(height>>8),UInt8(height&255),UInt8(screens.count),0]
        for screen in screens {
            message += [UInt8(screen.id>>24),UInt8((screen.id>>16)&255),UInt8((screen.id>>8)&255),UInt8(screen.id&255)]
            for value in [screen.x,screen.y,screen.width,screen.height] {message += [UInt8(value>>8),UInt8(value&255)]}
            message += [0,0,0,0]
        }
        send(message)
    }
    private func send(_ bytes:[UInt8]){
        state.lock();let connected=ready && !stopped;state.unlock()
        if connected {writes.async{[self] in
            do {
                if bytes.first == 4 {
                    let delay=lastKeyWrite+0.010-ProcessInfo.processInfo.systemUptime
                    if delay>0 {Thread.sleep(forTimeInterval:delay)}
                }
                try write(Data(bytes))
                if bytes.first == 4 {lastKeyWrite=ProcessInfo.processInfo.systemUptime}
            }catch{stop()}
        }}
    }
    private var isStopped:Bool {state.lock();defer{state.unlock()};return stopped}
    private func failure(_ text:String)->NSError {NSError(domain:"Desktop",code:1,userInfo:[NSLocalizedDescriptionKey:text])}
    private func read(_ count:Int)throws->Data {
        guard count>=0,count<=8_388_608*4 else{throw failure("The desktop update is too large.")}
        if count == 0 {return Data()}
        var bytes=Data(count:count)
        try bytes.withUnsafeMutableBytes{buffer in
            var offset=0
            while offset<count {
                if isStopped {throw failure("The desktop connection closed.")}
                var descriptor=pollfd(fd:fd,events:Int16(POLLIN),revents:0)
                let result=poll(&descriptor,1,200)
                if result<0 && errno == EINTR {continue}
                guard result>=0 else{throw failure("The desktop disconnected.")}
                if result == 0 {
                    state.lock();let expectingPixels=ready && updates;state.unlock()
                    let now=ProcessInfo.processInfo.systemUptime
                    if expectingPixels {
                        if now-lastReadAt>8 {throw failure("The desktop stopped updating. Reconnecting…")}
                        if count == 1,offset == 0,now-lastReadAt>2,now-lastRefreshAt>2 {
                            lastRefreshAt=now;try request(incremental:false)
                        }
                    }
                    continue
                }
                let received=recv(fd,buffer.baseAddress!.advanced(by:offset),min(count-offset,65536),0)
                guard received>0 else{throw failure("The desktop disconnected.")}
                lastReadAt=ProcessInfo.processInfo.systemUptime;offset+=received
            }
        }
        return bytes
    }
    private func write(_ data:Data)throws {
        writeLock.lock();defer{writeLock.unlock()}
        guard fd>=0,!isStopped else{throw failure("The desktop disconnected.")}
        try data.withUnsafeBytes{buffer in
            var offset=0
            while offset<data.count {
                let sent=Darwin.send(fd,buffer.baseAddress!.advanced(by:offset),data.count-offset,0)
                guard sent>0 else{throw failure("Cannot send desktop input.")};offset+=sent
            }
        }
    }
    private func u16(_ data:Data,_ offset:Int)->Int {data.withUnsafeBytes{Int(UInt16(bigEndian:$0.loadUnaligned(fromByteOffset:offset,as:UInt16.self)))}}
    private func u32(_ data:Data,_ offset:Int)->UInt32 {data.withUnsafeBytes{UInt32(bigEndian:$0.loadUnaligned(fromByteOffset:offset,as:UInt32.self))}}
    private func request(incremental:Bool)throws {
        state.lock();let value=screen;state.unlock()
        var bytes:[UInt8]=[3,incremental ? 1:0]
        for number in [value.x,value.y,value.width,value.height] {bytes += [UInt8(number>>8),UInt8(number&255)]}
        try write(Data(bytes))
    }
    private func setScreen(_ value:DesktopScreen)throws {
        guard value.width>0,value.height>0,value.width<=4096,value.height<=4096,value.width<=8_388_608/value.height else{
            throw failure("Unsupported desktop dimensions.")
        }
        state.lock();let changed=screen.width != value.width || screen.height != value.height || screen.x != value.x || screen.y != value.y
        screen=value;state.unlock()
        if changed || pixels.isEmpty {pixels=Data(count:value.width*value.height*4)}
        Task{@MainActor [layout] in layout(value)}
    }
    private func run(){
        do {
            let socket=Darwin.socket(AF_UNIX,SOCK_STREAM,0)
            guard socket>=0 else{throw failure("Cannot open the Windows desktop.")}
            writeLock.lock();fd=socket;writeLock.unlock()
            defer{writeLock.lock();Darwin.close(socket);fd = -1;writeLock.unlock()}
            var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX)
            let pathBytes=Array(path.utf8)+[0]
            guard pathBytes.count<=MemoryLayout.size(ofValue:address.sun_path) else{throw failure("Desktop socket path is too long.")}
            withUnsafeMutableBytes(of:&address.sun_path){$0.copyBytes(from:pathBytes)}
            let connected=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){connect(socket,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
            guard connected == 0 else{throw failure("Windows is preparing its desktop.")}
            var yes:Int32=1;_=setsockopt(socket,SOL_SOCKET,SO_NOSIGPIPE,&yes,socklen_t(MemoryLayout<Int32>.size))
            var timeout=timeval(tv_sec:3,tv_usec:0);_=setsockopt(socket,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
            let banner=try read(12)
            guard String(data:banner,encoding:.ascii)?.hasPrefix("RFB 003.") == true else{throw failure("Unsupported desktop protocol.")}
            try write(Data("RFB 003.008\n".utf8))
            let count=Int(try read(1)[0]);guard count>0 else{throw failure("The desktop refused this connection.")}
            let types=try read(count);guard types.contains(1) else{throw failure("The private desktop requires unexpected authentication.")}
            try write(Data([1]));let security=try read(4);guard u32(security,0) == 0 else{throw failure("The desktop refused this connection.")}
            try write(Data([1]));let info=try read(24)
            framebufferWidth=u16(info,0);framebufferHeight=u16(info,2)
            let nameLength=Int(u32(info,20));guard nameLength<=4096 else{throw failure("Invalid desktop name.")};_=try read(nameLength)
            try setScreen(DesktopScreen(id:0,x:0,y:0,width:framebufferWidth,height:framebufferHeight))
            try write(Data([0,0,0,0,32,24,0,1,0,255,0,255,0,255,16,8,0,0,0,0]))
            var encodings:[UInt8]=[2,0,0,3]
            for value:Int32 in [0,-223,-308] {let n=UInt32(bitPattern:value);encodings += [UInt8(n>>24),UInt8((n>>16)&255),UInt8((n>>8)&255),UInt8(n&255)]}
            try write(Data(encodings))
            state.lock();ready=true;let planned=pendingLayout;pendingLayout=nil;state.unlock()
            if let planned {setScreens(planned)}
            try request(incremental:false)
            while !isStopped {
                let type=try read(1)[0]
                switch type {
                case 0:try update()
                case 2:break
                case 3:
                    let header=try read(7);let size=Int(u32(header,3));guard size<=1_048_576 else{throw failure("Oversized desktop clipboard.")};_=try read(size)
                default:throw failure("Unsupported desktop update (\(type)).")
                }
            }
        }catch {
            if !isStopped {let reason=error.localizedDescription;Task{@MainActor [failed] in failed(reason)}}
        }
        state.lock();ready=false;state.unlock()
    }
    private func update()throws {
        let header=try read(3),count=u16(header,1)
        guard count<=4096 else{throw failure("Too many desktop rectangles.")}
        var changed=false
        for _ in 0..<count {
            let rect=try read(12);let x=u16(rect,0),y=u16(rect,2),width=u16(rect,4),height=u16(rect,6)
            let encoding=Int32(bitPattern:u32(rect,8))
            if encoding == -223 {
                framebufferWidth=width;framebufferHeight=height
                try setScreen(DesktopScreen(id:0,x:0,y:0,width:width,height:height));continue
            }
            if encoding == -308 {
                let layout=try read(4);let number=Int(layout[0]);guard number>0,number<=16 else{throw failure("Invalid desktop layout.")}
                var screens:[DesktopScreen]=[]
                for _ in 0..<number {let info=try read(16);screens.append(DesktopScreen(id:u32(info,0),x:u16(info,4),y:u16(info,6),width:u16(info,8),height:u16(info,10)))}
                if x == 1 && y != 0 {throw failure("Windows did not accept the requested display layout (\(y)).")}
                if y == 0,let primary=screens.first(where:{$0.id == 0}) ?? screens.first {
                    framebufferWidth=width;framebufferHeight=height;try setScreen(primary)
                }
                continue
            }
            guard encoding == 0,width>0,height>0,width<=8_388_608/height else{throw failure("Unsupported desktop encoding.")}
            let bytes=try read(width*height*4)
            state.lock();let target=screen;state.unlock()
            let left=max(x,target.x),top=max(y,target.y),right=min(x+width,target.x+target.width),bottom=min(y+height,target.y+target.height)
            if right>left,bottom>top {
                pixels.withUnsafeMutableBytes{destination in bytes.withUnsafeBytes{source in
                    for row in top..<bottom {
                        memcpy(destination.baseAddress!.advanced(by:((row-target.y)*target.width+left-target.x)*4),
                               source.baseAddress!.advanced(by:((row-y)*width+left-x)*4),(right-left)*4)
                    }
                }}
                changed=true
            }
        }
        if changed {
            state.lock();let target=screen;state.unlock()
            let image=pixels;let gate=DispatchSemaphore(value:0)
            Task{@MainActor [receive] in receive(image,target.width,target.height);gate.signal()}
            while gate.wait(timeout:.now()+0.2) == .timedOut {if isStopped {return}}
        }
        state.lock();let enabled=updates;state.unlock()
        if enabled {try request(incremental:true)}
    }
}
