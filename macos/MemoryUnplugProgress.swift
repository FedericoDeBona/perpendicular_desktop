/// A lower request is not an acknowledgement that Windows released memory.
/// Keep the original grace period while pinned blocks remain unchanged.
struct MemoryUnplugProgress {
    private var lastPlugged:UInt64?
    private var lastRequested:UInt64?
    private var progressAt=0.0

    mutating func observe(plugged:UInt64,requested:UInt64,at now:Double){
        let wasPending:Bool
        if let lastPlugged,let lastRequested {wasPending=lastRequested<lastPlugged}
        else {wasPending=false}
        if lastPlugged != plugged || !wasPending || requested>=plugged {progressAt=now}
        lastPlugged=plugged;lastRequested=requested
    }

    func stalled(at now:Double)->Bool {now-progressAt>=20}
}
