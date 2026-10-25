struct GuestApplicationState:Equatable {
    struct Window:Equatable {let id:String;let stopped:Bool}
    let id:String
    let activationPending:Bool
    let processes:Set<String>
    let windows:[Window]
    var running:Bool {!processes.isEmpty}
    init?(_ row:[String:Any]) {
        guard let id=row["app"] as? String,id.utf8.count==64,
              let processes=row["processes"] as? [[String:Any]],processes.count<=16,
              let windows=row["windows"] as? [[String:Any]],windows.count<=16 else{return nil}
        self.id=id;activationPending=row["activationPending"] as? Bool == true
        self.processes=Set(processes.compactMap{row in
            guard let pid=row["pid"] as? Int,let creation=row["creation"] as? String else{return nil}
            return "\(pid):\(creation)"
        })
        self.windows=windows.compactMap{row in
            guard let id=row["id"] as? String else{return nil}
            return Window(id:id,stopped:row["captureStopped"] as? Bool != false)
        }
    }
}
