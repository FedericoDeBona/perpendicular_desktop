import AppKit
import ColorSync

/// Host points and backing pixels are separate inputs to the guest topology.
/// IDs describe this display connection; never assume Windows uses the same IDs.
struct HostDisplay {
    let id:UInt32
    let frame:NSRect
    let workArea:NSRect
    let scale:CGFloat
    let primary:Bool
    let physicalWidthMM:Int?
    let physicalHeightMM:Int?
    let stableID:String?

    init(id:UInt32,frame:NSRect,workArea:NSRect,scale:CGFloat,primary:Bool,
         physicalWidthMM:Int?=nil,physicalHeightMM:Int?=nil,stableID:String?=nil){
        self.id=id;self.frame=frame;self.workArea=workArea;self.scale=scale;self.primary=primary
        self.physicalWidthMM=physicalWidthMM.flatMap{(10...2550).contains($0) ? $0:nil}
        self.physicalHeightMM=physicalHeightMM.flatMap{(10...2550).contains($0) ? $0:nil}
        self.stableID=stableID.flatMap{UUID(uuidString:$0)?.uuidString.lowercased()}
    }

    @MainActor static func current()->[HostDisplay]{
        NSScreen.screens.prefix(16).enumerated().compactMap{index,screen in
            guard let number=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else{return nil}
            let id=number.uint32Value
            let physical=CGDisplayScreenSize(id)
            let identity=CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
            let stableID=identity.flatMap{CFUUIDCreateString(kCFAllocatorDefault,$0) as String?}
            return HostDisplay(id:id,frame:screen.frame,workArea:screen.visibleFrame,
                               scale:screen.backingScaleFactor,primary:index == 0,
                               physicalWidthMM:millimetres(physical.width),
                               physicalHeightMM:millimetres(physical.height),stableID:stableID)
        }
    }
    private static func millimetres(_ value:CGFloat)->Int?{
        guard value.isFinite,(10...2550).contains(value) else{return nil}
        return Int(value.rounded())
    }
    var description:[String:Any]{
        var value:[String:Any]=["id":id,"primary":primary,"scale":Double(scale),
         "points":["x":frame.minX,"y":frame.minY,"width":frame.width,"height":frame.height],
         "workArea":["x":workArea.minX,"y":workArea.minY,"width":workArea.width,"height":workArea.height],
         "pixelWidth":Int((frame.width*scale).rounded()),"pixelHeight":Int((frame.height*scale).rounded())]
        if let physicalWidthMM {value["physicalWidthMM"]=physicalWidthMM}
        if let physicalHeightMM {value["physicalHeightMM"]=physicalHeightMM}
        if let stableID {value["stableID"]=stableID}
        return value
    }
}
