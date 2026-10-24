import Foundation
import Darwin
import Metal
import CryptoKit

/// Private single-window experiment. Only descriptors cross this socket.
final class ExperimentalGpuFrames:@unchecked Sendable {
    static let shared=ExperimentalGpuFrames()
    private struct Endpoint:Codable {var socket:String;var qemuPID:Int32;var frontendPID:Int32}
    private static let trialRoot=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Perpendicular IVSHMEM Trial")
    private static let endpointURL=trialRoot.appendingPathComponent("Control/wgc-export-endpoint.json")
    private static let machineID="c9f319b7-6689-45ac-8003-b8e5fbaebbb8"
    private static let qmp="/tmp/perpendicular-\(getuid())-c9f319b7.sock"
    private static let savedEndpoint:Endpoint? = {
        var info=stat();guard lstat(endpointURL.path,&info)==0,info.st_uid==getuid(),info.st_mode & 0o777 == 0o600,
            let data=try? Data(contentsOf:endpointURL),data.count<1024,let e=try? JSONDecoder().decode(Endpoint.self,from:data),
            e.qemuPID>1,e.frontendPID>1,e.socket.hasPrefix("/tmp/perp-wgc-\(getuid())-"),e.socket.hasSuffix(".sock"),
            e.socket.dropFirst("/tmp/perp-wgc-\(getuid())-".count).dropLast(5).allSatisfy({$0.isNumber}),
            (try? MachineControl.execute(socket:qmp,operation:"query-uuid",expectedUUID:machineID,expectedPID:e.qemuPID)) != nil else{return nil}
        return e
    }()
    static let socketPath=savedEndpoint?.socket ?? "/tmp/perp-wgc-\(getuid())-\(getpid()).sock"
    private let queue=DispatchQueue(label:"perpendicular.wgc-gpu")
    private let device=MTLCreateSystemDefaultDevice()!
    private var commands:(any MTLCommandQueue)?
    private var source:DispatchSourceRead?
    private var listener:Int32 = -1
    private var resources:[Resource]=[]
    private let failureLock=NSLock()
    private var broken=false
    var isFailed:Bool{failureLock.lock();defer{failureLock.unlock()};return broken}
    private func fail(){failureLock.lock();broken=true;failureLock.unlock()}
    private final class Resource:@unchecked Sendable {
        let width:Int,height:Int,stride:Int
        let buffer:any MTLBuffer
        let texture:any MTLTexture
        init(width:Int,height:Int,stride:Int,buffer:any MTLBuffer,texture:any MTLTexture){
            self.width=width;self.height=height;self.stride=stride;self.buffer=buffer;self.texture=texture
        }
    }
    func start()throws {
        commands=device.makeCommandQueue()
        if let previous=Self.savedEndpoint {
            guard kill(previous.frontendPID,0) != 0,errno==ESRCH else{throw CocoaError(.fileWriteFileExists)}
            var info=stat()
            if lstat(Self.socketPath,&info)==0 {
                guard info.st_uid==getuid(),info.st_mode & mode_t(S_IFMT)==mode_t(S_IFSOCK),unlink(Self.socketPath)==0 else{throw CocoaError(.fileWriteNoPermission)}
            }
        }
        let fd=Darwin.socket(AF_UNIX,SOCK_DGRAM,0);guard fd>=0 else{throw CocoaError(.fileReadUnknown)}
        var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX)
        let path=Array(Self.socketPath.utf8)+[0]
        guard path.count<=MemoryLayout.size(ofValue:address.sun_path) else{Darwin.close(fd);throw CocoaError(.fileReadUnknown)}
        withUnsafeMutableBytes(of:&address.sun_path){$0.copyBytes(from:path)}
        let result=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        guard result==0,chmod(Self.socketPath,0o600)==0,fcntl(fd,F_SETFL,O_NONBLOCK)==0 else{Darwin.close(fd);throw CocoaError(.fileReadUnknown)}
        listener=fd;let source=DispatchSource.makeReadSource(fileDescriptor:fd,queue:queue);self.source=source
        source.setEventHandler{[weak self] in self?.receive()};source.resume()
    }
    func publishEndpoint()throws {
        let text=try String(contentsOf:Self.trialRoot.appendingPathComponent("qemu-system-aarch64.pid"),encoding:.utf8)
        guard let pid=Int32(text.trimmingCharacters(in:.whitespacesAndNewlines)),pid>1 else{throw CocoaError(.fileReadCorruptFile)}
        _=try MachineControl.execute(socket:Self.qmp,operation:"query-uuid",expectedUUID:Self.machineID,expectedPID:pid)
        let data=try JSONEncoder().encode(Endpoint(socket:Self.socketPath,qemuPID:pid,frontendPID:getpid()))
        try data.write(to:Self.endpointURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:Self.endpointURL.path)
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
            while resources.count>=16 || resources.reduce(0,{$0+$1.buffer.length})+length>128*1024*1024 {guard !resources.isEmpty else{break};resources.removeFirst()}
            resources.append(Resource(width:width,height:height,stride:stride,buffer:buffer,texture:texture))
            ExperimentalGpuTrace.record("gpu-resource",h)
        }
    }
    func copy(_ header:[String:Any],completion:@escaping @Sendable (GuestFrameSurface?,[String:Any])->Void){
        let packet=GuestPacket(header:header)
        queue.async{[self] in
            let header=packet.header
            receive()
            let started=ProcessInfo.processInfo.systemUptime
            guard let w=header["width"] as? Int,let h=header["height"] as? Int,let stride=header["stride"] as? Int,
                  let marker=header["gpuMarker"] as? String,marker.count==64,
                  marker.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),
                  let resource=resources.first(where:{r in
                      guard r.width==((w+63)/64)*64,r.height==((h+63)/64)*64+1,r.stride==stride else{return false}
                      let p=r.buffer.contents().advanced(by:h*stride).assumingMemoryBound(to:UInt8.self)
                      return (0..<32).map{String(format:"%02x",p[$0])}.joined()==marker
                  }),let output=GuestFrameSurface.allocate(width:w,height:h,stride:stride),
                  let command=commands?.makeCommandBuffer(),let blit=command.makeBlitCommandEncoder() else{self.fail();var diagnostic=header;diagnostic["cachedResources"]=resources.map{["width":$0.width,"height":$0.height,"stride":$0.stride]};ExperimentalGpuTrace.record("gpu-rejected",diagnostic);completion(nil,[:]);return}
            blit.copy(from:resource.texture,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),sourceSize:MTLSize(width:w,height:h,depth:1),
                      to:output.texture,destinationSlice:0,destinationLevel:0,destinationOrigin:MTLOrigin(x:0,y:0,z:0));blit.endEncoding()
            command.addCompletedHandler{buffer in
                let header=packet.header
                guard buffer.status == .completed else{self.fail();ExperimentalGpuTrace.record("gpu-rejected",header);completion(nil,[:]);return}
                var metrics:[String:Any]=["hostGpuCopyMilliseconds":(ProcessInfo.processInfo.systemUptime-started)*1000,"hostGpuSourceMatched":true]
                if let expected=header["guestPixelsSHA256Packed"] as? String{
                    var hash=SHA256();for row in 0..<h{hash.update(data:Data(bytesNoCopy:output.contents.advanced(by:row*stride),count:w*4,deallocator:.none))}
                    let actual=hash.finalize().map{String(format:"%02x",$0)}.joined()
                    metrics["hostPixelsSHA256Packed"]=actual;metrics["hostPixelsMatchGuest"]=actual==expected
                    guard actual==expected else{self.fail();completion(nil,metrics);return}
                }
                // After this GPU copy finishes the guest may reuse its source.
                // Metal presentation reads only our separate immutable output.
                withExtendedLifetime(resource){completion(output,metrics)}
            };command.commit()
        }
    }
}
