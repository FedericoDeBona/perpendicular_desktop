import Foundation
import CoreGraphics
import Darwin

private struct CursorCheckFailure: Error { let message: String }

@main
private enum RFBCursorCheck {
    static func run() throws -> Int {
        var assertions = 0
        func check(_ value: Bool, _ message: String) throws {
            assertions += 1
            if !value { throw CursorCheckFailure(message: message) }
        }
        func rejected(_ expected: RFBCursorError, _ body: () throws -> Void) throws {
            do { try body(); throw CursorCheckFailure(message: "malformed cursor accepted: \(expected)") }
            catch let error as RFBCursorError { try check(error == expected, "wrong error for malformed cursor") }
        }
        try check(RFBCursor.encoding == -239, "RichCursor encoding")
        // Fixed oracle: non-square, row padding, MSB and rightmost ninth bit.
        let width = 9, height = 3, pixelLength = width * height * 4
        var payload = Data()
        for i in 0..<(width * height) { payload.append(contentsOf: [UInt8(11+i), UInt8(31+i), UInt8(91+i), 7]) }
        payload.append(contentsOf: [0x80, 0x80, 0x40, 0x00, 0x01, 0xff])
        try check(try RFBCursor.payloadLength(width: width, height: height, hotspotX: 8, hotspotY: 2) == 114,
                  "pixel+row-padded mask payload length")
        let cursor = try RFBCursor.decode(width: width, height: height, hotspotX: 8, hotspotY: 2, payload: payload)
        let visible: Set<Int> = [0, 8, 10, 25, 26]
        for i in 0..<(width * height) {
            let expected: [UInt8] = visible.contains(i) ? [UInt8(11+i), UInt8(31+i), UInt8(91+i), 255] : [0,0,0,0]
            try check(Array(cursor.pixelsBGRA[i*4..<(i*4+4)]) == expected, "RichCursor mask/color oracle at pixel \(i)")
        }
        try check(cursor.width == 9 && cursor.height == 3 && cursor.hotspotX == 8 && cursor.hotspotY == 2 && !cursor.isHidden,
                  "non-square metadata and edge hotspot")
        // Bits beyond width are padding, not pixels or the next row's mask.
        var paddingChanged = payload
        paddingChanged[pixelLength+1] |= 0x7f
        paddingChanged[pixelLength+3] |= 0x7f
        paddingChanged[pixelLength+5] &= 0x80
        try check(try RFBCursor.decode(width: 9, height: 3, hotspotX: 8, hotspotY: 2, payload: paddingChanged) == cursor,
                  "mask padding affected pixels")
        var sliced = Data([99]); sliced.append(payload); sliced.append(88)
        try check(try RFBCursor.decode(width: 9, height: 3, hotspotX: 8, hotspotY: 2,
                                     payload: sliced[1..<(1+payload.count)]) == cursor, "Data slice offset")
        let byteAligned = try RFBCursor.decode(width: 8, height: 2, hotspotX: 0, hotspotY: 0,
            payload: Data(repeating: 32, count: 64) + Data([0x80, 0x01]))
        try check(byteAligned.pixelsBGRA[3] == 255 && byteAligned.pixelsBGRA[63] == 255 &&
                  byteAligned.pixelsBGRA[7] == 0 && byteAligned.pixelsBGRA[35] == 0, "byte-aligned independent rows")
        let transparent = try RFBCursor.decode(width: 1, height: 1, hotspotX: 0, hotspotY: 0,
            payload: Data([42,43,44,255,0x01]))
        try check(transparent.pixelsBGRA == Data([0,0,0,0]) && !transparent.isHidden, "MSB first and explicit alpha mask")
        let opaque = try RFBCursor.decode(width: 1, height: 1, hotspotX: 0, hotspotY: 0,
            payload: Data([42,43,44,0,0x80]))
        try check(opaque.pixelsBGRA == Data([42,43,44,255]), "wire padding is not alpha")
        let hidden = try RFBCursor.decode(width: 0, height: 0, hotspotX: 0, hotspotY: 0, payload: Data())
        try check(hidden.isHidden && hidden.pixelsBGRA.isEmpty, "explicit hidden cursor")
        try check(try RFBCursor.payloadLength(width: 0, height: 0, hotspotX: 0, hotspotY: 0) == 0, "hidden payload length")
        try check(try hidden.fittedGeometry(framebufferSize: .zero, viewBounds: .zero) == nil, "hidden has no image geometry")
        for (w,h) in [(0,1),(1,0),(-1,1),(1,-1),(513,1),(1,513),(Int.max,Int.max),(Int.min,Int.max)] {
            var payloadReaderCalled = false
            try rejected(.invalidDimensions) {
                _ = try RFBCursor.payloadLength(width: w, height: h, hotspotX: 0, hotspotY: 0)
                payloadReaderCalled = true
            }
            try check(!payloadReaderCalled, "invalid header reached payload reader")
        }
        for (w,h,x,y) in [(1,1,-1,0),(1,1,0,-1),(9,3,9,0),(9,3,0,3),(0,0,1,0),(0,0,0,1),(1,1,Int.max,Int.min)] {
            try rejected(.invalidHotspot) { _ = try RFBCursor.payloadLength(width:w,height:h,hotspotX:x,hotspotY:y) }
        }
        for malformed in [Data(),Data(payload.dropLast()),payload+Data([0]),Data(repeating:0,count:pixelLength)] {
            try rejected(.invalidPayload) { _ = try RFBCursor.decode(width:9,height:3,hotspotX:8,hotspotY:2,payload:malformed) }
        }
        try rejected(.invalidPayload) { _ = try RFBCursor.decode(width:0,height:0,hotspotX:0,hotspotY:0,payload:Data([0])) }
        let maximumLength = try RFBCursor.payloadLength(width:512,height:512,hotspotX:511,hotspotY:511)
        try check(maximumLength == RFBCursor.maximumPayloadLength, "maximum validated payload bound")
        let maximum = try RFBCursor.decode(width:512,height:512,hotspotX:511,hotspotY:511,
            payload:Data(repeating:255,count:maximumLength))
        try check(maximum.pixelsBGRA.count == 1_048_576 && maximum.pixelsBGRA.last == 255, "maximum supported cursor")
        let geometry = try cursor.fittedGeometry(framebufferSize:CGSize(width:1600,height:900),
            viewBounds:CGRect(x:10,y:20,width:1000,height:1000))!
        try check(geometry.pointsPerGuestPixel == 0.625 && geometry.framebufferRect == CGRect(x:10,y:238.75,width:1000,height:562.5),
                  "aspect fit and nonzero view origin")
        try check(geometry.imageSize == CGSize(width:5.625,height:1.875) && geometry.hotspot == CGPoint(x:5,y:1.25),
                  "scaled cursor image and hotspot")
        try check(geometry.imageRect(atViewPoint:CGPoint(x:510,y:520)) == CGRect(x:505,y:518.75,width:5.625,height:1.875),
                  "cursor anchors at pointer minus scaled hotspot")
        try check(geometry.imageRect(atViewPoint:CGPoint(x:10,y:20)) == nil &&
                  geometry.imageRect(atViewPoint:CGPoint(x:1010,y:520)) == nil &&
                  geometry.imageRect(atViewPoint:CGPoint(x:CGFloat.nan,y:520)) == nil, "letterbox/border/nonfinite pointer")
        let upscaled = try cursor.fittedGeometry(framebufferSize:CGSize(width:100,height:50),
            viewBounds:CGRect(x:0,y:0,width:300,height:150))!
        try check(upscaled.imageSize == CGSize(width:27,height:9) && upscaled.hotspot == CGPoint(x:24,y:6),
                  "integer upscale without double backing-scale application")
        let invalidSizes: [CGSize] = [.zero, CGSize(width:-1,height:10),CGSize(width:CGFloat.nan,height:10),
            CGSize(width:CGFloat.infinity,height:10)]
        for size in invalidSizes {
            try rejected(.invalidGeometry) { _ = try cursor.fittedGeometry(framebufferSize:size,viewBounds:CGRect(x:0,y:0,width:100,height:100)) }
        }
        let invalidBounds: [CGRect] = [.zero, CGRect(x:0,y:0,width:-1,height:100),CGRect(x:CGFloat.infinity,y:0,width:10,height:10),
            CGRect(x:0,y:0,width:CGFloat.nan,height:10),CGRect(x:CGFloat.greatestFiniteMagnitude,y:0,width:CGFloat.greatestFiniteMagnitude,height:10)]
        for rect in invalidBounds {
            try rejected(.invalidGeometry) { _ = try cursor.fittedGeometry(framebufferSize:CGSize(width:100,height:100),viewBounds:rect) }
        }
        try rejected(.invalidGeometry) {
            _ = try cursor.fittedGeometry(framebufferSize:CGSize(width:CGFloat.leastNonzeroMagnitude,height:CGFloat.leastNonzeroMagnitude),
                viewBounds:CGRect(x:0,y:0,width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude))
        }
        return assertions
    }
    static func main() {
        do { let count = try run(); print("{\"result\":\"pass\",\"assertions\":\(count),\"ui\":false,\"maximum_dimension\":512}") }
        catch {
            let message = (error as? CursorCheckFailure)?.message ?? String(describing:error)
            FileHandle.standardError.write(Data(("RFBCursor check: " + message + "\n").utf8));exit(1)
        }
    }
}
