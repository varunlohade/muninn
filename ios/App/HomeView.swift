import SwiftUI

@MainActor
final class HomeModel: ObservableObject {
    @Published var summary: Summary?
    @Published var brief: [String] = []
    @Published var clients: [Client] = []
    @Published var payments: [Payment] = []
    @Published var paymentTimes: [Date] = []
    @Published var error: String?
    @Published var raven: Payment?

    private let briefKey = "brief_cache"
    private let paidKey = "known_paid_ids"
    /// The brief runs a model call, so one answer serves for 10 minutes.
    static let briefTTL: TimeInterval = 600

    func load() async {
        let api = APIClient.shared()
        async let s = api.summary()
        async let c = api.clients()
        async let p = api.payments()
        async let t = api.transactions(range: "today")
        do {
            summary = try await s
            payments = try await p
            clients = (try? await c) ?? []
            paymentTimes = ((try? await t)?.transactions ?? []).compactMap { parseDate($0.date) }
            error = nil
            checkNewlyPaid()
        } catch {
            self.error = error.localizedDescription
        }
        await loadBrief(api)
    }

    private func loadBrief(_ api: APIClient) async {
        let d = UserDefaults.standard
        if let at = d.object(forKey: briefKey + ".at") as? Date, Date().timeIntervalSince(at) < Self.briefTTL,
           let lines = d.stringArray(forKey: briefKey) {
            brief = lines
            return
        }
        guard let b = try? await api.brief() else { return }
        brief = b.lines
        d.set(b.lines, forKey: briefKey)
        d.set(Date(), forKey: briefKey + ".at")
    }

    /// "The raven returns" plays once for each payment that turned paid since the last look.
    private func checkNewlyPaid() {
        let d = UserDefaults.standard
        let paid = payments.filter { $0.state == "paid" }
        let ids = Set(paid.map(\.id))
        if let known = d.stringArray(forKey: paidKey) {
            raven = paid.first { !Set(known).contains($0.id) }
        }
        d.set(Array(ids), forKey: paidKey)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ravenDemo") { raven = paid.first ?? payments.first }
        #endif
    }

    var unpaid: [Payment] { payments.filter { $0.state == "unpaid" } }

    /// Every invoice and pay link starts in the keyboard, so paid ones are what the keyboard brought back.
    var broughtBack: (money: String, chats: Int)? {
        let paid = payments.filter { $0.state == "paid" }
        guard !paid.isEmpty else { return nil }
        let currency = paid.first?.currency ?? "USD"
        let cents = paid.filter { $0.currency == currency }.reduce(0) { $0 + Int((Double($1.amount) ?? 0) * 100 + 0.5) }
        let chats = Set(paid.map { $0.client_name ?? $0.id }).count
        return (formatMoney(String(format: "%.2f", Double(cents) / 100), currency), chats)
    }

    /// All of a client's payments: unpaid first, newest first.
    func papers(for client: Client) -> [Payment] {
        payments.filter { $0.client_name != nil && $0.client_name == client.name }
            .sorted { a, b in
                let ua = a.state == "unpaid", ub = b.state == "unpaid"
                return ua != ub ? ua : a.created_at > b.created_at
            }
    }

    /// What a folder shows: up to 2 unpaid sheets, then one green sheet if any invoice is paid.
    func folderPapers(for client: Client) -> [Payment] {
        let all = papers(for: client)
        return Array(all.filter { $0.state == "unpaid" }.prefix(2)) + Array(all.filter { $0.state == "paid" }.prefix(1))
    }
}

struct HomeView: View {
    @EnvironmentObject var session: Session
    @StateObject private var model = HomeModel()
    @Namespace private var folders

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                summaryCard
                if !model.brief.isEmpty { briefCard }
                keyboardCard
                if let n = model.summary?.open_disputes, n > 0 { disputesRow(n) }
                if let error = model.error {
                    Text(error).font(Theme.Font.label).foregroundStyle(Theme.Color.due).padding(.horizontal, Theme.Metric.margin)
                }
                clientsShelf
                unpaidList
            }
            .padding(.bottom, 96)
        }
        .scrollIndicators(.hidden)
        .background(Theme.Color.bg.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { AskBar() }
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await model.load() }
        .task { await model.load() }
        .overlay {
            if let p = model.raven {
                RavenReturns(payment: p) { model.raven = nil }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            MarkView(size: 36)
            Text(AppConfig.displayName).font(Theme.Font.appName).tracking(Theme.Tracking.appName).foregroundStyle(Theme.Color.text1)
            Spacer()
            NavigationLink { IntegrationsView() } label: { IconCircle(systemImage: "square.grid.2x2") }
                .accessibilityLabel("Integrations")
                .accessibilityIdentifier("nav.integrations")
        }
        .padding(.leading, Theme.Metric.margin)
        .padding(.trailing, Theme.Metric.cardInset)
        .padding(.top, 8)
    }

    private var summaryCard: some View {
        Card {
            VStack(spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        let today = mainTotal(model.summary?.earned_today) ?? ("0.00", "USD")
                        MoneyValue(amount: today.amount, currency: today.currency)
                        Text("Earned today").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        let week = mainTotal(model.summary?.earned_this_week) ?? ("0.00", "USD")
                        MoneyValue(amount: week.amount, currency: week.currency, font: Theme.Font.heroSmall, tracking: Theme.Tracking.heroSmall, showCents: false)
                            .padding(.top, 18)
                        Text("This week").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                    }
                }
                TickBar(payments: model.paymentTimes)
            }
        }
        .padding(.horizontal, Theme.Metric.cardInset)
    }

    private var briefCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.brief, id: \.self) { line in
                    Text(line).font(Theme.Font.body).foregroundStyle(Theme.Color.text1).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, Theme.Metric.cardInset)
        .accessibilityIdentifier("home.brief")
    }

    private var keyboardCard: some View {
        NavigationLink {
            ScrollView { EnableKeyboardSteps().padding(Theme.Metric.cardInset) }.background(Theme.Color.bg.ignoresSafeArea())
        } label: {
            Card(padding: 14) {
                HStack(spacing: 14) {
                    IconCircle(systemImage: "keyboard")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SharedStore.keyboardLastSeen == nil ? "Turn on the keyboard" : "Keyboard is on")
                            .font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                        if let b = model.broughtBack {
                            (Text("Brought back ") + Text(b.money).foregroundStyle(Theme.Color.paidInk).font(Theme.Font.urbanist(13, 600))
                                + Text(" from \(b.chats) chat\(b.chats == 1 ? "" : "s")"))
                                .font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                        } else {
                            Text("Invoices you send from chats show up here").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                        }
                    }
                    Spacer()
                    IconCircle(systemImage: "chevron.right")
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Metric.cardInset)
    }

    private func disputesRow(_ n: Int) -> some View {
        NavigationLink { DisputesView() } label: {
            Card(padding: 14) {
                HStack {
                    Text("Disputes").font(Theme.Font.body).foregroundStyle(Theme.Color.text1)
                    Spacer()
                    Text("\(n) open").font(Theme.Font.label).foregroundStyle(Theme.Color.due)
                    Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(Theme.Color.text3)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Metric.cardInset)
    }

    private var clientsShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Clients", count: model.clients.count)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(model.clients.prefix(6)) { client in
                        NavigationLink {
                            ClientDetailView(client: client, papers: model.papers(for: client))
                                .zoomTransition(id: client.id, in: folders)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                FolderView(papers: model.folderPapers(for: client), width: 160, channel: channelIcon(client.channels))
                                    .zoomSource(id: client.id, in: folders)
                                    .padding(.top, 34)
                                Text(client.displayName).font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1).padding(.top, 8)
                                ClientLine(client: client)
                            }
                        }
                        .buttonStyle(PressScale())
                        .accessibilityIdentifier("folder.\(client.displayName)")
                    }
                }
                .padding(.horizontal, Theme.Metric.margin)
            }
        }
    }

    private var unpaidList: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Unpaid", count: model.unpaid.count)
            VStack(spacing: 0) {
                ForEach(Array(model.unpaid.prefix(8).enumerated()), id: \.element.id) { i, p in
                    if i > 0 { Rectangle().fill(Theme.Color.hairline).frame(height: 1) }
                    PaymentRow(payment: p)
                }
            }
            .padding(.horizontal, Theme.Metric.margin)
        }
    }
}

struct ClientLine: View {
    let client: Client

    var body: some View {
        if let open = mainTotal(client.open_amount) {
            Text("\(formatMoney(open.amount, open.currency)) open").font(Theme.Font.label).foregroundStyle(Theme.Color.due)
        } else {
            Text("Remembers \(client.visits) visit\(client.visits == 1 ? "" : "s")").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
        }
    }
}

struct PaymentRow: View {
    let payment: Payment
    /// Off inside a client's folder, where the name is already the title.
    var showClient = true

    var body: some View {
        HStack(spacing: 14) {
            MiniSheet(paid: payment.state == "paid")
            VStack(alignment: .leading, spacing: 2) {
                Text(showClient ? payment.client_name ?? payment.item : payment.item).font(Theme.Font.body).foregroundStyle(Theme.Color.text1)
                Text(showClient ? payment.item : shortDate(payment.created_at)).font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                let m = moneyParts(payment.amount, payment.currency)
                Text(m.whole + m.cents).font(Theme.Font.body).monospacedDigit().foregroundStyle(Theme.Color.text1)
                status
            }
        }
        .frame(minHeight: Theme.Metric.rowHeight)
    }

    @ViewBuilder private var status: some View {
        switch payment.state {
        case "paid": Text("Paid").font(Theme.Font.label).foregroundStyle(Theme.Color.paid)
        case "unpaid" where payment.days_overdue > 0:
            Text("\(payment.days_overdue) day\(payment.days_overdue == 1 ? "" : "s") late").font(Theme.Font.label).foregroundStyle(Theme.Color.due)
        case "unpaid": Text("Open").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
        default: Text(payment.state.capitalized).font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
        }
    }
}

/// The prompt pill. There is no chat-command route on the server yet, so it only takes text for now.
struct AskBar: View {
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            TextField("", text: $text, prompt: Text("Ask Muninn to invoice or remind").foregroundStyle(Theme.Color.text3))
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.text1)
                .padding(.leading, 22)
            IconCircle(systemImage: "mic")
        }
        .frame(height: 56)
        .padding(.trailing, 6)
        .background(Theme.Color.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Color.edge, lineWidth: 1))
        .padding(.horizontal, Theme.Metric.cardInset)
        .padding(.bottom, 4)
        .background(LinearGradient(colors: [Theme.Color.bg.opacity(0), Theme.Color.bg], startPoint: .top, endPoint: .center).ignoresSafeArea())
    }
}

extension View {
    /// iOS 18 zoom transition from a folder into the client detail; plain push on iOS 17.
    @ViewBuilder func zoomTransition(id: String, in ns: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) { navigationTransition(.zoom(sourceID: id, in: ns)) } else { self }
    }

    @ViewBuilder func zoomSource(id: String, in ns: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) { matchedTransitionSource(id: id, in: ns) } else { self }
    }
}
