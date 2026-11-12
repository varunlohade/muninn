import SwiftUI

/// "Who owes you": the total, then one row per client with Copy link and Nudge.
/// Remind only asks: `remind` gets the card's one chip, and the caller shows the confirm.
struct UnpaidListView: View {
    let clients: [UnpaidClient]
    /// The row colour: the surface tone on Home, paper inside the Ask bar.
    var fill = Theme.Color.surface
    let remind: (Chip) -> Void
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("Who owes you").font(Theme.Font.section).foregroundStyle(Theme.Color.text1)
                Spacer()
                Text(WhoPaid.header(clients)).font(Theme.Font.label).monospacedDigit()
                    .foregroundStyle(clients.isEmpty ? Theme.Color.paid : Theme.Color.text2)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityIdentifier("unpaid.header")
            }
            .padding(.horizontal, 2).padding(.bottom, 2)
            ForEach(clients) { c in row(c) }
        }
    }

    private func row(_ c: UnpaidClient) -> some View {
        HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.xs) {
                    Text(c.name).font(Theme.Font.sans(15, 500)).foregroundStyle(Theme.Color.text1).lineLimit(1)
                    if c.veryLate {
                        StatusPill(text: "Very late", tone: .due)
                            .accessibilityIdentifier("unpaid.verylate.\(c.name)")
                    }
                }
                Text("\(c.item), \(c.late.lowercased())").font(Theme.Font.sans(12.5))
                    .foregroundStyle(c.daysLate > 0 ? Theme.Color.due : Theme.Color.text2).lineLimit(1)
            }
            Spacer(minLength: Theme.Space.xxs)
            Text(c.money).font(Theme.Font.sans(15, 500)).monospacedDigit().foregroundStyle(Theme.Color.text1).padding(.trailing, 2)
            if let link = c.link {
                Button {
                    UIPasteboard.general.string = link
                    copied = c.id
                } label: {
                    Image(systemName: copied == c.id ? "checkmark" : "link").font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(QuietButton(small: true, wide: false))
                .accessibilityLabel(copied == c.id ? "Copied" : "Copy link")
                .accessibilityIdentifier("unpaid.copy.\(c.name)")
            }
            if let chip = c.remind {
                Button("Nudge") { remind(chip) }
                    .buttonStyle(QuietButton(small: true, wide: false))
                    .accessibilityIdentifier("unpaid.remind.\(c.name)")
            }
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 8)
        .frame(minHeight: Theme.Metric.rowHeight)
        .cardSurface(radius: Theme.Metric.rowRadius, fill: fill)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("unpaid.card.\(c.name)")
    }
}
