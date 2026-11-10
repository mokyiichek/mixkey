import AppKit

/// Colour themes for the choice bar.
struct Theme {
    let id: String
    let name: String
    let backgroundTop: NSColor
    let backgroundBottom: NSColor
    let border: NSColor
    let text: NSColor
    let subtext: NSColor
    /// Fill of the chip for the word that will be typed (or the one you moved to).
    let accent: NSColor
    let accentText: NSColor
    /// Fill of the other chips.
    let chip: NSColor

    static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: a)
    }

    static let all: [Theme] = [
        Theme(id: "ocean", name: "Ocean 海洋",
              backgroundTop: rgb(0xF4F8FF), backgroundBottom: rgb(0xE6EFFF), border: rgb(0xC9DAFB),
              text: rgb(0x1B2A4A), subtext: rgb(0x6A7FA8), accent: rgb(0x2F6BFF), accentText: .white, chip: rgb(0xFFFFFF, 0.85)),
        Theme(id: "sakura", name: "Sakura 樱花",
              backgroundTop: rgb(0xFFF6F8), backgroundBottom: rgb(0xFFE8EE), border: rgb(0xF7C6D3),
              text: rgb(0x4A1F2C), subtext: rgb(0xB0717F), accent: rgb(0xF0507A), accentText: .white, chip: rgb(0xFFFFFF, 0.85)),
        Theme(id: "jade", name: "Jade 翡翠",
              backgroundTop: rgb(0xF2FBF6), backgroundBottom: rgb(0xE0F5EA), border: rgb(0xB9E4CC),
              text: rgb(0x173B2A), subtext: rgb(0x5E8F76), accent: rgb(0x14A06A), accentText: .white, chip: rgb(0xFFFFFF, 0.85)),
        Theme(id: "sunset", name: "Sunset 夕阳",
              backgroundTop: rgb(0xFFF8EF), backgroundBottom: rgb(0xFFEBD6), border: rgb(0xF6D2A8),
              text: rgb(0x4A2E12), subtext: rgb(0xA97B4C), accent: rgb(0xFF7A1A), accentText: .white, chip: rgb(0xFFFFFF, 0.85)),
        Theme(id: "grape", name: "Grape 葡萄",
              backgroundTop: rgb(0xF8F5FF), backgroundBottom: rgb(0xECE5FF), border: rgb(0xD5C8FA),
              text: rgb(0x2B1D52), subtext: rgb(0x7F6DB2), accent: rgb(0x7B4DFF), accentText: .white, chip: rgb(0xFFFFFF, 0.85)),
        Theme(id: "midnight", name: "Midnight 夜空",
              backgroundTop: rgb(0x22263A), backgroundBottom: rgb(0x171A28), border: rgb(0x3A4060),
              text: rgb(0xEDEFFF), subtext: rgb(0x9097BF), accent: rgb(0x6C8CFF), accentText: .white, chip: rgb(0xFFFFFF, 0.08)),
        Theme(id: "mono", name: "Classic 经典",
              backgroundTop: rgb(0xFFFFFF), backgroundBottom: rgb(0xF5F5F7), border: rgb(0xDADADF),
              text: rgb(0x1D1D1F), subtext: rgb(0x86868B), accent: rgb(0x1D1D1F), accentText: .white, chip: rgb(0x000000, 0.04)),
    ]

    static var current: Theme {
        let id = Settings.shared.themeID
        return all.first { $0.id == id } ?? all[0]
    }
}
