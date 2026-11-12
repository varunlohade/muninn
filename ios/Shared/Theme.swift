import SwiftUI
import UIKit

/// All colors, type, sizes and motion. Tokens follow the cofounder-style redesign (STYLE.md, 2026-11-12):
/// warm paper, white cards with hairline rings, tactile buttons, two-tone headlines and soft status pills.
enum Theme {
    /// Each token has a light and a dark value and follows the system setting.
    /// Light is the paper palette from STYLE.md. Dark keeps the same warmth on a near-black ground.
    enum Color {
        /// The page: warm paper.
        static let bg = dynamic(light: 0xF5F5F2, dark: 0x111110)
        /// Cards: white on paper.
        static let card = dynamic(light: 0xFFFFFF, dark: 0x1C1C1A)
        /// Rows, chips and catalog items: one step warmer than a card.
        static let surface = dynamic(light: 0xFBFBF8, dark: 0x191917)
        /// The hairline ring that stands in for a border.
        static let edge = dynamic(light: .black.withAlphaComponent(0.08), dark: .white.withAlphaComponent(0.09))
        static let chipEdge = dynamic(light: .black.withAlphaComponent(0.10), dark: .white.withAlphaComponent(0.11))
        /// Plain fills: icon circles, number badges, empty tracks.
        static let button = dynamic(light: 0xEFEFEA, dark: 0x262624)
        static let key = dynamic(light: 0xFFFFFF, dark: 0x2A2A28)
        static let keyFn = dynamic(light: 0xD5D7DC, dark: 0x1B1B1E)
        static let keyboardBed = dynamic(light: 0xE2E4E7, dark: 0x0F0F11)
        static let hairline = dynamic(light: .black.withAlphaComponent(0.08), dark: .white.withAlphaComponent(0.10))
        /// Dashed lines inside cards.
        static let dash = dynamic(light: UIColor(red: 38 / 255, green: 35 / 255, blue: 35 / 255, alpha: 0.16), dark: .white.withAlphaComponent(0.14))
        /// Ink: all primary text.
        static let text1 = dynamic(light: 0x171717, dark: 0xF2F2EF)
        /// Ink 2: the second half of a headline, labels, sub-lines.
        static let text2 = dynamic(light: UIColor(red: 38 / 255, green: 35 / 255, blue: 35 / 255, alpha: 0.62), dark: .white.withAlphaComponent(0.62))
        static let text3 = dynamic(light: UIColor(red: 38 / 255, green: 35 / 255, blue: 35 / 255, alpha: 0.46), dark: .white.withAlphaComponent(0.42))
        static let cents = text3
        static let tick = dynamic(light: 0xE3E3DD, dark: 0x2E2E2B)
        static let tickPayment = dynamic(light: 0x3B3B3A, dark: 0xD9D9D4)
        /// Status: Paid (green), Booked (blue), Needs your OK / late (amber).
        static let paid = dynamic(light: 0x2C7A3A, dark: 0x8FD49A)
        static let paidInk = paid
        static let paidChip = dynamic(light: 0xE0F2DC, dark: 0x1D3322)
        static let paidChipEdge = dynamic(light: UIColor(red: 44 / 255, green: 122 / 255, blue: 58 / 255, alpha: 0.22),
                                          dark: UIColor(red: 143 / 255, green: 212 / 255, blue: 154 / 255, alpha: 0.22))
        static let paidChipText = paid
        static let booked = dynamic(light: 0x1D5FB8, dark: 0x8DB8F0)
        static let bookedChip = dynamic(light: 0xDAE9FB, dark: 0x1B2A40)
        static let due = dynamic(light: 0xA3591A, dark: 0xF0B072)
        static let dueChip = dynamic(light: 0xFBEBD4, dark: 0x3A2A17)
        /// Data bars: paid and still out.
        static let barPaid = dynamic(light: 0xA6E39A, dark: 0x4E8F4A)
        static let barOut = dynamic(light: 0xF7D49B, dark: 0x9A7238)
        static let dotPaid = dynamic(light: 0x7DCB6E, dark: 0x6DB662)
        static let dotOut = dynamic(light: 0xEFB95F, dark: 0xD99E45)
        static let paidSheet = SwiftUI.Color(hex: 0xCDE8C6)
        static let paper = SwiftUI.Color(hex: 0xF4F1EA)
        static let ink = SwiftUI.Color(hex: 0x171717)
        /// The tactile dark button. In dark mode it turns light, so it still stands out.
        static let darkButton = dynamic(light: 0x3B3B3A, dark: 0xEDEDE8)
        static let darkButtonText = dynamic(light: 0xFFFFFF, dark: 0x171717)
        static let lightButton = dynamic(light: 0xF7F7F3, dark: 0x2A2A27)
        static let quietButton = dynamic(light: 0xFBFBF8, dark: 0x22221F)
        /// The dotted grid behind boards and the catalog panel.
        static let dots = dynamic(light: UIColor(red: 38 / 255, green: 35 / 255, blue: 35 / 255, alpha: 0.13), dark: .white.withAlphaComponent(0.10))

        private static func dynamic(light: UInt32, dark: UInt32) -> SwiftUI.Color {
            dynamic(light: UIColor(hex: light), dark: UIColor(hex: dark))
        }
        private static func dynamic(light: UIColor, dark: UIColor) -> SwiftUI.Color {
            SwiftUI.Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
        }
    }

    /// Figtree 400/500/600 for all app type, Newsreader for the wordmark only, IBM Plex Mono for times and pills.
    /// All three are SIL OFL 1.1 and ship in Shared/Fonts.
    enum Font {
        static func sans(_ size: CGFloat, _ weight: Int = 400) -> SwiftUI.Font {
            .custom(weight >= 600 ? "Figtree-SemiBold" : weight >= 500 ? "Figtree-Medium" : "Figtree-Regular", size: size)
        }
        static func mono(_ size: CGFloat) -> SwiftUI.Font { .custom("IBMPlexMono-Regular", size: size) }
        static func serif(_ size: CGFloat) -> SwiftUI.Font { .custom("Newsreader-Regular", size: size) }
        /// Printed type on an invoice sheet.
        static func paper(_ size: CGFloat) -> SwiftUI.Font { mono(size) }

        static let appName = serif(30)
        static let hero = sans(42, 400).monospacedDigit()
        static let heroSmall = sans(24, 400).monospacedDigit()
        /// Big two-tone headlines on onboarding.
        static let headline = sans(31, 400)
        static let title = sans(27, 400)
        static let cardTitle = sans(15, 500)
        static let body = sans(16, 400)
        static let section = sans(17, 500)
        static let label = sans(13, 400)
        static let axis = sans(11.5, 400)
        static let count = sans(13, 500)
        static let pill = mono(11.5)
        static let time = mono(12)
        static let button = sans(16, 500)
        static let smallButton = sans(14, 500)
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
        static let barHeight: CGFloat = 51.33
        static let cornerRadius: CGFloat = 8.5
        static let dividerHeight: CGFloat = 24

        /// Sizes that change with the phone width. Measured against Apple's keyboard in the same text field
        /// (iOS 26.4 simulator, 2026-11-11) at 375, 393, 402 and 440 pt; values between are interpolated.
        struct Sizes {
            let keyHeight: CGFloat, rowGap: CGFloat, bottomInset: CGFloat
            let wideKey: CGFloat      // shift, delete, #+=
            let modeKey: CGFloat      // 123 / ABC, globe
            let returnKey: CGFloat
        }
        static func sizes(for width: CGFloat) -> Sizes {
            func at(_ points: [(CGFloat, CGFloat)]) -> CGFloat {
                guard let first = points.first, let last = points.last else { return 0 }
                if width <= first.0 { return first.1 }
                if width >= last.0 { return last.1 }
                let i = points.firstIndex { $0.0 >= width }!
                let (w0, v0) = points[i - 1], (w1, v1) = points[i]
                return v0 + (v1 - v0) * (width - w0) / (w1 - w0)
            }
            return Sizes(keyHeight: at([(375, 42), (393, 43), (402, 43), (440, 45)]),
                         rowGap: at([(375, 12), (393, 11)]),
                         bottomInset: at([(375, 4.33), (393, 3.33), (402, 3.33), (440, 5)]),
                         wideKey: at([(375, 41.83), (393, 44.16), (402, 45.5), (440, 50.16)]),
                         modeKey: at([(375, 39.83), (402, 43.5), (440, 48.16)]),
                         returnKey: at([(375, 85.83), (402, 93.2), (440, 102.5)]))
        }
        /// This phone, in portrait. The keyboard is always as wide as the screen.
        static let current = sizes(for: UIScreen.main.bounds.width)
        static var keyHeight: CGFloat { current.keyHeight }
        static var rowGap: CGFloat { current.rowGap }
        static var bottomInset: CGFloat { current.bottomInset }
        static var height: CGFloat { barHeight + 4 * keyHeight + 3 * rowGap + bottomInset }
        /// The keyboard while the visual panel is open: the drawing needs more room than the keys.
        static let visualHeight: CGFloat = 470

        static let letter = SwiftUI.Font.system(size: 22.5, weight: .regular)
        static let symbol = SwiftUI.Font.system(size: 22.5, weight: .regular)
        static let mode = SwiftUI.Font.system(size: 17, weight: .regular)
        static let smallMode = SwiftUI.Font.system(size: 13, weight: .regular)
        static let icon = SwiftUI.Font.system(size: 18, weight: .regular)
        static let callout = SwiftUI.Font.system(size: 40, weight: .regular)
        static let prediction = SwiftUI.Font.system(size: 17, weight: .regular)
        static let predictionSmall = SwiftUI.Font.system(size: 12, weight: .regular)
    }

    /// The keys stay the system font. The bar and panels use Figtree, like the app.
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
        static let appName: CGFloat = -0.2
        static let hero: CGFloat = -1
        static let heroSmall: CGFloat = -0.6
    }

    /// Spacing on a 4 pt grid. Use only these steps; one-off offsets only to line up art optically.
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
        static let xxxl: CGFloat = 64
    }

    enum Metric {
        /// Cards 12, buttons 10, rows 8.
        static let radius: CGFloat = 12
        static let buttonRadius: CGFloat = 10
        static let rowRadius: CGFloat = 8
        /// Side gutter for cards: 16 pt, 20 pt on phones 428 pt wide or more.
        static let cardInset: CGFloat = screenWidth >= 428 ? 20 : Space.m
        /// Text outside cards (titles, section headers, plain rows) sits one step in from the cards.
        static let margin: CGFloat = cardInset + Space.xs
        static let cardPadding: CGFloat = Space.m
        /// Gap between cards in a stack, and the extra gap above a new section.
        static let cardGap: CGFloat = Space.s
        static let sectionGap: CGFloat = Space.l
        static let iconButton: CGFloat = 44
        static let rowHeight: CGFloat = 54
        static let chipHeight: CGFloat = 44
        static let primaryButton: CGFloat = 52
        static let secondaryButton: CGFloat = 44
        static let keyRadius: CGFloat = 7
        static let keyHeight: CGFloat = 43
        static let keyGap: CGFloat = 6
        static let rowGap: CGFloat = 12
        static let barHeight: CGFloat = 52
        static var keyboardHeight: CGFloat { barHeight + 4 * keyHeight + 3 * rowGap + 16 }

        private static var screenWidth: CGFloat { UIScreen.main.bounds.width }
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
        static let onboardingStep = Animation.spring(response: 0.42, dampingFraction: 0.82)
        static let onboardingCheckHold: Duration = .milliseconds(520)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
