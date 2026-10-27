import Foundation
import Darwin

enum SharedFolderKind:String,CaseIterable,Codable,Sendable,Identifiable {
    case desktop,documents,downloads,pictures,music,videos
    var id:String {rawValue}
    var title:String {
        switch self {
        case .desktop:return "Scrivania"
        case .documents:return "Documenti"
        case .downloads:return "Download"
        case .pictures:return "Immagini"
        case .music:return "Musica"
        case .videos:return "Video"
        }
    }
    var icon:String {
        switch self {
        case .desktop:return "desktopcomputer"
        case .documents:return "doc"
        case .downloads:return "arrow.down.circle"
        case .pictures:return "photo"
        case .music:return "music.note"
        case .videos:return "film"
        }
    }
    var hostDirectory:URL {
        let directory:FileManager.SearchPathDirectory
        switch self {
        case .desktop:directory = .desktopDirectory
        case .documents:directory = .documentDirectory
        case .downloads:directory = .downloadsDirectory
        case .pictures:directory = .picturesDirectory
        case .music:directory = .musicDirectory
        case .videos:directory = .moviesDirectory
        }
        return FileManager.default.urls(for:directory,in:.userDomainMask).first!.standardizedFileURL
    }
    var tag:String {"mac-"+rawValue}
}

struct SharedFolderExport:Codable,Equatable,Sendable {
    let kind:SharedFolderKind
    let hostPath:String
    var tag:String {kind.tag}
    /// Ask macOS from the app before starting the backend's bounded socket wait.
    /// Opening the directory may wait for the user's Files and Folders consent.
    func requestAccess()throws {
        guard let directory=opendir(hostPath) else {
            throw MachineSettings.failure("Consenti l’accesso alla cartella \(kind.title) del Mac prima di avviare Windows.")
        }
        closedir(directory)
    }
    func validate(createIfMissing:Bool=false)throws {
        let root=URL(fileURLWithPath:hostPath).standardizedFileURL
        guard hostPath.hasPrefix("/"),root.path == hostPath,
              !hostPath.contains(","),!hostPath.contains("\n") else {
            throw MachineSettings.failure("Il percorso della cartella \(kind.title) non è valido.")
        }
        if createIfMissing,!FileManager.default.fileExists(atPath:hostPath),root == kind.hostDirectory {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        }
        // Standard macOS folders may not exist until their first use.
        if !createIfMissing,!FileManager.default.fileExists(atPath:hostPath),root == kind.hostDirectory {return}
        var directory:ObjCBool=false
        guard FileManager.default.fileExists(atPath:hostPath,isDirectory:&directory),directory.boolValue,
              FileManager.default.isReadableFile(atPath:hostPath),FileManager.default.isWritableFile(atPath:hostPath) else {
            throw MachineSettings.failure("Consenti l’accesso alla cartella \(kind.title) del Mac prima di avviare Windows.")
        }
    }
}

struct SharedFoldersConfiguration:Codable,Equatable,Sendable {
    let folders:[SharedFolderExport]
    func validate()throws {
        guard folders.count<=SharedFolderKind.allCases.count,Set(folders.map(\.kind)).count == folders.count else {
            throw MachineSettings.failure("La selezione delle cartelle Mac non è valida.")
        }
        for folder in folders {try folder.validate()}
    }
}

/// Decode the previous single-folder profile without changing a running VM.
struct SharedDownloadsConfiguration:Codable {
    let hostPath:String
    let tag:String
    func validate()throws {
        guard tag == SharedFolderKind.downloads.tag else {throw MachineSettings.failure("Configurazione Download non valida.")}
        try SharedFolderExport(kind:.downloads,hostPath:hostPath).validate()
    }
}
