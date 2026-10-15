import AppKit

/// A printable symbol is a Windows key location plus actual modifiers. QEMU's
/// classic RFB path discards Shift/AltGr flags from its keysym map, so forwarding
/// just '/', '*' or an ambiguous bracket keysym cannot represent this text.
struct VMKeyboardTextStroke: Equatable {
    let base: UInt32
    let shift: Bool
    let altGr: Bool

    static func resolve(_ event: NSEvent, layout: String) -> Self? {
        guard !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.command),
              let text = event.characters, text.unicodeScalars.count == 1,
              let character = text.unicodeScalars.first else { return nil }
        let table = layout == "it" ? italian : layout == "en-us" ? american : [:]
        return table[character.value]
    }

    private static func shifted(_ base: UInt32) -> Self { Self(base: base, shift: true, altGr: false) }
    private static func plain(_ base: UInt32) -> Self { Self(base: base, shift: false, altGr: false) }
    private static func altGr(_ base: UInt32, shift: Bool = false) -> Self { Self(base: base, shift: shift, altGr: true) }
    // Base keysyms here each identify one QEMU scan code in the selected map.
    // In particular, the XKB 'it' aliases [/@/{ on number/Q keys are not the
    // Windows Italian locations. egrave/plus/ograve/agrave disambiguate them.
    private static let italian: [UInt32: Self] = [
        0x27: plain(0x27), 0x2b: plain(0x2b), 0x2c: plain(0x2c),
        0x2d: plain(0x2d), 0x2e: plain(0x2e), 0x5c: plain(0x5c),
        0x21: shifted(0x31), 0x22: shifted(0x32), 0x24: shifted(0x34),
        0x25: shifted(0x35), 0x26: shifted(0x36), 0x2f: shifted(0x37),
        0x28: shifted(0x38), 0x29: shifted(0x39), 0x3d: shifted(0x30),
        0x3f: shifted(0x27), 0x5e: shifted(0xec), 0x3a: shifted(0x2e),
        0x3b: shifted(0x2c), 0x5f: shifted(0x2d), 0x2a: shifted(0x2b),
        0x7c: shifted(0x5c), 0x5b: altGr(0xe8), 0x5d: altGr(0x2b),
        0x7b: altGr(0xe8, shift: true), 0x7d: altGr(0x2b, shift: true),
        0x40: altGr(0xf2), 0x23: altGr(0xe0)
    ]
    private static let american: [UInt32: Self] = [
        0x27: plain(0x27), 0x2c: plain(0x2c), 0x2d: plain(0x2d),
        0x2e: plain(0x2e), 0x2f: plain(0x2f), 0x3b: plain(0x3b),
        0x3d: plain(0x3d), 0x5b: plain(0x5b), 0x5c: plain(0x5c), 0x5d: plain(0x5d),
        0x21: shifted(0x31), 0x40: shifted(0x32), 0x23: shifted(0x33),
        0x24: shifted(0x34), 0x25: shifted(0x35), 0x5e: shifted(0x36),
        0x26: shifted(0x37), 0x2a: shifted(0x38), 0x28: shifted(0x39),
        0x29: shifted(0x30), 0x5f: shifted(0x2d), 0x2b: shifted(0x3d),
        0x7b: shifted(0x5b), 0x7d: shifted(0x5d), 0x3a: shifted(0x3b),
        0x22: shifted(0x27), 0x7c: shifted(0x5c), 0x3c: shifted(0x2c),
        0x3e: shifted(0x2e), 0x3f: shifted(0x2f)
    ]
}
