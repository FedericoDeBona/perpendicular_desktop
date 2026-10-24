import Foundation
final class ExperimentalGpuTrace {
 static func record(_ event:String,_ header:[String:Any]) {
  let path=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Perpendicular IVSHMEM Trial/wgc-gpu-events.jsonl")
  guard let data=try? JSONSerialization.data(withJSONObject:["event":event,"hostTime":ProcessInfo.processInfo.systemUptime,"header":header],options:[.sortedKeys]) else{return}
  if !FileManager.default.fileExists(atPath:path.path){FileManager.default.createFile(atPath:path.path,contents:nil,attributes:[.posixPermissions:0o600])}
  if let f=try? FileHandle(forWritingTo:path){defer{try? f.close()};_=try? f.seekToEnd();try? f.write(contentsOf:data+Data([10]))}
 }
}
