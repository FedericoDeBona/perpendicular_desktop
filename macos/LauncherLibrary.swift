import Foundation
import CryptoKit

struct WindowsApplication:Identifiable,Codable {
    let id:String
    let name:String
    var key:String = ""
    var essential:Bool = false
    var iconRevision:String = ""
    func matches(_ query:String)->Bool {
        let aliases:[String:String] = ["explorer":"Esplora file Esplora risorse File Explorer", "edge":"Microsoft Edge browser", "settings":"Impostazioni Settings", "notepad":"Blocco note Notepad", "calculator":"Calcolatrice Calculator"]
        return name.localizedStandardContains(query) || (aliases[key] ?? key).localizedStandardContains(query)
    }
}

struct LauncherUsage:Codable {
    var count:Int
    var opened:Date
}
struct LauncherPreferences:Codable {
    var pinned:Set<String> = []
    var usage:[String:LauncherUsage] = [:]
    mutating func record(_ id:String,at date:Date = Date()) {
        let count=min(1_000_000,(usage[id]?.count ?? 0)+1)
        usage[id]=LauncherUsage(count:count,opened:date)
    }
    func recent(_ apps:[WindowsApplication])->[WindowsApplication] {
        apps.filter{usage[$0.id] != nil}.sorted{
            let left=usage[$0.id]!.opened,right=usage[$1.id]!.opened
            return left == right ? $0.name.localizedStandardCompare($1.name) == .orderedAscending:left>right
        }
    }
    func sections(_ apps:[WindowsApplication],recentLimit:Int=6)->(favorites:[WindowsApplication],recent:[WindowsApplication],remaining:[WindowsApplication]) {
        let favorites=apps.filter{pinned.contains($0.id)}.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}
        let recent=Array(recent(apps).filter{!pinned.contains($0.id)}.prefix(max(0,recentLimit)))
        let shown=Set(favorites.map(\.id)+recent.map(\.id))
        return (favorites,recent,apps.filter{!shown.contains($0.id)}.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending})
    }
    func suggested(_ apps:[WindowsApplication],limit:Int=12,now:Date=Date())->[WindowsApplication] {
        let order=["explorer","edge","notepad","calculator","settings","terminal","paint","photos","snipping","store"]
        func score(_ app:WindowsApplication)->Double {
            guard let value=usage[app.id] else{return 0}
            let age=max(0,now.timeIntervalSince(value.opened))
            return log2(Double(value.count)+1)+2*max(0,1-age/(30*86400))
        }
        return Array(apps.filter{pinned.contains($0.id) || usage[$0.id] != nil || $0.essential}.sorted{
            let lp=pinned.contains($0.id),rp=pinned.contains($1.id)
            if lp != rp {return lp}
            let ls=score($0),rs=score($1)
            if ls != rs {return ls>rs}
            let li=order.firstIndex(of:$0.key) ?? order.count,ri=order.firstIndex(of:$1.key) ?? order.count
            return li == ri ? $0.name.localizedStandardCompare($1.name) == .orderedAscending:li<ri
        }.prefix(max(limit,pinned.count)))
    }
}

/// Private to one VM. Catalogue, usage and original PNGs survive frontend exits.
final class LauncherLibrary {
    private struct Icon:Codable {let revision:String;let sha256:String}
    private let root:URL
    private var icons:[String:Icon] = [:]
    init(directory:URL)throws {
        root=directory.appendingPathComponent("Launcher",isDirectory:true)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("icons-256"),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        if let data=read("icons.json",limit:512*1024),let values=try? JSONDecoder().decode([String:Icon].self,from:data) {
            icons=values.filter{Self.valid($0.key)}
        }
    }
    private static func valid(_ id:String)->Bool {id.utf8.count == 64 && id.utf8.allSatisfy{(48...57).contains($0)||(97...102).contains($0)}}
    private func read(_ path:String,limit:Int)->Data? {
        let url=root.appendingPathComponent(path)
        guard let attributes=try? FileManager.default.attributesOfItem(atPath:url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size=attributes[.size] as? Int,size>0,size<=limit else{return nil}
        return try? Data(contentsOf:url)
    }
    private func write(_ data:Data,to path:String)throws {
        let url=root.appendingPathComponent(path)
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    func loadPreferences()->LauncherPreferences {
        guard let data=read("preferences.json",limit:1024*1024),var value=try? JSONDecoder().decode(LauncherPreferences.self,from:data) else{return .init()}
        value.pinned=Set(value.pinned.filter(Self.valid));value.usage=value.usage.filter{Self.valid($0.key) && $0.value.count>0 && $0.value.count<=1_000_000}
        return value
    }
    func save(_ preferences:LauncherPreferences)throws {try write(JSONEncoder().encode(preferences),to:"preferences.json")}
    func loadCatalogue()->[WindowsApplication] {
        guard let data=read("catalogue.json",limit:1024*1024),let apps=try? JSONDecoder().decode([WindowsApplication].self,from:data),apps.count<=1024 else{return []}
        return apps.filter{Self.valid($0.id) && !$0.name.isEmpty && $0.name.utf8.count<=512}
    }
    func saveCatalogue(_ apps:[WindowsApplication])throws {try write(JSONEncoder().encode(apps),to:"catalogue.json")}
    func cachedIcon(for app:WindowsApplication)->Data? {
        guard Self.valid(app.id),let record=icons[app.id],record.revision == app.iconRevision,
              let data=read("icons-256/"+app.id+".png",limit:512*1024),
              SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined() == record.sha256 else{return nil}
        return data
    }
    func saveIcon(_ data:Data,for app:WindowsApplication)throws {
        guard Self.valid(app.id),!data.isEmpty,data.count<=512*1024 else{return}
        try write(data,to:"icons-256/"+app.id+".png")
        icons[app.id]=Icon(revision:app.iconRevision,sha256:SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined())
        try write(JSONEncoder().encode(icons),to:"icons.json")
    }
}
