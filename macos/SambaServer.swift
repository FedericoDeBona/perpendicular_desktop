import Foundation
import CryptoKit
import Security
import Darwin

struct SambaCredentials:Codable,Sendable {
    let username:String
    let password:String
    let port:UInt16
    var server:String {"10.0.2.4"}
}

/// One authenticated, loopback-only server per VM. QEMU exposes its TCP stream
/// at a private guest address; no host LAN listener or macOS account password.
@MainActor
enum SambaServer {
    static func credentials(in directory:URL)throws->SambaCredentials {
        try JSONDecoder().decode(SambaCredentials.self,from:Data(contentsOf:directory.appendingPathComponent("Samba/connection.json")))
    }
    static func ensure(directory:URL,exports:[SharedFolderExport],runtime:URL)async throws->SambaCredentials {
        let fm=FileManager.default,root=directory.appendingPathComponent("Samba")
        guard root.path.utf8.count<85 else {throw MachineSettings.failure("Il percorso della VM è troppo lungo per il servizio cartelle.")}
        try fm.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file=root.appendingPathComponent("connection.json")
        let value:SambaCredentials
        if fm.fileExists(atPath:file.path) {value=try credentials(in:directory)}
        else {
            var bytes=[UInt8](repeating:0,count:32)
            guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes)==errSecSuccess else {throw MachineSettings.failure("Non riesco a preparare l’accesso alle cartelle.")}
            value=SambaCredentials(username:NSUserName(),password:bytes.map{String(format:"%02x",$0)}.joined(),port:try freePort())
            try write(try JSONEncoder().encode(value),to:file)
        }
        var source=value.password.data(using:.utf16LittleEndian)!
        var hash=[UInt8](repeating:0,count:Int(CC_MD4_DIGEST_LENGTH))
        source.withUnsafeMutableBytes{_ = CC_MD4($0.baseAddress,CC_LONG($0.count),&hash)}
        let nt=hash.map{String(format:"%02X",$0)}.joined()
        let line="\(value.username):\(getuid()):XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX:\(nt):[U          ]:LCT-\(String(Int(Date().timeIntervalSince1970),radix:16)):\n"
        let passwordFile=root.appendingPathComponent("smbpasswd")
        if !fm.fileExists(atPath:passwordFile.path) {try write(Data(line.utf8),to:passwordFile)}
        var config="""
        [global]
        server role = standalone server
        security = user
        netbios name = PERPENDICULAR
        workgroup = WORKGROUP
        passdb backend = smbpasswd:\(passwordFile.path)
        private dir = \(root.path)
        state directory = \(root.path)
        cache directory = \(root.path)
        lock directory = \(root.path)
        pid directory = \(root.path)
        ncalrpc dir = \(root.path)/ncalrpc
        log file = \(root.path)/server.log
        interfaces = 127.0.0.1
        bind interfaces only = yes
        smb ports = \(value.port)
        server min protocol = SMB3_00
        server signing = mandatory
        smb encrypt = required
        map to guest = Never
        smb2 leases = no
        oplocks = no
        level2 oplocks = no
        load printers = no
        printing = bsd
        disable spoolss = yes
        usershare max shares = 0
        multicast dns register = no
        \n
        """
        for folder in exports {
            try folder.validate(createIfMissing:true)
            try await Task.detached {try folder.requestAccess()}.value
            guard !folder.hostPath.contains("%"),!folder.hostPath.contains("\r") else {throw MachineSettings.failure("Il percorso della cartella \(folder.kind.title) non è supportato.")}
            config += "[\(folder.kind.windowsName)]\npath = \(folder.hostPath)\nread only = no\nvalid users = \(value.username)\nbrowseable = yes\nfollow symlinks = no\n\n"
        }
        let configFile=root.appendingPathComponent("smb.conf"),data=Data(config.utf8)
        let changed=(try? Data(contentsOf:configFile)) != data
        if changed {try write(data,to:configFile)}
        let pidFile=root.appendingPathComponent("server.pid")
        if let text=try? String(contentsOf:pidFile,encoding:.utf8),let pid=Int32(text),kill(pid,0)==0 {
            let inspect=Process();inspect.executableURL=URL(fileURLWithPath:"/bin/ps");inspect.arguments=["-p",String(pid),"-o","command="]
            let pipe=Pipe();inspect.standardOutput=pipe;try inspect.run();let command=String(data:pipe.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? "";inspect.waitUntilExit()
            guard command.contains("/Samba/bin/samba-dot-org-smbd"),command.contains(configFile.path) else {throw MachineSettings.failure("Il processo delle cartelle non appartiene a questa VM.")}
            if changed {kill(pid,SIGHUP)}
            let deadline=Date().addingTimeInterval(30)
            while kill(pid,0)==0,Date()<deadline {
                if reachable(value.port){return value}
                try await Task.sleep(for:.milliseconds(50))
            }
            throw MachineSettings.failure("Il servizio cartelle non risponde. Riprova l’avvio.")
        }
        let exe=runtime.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Samba/bin/samba-dot-org-smbd")
        guard fm.isExecutableFile(atPath:exe.path) else {throw MachineSettings.failure("Il pacchetto dell’app non contiene il servizio cartelle.")}
        let process=Process();process.executableURL=exe;process.arguments=["-F","--no-process-group","--configfile="+configFile.path]
        let log=root.appendingPathComponent("process.log")
        if !fm.fileExists(atPath:log.path){fm.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600])}
        let output=try FileHandle(forWritingTo:log);try output.seekToEnd();process.standardOutput=output;process.standardError=output
        try process.run();try write(Data(String(process.processIdentifier).utf8),to:pidFile)
        let deadline=Date().addingTimeInterval(30)
        while process.isRunning,Date()<deadline {
            if reachable(value.port){return value}
            try await Task.sleep(for:.milliseconds(50))
        }
        throw MachineSettings.failure("Non riesco ad avviare la condivisione delle cartelle. Consulta il registro del servizio.")
    }
    private static func write(_ data:Data,to url:URL)throws {
        try data.write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    private static func address(_ port:UInt16)->sockaddr_in {
        var value=sockaddr_in();value.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);value.sin_family=sa_family_t(AF_INET);value.sin_port=port.bigEndian;value.sin_addr.s_addr=inet_addr("127.0.0.1");return value
    }
    private static func reachable(_ port:UInt16)->Bool {
        let fd=socket(AF_INET,SOCK_STREAM,0);guard fd>=0 else{return false};defer{close(fd)}
        var addr=address(port)
        return withUnsafePointer(to:&addr){$0.withMemoryRebound(to:sockaddr.self,capacity:1){connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))==0}}
    }
    private static func freePort()throws->UInt16 {
        let fd=socket(AF_INET,SOCK_STREAM,0);guard fd>=0 else{throw MachineSettings.failure("Non riesco a preparare la rete delle cartelle.")};defer{close(fd)}
        var addr=address(0),count=socklen_t(MemoryLayout<sockaddr_in>.size)
        let result=withUnsafeMutablePointer(to:&addr){p in p.withMemoryRebound(to:sockaddr.self,capacity:1){bind(fd,$0,count)==0 && getsockname(fd,$0,&count)==0}}
        guard result else{throw MachineSettings.failure("Non riesco a preparare la rete delle cartelle.")};return UInt16(bigEndian:addr.sin_port)
    }
}
