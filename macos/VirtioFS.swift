import Foundation

/// One explicit host directory. Mounting and Known Folder redirection are
/// performed by the guest setup, after the volume is actually usable.
struct SharedDownloadsConfiguration:Codable {
    let hostPath:String
    let tag:String
    func validate()throws {
        let root=URL(fileURLWithPath:hostPath).standardizedFileURL
        guard hostPath.hasPrefix("/"),root.path == hostPath,
              !hostPath.contains(","),!hostPath.contains("\n"),
              tag == "mac-downloads" else {throw Self.failure("Configurazione Download condivisi non valida.")}
        var directory:ObjCBool=false
        guard FileManager.default.fileExists(atPath:hostPath,isDirectory:&directory),directory.boolValue,
              FileManager.default.isReadableFile(atPath:hostPath),FileManager.default.isWritableFile(atPath:hostPath) else {
            throw Self.failure("Consenti l’accesso alla cartella Download del Mac prima di avviare Windows.")
        }
    }
    private static func failure(_ message:String)->NSError {
        NSError(domain:"VirtioFS",code:1,userInfo:[NSLocalizedDescriptionKey:message])
    }
}
