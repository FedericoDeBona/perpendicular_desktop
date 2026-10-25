import Foundation

@main struct LauncherLibraryChecks {
    static func main()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("perpendicular-launcher-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let explorer=WindowsApplication(id:String(repeating:"a",count:64),name:"Esplora file",key:"explorer",essential:true)
        let edge=WindowsApplication(id:String(repeating:"b",count:64),name:"Microsoft Edge",key:"edge",essential:true)
        let other=WindowsApplication(id:String(repeating:"c",count:64),name:"Un’app aggiuntiva")
        let apps=[other,edge,explorer],now=Date(timeIntervalSince1970:1_800_000_000)
        var preferences=LauncherPreferences()
        precondition(preferences.suggested(apps).map(\.id) == [explorer.id,edge.id])
        precondition(explorer.matches("esplora risorse") && explorer.matches("File Explorer"))
        preferences.record(other.id,at:now);preferences.record(other.id,at:now.addingTimeInterval(1))
        precondition(preferences.suggested(apps,now:now).first?.id == other.id)
        preferences.pinned.insert(edge.id)
        precondition(preferences.suggested(apps,now:now).first?.id == edge.id)
        let library=try LauncherLibrary(directory:root)
        try library.save(preferences);try library.saveCatalogue(apps)
        let restored=try LauncherLibrary(directory:root)
        precondition(restored.loadPreferences().usage[other.id]?.count == 2 && restored.loadPreferences().pinned.contains(edge.id))
        precondition(restored.loadCatalogue().map(\.id) == apps.map(\.id))
        let bytes=Data([1,2,3]);try library.saveIcon(bytes,for:edge)
        let cached=try LauncherLibrary(directory:root)
        precondition(cached.cachedIcon(for:edge) == bytes)
        var updated=edge;updated.iconRevision="changed"
        precondition(library.cachedIcon(for:updated) == nil)
        try Data([4]).write(to:root.appendingPathComponent("Launcher/icons-256/"+edge.id+".png"))
        precondition(library.cachedIcon(for:edge) == nil)
        print("Launcher: selection, aliases, usage, persistence and cache invalidation passed")
    }
}
