@main struct DesktopResizeReadChecks {
    @MainActor static func main() async {
        var previous:DesktopResizeRead?
        let superseded:Bool=await withCheckedContinuation { continuation in
            let read=DesktopResizeRead {continuation.resume(returning:$0)}
            previous=read
            read.finish(false)
            // The delayed reply belongs to the previous size, even if it
            // reports a successful mode. It cannot resume the wait twice.
            read.finish(true)
        }
        precondition(!superseded)
        let current:Bool=await withCheckedContinuation { continuation in
            let read=DesktopResizeRead {continuation.resume(returning:$0)}
            previous?.finish(true)
            precondition(read.pending,"An old reply cannot complete the current resize")
            read.finish(true)
            read.finish(false)
        }
        precondition(current)
        print("Resize read: superseded and late replies preserve the current completion")
    }
}
