import Foundation

@main
struct RFBDesktopResizeCheck {
    static func main() throws {
        let request = try RFBDesktopResize.request(width: 1920, height: 1080, screenID: 0x01020304)
        let expected: [UInt8] = [251,0,7,128,4,56,1,0,1,2,3,4,0,0,0,0,7,128,4,56,0,0,0,0]
        precondition([UInt8](request) == expected, "RFB SetDesktopSize wire bytes differ")
        for dimensions in [(0,1080),(639,480),(640,479),(3841,1080),(1920,2161),(Int.max,Int.max)] {
            do {
                _ = try RFBDesktopResize.request(width: dimensions.0, height: dimensions.1, screenID: 0)
                fatalError("Invalid target admitted")
            } catch RFBDesktopResizeError.invalidRequest {}
        }
        var payload = Data([1,0,0,0]); payload.append(request.dropFirst(8))
        let forwarded = try RFBDesktopResize.decode(width: 1920, height: 1080, reason: 1, status: 4, payload: payload)
        precondition(forwarded.acknowledgement == .forwarded)
        precondition(forwarded.singleScreenID == 0x01020304)
        precondition(forwarded.screens[0].width == 1920)
        for status: UInt16 in [1,2,3] {
            let rejected = try RFBDesktopResize.decode(width: 1920, height: 1080, reason: 1, status: status, payload: payload)
            precondition(rejected.acknowledgement == .rejected(status))
        }
        let announced = try RFBDesktopResize.decode(width: 1920, height: 1080, reason: 0, status: 0, payload: payload)
        precondition(announced.acknowledgement == .announcement)
        let future = try RFBDesktopResize.decode(width: 1920, height: 1080, reason: 9, status: 8, payload: payload)
        precondition(future.acknowledgement == .unknown(reason: 9, status: 8))

        var invalid: [Data] = [Data(), Data([1,0,0]), Data([0,0,0,0]), Data([17,0,0,0]), payload.dropLast(), payload + Data([0])]
        var outOfBounds = payload; outOfBounds[8] = 255; invalid.append(outOfBounds)
        var emptyScreen = payload; emptyScreen[12] = 0; emptyScreen[13] = 0; invalid.append(emptyScreen)
        var duplicate = payload; duplicate[0] = 2; duplicate.append(payload.dropFirst(4)); invalid.append(duplicate)
        for data in invalid {
            do {
                _ = try RFBDesktopResize.decode(width: 1920, height: 1080, reason: 0, status: 0, payload: data)
                fatalError("Malformed layout admitted")
            } catch RFBDesktopResizeError.invalidLayout {}
        }
        for dimensions in [(0,1080),(16385,1080),(16384,16384),(Int.max,Int.max)] {
            do {
                _ = try RFBDesktopResize.decode(width: dimensions.0, height: dimensions.1, reason: 0, status: 0, payload: payload)
                fatalError("Unbounded framebuffer admitted")
            } catch RFBDesktopResizeError.invalidLayout {}
        }
        let maximumPayloadLength = try RFBDesktopResize.payloadLength(header: Data([16,99,23,15]))
        precondition(maximumPayloadLength == 260)
        print("RFB desktop resize wire, forwarding/rejection and bounded layout checks passed.")
    }
}
