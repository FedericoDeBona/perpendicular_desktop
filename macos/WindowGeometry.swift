import AppKit

struct ResizeEdges:OptionSet {
    let rawValue:Int
    static let left=ResizeEdges(rawValue:1),right=ResizeEdges(rawValue:2)
    static let top=ResizeEdges(rawValue:4),bottom=ResizeEdges(rawValue:8)
    init(rawValue:Int){self.rawValue=rawValue}
    static func regions(in bounds:NSRect)->[(ResizeEdges,NSRect)]{
        let x=bounds.minX,y=bounds.minY,w=bounds.width,h=bounds.height
        let corner=min(14,min(w,h)/2),border=min(6,corner)
        return [([.left,.bottom],NSRect(x:x,y:y,width:corner,height:corner)),
            ([.right,.bottom],NSRect(x:x+w-corner,y:y,width:corner,height:corner)),
            ([.left,.top],NSRect(x:x,y:y+h-corner,width:corner,height:corner)),
            ([.right,.top],NSRect(x:x+w-corner,y:y+h-corner,width:corner,height:corner)),
            (.left,NSRect(x:x,y:y+corner,width:border,height:h-2*corner)),
            (.right,NSRect(x:x+w-border,y:y+corner,width:border,height:h-2*corner)),
            (.bottom,NSRect(x:x+corner,y:y,width:w-2*corner,height:border)),
            (.top,NSRect(x:x+corner,y:y+h-border,width:w-2*corner,height:border))]
    }
    init(point:NSPoint,bounds:NSRect){
        self=Self.regions(in:bounds).first(where:{$0.1.contains(point)})?.0 ?? []
    }
    @MainActor var cursor:NSCursor {
        if #available(macOS 15,*) {
            let position:NSCursor.FrameResizePosition
            switch self {
            case [.top,.left]:position = .topLeft
            case [.top,.right]:position = .topRight
            case [.bottom,.left]:position = .bottomLeft
            case [.bottom,.right]:position = .bottomRight
            case .left:position = .left
            case .right:position = .right
            case .top:position = .top
            default:position = .bottom
            }
            return .frameResize(position:position,directions:.all)
        }
        if self == .left || self == .right {return .resizeLeftRight}
        if self == .top || self == .bottom {return .resizeUpDown}
        return Self.diagonalCursor(rising:contains(.top) == contains(.right))
    }
    @MainActor private static func diagonalCursor(rising:Bool)->NSCursor{
        let image=NSImage(size:NSSize(width:24,height:24),flipped:false){_ in
            let path=NSBezierPath()
            let low=NSPoint(x:5,y:rising ? 5:19),high=NSPoint(x:19,y:rising ? 19:5)
            path.move(to:low);path.line(to:high)
            path.move(to:NSPoint(x:5,y:12));path.line(to:low);path.line(to:NSPoint(x:12,y:low.y))
            path.move(to:NSPoint(x:19,y:12));path.line(to:high);path.line(to:NSPoint(x:12,y:high.y))
            path.lineCapStyle = .round;path.lineJoinStyle = .round
            NSColor.white.setStroke();path.lineWidth=4;path.stroke()
            NSColor.black.setStroke();path.lineWidth=2;path.stroke();return true
        }
        return NSCursor(image:image,hotSpot:NSPoint(x:12,y:12))
    }
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
