import Foundation
import Darwin
import Metal
import CryptoKit

/// Opt-in, bounded diagnostic trace. No titles, pixels or input text are logged.
/// A new private file is required; an existing file is never overwritten.
final class PipelineTrace:@unchecked Sendable {
    static let shared=PipelineTrace()
    private let lock=NSLock()
    private var count=0
    private var previousCostMilliseconds=0.0
    private let started=ProcessInfo.processInfo.systemUptime
    private let fd:Int32
    private init(){
        if let path=ProcessInfo.processInfo.environment["PERPENDICULAR_PIPELINE_TRACE"],path.hasPrefix("/") {
            fd=Darwin.open(path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        }else{fd = -1}
    }
    static func record(_ event:String,_ id:String,_ fields:[String:Any]=[:]){
        let trace=shared
        guard trace.fd>=0 else{return}
        let now=ProcessInfo.processInfo.systemUptime
        trace.lock.lock();defer{trace.lock.unlock()}
        guard trace.count<12000,now-trace.started<360 else{return}
        var row=fields;row["event"]=event;row["id"]=id;row["hostSeconds"]=now
        row["previousRecordMilliseconds"]=trace.previousCostMilliseconds
        guard let data=try? JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]) else{return}
        let bytes=data+Data([10])
        bytes.withUnsafeBytes{_ = Darwin.write(trace.fd,$0.baseAddress!,bytes.count)}
        trace.count+=1
        trace.previousCostMilliseconds=(ProcessInfo.processInfo.systemUptime-now)*1000
    }
    static var enabled:Bool {shared.fd>=0}
    static func frameID(_ header:[String:Any])->String {
        "wgc:\(header["window"] ?? "?"):\(header["generation"] ?? "?"):\(header["sequence"] ?? "?")"
    }
}

/// Receives descriptors from the matched renderer; pixel traffic stays on GPU.
final class NativeWindowFrames:@unchecked Sendable {
    static let shared=NativeWindowFrames()
    private struct Endpoint:Codable {var socket:String;var qemuPID:Int32;var frontendPID:Int32}
    private var endpointURL:URL!
    private var root:URL!
    private var machineID=""
    private var qmp=""
    private var savedEndpoint:Endpoint?
    private var ownerFD:Int32 = -1
    private(set) var socketPath=""
    private let queue=DispatchQueue(label:"perpendicular.window-gpu")
    private let device=MTLCreateSystemDefaultDevice()!
    private var commands:(any MTLCommandQueue)?
    private var source:DispatchSourceRead?
    private var listener:Int32 = -1
    private var resources:[Resource]=[]
    private let failureLock=NSLock()
    private var broken=false
    private var failureDetails:[String:Any]=[:]
    private var cacheDetails:[String:Any]=[:]
    var cacheDiagnostics:[String:Any]{failureLock.lock();defer{failureLock.unlock()};return cacheDetails}
    private func updateCacheDiagnostics(){
        let value:[String:Any]=["resources":resources.count,"bytes":resources.reduce(0,{$0+$1.buffer.length}),
                               "windows":Set(resources.compactMap(\.window)).count]
        failureLock.lock();cacheDetails=value;failureLock.unlock()
    }
    var diagnostics:[String:Any]{failureLock.lock();defer{failureLock.unlock()};return failureDetails}
    var isFailed:Bool{failureLock.lock();defer{failureLock.unlock()};return broken}
    private func fail(_ reason:String="gpu-command",details:[String:Any]=[:]){
        failureLock.lock();broken=true;failureDetails=details;failureDetails["reason"]=reason;failureLock.unlock()
    }
    private final class Resource:@unchecked Sendable {
        var window:String?
        let width:Int,height:Int,stride:Int
        let buffer:any MTLBuffer
        let texture:any MTLTexture
        init(width:Int,height:Int,stride:Int,buffer:any MTLBuffer,texture:any MTLTexture){
            self.width=width;self.height=height;self.stride=stride;self.buffer=buffer;self.texture=texture
        }
    }
    func prepare(directory:URL,machineID:String)throws {
        root=directory;self.machineID=machineID
        qmp="/tmp/perpendicular-\(getuid())-\(machineID.prefix(8)).sock"
        endpointURL=root.appendingPathComponent("Control/wgc-export-endpoint.json")
        socketPath="/tmp/perp-wgc-\(getuid())-\(getpid()).sock"
        var info=stat()
        let control=root.appendingPathComponent("Control")
        try FileManager.default.createDirectory(at:control,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        guard lstat(control.path,&info)==0,info.st_uid==getuid(),info.st_mode & mode_t(S_IFMT)==mode_t(S_IFDIR) else{throw CocoaError(.fileWriteNoPermission)}
        let lock=Darwin.open(control.appendingPathComponent("wgc-owner.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard lock>=0 else{throw CocoaError(.fileWriteNoPermission)}
        var keepLock=false;defer{if !keepLock{Darwin.close(lock)}}
        var ownership=flock()
        ownership.l_type=Int16(F_WRLCK);ownership.l_whence=Int16(SEEK_SET)
        guard fcntl(lock,F_SETLK,&ownership)==0 else{throw CocoaError(.fileWriteFileExists)}
        // The launch record stores the actual immutable renderer environment.
        // Publishing a new frontend must never redirect an already-running VM.
        var rendererSocket:String?
        let launchFile=root.appendingPathComponent("desktop-launch.json")
        if lstat(launchFile.path,&info)==0,info.st_uid==getuid(),info.st_mode & 0o777 == 0o600,
           let data=try? Data(contentsOf:launchFile),data.count<8192,
           let launch=try? JSONDecoder().decode(DesktopLaunch.self,from:data),launch.machineID==machineID,
           let path=launch.wgcSocket,path.hasPrefix("/tmp/perp-wgc-\(getuid())-"),path.hasSuffix(".sock"),
           path.dropFirst("/tmp/perp-wgc-\(getuid())-".count).dropLast(5).allSatisfy({$0.isNumber}),
           (try? MachineControl.execute(socket:qmp,operation:"query-uuid",expectedUUID:machineID,expectedPID:launch.pid)) != nil {
            rendererSocket=path
        }
        if lstat(endpointURL.path,&info)==0,info.st_uid==getuid(),info.st_mode & 0o777 == 0o600,
           let data=try? Data(contentsOf:endpointURL),data.count<1024,let e=try? JSONDecoder().decode(Endpoint.self,from:data),
           e.qemuPID>1,e.frontendPID>1,e.socket.hasPrefix("/tmp/perp-wgc-\(getuid())-"),e.socket.hasSuffix(".sock"),
           e.socket.dropFirst("/tmp/perp-wgc-\(getuid())-".count).dropLast(5).allSatisfy({$0.isNumber}),
           (try? MachineControl.execute(socket:qmp,operation:"query-uuid",expectedUUID:machineID,expectedPID:e.qemuPID)) != nil {
            guard kill(e.frontendPID,0) != 0,errno==ESRCH else{throw CocoaError(.fileWriteFileExists)}
            savedEndpoint=e;socketPath=e.socket
        }
        if let rendererSocket {socketPath=rendererSocket}
        if lstat(socketPath,&info)==0 {
            guard info.st_uid==getuid(),info.st_mode & mode_t(S_IFMT)==mode_t(S_IFSOCK),unlink(socketPath)==0 else{throw CocoaError(.fileWriteNoPermission)}
        }
        commands=device.makeCommandQueue()
        let fd=Darwin.socket(AF_UNIX,SOCK_DGRAM,0);guard fd>=0 else{throw CocoaError(.fileReadUnknown)}
        var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX)
        let path=Array(socketPath.utf8)+[0]
        guard path.count<=MemoryLayout.size(ofValue:address.sun_path) else{Darwin.close(fd);throw CocoaError(.fileReadUnknown)}
        withUnsafeMutableBytes(of:&address.sun_path){$0.copyBytes(from:path)}
        let result=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        guard result==0,chmod(socketPath,0o600)==0,fcntl(fd,F_SETFL,O_NONBLOCK)==0 else{Darwin.close(fd);throw CocoaError(.fileReadUnknown)}
        listener=fd;let source=DispatchSource.makeReadSource(fileDescriptor:fd,queue:queue);self.source=source
        source.setEventHandler{[weak self] in self?.receive()};source.resume()
        ownerFD=lock;keepLock=true
    }
    func publishEndpoint()throws {
        let text=try String(contentsOf:root.appendingPathComponent("qemu-system-aarch64.pid"),encoding:.utf8)
        guard let pid=Int32(text.trimmingCharacters(in:.whitespacesAndNewlines)),pid>1 else{throw CocoaError(.fileReadCorruptFile)}
        _=try MachineControl.execute(socket:qmp,operation:"query-uuid",expectedUUID:machineID,expectedPID:pid)
        let data=try JSONEncoder().encode(Endpoint(socket:socketPath,qemuPID:pid,frontendPID:getpid()))
        try data.write(to:endpointURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:endpointURL.path)
    }
    private func receive(){
        for _ in 0..<32 {
            var bytes=[CChar](repeating:0,count:1024)
            let fd=perp_wgc_receive(listener,&bytes,bytes.count)
            guard fd>=0 else{return};defer{Darwin.close(fd)}
            guard let raw=String(bytes:bytes.prefix(while:{$0 != 0}).map{UInt8(bitPattern:$0)},encoding:.utf8)?.data(using:.utf8),
                  let h=try? JSONSerialization.jsonObject(with:raw) as? [String:Any],
                  let width=h["width"] as? Int,let height=h["height"] as? Int,let stride=h["stride"] as? Int,
                  let size=h["size"] as? Int,width>=32,width<=4096,height>=2,height<=4096,
                  stride>=width*4,stride<=width*4+255,stride%256==0,size==stride*height,size<=34*1024*1024 else{continue}
            var info=stat();guard fstat(fd,&info)==0,info.st_size>=size,info.st_size<=64*1024*1024,info.st_size%Int64(getpagesize())==0 else{continue}
            let length=Int(info.st_size)
            guard let pointer=mmap(nil,length,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0),pointer != MAP_FAILED else{continue}
            guard let buffer=device.makeBuffer(bytesNoCopy:pointer,length:length,options:.storageModeShared,deallocator:{p,n in _=munmap(p,n)}) else{munmap(pointer,length);continue}
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false)
            d.storageMode = .shared;d.usage = .shaderRead
            guard let texture=buffer.makeTexture(descriptor:d,offset:0,bytesPerRow:stride) else{continue}
            while resources.count>=32 || resources.reduce(0,{$0+$1.buffer.length})+length>256*1024*1024 {guard !resources.isEmpty else{break};resources.removeFirst()}
            resources.append(Resource(width:width,height:height,stride:stride,buffer:buffer,texture:texture))
            updateCacheDiagnostics()
            NativeWindowTrace.record("gpu-resource",h)
        }
    }
    func retire(window:String){
        queue.async{[self] in resources.removeAll{$0.window==window};updateCacheDiagnostics()}
    }
    func copy(_ header:[String:Any],completion:@escaping @Sendable (GuestFrameSurface?,[String:Any])->Void){
        let packet=GuestPacket(header:header)
        let traceID=PipelineTrace.frameID(header)
        PipelineTrace.record("wgc-header",traceID,header.filter{["sequence","generation","width","height","guestCaptureSelectedQPC","guestGpuSubmitMilliseconds","guestGpuWaitMilliseconds","guestReferenceReadback"].contains($0.key)})
        queue.async{[self] in
            let header=packet.header
            receive()
            let started=ProcessInfo.processInfo.systemUptime
            PipelineTrace.record("wgc-copy-start",traceID)
            guard let w=header["width"] as? Int,let h=header["height"] as? Int,let stride=header["stride"] as? Int,
                  let marker=header["gpuMarker"] as? String,marker.count==64,
                  marker.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),
                  let resource=resources.first(where:{r in
                      guard r.width==((w+63)/64)*64,r.height==((h+63)/64)*64+1,r.stride==stride else{return false}
                      let p=r.buffer.contents().advanced(by:h*stride).assumingMemoryBound(to:UInt8.self)
                      return (0..<32).map{String(format:"%02x",p[$0])}.joined()==marker
                  }),let output=GuestFrameSurface.allocate(width:w,height:h,stride:stride),
                  let command=commands?.makeCommandBuffer(),let blit=command.makeBlitCommandEncoder() else{var diagnostic=header;diagnostic["cachedResources"]=resources.map{["width":$0.width,"height":$0.height,"stride":$0.stride]};self.fail("resource-match-or-allocation",details:diagnostic);NativeWindowTrace.record("gpu-rejected",diagnostic);completion(nil,[:]);return}
            if let window=header["window"] as? String {
                resource.window=window
                // Only the newest allocation for this authenticated window is
                // reusable. In-flight copies retain their own Resource lease.
                resources.removeAll{$0 !== resource && $0.window==window}
                updateCacheDiagnostics()
            }
            blit.copy(from:resource.texture,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),sourceSize:MTLSize(width:w,height:h,depth:1),
                      to:output.texture,destinationSlice:0,destinationLevel:0,destinationOrigin:MTLOrigin(x:0,y:0,z:0));blit.endEncoding()
            output.traceID=traceID
            command.addCompletedHandler{buffer in
                PipelineTrace.record("wgc-copy-complete",traceID,["gpuStart":buffer.gpuStartTime,"gpuEnd":buffer.gpuEndTime,"status":buffer.status.rawValue])
                let header=packet.header
                guard buffer.status == .completed else{self.fail();NativeWindowTrace.record("gpu-rejected",header);completion(nil,[:]);return}
                var metrics:[String:Any]=["hostGpuCopyMilliseconds":(ProcessInfo.processInfo.systemUptime-started)*1000,"hostGpuSourceMatched":true]
                if let expected=header["guestPixelsSHA256Packed"] as? String{
                    var hash=SHA256();for row in 0..<h{hash.update(data:Data(bytesNoCopy:output.contents.advanced(by:row*stride),count:w*4,deallocator:.none))}
                    let actual=hash.finalize().map{String(format:"%02x",$0)}.joined()
                    metrics["hostPixelsSHA256Packed"]=actual;metrics["hostPixelsMatchGuest"]=actual==expected
                    guard actual==expected else{self.fail("pixel-hash",details:["window":header["window"] ?? "","expected":expected,"actual":actual,"metrics":metrics]);completion(nil,metrics);return}
                }
                // After this GPU copy finishes the guest may reuse its source.
                // Metal presentation reads only our separate immutable output.
                withExtendedLifetime(resource){completion(output,metrics)}
            };PipelineTrace.record("wgc-copy-commit",traceID);command.commit()
        }
    }
}


enum NativeWindowTrace {
    static func record(_ event:String,_ value:[String:Any]) {
        guard ProcessInfo.processInfo.environment["PERPENDICULAR_STATE_TRACE"] == "1",
              let data=try? JSONSerialization.data(withJSONObject:["type":event,"value":value],options:[.sortedKeys]) else{return}
        try? FileHandle.standardError.write(contentsOf:data+Data([10]))
    }
}
