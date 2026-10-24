import Foundation
import CoreGraphics
import AppKit

@main
struct WindowGeometryChecks {
    @MainActor static func main(){
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window=NSWindow(contentRect:NSRect(x:100,y:100,width:400,height:300),
                            styleMask:.borderless,backing:.buffered,defer:false)
        func event(_ type:NSEvent.EventType,_ point:NSPoint)->NSEvent {
            NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:1,
                windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        }
        let down=WindowMouseSample(event:event(.leftMouseDown,NSPoint(x:100,y:200)),window:window)
        let pending=[event(.leftMouseDragged,NSPoint(x:110,y:210)),
                     event(.leftMouseDragged,NSPoint(x:130,y:230)),
                     event(.leftMouseUp,NSPoint(x:130,y:230))]
        // Hit testing queues these samples before the first move is applied.
        let samples=pending.map {WindowMouseSample(event:$0,window:window)}
        for (sample,delta) in zip(samples,[NSPoint(x:10,y:10),NSPoint(x:30,y:30),NSPoint(x:30,y:30)]) {
            let actual=NSPoint(x:sample.screenLocation.x-down.screenLocation.x,
                               y:sample.screenLocation.y-down.screenLocation.y)
            precondition(actual == delta,"An earlier window move must not alter queued mouse coordinates")
            window.setFrameOrigin(NSPoint(x:100+actual.x,y:100+actual.y))
        }
        precondition(window.frame.origin == NSPoint(x:130,y:130),"Queued drag must follow the physical delta once")
        precondition(samples.last?.type == .leftMouseUp && down.clickCount == 1,"Frozen samples must retain gesture metadata")
        let original=NSRect(x:100,y:200,width:400,height:300)
        let minimum=NSSize(width:160,height:100),maximum=NSSize(width:800,height:552)
        let corner:ResizeEdges=[.left,.bottom]
        let small=corner.frame(from:original,delta:NSPoint(x:500,y:500),minimum:minimum,maximum:maximum)
        precondition(small == NSRect(x:340,y:400,width:160,height:100),"Shrinking must preserve the opposite corner")
        let large:ResizeEdges=[.right,.top]
        precondition(large.frame(from:original,delta:NSPoint(x:1000,y:2000),minimum:minimum,maximum:maximum)
            == NSRect(x:100,y:200,width:800,height:552),"Resize must stay within the current guest display")
        precondition(ResizeEdges.left.frame(from:original,delta:NSPoint(x:-200,y:0),minimum:minimum,maximum:maximum)
            == NSRect(x:-100,y:200,width:600,height:300),"Dragging the left edge must keep the right edge fixed")
        let hitBounds=NSRect(x:0,y:0,width:400,height:300)
        precondition(ResizeEdges(point:NSPoint(x:10,y:290),bounds:hitBounds) == [.left,.top],"The top-left cursor and gesture must agree")
        precondition(ResizeEdges(point:NSPoint(x:390,y:10),bounds:hitBounds) == [.right,.bottom],"The bottom-right cursor and gesture must agree")
        precondition(ResizeEdges(point:NSPoint(x:399,y:150),bounds:hitBounds) == .right,"The right border must resize horizontally")
        precondition(ResizeEdges(point:NSPoint(x:20,y:20),bounds:hitBounds).isEmpty,"The interior must keep normal app input")
        let host=HostDisplay(id:1,frame:NSRect(x:100,y:-80,width:1470,height:956),
            workArea:NSRect(x:100,y:-80,width:1470,height:923),scale:2,primary:true)
        precondition(host.guestPixelSize == NSSize(width:2940,height:1846),"The guest raster must exclude the Mac menu bar")
        var monitor:[String:Any]=["primary":true,"x":0,"y":0,"width":2940,"height":1846,"dpi":192,
            "workArea":["x":0,"y":0,"width":2940,"height":1750]]
        let mapping=SharedDisplay.primary(host:host,snapshot:["displays":[monitor]])!
        let guest=NSRect(x:240,y:180,width:1600,height:1200)
        precondition(mapping.pixelScale == 0.5 && mapping.macFrame(forGuest:guest) == NSRect(x:220,y:153,width:800,height:600))
        precondition(mapping.macFrame(forGuest:mapping.guestFrame) == host.workArea,"The whole guest raster must fit the usable Mac rectangle")
        precondition(mapping.guestFrame(forMac:mapping.macFrame(forGuest:guest)) == guest,"Geometry must round-trip across origins")
        monitor["dpi"]=240
        precondition(SharedDisplay.primary(host:host,snapshot:["displays":[monitor]]) != nil,"DPI changes UI size, not physical coordinates")
        monitor["width"]=1470;monitor["height"]=956
        precondition(SharedDisplay.primary(host:host,snapshot:["displays":[monitor]]) == nil,"The previous low resolution must not enable the Retina mapping")
        monitor["width"]=2940;monitor["height"]=1912
        precondition(SharedDisplay.primary(host:host,snapshot:["displays":[monitor]]) == nil,"A full-screen raster must not enable the usable-area mapping")
        monitor["height"]=1846;monitor["workArea"]=["x":0,"y":0,"width":2940,"height":1846]
        precondition(SharedDisplay.primary(host:host,snapshot:["displays":[monitor]]) != nil,"Windows can reclaim its own taskbar area independently")
        let dock=HostDisplay(id:1,frame:NSRect(x:0,y:0,width:1440,height:900),
            workArea:NSRect(x:70,y:0,width:1370,height:870),scale:2,primary:true)
        precondition(dock.guestPixelSize == NSSize(width:2740,height:1740),"A side Dock must reduce the guest width")
        let dockMapping=SharedDisplay.primary(host:dock,snapshot:["displays":[[
            "primary":true,"x":0,"y":0,"width":2740,"height":1740,"dpi":192,
            "workArea":["x":0,"y":0,"width":2740,"height":1644]]]])!
        precondition(dockMapping.macFrame(forGuest:dockMapping.guestFrame) == dock.workArea,"A side Dock must shift the guest origin")
        precondition(ResizeEdges.right.frame(from:original,delta:NSPoint(x:-999,y:0),
            minimum:NSSize(width:322,height:100),maximum:maximum).width == 322,"The preview must respect the Windows app minimum")
        print("Window geometry: resize and shared coordinate checks passed")
    }
}
