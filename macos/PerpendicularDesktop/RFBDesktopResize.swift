import Foundation

/// RFB ExtendedDesktopSize is a layout announcement or acknowledgement. It
/// never proves that Windows has applied a requested mode. QEMU status 4 means
/// only that the hint was forwarded to a display device.
struct RFBDesktopLayout: Equatable, Sendable {
    struct Screen: Equatable, Sendable {
        let id: UInt32
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let flags: UInt32
    }

    enum Acknowledgement: Equatable, Sendable {
        case announcement
        case forwarded
        case rejected(UInt16)
        case unknown(reason: UInt16, status: UInt16)
    }

    let width: Int
    let height: Int
    let reason: UInt16
    let status: UInt16
    let screens: [Screen]

    var acknowledgement: Acknowledgement {
        if status == 0 && reason <= 2 { return .announcement }
        if reason == 1 && status == 4 { return .forwarded }
        if reason == 1 && (1...3).contains(status) { return .rejected(status) }
        return .unknown(reason: reason, status: status)
    }

    var singleScreenID: UInt32? {
        guard screens.count == 1, let screen = screens.first,
              screen.x == 0, screen.y == 0,
              screen.width == width, screen.height == height else { return nil }
        return screen.id
    }
}

enum RFBDesktopResizeError: Error { case invalidRequest, invalidLayout }

enum RFBDesktopResize {
    static let encoding: Int32 = -308
    static let maximumScreens = 16

    static func request(width: Int, height: Int, screenID: UInt32) throws -> Data {
        guard (640...3840).contains(width), (480...2160).contains(height),
              width * height <= 8_294_400 else { throw RFBDesktopResizeError.invalidRequest }
        // Client message 251: header + exactly one 16-byte screen record.
        var bytes: [UInt8] = [251, 0]
        append16(width, to: &bytes); append16(height, to: &bytes)
        bytes += [1, 0]
        append32(screenID, to: &bytes)
        append16(0, to: &bytes); append16(0, to: &bytes)
        append16(width, to: &bytes); append16(height, to: &bytes)
        append32(0, to: &bytes)
        return Data(bytes)
    }

    static func payloadLength(header: Data) throws -> Int {
        guard header.count == 4 else { throw RFBDesktopResizeError.invalidLayout }
        let count = Int(header[header.startIndex])
        guard (1...maximumScreens).contains(count) else { throw RFBDesktopResizeError.invalidLayout }
        return 4 + count * 16
    }

    static func decode(width: Int, height: Int, reason: UInt16, status: UInt16,
                       payload: Data) throws -> RFBDesktopLayout {
        guard validFramebuffer(width: width, height: height), payload.count >= 4,
              try payloadLength(header: Data(payload.prefix(4))) == payload.count else {
            throw RFBDesktopResizeError.invalidLayout
        }
        let bytes = [UInt8](payload)
        var screens: [RFBDesktopLayout.Screen] = []
        var ids = Set<UInt32>()
        for offset in stride(from: 4, to: bytes.count, by: 16) {
            let id = read32(bytes, offset)
            let x = read16(bytes, offset + 4), y = read16(bytes, offset + 6)
            let w = read16(bytes, offset + 8), h = read16(bytes, offset + 10)
            guard ids.insert(id).inserted, w > 0, h > 0,
                  x <= width, y <= height, w <= width - x, h <= height - y else {
                throw RFBDesktopResizeError.invalidLayout
            }
            screens.append(.init(id: id, x: x, y: y, width: w, height: h,
                                 flags: read32(bytes, offset + 12)))
        }
        return .init(width: width, height: height, reason: reason, status: status, screens: screens)
    }

    private static func validFramebuffer(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= 16384 && height <= 16384 &&
            width <= (128 * 1024 * 1024) / 4 / height
    }

    private static func append16(_ value: Int, to bytes: inout [UInt8]) {
        bytes += [UInt8((value >> 8) & 255), UInt8(value & 255)]
    }
    private static func append32(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes += [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
                  UInt8((value >> 8) & 255), UInt8(value & 255)]
    }
    private static func read16(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }
    private static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 |
            UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}
