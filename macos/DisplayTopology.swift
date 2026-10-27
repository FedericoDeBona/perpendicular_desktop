import AppKit
import ColorSync

/// Host points and backing pixels are separate inputs to the guest topology.
/// IDs describe this display connection; never assume Windows uses the same IDs.
struct HostDisplay:Equatable {
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
    /// The guest desktop fits the area available to ordinary Mac windows.
    /// Windows reserves its own taskbar inside this raster independently.
    /// SharedDisplay converts these pixels back to Mac points for geometry.
    var guestPixelSize:NSSize {
        let width=min(4096,max(640,Int((workArea.width*scale).rounded())))
        let height=min(4096,8_388_608/width,max(480,Int((workArea.height*scale).rounded())))
        return NSSize(width:width,height:height)
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

struct AppDisplayBinding:Codable {let hostID:String;let slot:Int}
struct AppDisplayBindings:Codable {let machineID:String;let pid:Int32;let displays:[AppDisplayBinding]}

/// One Windows DIP per Mac point. Keep a uniform guest DPI so ordinary and
/// legacy Windows apps do not change logical size while moving between Macs.
/// A non-Retina Mac downsamples the same raster through its normal presenter.
struct AppMonitorMode:Sendable {
    let slot:Int
    let width:Int
    let height:Int
    let changed:Bool
}

struct MixedDisplayPlan {
    let layout:[[String:Any]]
    let hosts:[HostDisplay]
    let devices:[String]
    let scale:Int
    let unavailableHosts:Int
    let modes:[AppMonitorMode]
    private let viewports:[String:NSRect]

    static func rasterScale(_ hosts:[HostDisplay])->Int {
        hosts.allSatisfy{fits($0.frame.size,scale:2)} ? 2:1
    }
    static func supported(_ hosts:[HostDisplay])->Bool {
        let scale=rasterScale(hosts)
        return (1...15).contains(hosts.count) && hosts.allSatisfy{fits($0.frame.size,scale:scale) && $0.stableID != nil}
    }
    private static func fits(_ size:NSSize,scale:Int)->Bool {
        let w=size.width*CGFloat(scale),h=size.height*CGFloat(scale)
        return w>=640 && h>=480 && w<=4096 && h<=4096 && w*h<=8_388_608
    }
    private static func failure(_ text:String)->NSError {NSError(domain:"Displays",code:1,userInfo:[NSLocalizedDescriptionKey:text])}

    init(hosts:[HostDisplay],bindings:AppDisplayBindings,topology:[String:Any])throws {
        guard !hosts.isEmpty,
              Set(bindings.displays.map(\.hostID)).count==bindings.displays.count,
              Set(bindings.displays.map(\.slot)).count==bindings.displays.count,
              let paths=topology["paths"] as? [[String:Any]],(2...16).contains(paths.count),
              let monitors=(topology["monitors"] as? [String:Any])?["displays"] as? [[String:Any]],
              monitors.count==paths.count else {
            throw Self.failure("Impossibile verificare la configurazione degli schermi Windows.")
        }
        // A newly attached Mac must not invalidate an already working output.
        // Admit only bindings whose real guest adapter is healthy. Keep every
        // other active guest output in the layout, without mapping it to a Mac.
        let available=hosts.filter { host in
            guard let binding=bindings.displays.first(where:{$0.hostID==host.stableID}),
                  (9...23).contains(binding.slot) else{return false}
            return paths.contains{($0["pciAddress"] as? Int)==binding.slot<<16 && $0["service"] as? String=="VioGpuDod" && $0["problem"] as? Int==0}
        }
        guard !available.isEmpty else{throw Self.failure("Nessuno schermo per le app è disponibile. Riavvia Windows per aggiornare gli schermi collegati.")}
        let scale=Self.rasterScale(available)
        guard available.allSatisfy({Self.fits($0.frame.size,scale:scale) && $0.stableID != nil}) else {
            throw Self.failure("La dimensione di uno schermo supera il limite grafico corrente.")
        }
        func path(slot:Int,service:String)throws->[String:Any] {
            let found=paths.filter{($0["pciAddress"] as? Int)==(slot<<16) && $0["service"] as? String==service && $0["problem"] as? Int==0}
            guard found.count==1,found[0]["device"] is String else {
                throw Self.failure("Il driver dello schermo aggiuntivo non è pronto. Completa l’installazione multischermo.")
            }
            return found[0]
        }
        let primary=try path(slot:8,service:"VioGpu3D")
        guard let primaryName=primary["device"] as? String,
              let width=primary["width"] as? Int,let height=primary["height"] as? Int,
              (640...4096).contains(width),(480...4096).contains(height),width*height<=8_388_608 else {
            throw Self.failure("Il desktop Windows non è disponibile.")
        }
        // The reserved desktop has no Mac point mapping. Preserve its working
        // raster and DPI: old Windows profiles may not advertise the new boot
        // raster. Only the app displays need the common 1-DIP/1-point scale.
        var layout:[[String:Any]]=[["device":primaryName,"x":0,"y":0,"width":width,"height":height,"primary":true]]
        var devices:[String]=[]
        // These are dedicated Windows surfaces. Taskbar pixels live outside
        // the 1:1 Mac viewport; pack the padded rasters in a connected strip so
        // their invisible padding cannot overlap a neighbouring monitor.
        var left=0
        var modes:[AppMonitorMode]=[]
        var viewports:[String:NSRect]=[:]
        for host in available {
            guard let binding=bindings.displays.first(where:{$0.hostID==host.stableID}),
                  (9...23).contains(binding.slot) else {throw Self.failure("Gli schermi sono cambiati. Riavvia Windows per aggiornarli.")}
            let device=try path(slot:binding.slot,service:"VioGpuDod")["device"] as! String
            guard let actual=monitors.first(where:{$0["device"] as? String==device}),
                  let frame=Self.area(actual.compactMapValues{$0 as? Int}),
                  let fields=actual["workArea"] as? [String:Int],let guestWork=Self.area(fields),
                  frame.contains(guestWork),let dpi=actual["dpi"] as? Int,dpi>0 else {
                throw Self.failure("Windows non ha comunicato l’area della barra delle applicazioni.")
            }
            let ratio=CGFloat(96*scale)/CGFloat(dpi)
            let insetLeft=Int(((guestWork.minX-frame.minX)*ratio).rounded())
            let insetTop=Int(((guestWork.minY-frame.minY)*ratio).rounded())
            let insetRight=Int(((frame.maxX-guestWork.maxX)*ratio).rounded())
            let insetBottom=Int(((frame.maxY-guestWork.maxY)*ratio).rounded())
            let viewportWidth=Int((host.frame.width*CGFloat(scale)).rounded())
            let viewportHeight=Int((host.frame.height*CGFloat(scale)).rounded())
            let width=viewportWidth+insetLeft+insetRight,height=viewportHeight+insetTop+insetBottom
            guard width<=4096,height<=4096 else {throw Self.failure("Lo schermo con lo spazio della barra Windows supera il limite corrente.")}
            left-=width
            let x=left,y=0
            let viewport=NSRect(x:x+insetLeft,y:y+insetTop,width:viewportWidth,height:viewportHeight)
            let work=host.workArea
            let area:[String:Int]=["x":Int(viewport.minX)+Int(((work.minX-host.frame.minX)*CGFloat(scale)).rounded()),
                "y":Int(viewport.minY)+Int(((host.frame.maxY-work.maxY)*CGFloat(scale)).rounded()),
                "width":Int((work.width*CGFloat(scale)).rounded()),"height":Int((work.height*CGFloat(scale)).rounded())]
            layout.append(["device":device,"x":x,"y":y,"width":width,"height":height,
                "primary":false,"dpi":96*scale,"workArea":area])
            devices.append(device);viewports[device]=viewport
            modes.append(AppMonitorMode(slot:binding.slot,width:width,height:height,
                changed:actual["width"] as? Int != width || actual["height"] as? Int != height))
        }
        for monitor in monitors where !layout.contains(where:{$0["device"] as? String==monitor["device"] as? String}) {
            guard let device=monitor["device"] as? String,let w=monitor["width"] as? Int,let h=monitor["height"] as? Int,
                  let adapter=paths.first(where:{$0["device"] as? String==device}),adapter["service"] as? String=="VioGpuDod",
                  let address=adapter["pciAddress"] as? Int,bindings.displays.contains(where:{$0.slot<<16==address}) else {
                throw Self.failure("Un’uscita Windows non corrisponde alla configurazione della macchina.")
            }
            let left=(layout.compactMap{$0["x"] as? Int}.min() ?? 0)-w
            layout.append(["device":device,"x":left,"y":0,"width":w,"height":h,"primary":false])
        }
        guard Set(devices).count==available.count,monitors.count==layout.count else {throw Self.failure("Le uscite Windows non sono distinte.")}
        self.layout=layout;self.hosts=available;self.devices=devices;self.scale=scale;self.unavailableHosts=hosts.count-available.count
        self.modes=modes;self.viewports=viewports
    }

    func mappings(snapshot:[String:Any])throws->[SharedDisplay] {
        guard let monitors=(snapshot["monitors"] as? [String:Any])?["displays"] as? [[String:Any]] else {throw Self.failure("Impossibile verificare gli schermi Windows.")}
        // Verify every real output, including the reserved desktop, before
        // treating a settings broadcast as an unchanged configuration.
        guard monitors.count==layout.count,layout.allSatisfy({ requested in
            guard let actual=monitors.first(where:{$0["device"] as? String==requested["device"] as? String}) else{return false}
            return ["x","y","width","height"].allSatisfy{actual[$0] as? Int==requested[$0] as? Int}
                && actual["primary"] as? Bool==requested["primary"] as? Bool
        }) else{throw Self.failure("Windows non ha confermato la disposizione completa degli schermi.")}
        return try zip(hosts,devices).map { host,device in
            guard let actual=monitors.first(where:{$0["device"] as? String==device}),
                  let requested=layout.first(where:{$0["device"] as? String==device}),
                  let mapping=SharedDisplay.mapped(host:host,monitor:actual,requested:requested,scale:scale,viewport:viewports[device]),
                  let requestedArea=requested["workArea"] as? [String:Int],
                  let osArea=actual["workArea"] as? [String:Int],
                  let expectedArea=Self.area(requestedArea),let systemArea=Self.area(osArea),
                  mapping.guestWorkArea==expectedArea,systemArea.contains(expectedArea) else {
                throw Self.failure("Windows non ha confermato posizione, dimensioni e scala degli schermi.")
            }
            return mapping
        }
    }
    private static func area(_ fields:[String:Int])->NSRect? {
        guard let x=fields["x"],let y=fields["y"],let w=fields["width"],let h=fields["height"],w>0,h>0 else{return nil}
        return NSRect(x:x,y:y,width:w,height:h)
    }

}
