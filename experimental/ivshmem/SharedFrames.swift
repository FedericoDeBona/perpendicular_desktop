import Foundation
import Darwin
import CryptoKit

@_silgen_name("OSMemoryBarrier") private func ivshmemBarrier()

/// Experimental single-session receiver. One writer, three slots, owned copy to Metal.
final class ExperimentalSharedFrames:@unchecked Sendable {
    static var mode:String { (try? String(contentsOf:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Perpendicular IVSHMEM Trial/frame-mode"),encoding:.utf8))?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "ivshmem" }
    static let regionBytes=64*1024*1024
    static let slotBytes=((regionBytes-4096)/3)/4096*4096
    static let payloadOffset=32768
    static let name="frames-"+UUID().uuidString+".shm"
    static let socketPath="/tmp/perp-frames-\(getuid())-\(getpid()).sock"
    private let queue=DispatchQueue(label:"perpendicular.ivshmem.experiment")
    private let memory:UnsafeMutableRawPointer
    private let fd:Int32
    private let listener:Int32
    private let epoch:UInt32
    private var listenerSource:DispatchSourceRead?
    private var connectionSource:DispatchSourceRead?
    private var connection:Int32 = -1
    private var seenShared=false
    private var disabled=false
    private let frame:@MainActor @Sendable (GuestPacket)->Void
    private let failed:@MainActor @Sendable ()->Void

    init(directory:URL,frame:@escaping @MainActor @Sendable (GuestPacket)->Void,
         failed:@escaping @MainActor @Sendable ()->Void)throws {
        self.frame=frame;self.failed=failed
        let path=directory.appendingPathComponent(Self.name).path
        let file=open(path,O_CREAT|O_EXCL|O_RDWR,0o600)
        guard file>=0 else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
        guard ftruncate(file,off_t(Self.regionBytes))==0,
              let mapped=mmap(nil,Self.regionBytes,PROT_READ|PROT_WRITE,MAP_SHARED,file,0),mapped != MAP_FAILED else {
            Darwin.close(file);throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))
        }
        memory=mapped;fd=file;epoch=UInt32.random(in:1...UInt32.max-1)
        memory.storeBytes(of:UInt32(0x49565331),as:UInt32.self)
        memory.advanced(by:8).storeBytes(of:epoch,as:UInt32.self)
        ivshmemBarrier();memory.advanced(by:4).storeBytes(of:UInt32(Self.mode == "ivshmem" ? 1:0),as:UInt32.self)
        let socket=Darwin.socket(AF_UNIX,SOCK_STREAM,0)
        guard socket>=0 else{munmap(mapped,Self.regionBytes);Darwin.close(file);throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
        listener=socket
        var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX)
        let bytes=Array(Self.socketPath.utf8)+[0]
        guard bytes.count<=MemoryLayout.size(ofValue:address.sun_path) else{throw CocoaError(.fileWriteInvalidFileName)}
        withUnsafeMutableBytes(of:&address.sun_path){$0.copyBytes(from:bytes)}
        let bound=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(socket,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        guard bound==0,chmod(Self.socketPath,0o600)==0,listen(socket,1)==0,
              fcntl(socket,F_SETFL,fcntl(socket,F_GETFL)|O_NONBLOCK)==0 else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
        let source=DispatchSource.makeReadSource(fileDescriptor:socket,queue:queue)
        listenerSource=source
        source.setEventHandler{[weak self] in self?.acceptConnection()}
        source.resume()
    }
    private func load(_ offset:Int)->UInt32 {let value=memory.advanced(by:offset).load(as:UInt32.self);ivshmemBarrier();return value}
    private func store(_ value:UInt32,_ offset:Int){ivshmemBarrier();memory.advanced(by:offset).storeBytes(of:value,as:UInt32.self)}
    func controlDisconnected(){queue.async{[weak self] in if let self,self.seenShared {self.fail()}}}
    func disable(){queue.async{[weak self] in self?.fail()}}
    private func fail(){
        guard !disabled else{return};disabled=true;store(0,4)
        connectionSource?.cancel();connectionSource=nil
        if connection>=0 {Darwin.close(connection);connection = -1}
        Task{@MainActor [failed] in failed()}
    }
    private func acceptConnection(){
        let incoming=Darwin.accept(listener,nil,nil)
        guard incoming>=0 else{return}
        guard connection<0,!disabled else{Darwin.close(incoming);return}
        connection=incoming
        _=fcntl(incoming,F_SETFL,fcntl(incoming,F_GETFL)|O_NONBLOCK)
        let source=DispatchSource.makeReadSource(fileDescriptor:incoming,queue:queue)
        connectionSource=source
        source.setEventHandler{[weak self] in self?.readNotifications()}
        source.resume()
    }
    private func readNotifications(){
        var bytes=[UInt8](repeating:0,count:4096)
        let count=Darwin.read(connection,&bytes,bytes.count)
        if count<0,errno==EAGAIN{return}
        guard count>0 else{fail();return}
        var pending=[(UInt32,Int)]()
        for slot in 0..<3 {
            let base=4096+slot*Self.slotBytes
            let ready=load(base)
            if ready != load(base+4){pending.append((ready,base))}
        }
        for (ready,base) in pending.sorted(by:{$0.0<$1.0}) {
            do {
                let started=ProcessInfo.processInfo.systemUptime
                let metadataCount=Int(load(base+8)),pixelCount=Int(load(base+12))
                guard ready>0,(1...16384).contains(metadataCount),pixelCount>0,pixelCount<=Self.slotBytes-Self.payloadOffset else{throw CocoaError(.coderReadCorrupt)}
                let json=Data(bytes:memory.advanced(by:base+64),count:metadataCount)
                guard var header=try JSONSerialization.jsonObject(with:json) as? [String:Any],
                      header["ivshmemEpoch"] as? UInt32 == epoch,header["ivshmemSequence"] as? UInt32 == ready,
                      header["type"] as? String == "frame",header["transport"] as? String == "ivshmem-raw",
                      let window=header["window"] as? String,window.utf8.count<192,
                      let width=header["width"] as? Int,let height=header["height"] as? Int,
                      let stride=header["stride"] as? Int,width>0,height>0,width<=16384,height<=16384,
                      width<=8_388_608/height,stride>=width*4,stride<=width*4+255,
                      stride<=34*1024*1024/height,pixelCount==stride*height,header["bytes"] as? Int==pixelCount else{throw CocoaError(.coderReadCorrupt)}
                let source=memory.advanced(by:base+Self.payloadOffset)
                let surface=GuestFrameSurface.allocate(width:width,height:height,stride:stride)
                let pixels:Data
                if let surface{surface.contents.copyMemory(from:source,byteCount:pixelCount);pixels=Data()}
                else{pixels=Data(bytes:source,count:pixelCount)}
                if let expected=header["guestPixelsSHA256"] as? String {
                    let data=Data(bytesNoCopy:source,count:pixelCount,deallocator:.none)
                    let actual=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
                    header["hostPixelsSHA256"]=actual;header["hostPixelsMatchGuest"]=expected==actual
                    guard expected==actual else{throw CocoaError(.coderReadCorrupt)}
                }
                let received=ProcessInfo.processInfo.systemUptime
                header["hostReceiveMilliseconds"]=(received-started)*1000
                header["hostDecodeMilliseconds"]=0;header["hostTrialReceiveAt"]=received
                // Release only after the final CPU read; Metal uses its own immutable copy.
                store(ready,base+4)
                seenShared=true
                let value=GuestPacket(header:header,pixels:pixels,surface:surface)
                Task{@MainActor [frame] in
                    var h=value.header;h["hostDispatchMilliseconds"]=(ProcessInfo.processInfo.systemUptime-received)*1000
                    frame(GuestPacket(header:h,pixels:value.pixels,surface:value.surface))
                }
            }catch{fail();return}
        }
    }
    deinit {
        listenerSource?.cancel();connectionSource?.cancel()
        if connection>=0{Darwin.close(connection)}
        Darwin.close(listener);Darwin.close(fd);munmap(memory,Self.regionBytes);unlink(Self.socketPath)
    }
}
