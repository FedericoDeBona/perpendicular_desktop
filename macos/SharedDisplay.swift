import AppKit
import CoreFoundation

/// A confirmed mapping of the primary guest monitor to the primary Mac display.
/// Windows rectangles use a top-left origin; AppKit rectangles use a bottom-left origin.
struct SharedDisplay {
    let pixelScale: CGFloat // Mac points per guest pixel.
    let guestFrame: NSRect
    let hostFrame: NSRect
    let guestWorkArea: NSRect?

    private init(host: HostDisplay, guestFrame: NSRect, guestWorkArea: NSRect?) {
        pixelScale = 1 / host.scale
        self.guestFrame = guestFrame
        hostFrame = host.frame
        self.guestWorkArea = guestWorkArea
    }

    /// Read the actual guest mode and DPI. Backend capabilities alone do not qualify a display.
    static func primary(host: HostDisplay, snapshot: [String: Any]) -> SharedDisplay? {
        guard host.primary, valid(host.frame), host.scale.isFinite, host.scale > 0,
              let displays = snapshot["displays"] as? [[String: Any]],
              !displays.isEmpty, displays.count <= 16 else { return nil }
        let primaryFlags = displays.compactMap { boolean($0["primary"]) }
        guard primaryFlags.count == displays.count,
              primaryFlags.filter({ $0 }).count == 1,
              let index = primaryFlags.firstIndex(of: true) else { return nil }
        let monitor = displays[index]
        guard let frame = rectangle(monitor),
              let dpi = integer(monitor["dpi"]), dpi > 0,
              frame.width == host.frame.width * host.scale,
              frame.height == host.frame.height * host.scale,
              dpi == 96 * host.scale else { return nil }

        var workArea: NSRect?
        if let value = monitor["workArea"] {
            guard let fields = value as? [String: Any], let area = rectangle(fields),
                  frame.contains(area) else { return nil }
            workArea = area
        }
        return SharedDisplay(host: host, guestFrame: frame, guestWorkArea: workArea)
    }

    func macFrame(forGuest frame: NSRect) -> NSRect {
        NSRect(x: hostFrame.minX + (frame.minX - guestFrame.minX) * pixelScale,
               y: hostFrame.maxY - (frame.maxY - guestFrame.minY) * pixelScale,
               width: frame.width * pixelScale, height: frame.height * pixelScale)
    }

    func guestFrame(forMac frame: NSRect) -> NSRect {
        NSRect(x: guestFrame.minX + (frame.minX - hostFrame.minX) / pixelScale,
               y: guestFrame.minY + (hostFrame.maxY - frame.maxY) / pixelScale,
               width: frame.width / pixelScale, height: frame.height / pixelScale)
    }

    private static func rectangle(_ fields: [String: Any]) -> NSRect? {
        guard let x = integer(fields["x"]), let y = integer(fields["y"]),
              let width = integer(fields["width"]), let height = integer(fields["height"]),
              x >= CGFloat(Int32.min), x <= CGFloat(Int32.max),
              y >= CGFloat(Int32.min), y <= CGFloat(Int32.max),
              width > 0, width <= CGFloat(UInt32.max),
              height > 0, height <= CGFloat(UInt32.max) else { return nil }
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private static func integer(_ value: Any?) -> CGFloat? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = CGFloat(number.doubleValue)
        return result.isFinite && result.rounded() == result ? result : nil
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func valid(_ frame: NSRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite &&
        frame.width.isFinite && frame.height.isFinite &&
        frame.width > 0 && frame.height > 0 &&
        frame.maxX.isFinite && frame.maxY.isFinite
    }
}
