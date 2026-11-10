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

    /// The keyboard copies the iOS 26 system keyboard (measured on the iPhone 17 Pro simulator, 402 pt wide).
    /// Our own look comes later; for now it is a replica, light and dark.
    enum SystemKeyboard {
        struct Palette {
            let bed: SwiftUI.Color, key: SwiftUI.Color, keyPressed: SwiftUI.Color, label: SwiftUI.Color
            let divider: SwiftUI.Color, secondaryLabel: SwiftUI.Color, accent: SwiftUI.Color
        }
        static let light = Palette(bed: SwiftUI.Color(hex: 0xE2E4E7), key: .white, keyPressed: SwiftUI.Color(hex: 0xB9BDC6),
                                   label: .black, divider: SwiftUI.Color(hex: 0xD0D2D7), secondaryLabel: SwiftUI.Color(hex: 0x6E6E73),
                                   accent: SwiftUI.Color(hex: 0x0088FF))
        static let dark = Palette(bed: SwiftUI.Color(hex: 0x171717), key: SwiftUI.Color(hex: 0x3D3D3D), keyPressed: SwiftUI.Color(hex: 0x6A6A6A),
                                  label: .white, divider: SwiftUI.Color(hex: 0x323234), secondaryLabel: SwiftUI.Color(hex: 0x98989D),
                                  accent: SwiftUI.Color(hex: 0x0091FF))

        static let sideInset: CGFloat = 6.5
        static let keyGap: CGFloat = 6
        static let keyHeight: CGFloat = 43
        static let rowGap: CGFloat = 11
        static let barHeight: CGFloat = 51.33
        static let bottomInset: CGFloat = 3.33
        static let cornerRadius: CGFloat = 8.5
        static let wideKey: CGFloat = 45.5      // shift, delete, #+=
        static let modeKey: CGFloat = 43.5      // 123 / ABC
        static let returnKey: CGFloat = 93.2
        static let dividerHeight: CGFloat = 24
        static var height: CGFloat { barHeight + 4 * keyHeight + 3 * rowGap + bottomInset }

        static let letter = SwiftUI.Font.system(size: 22.5, weight: .regular)
        static let symbol = SwiftUI.Font.system(size: 22.5, weight: .regular)
        static let mode = SwiftUI.Font.system(size: 17, weight: .regular)
        static let smallMode = SwiftUI.Font.system(size: 13, weight: .regular)
        static let icon = SwiftUI.Font.system(size: 18, weight: .regular)
        static let callout = SwiftUI.Font.system(size: 40, weight: .regular)
        static let prediction = SwiftUI.Font.system(size: 17, weight: .regular)
        static let predictionSmall = SwiftUI.Font.system(size: 12, weight: .regular)
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
