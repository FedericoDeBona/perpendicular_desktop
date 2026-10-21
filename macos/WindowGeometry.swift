import Foundation
import CoreGraphics

struct ResizeEdges:OptionSet {
    let rawValue:Int
    static let left=ResizeEdges(rawValue:1),right=ResizeEdges(rawValue:2)
    static let top=ResizeEdges(rawValue:4),bottom=ResizeEdges(rawValue:8)
    init(rawValue:Int){self.rawValue=rawValue}
    init(hit:Int){
        switch hit {
        case 10:self = .left
        case 11:self = .right
        case 12:self = .top
        case 13:self = [.top,.left]
        case 14:self = [.top,.right]
        case 15:self = .bottom
        case 16:self = [.bottom,.left]
        case 17:self = [.bottom,.right]
        default:self = []
        }
    }
    func frame(from original:NSRect,delta:NSPoint,minimum:NSSize,maximum:NSSize)->NSRect{
        let width=min(maximum.width,max(minimum.width,original.width+(contains(.right) ? delta.x:contains(.left) ? -delta.x:0)))
        let height=min(maximum.height,max(minimum.height,original.height+(contains(.top) ? delta.y:contains(.bottom) ? -delta.y:0)))
        return NSRect(x:contains(.left) ? original.maxX-width:original.minX,
                      y:contains(.bottom) ? original.maxY-height:original.minY,width:width,height:height)
    }
}
