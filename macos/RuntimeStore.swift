import Foundation
import CryptoKit

/// A running VM must not load helpers from a build directory that can be cleaned
/// or overwritten while Windows is still running. Keep each runtime immutable.
enum RuntimeStore {
    static func prepare(contents:URL,directory:URL)throws->URL {
        let paths=["Resources/QEMU","Frameworks/Runtime","Resources/Samba"] +
            (FileManager.default.fileExists(atPath:contents.appendingPathComponent("Resources/Native3D").path) ? ["Resources/Native3D"]:[])
        let identity=try digest(contents:contents,paths:paths)
        let store=directory.appendingPathComponent("Runtimes",isDirectory:true)
        try FileManager.default.createDirectory(at:store,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let destination=store.appendingPathComponent(identity,isDirectory:true)
        if FileManager.default.fileExists(atPath:destination.path) {
            guard try digest(contents:destination.appendingPathComponent("Contents"),paths:paths) == identity else {
                throw failure("The saved Windows runtime has changed. Restore its files before starting Windows.")
            }
            return destination.appendingPathComponent("Contents/Resources/QEMU/bin")
        }
        let staging=store.appendingPathComponent(".preparing-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer {try? FileManager.default.removeItem(at:staging)}
        for path in paths {
            let target=staging.appendingPathComponent("Contents/"+path)
            try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
            try FileManager.default.copyItem(at:contents.appendingPathComponent(path),to:target)
        }
        guard try digest(contents:staging.appendingPathComponent("Contents"),paths:paths) == identity else {
            throw failure("The Windows runtime changed while it was being prepared. Try starting the app again.")
        }
        try FileManager.default.moveItem(at:staging,to:destination)
        return destination.appendingPathComponent("Contents/Resources/QEMU/bin")
    }

    private static func digest(contents:URL,paths:[String])throws->String {
        var hash=SHA256()
        for path in paths.sorted() {
            let root=contents.appendingPathComponent(path)
            var enumerationError:Error?
            guard let items=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],options:[],errorHandler:{_,error in enumerationError=error;return false}) else {
                throw failure("The application does not contain the Windows runtime: "+path)
            }
            var files=[URL]()
            while let item=items.nextObject() as? URL {files.append(item)}
            if let enumerationError {throw enumerationError}
            // Paths and content both contribute, including the keymaps and the
            // relative library layout. A manifest of upstream hashes is not enough.
            for file in files.sorted(by:{$0.path<$1.path}) {
                let values=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
                let relative=String(file.path.dropFirst(contents.path.count+1))
                if values.isSymbolicLink == true {
                    let target=try FileManager.default.destinationOfSymbolicLink(atPath:file.path)
                    guard !target.hasPrefix("/"),file.resolvingSymlinksInPath().path.hasPrefix(contents.path+"/") else {
                        throw failure("The Windows runtime contains an external link: "+relative)
                    }
                    hash.update(data:Data(("link\0"+relative+"\0"+target+"\0").utf8))
                }else if values.isRegularFile == true {
                    hash.update(data:Data(("file\0"+relative+"\0").utf8))
                    hash.update(data:Data(SHA256.hash(data:try Data(contentsOf:file,options:.mappedIfSafe))))
                }
            }
            guard !files.isEmpty else {throw failure("The Windows runtime is incomplete: "+path)}
        }
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    private static func failure(_ message:String)->NSError {
        NSError(domain:"Runtime",code:1,userInfo:[NSLocalizedDescriptionKey:message])
    }
}
