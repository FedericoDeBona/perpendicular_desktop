import AppKit

/// An independent AppKit adapter for the negotiated RFB cursor value.
/// All sizes/hotspots are view points; backing scale is handled by NSImage.
@MainActor
struct RFBCursorPresentation {
    let rect: CGRect
    let cursor: NSCursor

    static func make(_ shape: RFBCursor, framebufferSize: CGSize, viewBounds: CGRect) -> Self? {
        let rect = VMDisplayGeometry.fit(source: framebufferSize, destination: viewBounds.size)
            .offsetBy(dx: viewBounds.minX, dy: viewBounds.minY)
        guard !rect.isEmpty else { return nil }
        if shape.isHidden {
            // A transparent local cursor rect, without unbalanced NSCursor.hide calls.
            guard let provider = CGDataProvider(data: Data(repeating: 0, count: 4) as CFData),
                  let pixel = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                      bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
            let image = NSImage(cgImage: pixel, size: NSSize(width: 1, height: 1))
            return Self(rect: rect, cursor: NSCursor(image: image, hotSpot: .zero))
        }
        guard let geometry = try? shape.fittedGeometry(framebufferSize: framebufferSize, viewBounds: viewBounds),
              let provider = CGDataProvider(data: shape.pixelsBGRA as CFData),
              let image = CGImage(width: shape.width, height: shape.height, bitsPerComponent: 8,
                  bitsPerPixel: 32, bytesPerRow: shape.width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                      .union(.byteOrder32Little),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let nativeImage = NSImage(cgImage: image, size: geometry.imageSize)
        return Self(rect: geometry.framebufferRect, cursor: NSCursor(image: nativeImage, hotSpot: geometry.hotspot))
    }
}
