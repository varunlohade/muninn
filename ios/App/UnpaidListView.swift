import SwiftUI

/// "Who hasn't paid": the total, then one card per client with Remind and Copy link.
/// Remind only asks: `remind` gets the card's one chip, and the caller shows the confirm.
struct UnpaidListView: View {
    let clients: [UnpaidClient]
    /// The card colour. The Ask bar is a card itself, so its cards sit one step lighter.
    var fill = Theme.Color.card
    let remind: (Chip) -> Void
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.cardGap) {
            Text(WhoPaid.header(clients)).font(Theme.Font.cardTitle).foregroundStyle(clients.isEmpty ? Theme.Color.paid : Theme.Color.text1)
                .padding(.horizontal, Theme.Space.xs)
                .accessibilityIdentifier("unpaid.header")
            ForEach(clients) { c in card(c) }
        }
    }

    private func card(_ c: UnpaidClient) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top, spacing: Theme.Space.xs) {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(c.name).font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1).lineLimit(1)
                    HStack(spacing: Theme.Space.xs) {
                        Text("\(c.item) \u{00B7} \(c.late)").font(Theme.Font.label)
                            .foregroundStyle(c.daysLate > 0 ? Theme.Color.due : Theme.Color.text2).lineLimit(1)
                        if c.veryLate {
                            Text("Very late").font(Theme.Font.urbanist(11, 600)).foregroundStyle(Theme.Color.bg)
                                .padding(.horizontal, Theme.Space.xs).frame(height: 20)
                                .background(Theme.Color.due, in: Capsule())
                                .accessibilityIdentifier("unpaid.verylate.\(c.name)")
                        }
                    }
                }
                Spacer(minLength: Theme.Space.xs)
                Text(c.money).font(Theme.Font.cardTitle).monospacedDigit().foregroundStyle(Theme.Color.text1)
            }
            HStack(spacing: Theme.Space.xs) {
                if let chip = c.remind {
                    AskChip(title: "Nudge", detail: nil) { remind(chip) }
                        .accessibilityIdentifier("unpaid.remind.\(c.name)")
                }
                if let link = c.link {
                    AskChip(title: copied == c.id ? "Copied" : "Copy link", detail: nil) {
                        UIPasteboard.general.string = link
                        copied = c.id
                    }
                    .accessibilityIdentifier("unpaid.copy.\(c.name)")
                }
            }
        }
        .padding(Theme.Metric.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: Theme.Metric.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metric.radius, style: .continuous).strokeBorder(Theme.Color.edge, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("unpaid.card.\(c.name)")
    }
}
