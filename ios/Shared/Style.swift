import SwiftUI

// Shared pieces of the paper look (STYLE.md): card rings, tactile buttons, pills, two-tone text and pixel icons.
// The app and the keyboard both use them.

/// A white card with a hairline ring and a soft drop shadow, instead of a border.
struct CardSurface: ViewModifier {
    var radius: CGFloat = Theme.Metric.radius
    var fill: Color = Theme.Color.card
    var lifted = true
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(fill).shadow(color: .black.opacity(lifted ? (scheme == .dark ? 0.3 : 0.06) : 0), radius: 6, y: 4))
            .overlay(shape.strokeBorder(.white.opacity(scheme == .dark ? 0.04 : 1), lineWidth: 0.8).padding(0.8))
            .overlay(shape.stroke(Theme.Color.edge, lineWidth: 0.8))
    }
}

extension View {
    func cardSurface(radius: CGFloat = Theme.Metric.radius, fill: Color = Theme.Color.card, lifted: Bool = true) -> some View {
        modifier(CardSurface(radius: radius, fill: fill, lifted: lifted))
    }

    /// A row: the surface tone, 8 pt corners, the same ring.
    func rowSurface() -> some View { cardSurface(radius: Theme.Metric.rowRadius, fill: Theme.Color.surface) }
}

/// The three tactile buttons: dark for the main action, light over pictures, quiet for the rest.
struct TactileButton: ButtonStyle {
    enum Kind { case dark, light, quiet }
    var kind: Kind = .dark
    var small = false
    /// Stretch to the full width.
    var wide = true

    func makeBody(configuration: Configuration) -> some View {
        Face(kind: kind, small: small, wide: wide, pressed: configuration.isPressed) { configuration.label }
    }

    private struct Face<Label: View>: View {
        let kind: Kind, small: Bool, wide: Bool, pressed: Bool
        @ViewBuilder let label: Label
        @Environment(\.colorScheme) private var scheme
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let dark = scheme == .dark
            let shape = RoundedRectangle(cornerRadius: small ? 8 : Theme.Metric.buttonRadius, style: .continuous)
            label
                .font(small ? Theme.Font.smallButton : Theme.Font.button)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(kind == .dark ? Theme.Color.darkButtonText : Theme.Color.text1)
                .padding(.horizontal, small ? 12 : 18)
                .frame(maxWidth: wide ? .infinity : nil, minHeight: small ? 32 : Theme.Metric.primaryButton)
                .background {
                    switch kind {
                    case .dark:
                        shape.fill(Theme.Color.darkButton
                            .shadow(.inner(color: .white.opacity(dark ? 0.5 : 0.24), radius: 0, y: 2))
                            .shadow(.inner(color: .black.opacity(0.25), radius: 1, y: -0.5)))
                            .shadow(color: .black.opacity(dark ? 0.4 : 0.16), radius: 2, y: 3)
                    case .light:
                        shape.fill(Theme.Color.lightButton
                            .shadow(.inner(color: .white.opacity(dark ? 0.12 : 0.6), radius: 0.5, y: 1))
                            .shadow(.inner(color: .black.opacity(0.1), radius: 1, y: -1)))
                            .shadow(color: .black.opacity(dark ? 0.4 : 0.15), radius: 4, y: 3)
                    case .quiet:
                        shape.fill(Theme.Color.quietButton
                            .shadow(.inner(color: .white.opacity(dark ? 0.08 : 1), radius: 0.5, y: 2)))
                            .shadow(color: .black.opacity(dark ? 0.3 : 0.04), radius: 4, y: 4)
                    }
                }
                .overlay(shape.stroke(kind == .light ? .white.opacity(dark ? 0.08 : 0.5) : Theme.Color.edge, lineWidth: kind == .light ? 1 : 0.9))
                .opacity(enabled ? 1 : 0.5)
                .scaleEffect(pressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.16), value: pressed)
        }
    }
}

/// A soft status pill in mono type: Paid, Booked, Needs your OK.
struct StatusPill: View {
    enum Tone { case paid, booked, due, neutral }
    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(Theme.Font.pill)
            .foregroundStyle(ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(fill, in: Capsule())
    }

    private var ink: Color {
        switch tone {
        case .paid: Theme.Color.paid
        case .booked: Theme.Color.booked
        case .due: Theme.Color.due
        case .neutral: Theme.Color.text2
        }
    }
    private var fill: Color {
        switch tone {
        case .paid: Theme.Color.paidChip
        case .booked: Theme.Color.bookedChip
        case .due: Theme.Color.dueChip
        case .neutral: Theme.Color.button
        }
    }
}

/// The signature headline: the first clause in ink, the rest in ink 2.
/// `breaks` puts the second clause on its own line.
func twoTone(_ first: String, _ rest: String, ink: Color = Theme.Color.text1, ink2: Color = Theme.Color.text2, breaks: Bool = false) -> Text {
    Text(first).foregroundColor(ink) + Text(rest.isEmpty ? "" : (breaks ? "\n" : " ") + rest).foregroundColor(ink2)
}

/// A task card: an icon tile, a title and a grey sub-line ("Invoice $45 / Sam"). Keyboard chips and previews use it.
struct TaskCardLabel: View {
    let icon: PixelIcon.Name
    var iconFill: Color = .white
    let title: String
    var detail: String? = nil
    var titleColor: Color = Theme.Color.text1
    var height: CGFloat = 42

    var body: some View {
        HStack(spacing: 9) {
            IconTile(icon: icon, fill: iconFill)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.sans(14, 500)).foregroundStyle(titleColor).lineLimit(1)
                if let detail { Text(detail).font(Theme.Font.sans(11.5)).foregroundStyle(Theme.Color.text2).lineLimit(1) }
            }
        }
        .padding(.leading, 6).padding(.trailing, 14)
        .frame(height: height)
        .cardSurface(radius: 10, fill: Theme.Color.surface)
    }
}

/// A 30 pt white tile with a pixel icon, for rows and chips.
struct IconTile: View {
    let icon: PixelIcon.Name
    var fill: Color = .white
    var size: CGFloat = 30

    var body: some View {
        PixelIcon(name: icon, fill: fill, size: size * 0.8)
            .frame(width: size, height: size)
            .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous).strokeBorder(Theme.Color.edge, lineWidth: 1))
    }
}

/// The dotted grid behind boards and the catalog panel.
struct DottedGrid: View {
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            var y: CGFloat = 6
            while y < size.height {
                var x: CGFloat = 6
                while x < size.width { path.addEllipse(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)); x += 12 }
                y += 12
            }
            ctx.fill(path, with: .color(Theme.Color.dots))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 12 x 12 pixel icons, drawn from code grids so they stay crisp at any size. Our own art.
struct PixelIcon: View {
    enum Name: String { case scissors, razor, drop, comb, invoice, bell, link, calendar, note, tag, people, spark, check, chat }
    let name: Name
    var fill: Color = .white
    var size: CGFloat = 24
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = scheme == .dark ? Color(hex: 0xE8E8E3) : Color(hex: 0x2A2A28)
        PixelGrid(rows: Self.grids[name] ?? [], palette: ["#": ink, "o": fill, "w": .white])
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// A picture for a catalog item from words in its name: a haircut gets scissors, color a drop.
    static func forItem(_ name: String) -> Name {
        let n = name.lowercased()
        if ["beard", "shave", "razor", "trim"].contains(where: n.contains) { return .razor }
        if ["color", "colour", "dye", "balayage", "highlight", "paint"].contains(where: n.contains) { return .drop }
        if ["wash", "style", "blow", "comb", "bridal"].contains(where: n.contains) { return .comb }
        if ["cut", "hair", "scissor"].contains(where: n.contains) { return .scissors }
        return .tag
    }

    static func fill(for icon: Name) -> Color {
        switch icon {
        case .drop: Color(hex: 0xE9806E)
        case .razor: Color(hex: 0x9BD2F2)
        case .comb, .tag, .bell: Color(hex: 0xF4D35E)
        default: .white
        }
    }

    static let grids: [Name: [String]] = [
        .scissors: ["............", ".##......##.", "#..#....#..#", "#..#...#..#.", ".##.#.#.##..", "....##.#....", ".....##.....", "....#.##....", "...#...##...", "..#.....##..", ".#.......##.", "............"],
        .razor: ["............", "..########..", "..#oooooo#..", "..########..", ".....##.....", ".....##.....", ".....##.....", "....####....", "....#..#....", "....#..#....", "....####....", "............"],
        .drop: [".....#......", "....#o#.....", "....#o#.....", "...#ooo#....", "...#ooo#....", "..#ooooo#...", "..#oowoo#...", "..#ooooo#...", "..#ooooo#...", "...#ooo#....", "....###.....", "............"],
        .comb: ["............", ".##########.", ".#oooooooo#.", ".##########.", ".#.#.#.#.#..", ".#.#.#.#.#..", ".#.#.#.#.#..", ".#.#.#.#.#..", "............", "............", "............", "............"],
        .invoice: ["..#######...", "..#ooooo##..", "..#o###o#o#.", "..#ooooo####", "..#o####oo#.", "..#oooooo#..", "..#o####o#..", "..#oooooo#..", "..#o##ooo#..", "..#oooooo#..", "..########..", "............"],
        .bell: [".....##.....", "....####....", "...#oooo#...", "...#oooo#...", "..#oooooo#..", "..#oooooo#..", "..#oooooo#..", ".#oooooooo#.", ".##########.", ".....##.....", "............", "............"],
        .link: ["............", "......####..", ".....#oooo#.", "....#oo##o#.", "....#o#..#o#", ".....#.#o#..", "..#o#.#.....", "#o#..#o#....", ".#o##oo#....", ".#oooo#.....", "..####......", "............"],
        .calendar: ["............", "..#....#....", ".##########.", ".#oooooooo#.", ".##########.", ".#oooooooo#.", ".#o#oo#oo#.", ".#oooooooo#.", ".#o#oo#oo#.", ".#oooooooo#.", ".##########.", "............"],
        .note: ["............", ".#########..", ".#ooooooo##.", ".#o#####o#o#", ".#ooooooo###", ".#o#####oo#.", ".#ooooooo#..", ".#o####oo#..", ".#ooooooo#..", ".#ooooooo#..", ".#########..", "............"],
        .tag: ["............", ".######.....", ".#oooo##....", ".#o##ooo#...", ".#o##oooo#..", ".#oooooooo#.", "..#oooooooo#", "...#oooooo#.", "....#oooo#..", ".....#oo#...", "......##....", "............"],
        .people: ["............", "...##..##...", "..#oo##oo#..", "..#oo##oo#..", "...##..##...", "............", ".####.####..", "#oooo#oooo#.", "#oooo#oooo#.", "#oooo#oooo#.", "##########..", "............"],
        .spark: [".....#......", ".....#......", "....#o#.....", "..##ooo##...", "##ooooooo##.", "..##ooo##...", "....#o#.....", ".....#....#.", ".....#...#o#", "..........#.", "............", "............"],
        .check: ["............", "..........##", ".........#o#", "........#o#.", ".##....#o#..", "#oo#..#o#...", ".#oo##o#....", "..#ooo#.....", "...#o#......", "....#.......", "............", "............"],
        .chat: ["............", ".#########..", "#ooooooooo#.", "#o#o#o#oo#.", "#ooooooooo#.", "#ooooooooo#.", ".####oo###..", "....#o#.....", "....##......", "............", "............", "............"],
    ]
}

/// Muninn, the raven, sitting. 14 x 9 art pixels.
struct PixelRaven: View {
    var scale: CGFloat = 2

    var body: some View {
        PixelGrid(rows: Self.rows, palette: ["#": Color(hex: 0x151A2B), "b": Color(hex: 0x2E3D63), "e": Color(hex: 0xF2F2F2),
                                             ">": Color(hex: 0x3A3A3A), "|": Color(hex: 0x1B1B1B)])
            .frame(width: 14 * scale, height: 9 * scale)
            .accessibilityHidden(true)
    }

    static let rows = ["...##.........", "..#e##........", ">>###b#.......", "...#####......", "...##bb###....",
                       "....#bbb####..", ".....########.", "......###..###", "......|.|....."]
}

/// Draws a character grid: one filled square per character found in the palette.
struct PixelGrid: View {
    let rows: [String]
    let palette: [Character: Color]

    var body: some View {
        Canvas { ctx, size in
            let h = CGFloat(rows.count), w = CGFloat(rows.map(\.count).max() ?? 1)
            let cell = min(size.width / w, size.height / h)
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let c = palette[ch] else { continue }
                    ctx.fill(Path(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell + 0.01, height: cell + 0.01)), with: .color(c))
                }
            }
        }
    }
}
