@main struct MemoryUnplugProgressChecks {
    static func main(){
        var progress=MemoryUnplugProgress()
        progress.observe(plugged:2048,requested:2048,at:0)
        progress.observe(plugged:2048,requested:1920,at:100)
        precondition(!progress.stalled(at:119),"A new unplug cycle gets its grace period")
        progress.observe(plugged:2048,requested:1792,at:118)
        precondition(progress.stalled(at:120),"Lowering the request cannot postpone the fallback indefinitely")
        progress.observe(plugged:1984,requested:1792,at:121)
        precondition(!progress.stalled(at:140),"Real unplug progress renews the grace period")
        precondition(progress.stalled(at:141))
        progress.observe(plugged:1984,requested:2048,at:150)
        progress.observe(plugged:1984,requested:1792,at:200)
        precondition(!progress.stalled(at:219),"Restoring memory ends the previous unplug cycle")
        print("Unplug progress: request-only changes, real release and restore passed")
    }
}
