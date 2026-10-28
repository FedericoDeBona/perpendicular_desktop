import Foundation

@main struct MachineSettingsChecks {
    static func main()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("perpendicular-settings-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let localOnly=Dictionary(uniqueKeysWithValues:SharedFolderKind.allCases.map{($0.rawValue,false)})
        let current=MachineSettings(cpus:1,initialMemoryMiB:2048,automaticMemory:true,maximumMemoryMiB:4096,backgroundMemoryMiB:1536,reserveMemoryMiB:512,sharedFolderSelection:localOnly)
        var defaults=current;defaults.sharedFolderSelection=nil
        precondition(defaults.enabledSharedFolders.count == 6,"All six standard folders must be selected by default")
        let older=Data(#"{"cpus":1,"initialMemoryMiB":2048,"automaticMemory":false,"maximumMemoryMiB":4096,"backgroundMemoryMiB":1536,"reserveMemoryMiB":512}"#.utf8)
        let decodedOlder=try JSONDecoder().decode(MachineSettings.self,from:older)
        precondition(decodedOlder.enabledSharedFolders.count == 6)

        var future=current;future.initialMemoryMiB=1024
        future.useAutomaticMemoryPolicy()
        precondition(future.automaticMemory && future.backgroundMemoryMiB==1024 && future.reserveMemoryMiB==512 && future.initialMemoryMiB==1024 && future.maximumMemoryMiB==4096)
        try future.validate()
        var capped=future;capped.maximumMemoryMiB=capped.initialMemoryMiB;capped.useAutomaticMemoryPolicy()
        try capped.validate()
        precondition(!capped.automaticMemory && capped.dynamicMemory == nil)
        let original=Data(#"{"id":"fixture","cpus":1,"memoryMiB":2048,"disk":"keep-disk","variables":"keep-efi","tpmStateFile":"keep-tpm","token":"sentinel","extra":{"keep":true},"dynamicMemory":{"hotplugMiB":2048,"backgroundMiB":1536,"reserveMiB":512}}"#.utf8)
        let file=root.appendingPathComponent("machine.json")
        try original.write(to:file)
        try MachineSettingsStore.save(future,in:root,machineID:"fixture",current:current)
        let unchanged=try Data(contentsOf:file)
        let pending=try MachineSettingsStore.pending(in:root,machineID:"fixture")
        precondition(unchanged == original,"Saving while running must not edit the current configuration")
        precondition(pending == future)
        let merged=try JSONSerialization.jsonObject(with:MachineSettingsStore.merged(future,with:original,machineID:"fixture")) as! [String:Any]
        precondition(merged["memoryMiB"] as? Int == 1024)
        precondition((merged["dynamicMemory"] as? [String:Int])?["hotplugMiB"] == 3072)
        precondition(merged["token"] as? String == "sentinel" && merged["disk"] as? String == "keep-disk" && merged["variables"] as? String == "keep-efi" && merged["tpmStateFile"] as? String == "keep-tpm")
        precondition((merged["extra"] as? [String:Bool])?["keep"] == true)
        func rejected(_ operation:()throws->Void){do{try operation();preconditionFailure("Expected rejection")}catch{}}
        rejected{_ = try MachineSettingsStore.pending(in:root,machineID:"other")}
        rejected{_ = try MachineSettingsStore.merged(future,with:original,machineID:"other")}
        var invalid=future;invalid.maximumMemoryMiB=512
        rejected{try MachineSettingsStore.save(invalid,in:root,machineID:"fixture",current:current)}
        let preserved=try MachineSettingsStore.pending(in:root,machineID:"fixture")
        precondition(preserved == future,"Invalid settings must preserve the saved draft")
        var fixed=future;fixed.automaticMemory=false
        let fixedJSON=try JSONSerialization.jsonObject(with:MachineSettingsStore.merged(fixed,with:original,machineID:"fixture")) as! [String:Any]
        precondition(fixedJSON["dynamicMemory"] == nil)
        var shared=try JSONSerialization.jsonObject(with:original) as! [String:Any]
        shared["sharedDownloads"]=["hostPath":"/Users/example/Downloads","tag":"mac-downloads"]
        let sharedData=try JSONSerialization.data(withJSONObject:shared)
        var shareSettings=future;shareSettings.setShared(.downloads,enabled:true)
        let sharedJSON=try JSONSerialization.jsonObject(with:MachineSettingsStore.merged(shareSettings,with:sharedData,machineID:"fixture")) as! [String:Any]
        precondition(sharedJSON["memoryMiB"] as? Int == future.initialMemoryMiB && sharedJSON["dynamicMemory"] != nil,
                     "Shared folders must not force a RAM backing or disable automatic memory")
        let exports=try JSONDecoder().decode(SharedFoldersConfiguration.self,from:JSONSerialization.data(withJSONObject:sharedJSON["sharedFolders"]!))
        precondition(exports.folders == [SharedFolderExport(kind:.downloads,hostPath:"/Users/example/Downloads")],"Migration must preserve the selected host directory")
        precondition(sharedJSON["sharedDownloads"] == nil)
        shareSettings.useAutomaticMemoryPolicy()
        precondition(shareSettings.automaticMemory && shareSettings.initialMemoryMiB == future.initialMemoryMiB)
        let disabled=try JSONSerialization.jsonObject(with:MachineSettingsStore.merged(current,with:sharedData,machineID:"fixture")) as! [String:Any]
        let noExports=try JSONDecoder().decode(SharedFoldersConfiguration.self,from:JSONSerialization.data(withJSONObject:disabled["sharedFolders"]!))
        precondition(noExports.folders.isEmpty,"Explicitly disabling every folder must remove all host exports")
        try MachineSettingsStore.save(current,in:root,machineID:"fixture",current:current,forcePending:true)
        let explicitOff=try MachineSettingsStore.pending(in:root,machineID:"fixture")
        precondition(explicitOff == current,"An initial all-off selection must not revert to defaults")
        try MachineSettingsStore.save(current,in:root,machineID:"fixture",current:current)
        let cancelled=try MachineSettingsStore.pending(in:root,machineID:"fixture")
        precondition(cancelled == nil)
        print("Settings: deferred save, 1 GB limits, identity/field preservation, invalid input and cancellation passed")
    }
}
