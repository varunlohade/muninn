import SwiftUI

/// A white card on paper: 12 pt corners, a hairline ring and a soft shadow.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Metric.cardPadding
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
    }
}

/// A quiet round button with a line icon.
struct IconCircle: View {
    let systemImage: String
    var size: CGFloat = Theme.Metric.iconButton

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.36, weight: .regular))
            .foregroundStyle(Theme.Color.text1)
            .frame(width: size, height: size)
            .background(Circle().fill(Theme.Color.quietButton.shadow(.inner(color: .white.opacity(0.8), radius: 0.5, y: 1.5))))
            .overlay(Circle().stroke(Theme.Color.edge, lineWidth: 0.9))
            .shadow(color: .black.opacity(0.04), radius: 3, y: 3)
    }
}

/// Muninn's mark: the pixel raven on a paper tile.
struct MarkView: View {
    var size: CGFloat = 36

    var body: some View {
        PixelRaven(scale: size / 22)
            .frame(width: size, height: size)
            .cardSurface(radius: size * 0.28, fill: Theme.Color.surface)
            .accessibilityHidden(true)
    }
}

/// The "Muninn" wordmark in the serif.
struct Wordmark: View {
    var size: CGFloat = 30
    var color: Color = Theme.Color.text1

    var body: some View {
        Text(AppConfig.displayName).font(Theme.Font.serif(size)).tracking(Theme.Tracking.appName).foregroundStyle(color)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A section head: the title in ink, a quiet note on the right ("3 people", "Thu, Nov 12").
struct SectionHeader: View {
    let title: String
    var count: Int? = nil
    var note: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Theme.Font.section).foregroundStyle(Theme.Color.text1)
            Spacer()
            if let trailing = note ?? count.map(String.init) {
                Text(trailing).font(Theme.Font.label).monospacedDigit().foregroundStyle(Theme.Color.text2)
            }
        }
        .padding(.horizontal, Theme.Metric.cardInset + 2)
    }
}

/// The pixel sky card: our own procedural scene (exported from build/pixel.js), two-tone words on the sky,
/// and an optional light button.
struct PixelBanner<Action: View>: View {
    let first: String
    let rest: String
    var height: CGFloat = 148
    @ViewBuilder var action: Action

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Metric.radius, style: .continuous)
        ZStack(alignment: .topLeading) {
            GeometryReader { g in
                Image("PixelCard").resizable().interpolation(.none)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: g.size.width, height: g.size.height, alignment: .bottom)
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 0) {
                twoTone(first, rest, ink: .white, ink2: .white.opacity(0.8), breaks: true)
                    .font(Theme.Font.sans(18)).tracking(-0.2).lineSpacing(1)
                    .shadow(color: Color(hex: 0x0B4A94).opacity(0.25), radius: 0, y: 1)
                    .frame(maxWidth: 270, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Space.s)
                action
            }
            .padding(16)
        }
        .frame(height: height)
        .clipShape(shape)
        .overlay(shape.stroke(.black.opacity(0.06), lineWidth: 1))
    }
}

extension PixelBanner where Action == EmptyView {
    init(first: String, rest: String, height: CGFloat = 148) {
        self.init(first: first, rest: rest, height: height) { EmptyView() }
    }
}

/// Numbered rows in one card, split by dashed hairlines: a mono number, then the step.
struct NumberedSteps: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, text in
                if i > 0 { DashedLine() }
                NumberedLine(number: i + 1, text: text).padding(.vertical, Theme.Space.s)
            }
        }
        .padding(.horizontal, Theme.Metric.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

struct NumberedLine: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text("\(number)").font(Theme.Font.mono(12)).foregroundStyle(Theme.Color.text3).frame(width: 14, alignment: .leading)
            Text(text).font(Theme.Font.body).foregroundStyle(Theme.Color.text1).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The dashed hairline inside cards.
struct DashedLine: View {
    var body: some View {
        Line().stroke(Theme.Color.dash, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(height: 1)
    }

    private struct Line: Shape {
        func path(in r: CGRect) -> Path { Path { $0.move(to: CGPoint(x: 0, y: r.midY)); $0.addLine(to: CGPoint(x: r.maxX, y: r.midY)) } }
    }
}

/// Value over label. Cents are dimmed.
struct MoneyValue: View {
    let amount: String
    let currency: String
    var font: Font = Theme.Font.hero
    var tracking: CGFloat = Theme.Tracking.hero
    var showCents = true

    var body: some View {
        let parts = moneyParts(amount, currency)
        (Text(parts.whole).foregroundStyle(Theme.Color.text1)
            + Text(showCents && parts.cents != ".00" ? parts.cents : "").foregroundStyle(Theme.Color.cents))
            .font(font)
            .tracking(tracking)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// One bar: what is paid (green) beside what is still out (amber). An empty week shows an empty track.
struct EarnedBar: View {
    let paid: Double
    let out: Double

    var body: some View {
        GeometryReader { g in
            let total = paid + out
            let gap: CGFloat = paid > 0 && out > 0 ? 2 : 0
            let w = max(0, g.size.width - gap)
            HStack(spacing: gap) {
                if paid > 0 { Theme.Color.barPaid.frame(width: total > 0 ? w * paid / total : 0) }
                if out > 0 { Theme.Color.barOut.frame(maxWidth: .infinity) }
            }
            .frame(width: g.size.width, alignment: .leading)
        }
        .frame(height: 22)
        .background(Theme.Color.button)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityHidden(true)
    }
}

func shortDate(_ iso: String) -> String {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let d = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
    let f = DateFormatter()
    f.dateFormat = "dd.MM.yy"
    return f.string(from: d)
}

func parseDate(_ iso: String) -> Date? {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(configuration.isPressed ? Theme.Motion.press : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
