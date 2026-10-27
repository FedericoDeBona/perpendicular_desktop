import Foundation
import CryptoKit
import Darwin

/// Uses the authenticated guest channel and the already installed signed client.
/// The script lives under protected Program Files, never on a writable share.
@MainActor
final class SharedFolderIntegration {
    private var task:Task<Void,Never>?
    private let executable="C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
    private let scriptPath="C:\\Program Files\\Perpendicular Shared Files\\configure-shared-folders.ps1"
    func cancel(){task?.cancel();task=nil}
    func apply(exports:[SharedFolderExport],bridge:GuestBridge,directory:URL,
               update:@escaping (String,Bool,Bool)->Void){
        cancel()
        task=Task{@MainActor [weak self] in
            guard let self else{return}
            func log(_ message:String){
                let url=directory.appendingPathComponent("shared-folders.log")
                let line="\(ISO8601DateFormatter().string(from:Date())) \(message)\n"
                if !FileManager.default.fileExists(atPath:url.path){FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600])}
                if let handle=try? FileHandle(forWritingTo:url){defer{try? handle.close()};_ = try? handle.seekToEnd();try? handle.write(contentsOf:Data(line.utf8))}
            }
            do {
                update("Preparazione delle cartelle…",false,true)
                try await self.installScript(bridge:bridge)
                var failed:[String]=[]
                for kind in SharedFolderKind.allCases {
                    try Task.checkCancellation()
                    let enabled=exports.contains{$0.kind == kind}
                    update("Preparazione di \(kind.title)…",false,true)
                    do {
                        var args=["-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File",self.scriptPath,
                                  "-Folder",kind.rawValue,"-Owner","\(getuid()):\(getgid())"]
                        if !enabled {args.append("-Disable")}
                        let output=try await self.execute(args,bridge:bridge,seconds:50)
                        guard output.contains("PERP_FOLDER_READY:"+kind.rawValue+":"+(enabled ? "shared":"local")) else {
                            throw Self.failure("Folder setup did not confirm its final state.")
                        }
                        log("\(kind.rawValue): \(enabled ? "shared":"local")")
                    }catch is CancellationError {throw CancellationError()}
                    catch {failed.append(kind.title);log("\(kind.rawValue): \(error.localizedDescription)")}
                }
                try Task.checkCancellation()
                if failed.isEmpty {
                    let count=exports.count
                    update(count == 0 ? "Windows usa le sue cartelle locali.":count == 1 ? "1 cartella Mac collegata.":"\(count) cartelle Mac collegate.",false,false)
                }else {update("Non riesco a preparare: "+failed.joined(separator:", ")+". Riprova il collegamento.",true,false)}
            }catch is CancellationError {}
            catch {if !Task.isCancelled {log(error.localizedDescription);update("Non riesco a preparare le cartelle. Verifica che i componenti Windows siano installati e riprova il collegamento.",true,false)}}
        }
    }
    private func installScript(bridge:GuestBridge)async throws {
        guard let url=Bundle.main.url(forResource:"configure-shared-folders",withExtension:"ps1",subdirectory:"Guest") else {
            throw Self.failure("Missing folder integration helper.")
        }
        let data=try Data(contentsOf:url)
        let sha=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        let probe="""
        $ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$path='\(scriptPath)';if(![IO.File]::Exists('C:\\Program Files\\Perpendicular Shared Files\\virtiofs.exe')){throw 'Signed folder components are not installed'};if([IO.File]::Exists($path)){$sha=[Security.Cryptography.SHA256]::Create();$value=[BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($path))).Replace('-','').ToLowerInvariant();$sha.Dispose();if($value -eq '\(sha)'){[Console]::WriteLine('MATCH')}}
        """
        if try await powershell(probe,bridge:bridge).contains("MATCH") {return}
        for offset in stride(from:0,to:data.count,by:1900) {
            try Task.checkCancellation()
            let bytes=data.subdata(in:offset..<min(data.count,offset+1900)).base64EncodedString()
            let mode=offset == 0 ? "Create":"Append"
            let write="""
            $ErrorActionPreference='Stop';$bytes=[Convert]::FromBase64String('\(bytes)');$file=[IO.FileStream]::new('\(scriptPath)',[IO.FileMode]::\(mode),[IO.FileAccess]::Write,[IO.FileShare]::None);try{$file.Write($bytes,0,$bytes.Length)}finally{$file.Dispose()}
            """
            _ = try await powershell(write,bridge:bridge)
        }
        guard try await powershell(probe,bridge:bridge).contains("MATCH") else {throw Self.failure("Folder helper delivery differs.")}
    }
    private func powershell(_ source:String,bridge:GuestBridge)async throws->String {
        let encoded=source.data(using:.utf16LittleEndian)!.base64EncodedString()
        return try await execute(["-NoProfile","-NonInteractive","-EncodedCommand",encoded],bridge:bridge,seconds:15)
    }
    private func execute(_ args:[String],bridge:GuestBridge,seconds:Int)async throws->String {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation {continuation in
            bridge.command("execute",["executable":executable,"args":args,"timeoutSeconds":seconds],timeout:.seconds(seconds+5)){result in
                do {
                    let value=try result.get()["value"] as? [String:Any] ?? [:]
                    guard value["exitCode"] as? Int == 0,value["timedOut"] as? Bool != true else {
                        throw Self.failure(value["stderr"] as? String ?? "Windows folder setup failed.")
                    }
                    continuation.resume(returning:value["stdout"] as? String ?? "")
                }catch {continuation.resume(throwing:error)}
            }
        }
    }
    private static func failure(_ message:String)->NSError {NSError(domain:"SharedFolders",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
}
