import Foundation
import CoreGraphics

/// RFB Cursor/RichCursor pseudo-encoding for the client's explicitly negotiated
/// 32bpp/depth24 little-endian RGB888 format (shifts R16/G8/B0).
/// Immutable top-row-first BGRA8; alpha comes ONLY from the shape bitmask.
/// This value does not manipulate the host pointer, cursor visibility or UI.
struct RFBCursor: Equatable, Sendable {
    static let encoding: Int32 = -239
    static let maximumDimension = 512
    static let maximumPayloadLength = 1_081_344 // 512*512*4 + 64*512

    let width: Int
    let height: Int
    let hotspotX: Int
    let hotspotY: Int
    let pixelsBGRA: Data
    var isHidden: Bool { width == 0 && height == 0 }

    private init(width: Int, height: Int, hotspotX: Int, hotspotY: Int, pixelsBGRA: Data) {
        self.width = width; self.height = height
        self.hotspotX = hotspotX; self.hotspotY = hotspotY; self.pixelsBGRA = pixelsBGRA
    }

    /// Validate rectangle metadata BEFORE reading/allocating any payload.
    /// A hide update is exactly 0x0 with hotspot (0,0) and no payload. A single
    /// zero dimension, negative/unbounded integer, or off-image hotspot is invalid.
    static func payloadLength(width: Int, height: Int, hotspotX: Int, hotspotY: Int) throws -> Int {
        if width == 0 && height == 0 {
            guard hotspotX == 0, hotspotY == 0 else { throw RFBCursorError.invalidHotspot }
            return 0
        }
        guard (1...maximumDimension).contains(width), (1...maximumDimension).contains(height) else {
            throw RFBCursorError.invalidDimensions
        }
        guard hotspotX >= 0, hotspotY >= 0, hotspotX < width, hotspotY < height else {
            throw RFBCursorError.invalidHotspot
        }
        // Dimensions are bounded before every arithmetic operation below.
        return width * height * 4 + ((width + 7) / 8) * height
    }

    static func decode(width: Int, height: Int, hotspotX: Int, hotspotY: Int, payload: Data) throws -> RFBCursor {
        let length = try payloadLength(width: width, height: height, hotspotX: hotspotX, hotspotY: hotspotY)
        guard payload.count == length else { throw RFBCursorError.invalidPayload }
        if length == 0 { return .init(width: 0, height: 0, hotspotX: 0, hotspotY: 0, pixelsBGRA: Data()) }
        let pixelLength = width * height * 4
        let maskStride = (width + 7) / 8
        var pixels = Data(count: pixelLength) // Transparent pixels stay RGBA zero.
        pixels.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
            payload.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                for y in 0..<height {
                    for x in 0..<width {
                        let mask = source[pixelLength + y * maskStride + x / 8]
                        if mask & (0x80 >> (x & 7)) != 0 {
                            let offset = (y * width + x) * 4
                            destination[offset] = source[offset]
                            destination[offset + 1] = source[offset + 1]
                            destination[offset + 2] = source[offset + 2]
                            destination[offset + 3] = 255 // Wire's unused fourth byte is not alpha.
                        }
                    }
                }
            }
        }
        return .init(width: width, height: height, hotspotX: hotspotX, hotspotY: hotspotY, pixelsBGRA: pixels)
    }

    /// All geometry is in flipped/top-left VIEW POINTS, not backing pixels.
    /// The caller supplies framebuffer pixels and its actual view bounds so
    /// cursor image and hotspot use exactly the same aspect-fit scale. Hidden
    /// updates have no image geometry. No cursor position is inferred here.
    func fittedGeometry(framebufferSize: CGSize, viewBounds: CGRect) throws -> RFBCursorGeometry? {
        guard !isHidden else { return nil }
        let fw = framebufferSize.width, fh = framebufferSize.height
        let vw = viewBounds.size.width, vh = viewBounds.size.height
        let vx = viewBounds.origin.x, vy = viewBounds.origin.y
        guard [fw, fh, vw, vh, vx, vy].allSatisfy(\.isFinite), fw > 0, fh > 0, vw > 0, vh > 0,
              (vx + vw).isFinite, (vy + vh).isFinite else { throw RFBCursorError.invalidGeometry }
        let scale = min(vw / fw, vh / fh)
        let fittedWidth = fw * scale, fittedHeight = fh * scale
        let imageWidth = CGFloat(width) * scale, imageHeight = CGFloat(height) * scale
        let hx = CGFloat(hotspotX) * scale, hy = CGFloat(hotspotY) * scale
        let x = vx + (vw - fittedWidth) / 2, y = vy + (vh - fittedHeight) / 2
        guard [scale, fittedWidth, fittedHeight, imageWidth, imageHeight, hx, hy, x, y].allSatisfy(\.isFinite),
              scale > 0, fittedWidth > 0, fittedHeight > 0, imageWidth > 0, imageHeight > 0,
              (x + fittedWidth).isFinite, (y + fittedHeight).isFinite else { throw RFBCursorError.invalidGeometry }
        return .init(framebufferRect: CGRect(x: x, y: y, width: fittedWidth, height: fittedHeight),
            imageSize: CGSize(width: imageWidth, height: imageHeight), hotspot: CGPoint(x: hx, y: hy),
            pointsPerGuestPixel: scale)
    }
}

enum RFBCursorError: Error, Equatable { case invalidDimensions, invalidHotspot, invalidPayload, invalidGeometry }

struct RFBCursorGeometry: Equatable, Sendable {
    let framebufferRect: CGRect
    let imageSize: CGSize
    let hotspot: CGPoint
    let pointsPerGuestPixel: CGFloat
    fileprivate init(framebufferRect: CGRect, imageSize: CGSize, hotspot: CGPoint, pointsPerGuestPixel: CGFloat) {
        self.framebufferRect = framebufferRect; self.imageSize = imageSize
        self.hotspot = hotspot; self.pointsPerGuestPixel = pointsPerGuestPixel
    }

    /// Local pointer point, supplied by the caller. Letterbox/outside/nonfinite
    /// coordinates produce no cursor image; the image itself is not clipped.
    func imageRect(atViewPoint point: CGPoint) -> CGRect? {
        guard point.x.isFinite, point.y.isFinite, framebufferRect.contains(point) else { return nil }
        let origin = CGPoint(x: point.x - hotspot.x, y: point.y - hotspot.y)
        guard origin.x.isFinite, origin.y.isFinite,
              (origin.x + imageSize.width).isFinite, (origin.y + imageSize.height).isFinite else { return nil }
        return CGRect(origin: origin, size: imageSize)
    }
}
