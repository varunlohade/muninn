import SwiftUI

struct HomeView: View {
    @EnvironmentObject var session: Session
    @State private var summary: Summary?
    @State private var payments: [Payment] = []
    @State private var error: String?

    var body: some View {
        List {
            VStack(alignment: .leading, spacing: 4) {
                Text("Earned today").font(Theme.Font.secondary).foregroundStyle(Theme.Color.text2)
                Text(money(summary?.earned_today)).font(Theme.Font.numeral).tracking(Theme.Tracking.numeral).foregroundStyle(Theme.Color.text1)
                Text("This week \(money(summary?.earned_this_week)) · \(summary?.unpaid_count ?? 0) unpaid")
                    .font(Theme.Font.secondary).foregroundStyle(Theme.Color.text2)
            }
            .listRowBackground(Theme.Color.bg)

            if let error {
                Text(error).font(Theme.Font.secondary).foregroundStyle(Theme.Color.due).listRowBackground(Theme.Color.bg)
            }

            ForEach(payments) { p in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.client_name ?? p.item).font(Theme.Font.body).foregroundStyle(Theme.Color.text1)
                        Text("\(p.item) · \(p.kind)").font(Theme.Font.secondary).foregroundStyle(Theme.Color.text2)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(p.currency) \(p.amount)").font(Theme.Font.money).foregroundStyle(Theme.Color.text1)
                        Text(p.days_overdue > 0 ? "\(p.days_overdue)d late" : p.state)
                            .font(Theme.Font.secondary)
                            .foregroundStyle(p.state == "paid" ? Theme.Color.paid : Theme.Color.due)
                    }
                }
                .frame(minHeight: Theme.Metric.rowHeight)
                .listRowBackground(Theme.Color.bg)
                .listRowSeparatorTint(Theme.Color.hairline)
            }

            NavigationLink("Keyboard Lab (debug)") { KeyboardLabView() }
                .listRowBackground(Theme.Color.surface1)
            NavigationLink("Keyboard setup") { ScrollView { EnableKeyboardSteps().padding(Theme.Metric.margin) }.background(Theme.Color.bg) }
                .listRowBackground(Theme.Color.surface1)
            Button("Unpair", role: .destructive) { session.unpair() }
                .listRowBackground(Theme.Color.surface1)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle(AppConfig.displayName)
        .refreshable { await load(refresh: true) }
        .task { await load(refresh: false) }
    }

    private func money(_ m: [String: String]?) -> String {
        guard let m, !m.isEmpty else { return "$0" }
        return m.sorted { $0.key < $1.key }.map { "\($0.key == "USD" ? "$" : $0.key + " ")\($0.value)" }.joined(separator: " + ")
    }

    private func load(refresh: Bool) async {
        let api = APIClient.shared()
        do {
            async let s = api.summary()
            async let p = api.payments()
            summary = try await s
            payments = try await p
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
