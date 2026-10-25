import Foundation

@main struct MachineSettingsChecks {
    static func main()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("perpendicular-settings-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let current=MachineSettings(cpus:1,initialMemoryMiB:2048,automaticMemory:true,maximumMemoryMiB:4096,backgroundMemoryMiB:1536,reserveMemoryMiB:512)
        var future=current;future.initialMemoryMiB=1024
        try future.validate()
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
        try MachineSettingsStore.save(current,in:root,machineID:"fixture",current:current)
        let cancelled=try MachineSettingsStore.pending(in:root,machineID:"fixture")
        precondition(cancelled == nil)
        print("Settings: deferred save, 1 GB limits, identity/field preservation, invalid input and cancellation passed")
    }
}
