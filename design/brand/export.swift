// Export the native Icon Composer document, brand board and legacy macOS ICNS.
// Run from the repository root: swift design/brand/export.swift
import AppKit

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let output = root.appendingPathComponent(".build/brand")
try fm.createDirectory(at: output, withIntermediateDirectories: true)
let composerTool = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
for (rendition, filename) in [("Default", "Perpendicular.png"), ("Dark", "Perpendicular-dark.png")] {
    let export = Process()
    export.executableURL = URL(fileURLWithPath: composerTool)
    export.arguments = [root.appendingPathComponent("design/brand/Perpendicular.icon").path,
                        "--export-image", "--output-file", output.appendingPathComponent(filename).path,
                        "--platform", "macOS", "--rendition", rendition,
                        "--width", "1024", "--height", "1024", "--scale", "1", "--design-generation", "27"]
    try export.run()
    export.waitUntilExit()
    guard export.terminationStatus == 0 else { fatalError("Icon Composer export failed: \(rendition)") }
}
let paletteData = try Data(contentsOf: root.appendingPathComponent("design/brand/palette.json"))
let palette = try JSONSerialization.jsonObject(with: paletteData) as! [String: Any]
let colors = palette["colors"] as! [String: String]
func color(_ name: String) -> NSColor {
    let value = UInt32(colors[name]!.dropFirst(), radix: 16)!
    return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                   green: CGFloat((value >> 8) & 255) / 255,
                   blue: CGFloat(value & 255) / 255, alpha: 1)
}
func render(_ width: Int, _ height: Int, _ body: () -> Void) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current!.imageInterpolation = .high
    body()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}
func save(_ bitmap: NSBitmapImageRep, _ name: String) throws {
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}
func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat,
          _ shade: String = "ink", _ weight: NSFont.Weight = .regular) {
    (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color(shade)
    ])
}
let icon = NSImage(contentsOf: output.appendingPathComponent("Perpendicular.png"))!
let dark = NSImage(contentsOf: output.appendingPathComponent("Perpendicular-dark.png"))!
let colorList = NSColorList(name: "Perpendicular — Carbone e cobalto")
for name in colors.keys.sorted() {
    colorList.setColor(color(name), forKey: name)
}
try colorList.write(to: output.appendingPathComponent("Perpendicular.clr"))

// A legacy ICNS needs optical padding; the native .icon document does not.
let iconset = output.appendingPathComponent("Perpendicular.iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = base * scale
        let bitmap = render(size, size) {
            let edge = CGFloat(size) * 0.80
            let margin = (CGFloat(size) - edge) / 2
            icon.draw(in: NSRect(x: margin, y: margin, width: edge, height: edge))
        }
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(base)x\(base)\(suffix).png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("Perpendicular.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }

let board = render(1600, 1040) {
    color("paper").setFill()
    NSRect(x: 0, y: 0, width: 1600, height: 1040).fill()
    text("PERPENDICULAR", 86, 957, 18, "muted", .semibold)
    text("Carbone e cobalto", 86, 886, 48, "ink", .medium)
    text("Due tratti. Un solo segno.", 88, 847, 23, "muted")
    icon.draw(in: NSRect(x: 105, y: 335, width: 445, height: 445))
    dark.draw(in: NSRect(x: 590, y: 440, width: 230, height: 230))
    text("Principale", 266, 290, 19, "muted")
    text("Scura", 675, 402, 19, "muted")
    text("45°", 940, 729, 50, "ink", .light)
    text("Rotazione antioraria", 940, 690, 20, "muted")
    text("Due livelli di vetro.", 940, 612, 27, "ink", .medium)
    text("Cobalto su carbone.", 940, 570, 27, "ink", .medium)
    text("Tratti indipendenti.", 940, 528, 27, "ink", .medium)
    for (index, size) in [32, 64, 96].enumerated() {
        let x = CGFloat(950 + index * 148)
        icon.draw(in: NSRect(x: x, y: 360, width: CGFloat(size), height: CGFloat(size)))
        text("\(size) px", x, 325, 16, "muted")
    }
    let swatches = [("carbon", "Carbone"), ("carbonRaised", "Carbone rialzato"),
                    ("cobalt", "Cobalto"), ("cobaltLight", "Perla cobalto"), ("paper", "Carta")]
    for (index, item) in swatches.enumerated() {
        let x = CGFloat(86 + index * 290)
        color(item.0).setFill()
        let box = NSBezierPath(roundedRect: NSRect(x: x, y: 116, width: 268, height: 103), xRadius: 17, yRadius: 17)
        box.fill()
        color("lineLight").setStroke()
        box.lineWidth = 1
        box.stroke()
        text(item.1, x, 79, 19, "ink", .medium)
        text(colors[item.0]!, x, 50, 16, "muted")
    }
}
try save(board, "Perpendicular-brand-board.png")
print("Created .build/brand/Perpendicular.icns and Perpendicular-brand-board.png")
