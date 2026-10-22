import Foundation
import CoreGraphics
import AppKit

@main
struct WindowGeometryChecks {
    static func main(){
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
        let host=HostDisplay(id:1,frame:NSRect(x:100,y:-80,width:1470,height:956),
            workArea:NSRect(x:100,y:-80,width:1470,height:923),scale:2,primary:true)
        var monitor:[String:Any]=["primary":true,"x":0,"y":0,"width":1470,"height":956,"dpi":96,
            "workArea":["x":0,"y":33,"width":1470,"height":875]]
        let mapping=SharedDisplay.primary(host:host,snapshot:["displays":[monitor]])!
        let guest=NSRect(x:120,y:90,width:800,height:600)
        precondition(mapping.pixelScale == 1 && mapping.macFrame(forGuest:guest) == NSRect(x:220,y:186,width:800,height:600))
        precondition(mapping.guestFrame(forMac:mapping.macFrame(forGuest:guest)) == guest,"Geometry must round-trip across origins")
        monitor["dpi"]=240
        precondition(SharedDisplay.primary(host:host,snapshot:["displays":[monitor]]) != nil,"DPI changes UI size, not physical coordinates")
        monitor["width"]=2940;monitor["height"]=1912
        precondition(SharedDisplay.primary(host:host,snapshot:["displays":[monitor]]) == nil,"An old Retina mode must not enable the new mapping")
        monitor["width"]=1470;monitor["height"]=956;monitor["workArea"]=["x":0,"y":0,"width":1470,"height":908]
        precondition(SharedDisplay.primary(host:host,snapshot:["displays":[monitor]]) == nil,"The menu bar must be reserved on both sides")
        print("Window geometry: resize and shared coordinate checks passed")
    }
}
