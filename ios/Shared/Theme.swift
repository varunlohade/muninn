import SwiftUI

/// All colors, type and sizes. The design pass restyles the app from this one file.
/// Tokens follow design/claude/NOTES.md (v1 palette plus the v2 "Muninn" changes).
enum Theme {
    enum Color {
        static let bg = SwiftUI.Color(hex: 0x0C0C0E)
        static let surface1 = SwiftUI.Color(hex: 0x141416)
        static let surface2 = SwiftUI.Color(hex: 0x1A1A1D)
        static let surface3 = SwiftUI.Color(hex: 0x222226)
        static let key = SwiftUI.Color(hex: 0x2A2A2E)
        static let keyFn = SwiftUI.Color(hex: 0x1B1B1E)
        static let keyboardBed = SwiftUI.Color(hex: 0x0F0F11)
        static let hairline = SwiftUI.Color(hex: 0x2A2A2E)
        static let text1 = SwiftUI.Color(hex: 0xF2F2F4)
        static let text2 = SwiftUI.Color(hex: 0x9B9BA3)
        static let text3 = SwiftUI.Color(hex: 0x5F5F67)
        static let cents = SwiftUI.Color(hex: 0x4D4D55)
        static let chip = SwiftUI.Color(hex: 0x202024)
        static let chipPrimary = SwiftUI.Color(hex: 0x2B2B30)
        static let chipPaid = SwiftUI.Color(hex: 0x21352B)
        static let badge = SwiftUI.Color(hex: 0x2A2A2F)
        static let badgeGlyph = SwiftUI.Color(hex: 0xD4D4D9)
        static let paid = SwiftUI.Color(hex: 0x86BFA0)
        static let due = SwiftUI.Color(hex: 0xD8A75E)
        static let paper = SwiftUI.Color(hex: 0xECEAE4)
        static let ink = SwiftUI.Color(hex: 0x1C1C1F)
    }

    /// Geist for UI, Geist Mono for money. Key caps keep SF so they look native.
    enum Font {
        static func geist(_ size: CGFloat, _ weight: String = "Regular") -> SwiftUI.Font { .custom("Geist-\(weight)", size: size) }
        static func mono(_ size: CGFloat) -> SwiftUI.Font { .custom("GeistMono-Medium", size: size) }

        static let wordmark = geist(23, "SemiBold")
        static let numeral = geist(56, "SemiBold").monospacedDigit()
        static let centsNumeral = geist(30, "Medium")
        static let title = geist(21, "Medium")
        static let body = geist(16)
        static let money = mono(16)
        static let chip = geist(15, "SemiBold")
        static let secondary = geist(13)
        static let key = SwiftUI.Font.system(size: 22)
        static let keyFn = SwiftUI.Font.system(size: 15)
    }

    /// The keyboard extension ships no custom fonts, to stay light on memory.
    enum KeyboardFont {
        static let chip = SwiftUI.Font.system(size: 15, weight: .semibold).monospacedDigit()
        static let hint = SwiftUI.Font.system(size: 10, weight: .medium)
        static let secondary = SwiftUI.Font.system(size: 13).monospacedDigit()
    }

    enum Tracking {
        static let wordmark: CGFloat = -0.6
        static let numeral: CGFloat = -2.6
    }

    enum Metric {
        static let margin: CGFloat = 24
        static let rowHeight: CGFloat = 62
        static let chipHeight: CGFloat = 40
        static let keyRadius: CGFloat = 7
        static let keyHeight: CGFloat = 43
        static let keyGap: CGFloat = 6
        static let rowGap: CGFloat = 12
        static let barHeight: CGFloat = 48
        static var keyboardHeight: CGFloat { barHeight + 4 * keyHeight + 3 * rowGap + 16 }
    }

    static let chipAppear = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
