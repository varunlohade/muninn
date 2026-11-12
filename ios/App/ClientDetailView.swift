import SwiftUI

/// One client: the name and totals on a card, then every invoice and pay link as a row. Rows settle in once.
struct ClientDetailView: View {
    let client: Client
    let papers: [Payment]
    @State private var rowsIn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.cardGap) {
                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        HStack(alignment: .top) {
                            Text(client.displayName).font(Theme.Font.title).tracking(-0.3).foregroundStyle(Theme.Color.text1)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            if mainTotal(client.open_amount) != nil { StatusPill(text: "Owes you", tone: .due) }
                        }
                        DashedLine()
                        HStack(alignment: .top, spacing: Theme.Space.l) {
                            stat("Open", mainTotal(client.open_amount).map { formatMoney($0.amount, $0.currency) } ?? "None")
                            stat("Paid in all", mainTotal(client.total_paid).map { formatMoney($0.amount, $0.currency) } ?? "None")
                            stat("Visits", "\(client.visits)")
                        }
                    }
                }
                .padding(.horizontal, Theme.Metric.cardInset)
                SectionHeader(title: "Invoices and links", note: papers.isEmpty ? nil : "\(papers.count)").padding(.top, Theme.Space.s)
                VStack(spacing: 7) {
                    ForEach(Array(papers.enumerated()), id: \.element.id) { i, p in
                        PaymentRow(payment: p, showClient: false)
                            .padding(.leading, 10).padding(.trailing, 12)
                            .rowSurface()
                            .opacity(rowsIn ? 1 : 0)
                            .offset(y: rowsIn || reduceMotion ? 0 : 6)
                            .animation(reduceMotion ? Theme.Motion.crossfade : Theme.Motion.rowsIn.delay(Double(i) * 0.05), value: rowsIn)
                    }
                    if papers.isEmpty {
                        Text("No invoices yet. Send one from any chat with the keyboard.").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Space.m)
                            .rowSurface()
                    }
                }
                .padding(.horizontal, Theme.Metric.cardInset)
            }
            .padding(.top, Theme.Space.xs)
            .padding(.bottom, Theme.Space.l)
        }
        .background(Theme.Color.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { rowsIn = true }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
            Text(value).font(Theme.Font.sans(17, 500)).monospacedDigit().foregroundStyle(Theme.Color.text1)
        }
    }
}
