import Foundation
import CryptoKit
import Darwin

/// Uses the authenticated guest channel and the installed protected folder task.
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
                let credentials=try SambaServer.credentials(in:directory)
                let selected=exports.map{$0.kind.rawValue}
                let requestID=UUID().uuidString.lowercased()
                let payload=try JSONSerialization.data(withJSONObject:["id":requestID,"enabled":selected,"username":credentials.username,"password":credentials.password]).base64EncodedString()
                let submit=#"""
                $ErrorActionPreference='Stop';$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$root=Join-Path $env:ProgramData ('Perpendicular\FolderRequests\'+$sid);[IO.File]::WriteAllBytes((Join-Path $root 'request.json'),[Convert]::FromBase64String('\#(payload)'));& (Join-Path $env:SystemRoot 'System32\schtasks.exe') /Run /TN ('PerpendicularFolders-'+$sid)|Out-Null;if($LASTEXITCODE -ne 0){throw 'Folder configuration task is not installed'}
                """#
                _ = try await self.powershell(submit,bridge:bridge)
                let deadline=Date().addingTimeInterval(180)
                while true {
                    try Task.checkCancellation()
                    let poll=#"""
                    $ErrorActionPreference='Stop';$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$path=Join-Path $env:ProgramData ('Perpendicular\FolderRequests\'+$sid+'\response.json');[IO.File]::ReadAllText($path)
                    """#
                    let output=try await self.powershell(poll,bridge:bridge)
                    if let data=output.data(using:.utf8),let result=try? JSONSerialization.jsonObject(with:data) as? [String:Any],result["id"] as? String == requestID {
                        guard result["ok"] as? Bool == true else {throw Self.failure(result["error"] as? String ?? "Folder configuration failed.")}
                        log("Folder selection confirmed: "+selected.joined(separator:","))
                        let count=exports.count
                        update(count == 0 ? "Windows usa le sue cartelle locali.":count == 1 ? "1 cartella Mac collegata.":"\(count) cartelle Mac collegate.",false,false)
                        break
                    }
                    guard Date()<deadline else {throw Self.failure("Folder configuration did not finish in time.")}
                    try await Task.sleep(for:.seconds(2))
                }
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
        $ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$path='\(scriptPath)';if([IO.File]::Exists($path)){$sha=[Security.Cryptography.SHA256]::Create();$value=[BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($path))).Replace('-','').ToLowerInvariant();$sha.Dispose();if($value -eq '\(sha)'){[Console]::WriteLine('MATCH')}}
        """
        if try await powershell(probe,bridge:bridge).contains("MATCH") {return}
        throw Self.failure("Aggiorna i componenti Windows per collegare le cartelle.")
    }
    private func powershell(_ source:String,bridge:GuestBridge)async throws->String {
        let encoded=source.data(using:.utf16LittleEndian)!.base64EncodedString()
        return try await execute(["-NoProfile","-NonInteractive","-EncodedCommand",encoded],bridge:bridge,seconds:60)
    }
    private func execute(_ args:[String],bridge:GuestBridge,seconds:Int)async throws->String {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation {continuation in
            bridge.command("execute",["executable":executable,"args":args,"timeoutSeconds":seconds],timeout:.seconds(seconds+5)){result in
                do {
                    let value=try result.get()["value"] as? [String:Any] ?? [:]
                    guard value["exitCode"] as? Int == 0,value["timedOut"] as? Bool != true else {
                        let detail=value["stderr"] as? String ?? ""
                        throw Self.failure(value["timedOut"] as? Bool == true ? "Windows non ha completato il comando cartelle entro \(seconds) secondi.":detail.isEmpty ? "Comando cartelle terminato con codice \(value["exitCode"] ?? "sconosciuto").":detail)
                    }
                    continuation.resume(returning:value["stdout"] as? String ?? "")
                }catch {continuation.resume(throwing:error)}
            }
        }
    }
    private static func failure(_ message:String)->NSError {NSError(domain:"SharedFolders",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
}
