import Foundation
import Darwin

enum MachineControl {
    static func execute(socket path:String, operation:String, arguments:[String:Any]=[:]) throws -> [String:Any] {
        let fd=socket(AF_UNIX,SOCK_STREAM,0)
        guard fd>=0 else { throw failure("Cannot open machine control.") }
        defer { close(fd) }
        var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX)
        let bytes=Array(path.utf8)+[0]
        guard bytes.count<=MemoryLayout.size(ofValue:address.sun_path) else { throw failure("Machine control path is too long.") }
        withUnsafeMutableBytes(of:&address.sun_path){$0.copyBytes(from:bytes)}
        let connected=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        guard connected==0 else { throw failure("Windows is not running.") }
        var noSignal:Int32=1
        _=setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size))
        let deadline=ProcessInfo.processInfo.systemUptime+3
        var buffer=Data()
        func receive() throws -> [String:Any] {
            while true {
                if let newline=buffer.firstIndex(of:10) {
                    let record=buffer.prefix(upTo:newline);buffer.removeSubrange(...newline)
                    guard let value=try JSONSerialization.jsonObject(with:record) as? [String:Any] else { throw failure("Invalid machine reply.") }
                    return value
                }
                guard buffer.count<262144,ProcessInfo.processInfo.systemUptime<deadline else {throw failure("Machine control timed out.")}
                var descriptor=pollfd(fd:fd,events:Int16(POLLIN),revents:0)
                guard poll(&descriptor,1,100)>=0 else {throw failure("Machine control disconnected.")}
                if descriptor.revents==0 {continue}
                var bytes=[UInt8](repeating:0,count:8192)
                let size=recv(fd,&bytes,bytes.count,0)
                guard size>0 else {throw failure("Machine control disconnected.")}
                buffer.append(contentsOf:bytes.prefix(size))
            }
        }
        func exchange(_ command:[String:Any]) throws -> [String:Any] {
            var bytes=try JSONSerialization.data(withJSONObject:command);bytes.append(10)
            try bytes.withUnsafeBytes { pointer in
                var offset=0
                while offset<bytes.count {
                    let sent=send(fd,pointer.baseAddress!.advanced(by:offset),bytes.count-offset,0)
                    guard sent>0 else {throw failure("Cannot send machine command.")};offset+=sent
                }
            }
            while true {
                let reply=try receive()
                if let result=reply["return"] {return result as? [String:Any] ?? [:]}
                if let error=reply["error"] as? [String:Any] {throw failure(error["desc"] as? String ?? "Machine command failed.")}
            }
        }
        _=try receive()
        _=try exchange(["execute":"qmp_capabilities"])
        return try exchange(["execute":operation,"arguments":arguments])
    }
    private static func failure(_ message:String)->NSError {NSError(domain:"Machine",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
}
