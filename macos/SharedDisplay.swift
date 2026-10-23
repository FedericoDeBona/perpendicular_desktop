import AppKit
import CoreFoundation

/// A confirmed mapping of the primary guest monitor to the primary Mac display.
/// Windows rectangles use a top-left origin; AppKit rectangles use a bottom-left origin.
struct SharedDisplay:Equatable {
    let pixelScale: CGFloat // Mac points per guest pixel.
    let guestFrame: NSRect
    let hostFrame: NSRect
    let guestWorkArea: NSRect?

    private init(host: HostDisplay, guestFrame: NSRect, guestWorkArea: NSRect?) {
        pixelScale = host.workArea.width / guestFrame.width
        self.guestFrame = guestFrame
        hostFrame = host.workArea
        self.guestWorkArea = guestWorkArea
    }

    /// Confirm the requested pixel mode, independently of Windows UI scaling.
    /// DPI controls text/control sizes inside Windows; it does not change the
    /// physical coordinates reported by our per-monitor-aware guest worker.
    static func primary(host: HostDisplay, snapshot: [String: Any]) -> SharedDisplay? {
        guard host.primary, valid(host.workArea),host.frame.contains(host.workArea), host.scale.isFinite, host.scale > 0,
              let displays = snapshot["displays"] as? [[String: Any]],
              !displays.isEmpty, displays.count <= 16 else { return nil }
        let primaryFlags = displays.compactMap { boolean($0["primary"]) }
        guard primaryFlags.count == displays.count,
              primaryFlags.filter({ $0 }).count == 1,
              let index = primaryFlags.firstIndex(of: true) else { return nil }
        let monitor = displays[index]
        guard let frame = rectangle(monitor),
              let dpi = integer(monitor["dpi"]), dpi > 0,
              frame.size == host.guestPixelSize,
              host.workArea.width / frame.width == host.workArea.height / frame.height else { return nil }

        var workArea: NSRect?
        if let value = monitor["workArea"] {
            guard let fields = value as? [String: Any], let area = rectangle(fields),
                  frame.contains(area) else { return nil }
            workArea = area
        }
        let mapping=SharedDisplay(host: host, guestFrame: frame, guestWorkArea: workArea)
        // The entire guest raster already fits inside the Mac's usable area.
        // The remaining work-area inset belongs to the Windows taskbar.
        guard let workArea,host.workArea.contains(mapping.macFrame(forGuest:workArea)) else{return nil}
        return mapping
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
