import Foundation

/// Idle waiting is leased by the host. Every interactive entry queues a
/// confirmed restore after any older idle write, before opening its view.
@MainActor
final class RuntimeCPUController {
    private let machine:VirtualMachineController
    private struct Applied:Sendable {let supported:Bool,idle:Bool;let busy:Int}
    private var tail:Task<Applied,Error>?
    private var latest=UUID()
    private var appliedPID:Int32?
    private var appliedIdle=false
    private var unsupportedPID:Int32?
    private var appliedAt=0.0
    private var interactiveUntil=0.0
    private(set) var state:[String:Any]=["ready":false]

    init(machine:VirtualMachineController){self.machine=machine}

    func noteVisual(pid:Int32?){
        interactiveUntil=ProcessInfo.processInfo.systemUptime+15
        guard let pid,unsupportedPID != pid,
              appliedPID != pid || appliedIdle || tail != nil else{return}
        _=enqueue(idle:false,pid:pid)
    }

    func observe(pid:Int32?,eligible:Bool){
        guard let pid else {appliedPID=nil;unsupportedPID=nil;state=["ready":false];return}
        let now=ProcessInfo.processInfo.systemUptime
        let idle=eligible && now>=interactiveUntil
        guard tail == nil,unsupportedPID != pid,
              appliedPID != pid || idle != appliedIdle || (idle && now-appliedAt>=4) else{return}
        _=enqueue(idle:idle,pid:pid)
    }

    func requireInteractive()async throws {
        interactiveUntil=ProcessInfo.processInfo.systemUptime+15
        guard case .running(let pid)=await machine.observedState(),unsupportedPID != pid else{return}
        _=try await enqueue(idle:false,pid:pid).value
    }

    private func enqueue(idle:Bool,pid:Int32)->Task<Applied,Error> {
        let prior=tail,request=UUID(),socket=machine.controlSocket,id=machine.configuration.id
        latest=request
        let work=Task.detached {
            if let prior {_ = try? await prior.value}
            return try Self.apply(socket:socket,id:id,pid:pid,idle:idle)
        }
        tail=work
        Task{@MainActor [weak self] in
            let result=await work.result
            guard let self,self.latest==request else{return}
            self.tail=nil
            switch result {
            case .success(let value):
                self.appliedPID=pid;self.appliedIdle=value.idle
                self.appliedAt=ProcessInfo.processInfo.systemUptime
                if !value.supported {self.unsupportedPID=pid}
                self.state=["ready":true,"supported":value.supported,"idle":value.idle,
                    "busyNanoseconds":value.busy,"pid":pid,"updatedAt":Date().timeIntervalSince1970]
            case .failure(let error):
                self.appliedPID=nil
                self.state=["ready":false,"error":error.localizedDescription]
            }
        }
        return work
    }

    private nonisolated static func apply(socket:String,id:String,pid:Int32,idle:Bool)throws->Applied {
        func stats()throws->[String:Any]{
            let result=try MachineControl.value(socket:socket,operation:"qom-get",
                arguments:["path":"/machine","property":"perp-idle-wfi-stats"],expectedUUID:id,expectedPID:pid)
            guard let text=result as? String,let data=text.data(using:.utf8),
                  let value=try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  value["version"] as? Int == 1 else{throw failure("Invalid idle CPU capability.")}
            return value
        }
        do {_=try stats()}
        catch where error.localizedDescription.contains("perp-idle-wfi-stats") && error.localizedDescription.contains("not found") {
            // A retained older runtime has never enabled this lease. Preserve
            // normal use until its next qualified restart; do not claim savings.
            return Applied(supported:false,idle:false,busy:2_000_000)
        }
        _=try MachineControl.execute(socket:socket,operation:"qom-set",
            arguments:["path":"/machine","property":"perp-idle-wfi","value":idle],expectedUUID:id,expectedPID:pid)
        let value=try stats(),expected=idle ? 250_000:2_000_000
        guard value["idle"] as? Bool == idle,value["busyNanoseconds"] as? Int == expected else {
            throw failure("The requested CPU waiting mode was not confirmed.")
        }
        return Applied(supported:true,idle:idle,busy:expected)
    }
    private nonisolated static func failure(_ text:String)->NSError {
        NSError(domain:"CPUIdle",code:1,userInfo:[NSLocalizedDescriptionKey:text])
    }
}
