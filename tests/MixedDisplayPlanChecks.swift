import AppKit

@main struct MixedDisplayPlanChecks {
    static func main() throws {
        let first=HostDisplay(id:1,frame:NSRect(x:0,y:0,width:1470,height:956),workArea:NSRect(x:0,y:0,width:1470,height:923),scale:2,primary:true,stableID:"11111111-1111-1111-1111-111111111111")
        let second=HostDisplay(id:2,frame:NSRect(x:1470,y:0,width:1920,height:1080),workArea:NSRect(x:1470,y:0,width:1920,height:1050),scale:2,primary:false,stableID:"22222222-2222-2222-2222-222222222222")
        let binding=AppDisplayBinding(hostID:first.stableID!,slot:9)
        let bindings=AppDisplayBindings(machineID:"test",pid:1,displays:[binding])
        let desktop:[String:Any]=["device":"D1","pciAddress":8<<16,"service":"VioGpu3D","problem":0,"width":1920,"height":1280]
        let app:[String:Any]=["device":"D2","pciAddress":9<<16,"service":"VioGpuDod","problem":0,"width":2940,"height":1912,"x":0,"y":0,"dpi":192,"workArea":["x":0,"y":0,"width":2940,"height":1816]]
        let topology:[String:Any]=["paths":[desktop,app],"monitors":["displays":[desktop,app]]]
        let connected=try MixedDisplayPlan(hosts:[first,second],bindings:bindings,topology:topology)
        precondition(connected.hosts.count==1 && connected.unavailableHosts==1 && connected.devices==["D2"],"Adding an unprovisioned monitor must keep the verified monitor usable")
        precondition(connected.layout.count==2,"Every real Windows output must remain described")
        let secondBinding=AppDisplayBinding(hostID:second.stableID!,slot:10)
        let provisioned=AppDisplayBindings(machineID:"test",pid:1,displays:[binding,secondBinding])
        let orphan:[String:Any]=["device":"D3","pciAddress":10<<16,"service":"VioGpuDod","problem":0,"width":3840,"height":2160,"x":0,"y":0,"dpi":192,"workArea":["x":0,"y":0,"width":3840,"height":2064]]
        let unplugged=try MixedDisplayPlan(hosts:[first],bindings:provisioned,topology:["paths":[desktop,app,orphan],"monitors":["displays":[desktop,app,orphan]]])
        precondition(unplugged.hosts.count==1 && unplugged.layout.count==3 && unplugged.unavailableHosts==0,"Unplugging a Mac must preserve active guest outputs without inventing a Mac mapping")
        do {
            _=try MixedDisplayPlan(hosts:[second],bindings:bindings,topology:topology)
            preconditionFailure("No unverified monitor may be presented as ready")
        } catch {}
        do {
            _=try MixedDisplayPlan(hosts:[first],bindings:AppDisplayBindings(machineID:"test",pid:1,displays:[binding,binding]),topology:topology)
            preconditionFailure("Duplicate device identities must be rejected")
        } catch {}
        var widerDesktop=desktop;widerDesktop["width"]=3500
        let wider=try MixedDisplayPlan(hosts:[first],bindings:bindings,topology:["paths":[widerDesktop,app],"monitors":["displays":[widerDesktop,app]]])
        precondition(connected.layout[1]["x"] as? Int==wider.layout[1]["x"] as? Int,
                     "Resizing the reserved desktop must not move app displays")
        precondition((wider.layout[1]["x"] as! Int)+(wider.layout[1]["width"] as! Int)==0,"App displays must touch the left of the primary without depending on its raster")
        let applied=connected.layout.map { fields -> [String:Any] in
            var actual=fields
            let area=fields["workArea"] ?? ["x":fields["x"]!,"y":fields["y"]!,"width":fields["width"]!,"height":fields["height"]!]
            if fields["primary"] as? Bool == false {
                actual["workArea"]=["x":fields["x"]!,"y":fields["y"]!,"width":fields["width"]!,"height":(fields["height"] as! Int)-96]
            }else{actual["workArea"]=area}
            actual["appWorkArea"]=area
            return actual
        }
        let reused=try connected.mappings(snapshot:["monitors":["displays":applied]])
        precondition(reused.count==1,
                     "A fully confirmed unchanged layout must be reusable")
        var changed=applied
        changed[0]["x"]=1
        do {
            _=try connected.mappings(snapshot:["monitors":["displays":changed]])
            preconditionFailure("A changed reserved desktop must not pass the unchanged-layout gate")
        }catch{}
        changed=applied;changed[1]["appWorkArea"]=["x":0,"y":0,"width":10,"height":10]
        do {
            _=try connected.mappings(snapshot:["monitors":["displays":changed]])
            preconditionFailure("A stale private app work area must require configuration")
        }catch{}
        precondition(connected.modes[0].width==2940 && connected.modes[0].height==2008,
                     "The dedicated raster must include the Windows taskbar outside the Mac viewport")
        precondition(reused[0].macFrame(forGuest:reused[0].guestWorkArea!)==first.workArea,
                     "Maximize must occupy exactly the ordinary Mac work area with a hidden Dock")
        for area in [NSRect(x:0,y:70,width:1470,height:853),NSRect(x:80,y:0,width:1390,height:923)] {
            let dock=HostDisplay(id:1,frame:first.frame,workArea:area,scale:2,primary:true,stableID:first.stableID)
            let plan=try MixedDisplayPlan(hosts:[dock],bindings:bindings,topology:topology)
            var result=plan.layout
            result[1]["workArea"]=["x":result[1]["x"]!,"y":0,"width":2940,"height":1912]
            result[1]["appWorkArea"]=plan.layout[1]["workArea"]
            let mapping=try plan.mappings(snapshot:["monitors":["displays":result]])[0]
            precondition(mapping.macFrame(forGuest:mapping.guestWorkArea!)==area,
                         "A visible bottom or side Dock must use the area reported by macOS")
            precondition(mapping.pixelScale==0.5,"Dock changes must not stretch Windows pixels")
        }
        print("Mixed displays: binding checks and unchanged-layout verification passed")
    }
}
