import SwiftUI

/// Design tokens from spec §9.
enum Theme {
    static let bg = Color(hex: 0x16161A)
    static let bgDeep = Color(hex: 0x121215)
    static let panel = Color(hex: 0x1E1E23)
    static let surface = Color(hex: 0x212127)
    static let surfaceAlt = Color(hex: 0x26262D)
    static let surfaceHi = Color(hex: 0x2C2C34)
    static let surfaceHiAlt = Color(hex: 0x3A3A44)
    static let line = Color(hex: 0x2E2E36)
    static let text = Color(hex: 0xF3EFE6)
    static let textMuted = Color(hex: 0xA9A6A0)
    static let accent = Color(hex: 0xF5A524)
    static let onAccent = Color(hex: 0x1A1406)
    static let ok = Color(hex: 0x4FC3B5)

    enum SectionColor {
        static let onColor = Color(hex: 0x141416)
        static let intro = Color(hex: 0x7C8CE0)
        static let verse = Color(hex: 0x3FA39A)
        static let chorus = Color(hex: 0xF5A524)
        static let bridge = Color(hex: 0xC86FA8)
        static let solo = Color(hex: 0xE0663F)
        static let outro = Color(hex: 0x8A8F99)
    }

    enum Radius {
        static let control: CGFloat = 12
        static let card: CGFloat = 16
        static let pad: CGFloat = 22
    }

    // Barlow / Barlow Condensed get bundled later (OFL). Until then, the
    // system font at condensed width stands in.
    static func condensed(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }

    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Small uppercase label (Barlow Condensed, 0.14 em tracking in the spec).
struct Eyebrow: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.condensed(13, weight: .bold))
            .tracking(13 * 0.14)
            .foregroundStyle(Theme.textMuted)
    }
}
