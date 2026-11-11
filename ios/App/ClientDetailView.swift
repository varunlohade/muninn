import SwiftUI

/// Folder opens: the glass front squashes, papers fan out, then the invoice list slides in.
struct ClientDetailView: View {
    let client: Client
    let papers: [Payment]
    @State private var open = false
    @State private var fanned: [Bool] = [false, false, false]
    @State private var rowsIn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                FolderView(papers: Array(papers.filter { $0.state == "unpaid" }.prefix(2)) + Array(papers.filter { $0.state == "paid" }.prefix(1)), width: 250, channel: channelIcon(client.channels), openness: open ? 1 : 0, fanned: fanned)
                    .padding(.top, 120)
                    .padding(.bottom, Theme.Space.xl)
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(client.displayName).font(Theme.Font.title).foregroundStyle(Theme.Color.text1)
                    ClientLine(client: client)
                    if let paid = mainTotal(client.total_paid) {
                        Text("\(formatMoney(paid.amount, paid.currency)) paid in all").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Metric.margin)
                .padding(.bottom, Theme.Space.m)
                VStack(spacing: 0) {
                    ForEach(Array(papers.enumerated()), id: \.element.id) { i, p in
                        PaymentRow(payment: p, showClient: false)
                            .opacity(rowsIn ? 1 : 0)
                            .offset(x: rowsIn || reduceMotion ? 0 : 9)
                            .animation(reduceMotion ? Theme.Motion.crossfade : Theme.Motion.rowsIn.delay(Double(i) * 0.07), value: rowsIn)
                    }
                    if papers.isEmpty {
                        Text("No invoices yet").font(Theme.Font.label).foregroundStyle(Theme.Color.text3).padding(.vertical, Theme.Space.l)
                    }
                }
                .padding(.horizontal, Theme.Metric.margin)
            }
            .padding(.bottom, Theme.Space.l)
        }
        .background(Theme.Color.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { await playOpen() }
    }

    private func playOpen() async {
        if reduceMotion {
            withAnimation(Theme.Motion.crossfade) { open = true; fanned = [true, true, true]; rowsIn = true }
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        withAnimation(Theme.Motion.glassSquash) { open = true }
        for i in 0..<3 {
            try? await Task.sleep(for: .seconds(Theme.Motion.papersStagger))
            withAnimation(Theme.Motion.papersFan) { fanned[i] = true }
        }
        try? await Task.sleep(for: .milliseconds(150))
        rowsIn = true
    }
}
