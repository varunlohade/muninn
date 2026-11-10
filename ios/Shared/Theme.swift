import SwiftUI

/// All colors, type, sizes and motion. Tokens follow design/claude/NOTES.md, v3 section.
enum Theme {
    enum Color {
        static let bg = SwiftUI.Color(hex: 0x0C0C0E)
        static let card = SwiftUI.Color(hex: 0x131315)
        static let edge = SwiftUI.Color.white.opacity(0.06)
        static let chipEdge = SwiftUI.Color.white.opacity(0.09)
        static let button = SwiftUI.Color(hex: 0x1C1C1F)
        static let surface = SwiftUI.Color(hex: 0x141416)
        static let key = SwiftUI.Color(hex: 0x2A2A2E)
        static let keyFn = SwiftUI.Color(hex: 0x1B1B1E)
        static let keyboardBed = SwiftUI.Color(hex: 0x0F0F11)
        static let hairline = SwiftUI.Color(hex: 0x2A2A2E)
        static let text1 = SwiftUI.Color(hex: 0xF2F2F4)
        static let text2 = SwiftUI.Color(hex: 0x9B9BA3)
        static let text3 = SwiftUI.Color(hex: 0x5F5F67)
        static let cents = SwiftUI.Color(hex: 0x55555D)
        static let tick = SwiftUI.Color(hex: 0x2E2E33)
        static let tickPayment = SwiftUI.Color(hex: 0xD9D9DE)
        static let paid = SwiftUI.Color(hex: 0x86BFA0)
        static let paidInk = SwiftUI.Color(hex: 0xB6E0C8)
        static let paidSheet = SwiftUI.Color(hex: 0xB4D2BD)
        static let paidChip = SwiftUI.Color(hex: 0x1D2F25)
        static let paidChipEdge = SwiftUI.Color(red: 160 / 255, green: 214 / 255, blue: 184 / 255).opacity(0.22)
        static let paidChipText = SwiftUI.Color(hex: 0xE6F5EC)
        static let due = SwiftUI.Color(hex: 0xD8A75E)
        static let paper = SwiftUI.Color(hex: 0xECEAE4)
        static let ink = SwiftUI.Color(hex: 0x1C1C1F)
    }

    /// App type: Urbanist 400/500/600. Geist Mono only as printed type on paper.
    enum Font {
        static func urbanist(_ size: CGFloat, _ weight: Int = 500) -> SwiftUI.Font {
            .custom(weight >= 600 ? "Urbanist-SemiBold" : weight >= 500 ? "Urbanist-Medium" : "Urbanist-Regular", size: size)
        }
        static func paper(_ size: CGFloat) -> SwiftUI.Font { .custom("GeistMono-Medium", size: size) }

        static let appName = urbanist(24, 600)
        static let hero = urbanist(44, 400).monospacedDigit()
        static let heroSmall = urbanist(24, 400).monospacedDigit()
        static let title = urbanist(24, 600)
        static let cardTitle = urbanist(16, 600)
        static let body = urbanist(16, 500)
        static let section = urbanist(15, 500)
        static let label = urbanist(13, 500)
        static let axis = urbanist(11.5, 500)
        static let count = urbanist(13, 600)
    }

    /// The keyboard extension ships no custom fonts, to stay light on memory.
    enum KeyboardFont {
        static let chipKey = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let chipValue = SwiftUI.Font.system(size: 15, weight: .medium).monospacedDigit()
        static let chipText = SwiftUI.Font.system(size: 15, weight: .regular)
        static let hint = SwiftUI.Font.system(size: 10, weight: .medium)
        static let secondary = SwiftUI.Font.system(size: 13, weight: .medium).monospacedDigit()
        static let key = SwiftUI.Font.system(size: 22)
        static let keyFn = SwiftUI.Font.system(size: 15)
    }

    enum Tracking {
        static let appName: CGFloat = -0.4
        static let hero: CGFloat = -1.6
        static let heroSmall: CGFloat = -0.6
    }

    enum Metric {
        static let radius: CGFloat = 28
        static let cardInset: CGFloat = 16
        static let cardPadding: CGFloat = 20
        static let margin: CGFloat = 24
        static let iconButton: CGFloat = 44
        static let rowHeight: CGFloat = 58
        static let chipHeight: CGFloat = 40
        static let keyRadius: CGFloat = 7
        static let keyHeight: CGFloat = 43
        static let keyGap: CGFloat = 6
        static let rowGap: CGFloat = 12
        static let barHeight: CGFloat = 52
        static var keyboardHeight: CGFloat { barHeight + 4 * keyHeight + 3 * rowGap + 16 }
    }

    /// Springs from NOTES.md. All motion is interruptible springs on transform and opacity.
    enum Motion {
        static let chipAppear = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)
        static let chipStagger = 0.035
        static let chipFlip = Animation.spring(response: 0.62, dampingFraction: 0.74)
        static let press = Animation.easeOut(duration: 0.1)
        static let folderLift = Animation.spring(response: 0.55, dampingFraction: 0.80)
        static let glassSquash = Animation.spring(response: 0.50, dampingFraction: 0.70)
        static let papersFan = Animation.spring(response: 0.52, dampingFraction: 0.68)
        static let papersStagger = 0.045
        static let rowsIn = Animation.easeOut(duration: 0.35)
        static let ravenPath = Animation.timingCurve(0.77, 0, 0.175, 1, duration: 0.6)
        static let stamp = Animation.spring(response: 0.42, dampingFraction: 0.66)
        static let crossfade = Animation.easeOut(duration: 0.2)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
