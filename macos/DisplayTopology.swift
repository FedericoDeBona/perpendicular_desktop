import AppKit

/// Host points and backing pixels are separate inputs to the guest topology.
/// IDs describe this display connection; never assume Windows uses the same IDs.
struct HostDisplay {
    let id:UInt32
    let frame:NSRect
    let workArea:NSRect
    let scale:CGFloat
    let primary:Bool

    @MainActor static func current()->[HostDisplay]{
        NSScreen.screens.prefix(16).enumerated().compactMap{index,screen in
            guard let number=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else{return nil}
            return HostDisplay(id:number.uint32Value,frame:screen.frame,workArea:screen.visibleFrame,
                               scale:screen.backingScaleFactor,primary:index == 0)
        }
    }
    var description:[String:Any]{
        ["id":id,"primary":primary,"scale":Double(scale),
         "points":["x":frame.minX,"y":frame.minY,"width":frame.width,"height":frame.height],
         "workArea":["x":workArea.minX,"y":workArea.minY,"width":workArea.width,"height":workArea.height],
         "pixelWidth":Int((frame.width*scale).rounded()),"pixelHeight":Int((frame.height*scale).rounded())]
    }
}
