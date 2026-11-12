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
        .accessibilityElement(children: .combine)
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
                twoTone(first, rest, ink: .white, ink2: .white.opacity(0.8))
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

/// One tick per slot from 8 AM to now; payments are tall ticks, the newest in green.
struct TickBar: View {
    let payments: [Date]
    var slots = 40

    var body: some View {
        let cal = Calendar.current
        let now = Date()
        let start = cal.date(bySettingHour: 8, minute: 0, second: 0, of: now) ?? now.addingTimeInterval(-8 * 3600)
        let span = max(now.timeIntervalSince(start), 60)
        let slotOf: (Date) -> Int = { d in min(slots - 1, max(0, Int(d.timeIntervalSince(start) / span * Double(slots)))) }
        let hit = Set(payments.map(slotOf))
        let newest = payments.max().map(slotOf)
        VStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(0..<slots, id: \.self) { i in
                    let pay = hit.contains(i)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i == newest ? Theme.Color.paid : pay ? Theme.Color.tickPayment : Theme.Color.tick)
                        .frame(width: pay ? 3 : 1.5, height: pay ? 26 : 9)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 26)
            HStack {
                Text("8 AM")
                Spacer()
                Text("Now")
            }
            .font(Theme.Font.axis)
            .foregroundStyle(Theme.Color.text3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(payments.count) payments today")
    }
}

/// An invoice sheet: real paper with printed mono type. Paid sheets turn green.
struct PaperView: View {
    let payment: Payment
    var width: CGFloat = 150

    var body: some View {
        let paid = payment.state == "paid"
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(paid ? "PAID" : "INVOICE").font(Theme.Font.paper(8)).tracking(1)
                Spacer()
                Text(formatMoney(payment.amount, payment.currency)).font(Theme.Font.paper(10))
            }
            Text("No. \(payment.id.suffix(4))  \(shortDate(payment.created_at))").font(Theme.Font.paper(6.5)).opacity(0.7)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.Color.ink)
        .padding(10)
        .frame(width: width, height: width * 0.62, alignment: .topLeading)
        .background(paid ? Theme.Color.paidSheet : Theme.Color.paper, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if !paid && payment.days_overdue > 0 {
                Rectangle().fill(Theme.Color.due).frame(width: 18, height: 6).offset(x: -24, y: -3)
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

/// The small 17x21 sheet used on rows.
struct MiniSheet: View {
    var paid = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(paid ? Theme.Color.paidSheet : Theme.Color.paper)
            .frame(width: 17, height: 21)
            .overlay(alignment: .top) { Rectangle().fill(paid ? Theme.Color.paid : Theme.Color.due).frame(width: 7, height: 2.5).offset(y: -1) }
            .overlay { VStack(spacing: 2.5) { ForEach(0..<3, id: \.self) { _ in Rectangle().fill(Theme.Color.ink.opacity(0.18)).frame(width: 9, height: 1) } } }
            .frame(width: 24)
    }
}

/// A client is a glass folder with up to 3 papers peeking out.
struct FolderView: View {
    let papers: [Payment]
    var width: CGFloat = 170
    var channel: String? = nil
    /// 0 = closed, 1 = open (front squashes, papers fan).
    var openness: CGFloat = 0
    var fanned: [Bool] = []

    var body: some View {
        let h = width * 0.78
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.Color.button)
                .frame(width: width, height: h * 0.86)
            // Back to front: index 0 (newest unpaid) is drawn last and sits lowest; later sheets peek above it.
            let n = min(papers.count, 3)
            ForEach(Array(papers.prefix(3).enumerated()).reversed(), id: \.element.id) { i, p in
                let fan = i < fanned.count && fanned[i]
                // Spread around the centre: -15° to 12° across however many sheets there are.
                let spread = n > 1 ? Double(i) / Double(n - 1) - 0.5 : 0
                let angle: Double = fan ? spread * 27 - 1.5 : [-2, 1.5, -1][i]
                PaperView(payment: p, width: width * 0.86)
                    .rotationEffect(.degrees(angle), anchor: .bottom)
                    .offset(x: fan ? CGFloat(spread) * width * 0.34 : CGFloat(i) * 6 - 6,
                            y: -h * 0.36 - CGFloat(i) * 14 - (fan ? 44 : 0))
            }
            Glass()
                .frame(width: width, height: h * 0.56)
                .scaleEffect(x: 1, y: 1 - 0.2 * openness, anchor: .bottom)
                .offset(y: 6 * openness)
                .overlay(alignment: .bottomTrailing) {
                    Image("Mark").resizable().frame(width: 18, height: 18).clipShape(Circle()).opacity(0.28).padding(10)
                }
                .overlay(alignment: .bottomLeading) {
                    if let channel {
                        Image(systemName: channel)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Color.text1)
                            .frame(width: 30, height: 30)
                            .background(Theme.Color.button, in: Circle())
                            .overlay(Circle().strokeBorder(Theme.Color.edge, lineWidth: 1))
                            .offset(x: -6, y: 8)
                    }
                }
        }
        .frame(width: width, height: h)
    }
}

/// Frosted folder front: material plus a top highlight and a soft sheen. Glass lives only on folders.
struct Glass: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shadow = colorScheme == .dark ? 1.0 : 0.4
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0.16), .white.opacity(0.22)], startPoint: .top, endPoint: .bottom)))
            .overlay(shape.fill(LinearGradient(stops: [.init(color: .clear, location: 0.2), .init(color: .white.opacity(0.16), location: 0.3), .init(color: .clear, location: 0.42)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(shape.strokeBorder(.white.opacity(0.11), lineWidth: 1))
            .overlay(alignment: .top) { Capsule().fill(.white.opacity(0.5)).frame(height: 1.5).padding(.horizontal, 12) }
            .shadow(color: .black.opacity(0.35 * shadow), radius: 10, y: 8)
            .shadow(color: .black.opacity(0.4 * shadow), radius: 1, y: 1)
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

func channelIcon(_ channels: [String]) -> String {
    if channels.contains("pay_link") { return "link" }
    if channels.contains("paypal") { return "dollarsign" }
    return "bubble.left.fill"
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(configuration.isPressed ? Theme.Motion.press : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
