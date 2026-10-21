import Foundation
import CoreGraphics

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
        print("Window geometry: 3 checks passed")
    }
}
