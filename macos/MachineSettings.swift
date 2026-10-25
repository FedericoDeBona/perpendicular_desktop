import Foundation

struct DynamicMemoryConfiguration:Codable,Equatable,Sendable {
    let hotplugMiB:Int
    let backgroundMiB:Int
    let reserveMiB:Int
    func validate(baseMiB:Int)throws {
        guard (1024...16384).contains(baseMiB),hotplugMiB>=128,hotplugMiB<=8192,
              hotplugMiB%128==0,backgroundMiB>=1024,backgroundMiB<=baseMiB+hotplugMiB,
              (256...2048).contains(reserveMiB) else {
            throw NSError(domain:"Memory",code:1,userInfo:[NSLocalizedDescriptionKey:"Invalid dynamic Windows RAM limits."])
        }
    }
}

struct MachineSettings:Codable,Equatable,Sendable {
    var cpus:Int
    var initialMemoryMiB:Int
    var automaticMemory:Bool
    var maximumMemoryMiB:Int
    var backgroundMemoryMiB:Int
    var reserveMemoryMiB:Int
    static var cpuLimit:Int {max(1,ProcessInfo.processInfo.processorCount)}
    static var memoryLimitMiB:Int {min(16384,Int(ProcessInfo.processInfo.physicalMemory/1_048_576))}
    var dynamicMemory:DynamicMemoryConfiguration? {
        automaticMemory ? .init(hotplugMiB:maximumMemoryMiB-initialMemoryMiB,backgroundMiB:backgroundMemoryMiB,reserveMiB:reserveMemoryMiB):nil
    }
    mutating func useAutomaticMemoryPolicy(){
        automaticMemory=maximumMemoryMiB>initialMemoryMiB
        backgroundMemoryMiB=1024
        reserveMemoryMiB=512
    }
    func validate()throws {
        guard (1...Self.cpuLimit).contains(cpus) else{throw Self.failure("Scegli da 1 a \(Self.cpuLimit) processori.")}
        guard (1024...Self.memoryLimitMiB).contains(initialMemoryMiB),initialMemoryMiB%128==0 else {
            throw Self.failure("La RAM iniziale deve essere almeno 1 GB e in multipli di 128 MB.")
        }
        if automaticMemory {
            guard maximumMemoryMiB<=Self.memoryLimitMiB,maximumMemoryMiB>=initialMemoryMiB+128 else {
                throw Self.failure("Il limite RAM deve superare la RAM iniziale di almeno 128 MB e non superare \(Self.memoryLimitMiB) MB.")
            }
            guard maximumMemoryMiB-initialMemoryMiB<=8192 else{throw Self.failure("La RAM aggiungibile può essere al massimo 8 GB oltre alla RAM iniziale.")}
            guard backgroundMemoryMiB<=maximumMemoryMiB else{throw Self.failure("Il minimo in background non può superare il limite RAM.")}
            try dynamicMemory?.validate(baseMiB:initialMemoryMiB)
        }
    }
    static func failure(_ message:String)->NSError{NSError(domain:"MachineSettings",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
}

/// Changes stay separate from the running VM's configuration until a confirmed
/// stop. Reopening the frontend must never give its RAM controller future limits.
enum MachineSettingsStore {
    private struct Pending:Codable {let machineID:String;let settings:MachineSettings}
    private static func file(in directory:URL)->URL{directory.appendingPathComponent("settings-next-start.json")}
    static func pending(in directory:URL,machineID:String)throws->MachineSettings? {
        let url=file(in:directory)
        guard FileManager.default.fileExists(atPath:url.path) else{return nil}
        let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size=attributes[.size] as? Int,size>0,size<=8192 else {throw MachineSettings.failure("Le impostazioni salvate non sono leggibili.")}
        let value=try JSONDecoder().decode(Pending.self,from:Data(contentsOf:url))
        guard value.machineID == machineID else{throw MachineSettings.failure("Le impostazioni appartengono a un’altra VM.")}
        try value.settings.validate();return value.settings
    }
    static func save(_ settings:MachineSettings,in directory:URL,machineID:String,current:MachineSettings)throws {
        try settings.validate()
        if settings == current {try clear(in:directory);return}
        let bytes=try JSONEncoder().encode(Pending(machineID:machineID,settings:settings))
        try bytes.write(to:file(in:directory),options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file(in:directory).path)
    }
    static func clear(in directory:URL)throws {
        let url=file(in:directory)
        if FileManager.default.fileExists(atPath:url.path){try FileManager.default.removeItem(at:url)}
    }
    static func merged(_ settings:MachineSettings,with data:Data,machineID:String)throws->Data {
        try settings.validate()
        guard var value=try JSONSerialization.jsonObject(with:data) as? [String:Any],value["id"] as? String == machineID else {
            throw MachineSettings.failure("L’identità della VM è cambiata. Riapri le impostazioni.")
        }
        value["cpus"]=settings.cpus;value["memoryMiB"]=settings.initialMemoryMiB
        if let memory=settings.dynamicMemory {
            value["dynamicMemory"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(memory))
        }else{value.removeValue(forKey:"dynamicMemory")}
        return try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys])
    }
}
