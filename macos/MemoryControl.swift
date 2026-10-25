import Foundation

/// Targets are requests. Only device ACKs, current guest totals and host reclaim
/// counters describe completion. Pinned virtio-mem blocks may remain plugged.
@MainActor
final class RuntimeMemoryController {
    private let machine:VirtualMachineController
    private let bridge:GuestBridge
    private let config:DynamicMemoryConfiguration
    private let foreground:()->Bool
    private var task:Task<Void,Never>?
    private var connectedAt=ProcessInfo.processInfo.systemUptime
    private var emergencyUntil=0.0
    private var lastPlugged:UInt64?
    private var lastRequested:UInt64?
    private var plugProgressAt=ProcessInfo.processInfo.systemUptime
    var guestReady=false
    private(set) var state:[String:Any]=["enabled":true,"ready":false]
    private static let MiB:UInt64=1_048_576

    init(machine:VirtualMachineController,bridge:GuestBridge,configuration:DynamicMemoryConfiguration,foreground:@escaping ()->Bool){
        self.machine=machine;self.bridge=bridge;config=configuration;self.foreground=foreground
    }
    func start(){
        guard task == nil else{return}
        task=Task{@MainActor [weak self] in
            while !Task.isCancelled {
                if let self {await self.update()}
                do {try await Task.sleep(for:.seconds(3))}catch{return}
            }
        }
    }
    func stop(){task?.cancel();task=nil;guestReady=false}
    private struct Guest:Sendable {let total:UInt64;let available:UInt64}
    private struct Snapshot:Sendable {
        let actual:UInt64,plugged:UInt64,requested:UInt64,reusable:UInt64,discarded:UInt64
    }
    private func guestMemory()async throws->Guest {
        try await withCheckedThrowingContinuation { continuation in
            bridge.command("memory_status",timeout:.seconds(5)){result in
                do {
                    let reply=try result.get()["value"] as? [String:Any] ?? [:]
                    guard let total=reply["totalPhysicalBytes"] as? UInt64,
                          let available=reply["availablePhysicalBytes"] as? UInt64,
                          total>0,available<=total else{throw Self.failure("Invalid guest RAM measurement.")}
                    continuation.resume(returning:Guest(total:total,available:available))
                }catch{continuation.resume(throwing:error)}
            }
        }
    }
    private nonisolated static func snapshot(socket:String,id:String,pid:Int32)throws->Snapshot {
        func stats(_ path:String)throws->[String:Any]{
            let result=try MachineControl.value(socket:socket,operation:"qom-get",arguments:["path":path,"property":"perp-reclaim-stats"],expectedUUID:id,expectedPID:pid)
            guard let text=result as? String,let data=text.data(using:.utf8),
                  let value=try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  value["version"] as? Int == 1,value["enabled"] as? Bool == true else {
                throw failure("The running VM does not have the qualified RAM support.")
            }
            return value
        }
        let balloon=try stats("/machine/peripheral/balloon0")
        let memory=try stats("/machine/peripheral/vmem0/virtio-backend")
        // The guest can complete unplug requests between QMP calls. Read RAM,
        // base and balloon ownership together, rather than infer an inflated
        // balloon from two measurements taken at different instants.
        guard let ram=balloon["ramBytes"] as? UInt64,let base=balloon["baseBytes"] as? UInt64,
              let inflated=balloon["inflatedBytes"] as? UInt64,ram>=base,ram>=inflated,
              let requested=memory["requestedBytes"] as? UInt64,
              let discarded=memory["discardedBytes"] as? UInt64,
              let reusable=balloon["reusableBytes"] as? UInt64,
              balloon["failures"] as? UInt64 == 0 else{throw failure("RAM release is not verified.")}
        return Snapshot(actual:ram-inflated,plugged:ram-base,requested:requested,reusable:reusable,discarded:discarded)
    }
    private func update()async {
        guard bridge.connected,guestReady else {
            connectedAt=ProcessInfo.processInfo.systemUptime
            state=["enabled":true,"ready":false];return
        }
        do {
            guard case .running(let pid)=await machine.observedState() else{return}
            let socket=machine.controlSocket,id=machine.configuration.id
            let observed=try await Task.detached {try Self.snapshot(socket:socket,id:id,pid:pid)}.value
            let guest=try await guestMemory()
            guard !Task.isCancelled else{return}
            let base=UInt64(machine.configuration.memoryMiB)*Self.MiB
            let capacity=base+UInt64(config.hotplugMiB)*Self.MiB
            guard observed.plugged<=UInt64(config.hotplugMiB)*Self.MiB,
                  observed.actual<=base+observed.plugged else{throw Self.failure("Inconsistent RAM device totals.")}
            let inflated=base+observed.plugged-observed.actual
            let physical=base+observed.plugged
            let totalDifference=physical>guest.total ? physical-guest.total:guest.total-physical
            let guestTotalConfirmed=totalDifference<=64*Self.MiB
            let usedIncludingBalloon=guest.total-guest.available
            let used=usedIncludingBalloon>inflated ? usedIncludingBalloon-inflated:0
            let reserve=UInt64(config.reserveMiB)*Self.MiB
            let now=ProcessInfo.processInfo.systemUptime
            if lastPlugged != observed.plugged || lastRequested != observed.requested {
                plugProgressAt=now;lastPlugged=observed.plugged;lastRequested=observed.requested
            }
            if guest.available<reserve/2 {emergencyUntil=now+60}
            let visible=foreground()
            let active=visible || now<emergencyUntil || now-connectedAt<15 || !guestTotalConfirmed
            let quantum=UInt64(128)*Self.MiB
            let needed=min(capacity,((used+reserve+quantum-1)/quantum)*quantum)
            var target=active ? capacity:max(UInt64(config.backgroundMiB)*Self.MiB,needed)
            // Release gradually; restore immediately when needed or visible.
            if target<observed.actual {target=max(target,observed.actual>quantum ? observed.actual-quantum:0)}
            let wantedPlugged=target>base ? target-base:0
            let targetBalloon=min(target,base+observed.plugged)
            let restore=active || target>observed.actual
            let unplugStalled=observed.plugged>wantedPlugged && now-plugProgressAt>=20
            // Restore balloon ownership first. Shrink physical RAM before
            // inflating a balloon, so it cannot pin blocks pending removal.
            let balloonTarget=restore ? base+observed.plugged:targetBalloon
            try await Task.detached {
                if (restore || observed.plugged<=wantedPlugged || unplugStalled),balloonTarget != observed.actual {
                    _=try MachineControl.execute(socket:socket,operation:"balloon",arguments:["value":balloonTarget],expectedUUID:id,expectedPID:pid)
                }
                if observed.requested != wantedPlugged {
                    _=try MachineControl.execute(socket:socket,operation:"qom-set",arguments:["path":"/machine/peripheral/vmem0","property":"requested-size","value":wantedPlugged],expectedUUID:id,expectedPID:pid)
                }
            }.value
            state=["enabled":true,"ready":true,"foreground":active,"targetMiB":target/Self.MiB,
                "viewForeground":visible,"updatedAt":Date().timeIntervalSince1970,
                "pressureGraceSeconds":max(0,Int(emergencyUntil-now)),
                "actualMiB":observed.actual/Self.MiB,"pluggedMiB":observed.plugged/Self.MiB,
                "requestedPluggedMiB":wantedPlugged/Self.MiB,"balloonMiB":inflated/Self.MiB,
                "guestTotalMiB":guest.total/Self.MiB,"guestAvailableMiB":guest.available/Self.MiB,
                "guestTotalConfirmed":guestTotalConfirmed,
                "reusableBytes":observed.reusable,"discardedBytes":observed.discarded,
                "unplugStalled":unplugStalled,
                "pending":observed.plugged != wantedPlugged || observed.actual != target || !guestTotalConfirmed]
        }catch{state=["enabled":true,"ready":false,"error":error.localizedDescription]}
    }
    private nonisolated static func failure(_ text:String)->NSError{NSError(domain:"Memory",code:1,userInfo:[NSLocalizedDescriptionKey:text])}
}
