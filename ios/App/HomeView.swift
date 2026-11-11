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
    @Published var keyboardOn = false

    /// The keyboard writes a heartbeat to the App Group each time it appears (only possible with Full Access).
    /// Seen within the last 14 days means it is installed and on.
    static let heartbeatWindow: TimeInterval = 14 * 86_400
    func checkKeyboard() {
        keyboardOn = SharedStore.keyboardLastSeen.map { Date().timeIntervalSince($0) < Self.heartbeatWindow } ?? false
    }

    private let briefKey = "brief_cache"
    private let paidKey = "known_paid_ids"
    /// The brief runs a model call, so one answer serves for 10 minutes.
    static let briefTTL: TimeInterval = 600

    func load() async {
        checkKeyboard()
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
            CalendarModel.shared.refresh(clients: clients, payments: payments)
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
    @StateObject private var ask = AskModel()
    @ObservedObject private var calendar = CalendarModel.shared
    @Namespace private var folders

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                // The AI's work comes first: the brief, then who to bill today.
                if !model.brief.isEmpty { briefCard }
                if !calendar.today.isEmpty { todaySection }
                summaryCard
                keyboardCard
                if calendar.status == .notDetermined { calendarCard }
                if let n = model.summary?.open_disputes, n > 0 { disputesRow(n) }
                if let error = model.error {
                    Text(error).font(Theme.Font.label).foregroundStyle(Theme.Color.due).padding(.horizontal, Theme.Metric.margin)
                }
                clientsShelf
                unpaidList
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Theme.Color.bg.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { AskBar(model: ask) }
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await model.load() }
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in model.checkKeyboard(); calendar.refresh() }
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
            NavigationLink { ShortcutsView() } label: { IconCircle(systemImage: "bolt") }
                .accessibilityLabel("Shortcuts")
                .accessibilityIdentifier("nav.shortcuts")
            NavigationLink { NotesView() } label: { IconCircle(systemImage: "note.text") }
                .accessibilityLabel("Notes")
                .accessibilityIdentifier("nav.notes")
            NavigationLink { IntegrationsView() } label: { IconCircle(systemImage: "square.grid.2x2") }
                .accessibilityLabel("Integrations")
                .accessibilityIdentifier("nav.integrations")
        }
        .padding(.leading, Theme.Metric.margin)
        .padding(.trailing, Theme.Metric.cardInset)
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

    /// Today's appointments from the phone calendar. An ended one with no invoice today offers "Bill Sam?".
    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Today", count: calendar.today.count)
            Card(padding: 0) {
                TimelineView(.everyMinute) { now in
                    VStack(spacing: 0) {
                        ForEach(Array(calendar.today.enumerated()), id: \.element.id) { i, a in
                            if i > 0 { Rectangle().fill(Theme.Color.hairline).frame(height: 1).padding(.horizontal, 18) }
                            appointmentRow(a, ended: a.end <= now.date)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Metric.cardInset)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.today")
    }

    private func appointmentRow(_ a: Appointment, ended: Bool) -> some View {
        HStack(spacing: 14) {
            Text(a.time).font(Theme.Font.body).monospacedDigit().foregroundStyle(ended ? Theme.Color.text3 : Theme.Color.text1)
                .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.title).font(Theme.Font.body).foregroundStyle(Theme.Color.text1).lineLimit(1)
                if let name = a.clientName ?? a.clientEmail {
                    Text(name).font(Theme.Font.label).foregroundStyle(Theme.Color.text2).lineLimit(1)
                }
            }
            Spacer()
            if a.clientName != nil || a.clientEmail != nil {
                if a.billed {
                    Text("Billed").font(Theme.Font.label).foregroundStyle(Theme.Color.paid)
                } else if ended {
                    AskChip(title: "Bill \(a.who)?", detail: nil) { ask.prefill(a.invoicePrefix + " $") }
                        .accessibilityIdentifier("today.bill.\(a.who)")
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: Theme.Metric.rowHeight)
    }

    private var keyboardCard: some View {
        NavigationLink {
            ScrollView { EnableKeyboardSteps().padding(Theme.Metric.cardInset) }.background(Theme.Color.bg.ignoresSafeArea())
        } label: {
            Card(padding: 14) {
                HStack(spacing: 14) {
                    IconCircle(systemImage: "keyboard")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.keyboardOn ? "Keyboard is on" : "Turn on the keyboard")
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

    /// Optional, and never a blocking step. It goes away once the owner answers the system prompt.
    private var calendarCard: some View {
        Card(padding: 14) {
            HStack(spacing: 14) {
                IconCircle(systemImage: "calendar")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect Calendar").font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                    Text("See who to bill today").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                }
                Spacer()
                AskChip(title: "Connect", detail: nil) { Task { await calendar.connect() } }
                    .accessibilityIdentifier("home.calendar.connect")
            }
        }
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
                                    .padding(.top, 26)
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

/// The server calls the Ask bar makes: the router, then the same chip actions as the keyboard.
protocol AskAPI: KeyboardAPI {
    func ask(_ text: String) async throws -> AskResponse
}

extension APIClient: AskAPI {}

@MainActor
final class AskModel: ObservableObject {
    enum State: Equatable {
        case idle, loading, chips([Chip]), clients([Client]), confirm(Chip, String), ask(Chip, String), working, result(ActionResult), line(String), error(String)
        /// A money call that may not have run and no lookup found. A tap sends it again with the same key.
        case retry(Chip, String?)
    }
    @Published var text = ""
    @Published var state: State = .idle
    @Published var copied = false
    /// Goes up each time the field must take focus with a prefilled request.
    @Published var focusRequests = 0

    private let api: () -> AskAPI
    private let store: KeyboardStore
    private let now: () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private(set) var task: Task<Void, Never>?

    init(api: @escaping () -> AskAPI = { APIClient.shared() }, store: KeyboardStore = SharedKeyboardStore(), now: @escaping () -> Date = Date.init,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.api = api
        self.store = store
        self.now = now
        self.sleep = sleep
    }

    /// Starts the invoice flow with the client filled in. Nothing is sent until the owner submits.
    func prefill(_ request: String) {
        text = request
        state = .idle
        focusRequests += 1
    }

    /// The typed request goes through /v1/ask. The server picks one function; notes and the calendar stay on the phone.
    func submit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        state = .loading
        task = Task {
            do { show(try await api().ask(t).result) } catch { state = .error(plainLine(error)) }
        }
    }

    private func show(_ result: AskResponse.Result) {
        switch result {
        case .chips(let chips):
            state = chips.isEmpty ? .error("No action for that yet. Try \"invoice Sam $45 for a haircut\".") : .chips(chips)
        case .text(let line), .line(let line):
            state = .line(line)
        case .tone(let t):
            state = .line(t.calm ?? "Sounds fine \u{2713}")
        case .payments(let payments):
            state = .line(KeyboardModel.lateLine(payments))
        case .brief(let lines):
            state = .line(lines.joined(separator: "\n"))
        case .clients(let clients):
            state = clients.isEmpty ? .line("No clients yet") : .clients(clients)
        case .disputes(let disputes):
            let money = disputes.compactMap(\.amount).map { formatMoney($0.value, $0.currency_code) }
            state = .line(disputes.isEmpty ? "No disputes \u{2713}"
                : (["\(disputes.count) dispute\(disputes.count == 1 ? "" : "s")"] + money.prefix(3)).joined(separator: " \u{00B7} "))
        case .addNote(let note):
            store.notes.insert(Note(text: note), at: 0)
            text = ""
            state = .line("Note saved \u{2713}")
        case .showCalendar:
            let today = store.appointments
            state = .line(today.isEmpty ? "Nothing on your calendar today" : today.map { "\($0.time) \($0.who)" }.joined(separator: " \u{00B7} "))
        }
    }

    func run(_ chip: Chip, confirmed: String? = nil) {
        if confirmed == nil, BarItems.asksFirst(chip) {
            state = .confirm(chip, BarItems.recipient(chip))
            return
        }
        state = .working
        // The key belongs to this chip: a second tap on it replays the first call on the server.
        let key = chip.key
        let api = api()
        let sendsMoney = ChipActions.sendsMoney.contains(chip.kind)
        task = Task {
            do {
                let outcome: ChipOutcome
                do {
                    outcome = try await ChipActions.run(chip, confirmed: confirmed, source: text, api: api, key: key, sleep: sleep)
                } catch where sendsMoney && ChipActions.mayHaveRun(error) {
                    // It may have run on the server. Keep the chip and its key, and only look it up.
                    guard let found = try await ChipActions.check(chip, confirmed: confirmed, api: api, key: key, sleep: sleep) else {
                        state = .retry(chip, confirmed)
                        return
                    }
                    outcome = found
                }
                switch outcome {
                case .sent(let r): state = .result(r)
                case .insert(let line), .line(let line): state = .line(line)
                case .ask(let question, let next): state = .ask(next, question)
                }
                text = ""
            } catch APIError.needsConfirm(let r) {
                state = .confirm(chip, r)
            } catch { state = .error(plainLine(error)) }
        }
    }

    func copy(_ link: String) {
        UIPasteboard.general.string = link
        copied = true
    }
}

/// The prompt pill. A typed request goes to the router; money chips are the keyboard's chips and a tap runs the same action.
struct AskBar: View {
    @ObservedObject var model: AskModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                TextField("", text: $model.text, prompt: Text("Ask Muninn anything").foregroundStyle(Theme.Color.text3))
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.text1)
                    .submitLabel(.send)
                    .onSubmit(model.submit)
                    .focused($focused)
                    .onChange(of: model.focusRequests) { focused = true }
                    .padding(.leading, 16)
                    .accessibilityIdentifier("ask.field")
                Button(action: model.submit) { IconCircle(systemImage: model.state == .loading ? "ellipsis" : "arrow.up") }
                    .buttonStyle(PressScale())
                    .accessibilityLabel("Ask")
            }
            content
        }
        .padding(6)
        .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: Theme.Metric.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metric.radius, style: .continuous).strokeBorder(Theme.Color.edge, lineWidth: 1))
        .padding(.horizontal, Theme.Metric.cardInset)
        .padding(.bottom, 4)
        .background(Theme.Color.bg.ignoresSafeArea(edges: .bottom))
        .animation(Theme.Motion.chipAppear, value: model.state)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle, .loading:
            EmptyView()
        case .chips(let chips):
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips) { chip in
                        AskChip(title: BarItems.title(chip), detail: BarItems.detail(chip, fromCopied: false)) { model.run(chip) }
                            .accessibilityIdentifier("ask.chip.\(chip.kind)")
                    }
                }
                .padding(.horizontal, 10)
            }
            .padding(.bottom, 6)
        case .clients(let clients):
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(clients.prefix(8)) { client in
                        AskChip(title: client.displayName, detail: mainTotal(client.open_amount).map { "\(formatMoney($0.amount, $0.currency)) open" }) {
                            model.prefill((["Invoice", client.name, client.email].compactMap { $0 }).joined(separator: " ") + " $")
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .padding(.bottom, 6)
        case .confirm(let chip, let email):
            HStack(spacing: 8) {
                AskChip(title: BarItems.confirmTitle(chip, recipient: email), detail: nil) { model.run(chip, confirmed: email) }
                AskChip(title: "Cancel", detail: nil) { model.state = .idle }
            }
            .padding(.horizontal, 10).padding(.bottom, 6)
        case .ask(let chip, let question):
            HStack(spacing: 8) {
                AskChip(title: question, detail: nil) { model.run(chip) }
                AskChip(title: "Cancel", detail: nil) { model.state = .idle }
            }
            .padding(.horizontal, 10).padding(.bottom, 6)
        case .retry(let chip, let confirmed):
            HStack(spacing: 8) {
                AskChip(title: "It didn't go through. Tap to try again.", detail: nil) { model.run(chip, confirmed: confirmed) }
                    .accessibilityIdentifier("ask.retry")
                AskChip(title: "Cancel", detail: nil) { model.state = .idle }
            }
            .padding(.horizontal, 10).padding(.bottom, 6)
        case .line(let line):
            Text(line).font(Theme.Font.label).foregroundStyle(Theme.Color.text2).padding(.horizontal, 16).padding(.bottom, 8)
                .textSelection(.enabled)
        case .working:
            Text("Creating…").font(Theme.Font.label).foregroundStyle(Theme.Color.text2).padding(.horizontal, 16).padding(.bottom, 8)
        case .result(let r):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "checkmark").foregroundStyle(Theme.Color.paid)
                    Text(r.kind == "invoice" ? "Invoice sent · \(r.money)" : "Pay link ready · \(r.money)").font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                }
                Text(r.link).font(Theme.Font.paper(12)).foregroundStyle(Theme.Color.text2).lineLimit(2).textSelection(.enabled)
                    .accessibilityIdentifier("ask.link")
                HStack(spacing: 8) {
                    Button(model.copied ? "Copied" : "Copy link") { model.copy(r.link) }
                        .buttonStyle(PrimaryButton())
                        .accessibilityIdentifier("ask.copy")
                    Button("Done") { model.state = .idle; model.copied = false }
                        .font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text2).frame(width: 80, height: 48)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ask.result")
        case .error(let e):
            Text(e).font(Theme.Font.label).foregroundStyle(Theme.Color.due).padding(.horizontal, 16).padding(.bottom, 8)
        }
    }
}

struct AskChip: View {
    let title: String
    let detail: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(Theme.Font.urbanist(15, 600)).foregroundStyle(Theme.Color.text1)
                if let detail { Text(detail).font(Theme.Font.urbanist(11, 500)).foregroundStyle(Theme.Color.text3) }
            }
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: Theme.Metric.chipHeight + (detail == nil ? 0 : 6))
            .background(Theme.Color.button, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.Color.chipEdge, lineWidth: 1))
        }
        .buttonStyle(PressScale())
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
