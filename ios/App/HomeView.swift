import SwiftUI

@MainActor
final class HomeModel: ObservableObject {
    @Published var summary: Summary?
    @Published var brief: [String] = []
    @Published var clients: [Client] = []
    @Published var payments: [Payment] = []
    /// "Who hasn't paid", built once per load: each card keeps its one reminder chip.
    @Published var unpaidClients: [UnpaidClient] = []
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
            unpaidClients = WhoPaid.clients(payments, keeping: unpaidClients)
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

    /// Every invoice and pay link starts in the keyboard, so paid ones are what the keyboard brought back.
    var broughtBack: (money: String, chats: Int)? {
        let paid = payments.filter { $0.state == "paid" }
        guard !paid.isEmpty else { return nil }
        let currency = paid.first?.currency ?? "USD"
        let cents = paid.filter { $0.currency == currency }.reduce(0) { $0 + Int((Double($1.amount) ?? 0) * 100 + 0.5) }
        let chats = Set(paid.map { $0.client_name ?? $0.id }).count
        return (formatMoney(String(format: "%.2f", Double(cents) / 100), currency), chats)
    }

    /// What is still out in the week's main currency: every unpaid invoice and pay link.
    var stillOut: String {
        let currency = mainTotal(summary?.earned_this_week)?.currency ?? "USD"
        let cents = unpaidClients.filter { $0.currency == currency }.reduce(0) { $0 + Int((Double($1.amount) ?? 0) * 100 + 0.5) }
        return String(format: "%.2f", Double(cents) / 100)
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
    @ObservedObject private var keyboard = KeyboardSetup.shared

    var body: some View {
        // The 1 pt strip keeps the scroll view off the top edge, so scrolled cards never run under the clock.
        VStack(spacing: 0) {
        Theme.Color.bg.frame(height: 1)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.cardGap) {
                header
                ConnectPayPalCard()
                earnedCard
                if let error = model.error {
                    Text(error).font(Theme.Font.label).foregroundStyle(Theme.Color.due).padding(.horizontal, Theme.Metric.margin)
                        .fixedSize(horizontal: false, vertical: true)
                }
                unpaidList.padding(.top, Theme.Space.xs)
                if !calendar.today.isEmpty { todaySection }
                // The AI's note on the day, under the numbers it talks about.
                if !model.brief.isEmpty { briefCard }
                if !session.appleLinked {
                    SaveDetailsCard().padding(.horizontal, Theme.Metric.cardInset).padding(.top, Theme.Space.xs)
                } else if let notice = session.notice {
                    Text(notice).font(Theme.Font.label).foregroundStyle(Theme.Color.paid)
                        .padding(.horizontal, Theme.Metric.margin).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("home.saved")
                }
                SectionHeader(title: "Your keyboard").padding(.top, Theme.Space.s)
                keyboardCard
                if calendar.neverAsked { calendarCard }
                if let n = model.summary?.open_disputes, n > 0 { disputesRow(n) }
                if !model.clients.isEmpty { clientsList.padding(.top, Theme.Space.s) }
            }
            .padding(.top, Theme.Space.xxs)
            .padding(.bottom, Theme.Space.l)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) { AskBar(model: ask) }
        }
        .background(Theme.Color.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await model.load(); await PayPalConnector.shared.refresh() }
        // Loads again when the account changes: "Welcome back" brings the earlier account's data.
        .task(id: session.account) { await model.load(); await PayPalConnector.shared.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in calendar.refresh() }
        .overlay {
            if let p = model.raven {
                RavenReturns(payment: p) { model.raven = nil }
            }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.xs) {
            Wordmark(size: 32)
            Spacer()
            NavigationLink { CatalogView() } label: { IconCircle(systemImage: "tag", size: 36) }
                .accessibilityLabel("Catalog")
                .accessibilityIdentifier("nav.catalog")
            NavigationLink { ShortcutsView() } label: { IconCircle(systemImage: "bolt", size: 36) }
                .accessibilityLabel("Shortcuts")
                .accessibilityIdentifier("nav.shortcuts")
            NavigationLink { NotesView() } label: { IconCircle(systemImage: "note.text", size: 36) }
                .accessibilityLabel("Notes")
                .accessibilityIdentifier("nav.notes")
            NavigationLink { IntegrationsView() } label: { IconCircle(systemImage: "gearshape", size: 36) }
                .accessibilityLabel("Settings and integrations")
                .accessibilityIdentifier("nav.integrations")
        }
        .frame(height: 44)
        .padding(.horizontal, Theme.Metric.cardInset + 4)
        .padding(.bottom, Theme.Space.xxs)
    }

    /// Earned this week: the big number, then one bar of what is paid and what is still out.
    private var earnedCard: some View {
        let week = mainTotal(model.summary?.earned_this_week) ?? ("0.00", "USD")
        let today = mainTotal(model.summary?.earned_today)
        let paid = Double(week.amount) ?? 0, out = Double(model.stillOut) ?? 0
        return Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Earned this week").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                        .accessibilityIdentifier("home.earned")
                    Spacer()
                    if let today, (Double(today.amount) ?? 0) > 0 {
                        StatusPill(text: "+\(formatMoney(today.amount, today.currency)) today", tone: .paid)
                            .accessibilityIdentifier("home.today.earned")
                    }
                }
                MoneyValue(amount: week.amount, currency: week.currency, showCents: false)
                    .padding(.top, Theme.Space.xs).padding(.bottom, Theme.Space.s)
                EarnedBar(paid: paid, out: out)
                HStack(spacing: Theme.Space.m) {
                    legend(Theme.Color.dotPaid, "Paid", formatMoney(week.amount, week.currency))
                    legend(Theme.Color.dotOut, "Still out", formatMoney(model.stillOut, week.currency))
                }
                .padding(.top, 9)
            }
        }
        .padding(.horizontal, Theme.Metric.cardInset)

    }

    private func legend(_ color: Color, _ label: String, _ money: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            (Text(label + " ").foregroundStyle(Theme.Color.text2) + Text(money).foregroundStyle(Theme.Color.text1).font(Theme.Font.sans(12, 500)))
                .font(Theme.Font.sans(12)).monospacedDigit()
        }
    }

    private var briefCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.xs) {
                    PixelRaven(scale: 1.4)
                    Text("Muninn noticed").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                }
                ForEach(model.brief, id: \.self) { line in
                    Text(line).font(Theme.Font.body).foregroundStyle(Theme.Color.text1).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, Theme.Metric.cardInset)
        .padding(.top, Theme.Space.xs)
        .accessibilityIdentifier("home.brief")
    }

    /// Today's appointments from the phone calendar. An ended one with no invoice today offers "Invoice".
    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeader(title: "Today", note: Date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .padding(.bottom, 2)
            TimelineView(.everyMinute) { now in
                VStack(spacing: 7) {
                    ForEach(calendar.today) { a in
                        appointmentRow(a, ended: a.end <= now.date)
                    }
                }
            }
            .padding(.horizontal, Theme.Metric.cardInset)
        }
        .padding(.top, Theme.Space.s)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.today")
    }

    private func appointmentRow(_ a: Appointment, ended: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(a.time).font(Theme.Font.time).monospacedDigit().foregroundStyle(Theme.Color.text3)
                .frame(width: 40, alignment: .leading)
            (Text(a.clientName ?? a.clientEmail ?? a.title).foregroundStyle(Theme.Color.text1).font(Theme.Font.sans(15, 500))
                + Text(a.clientName != nil || a.clientEmail != nil ? " " + Self.what(a) : "").foregroundStyle(Theme.Color.text2).font(Theme.Font.sans(14)))
                .lineLimit(1)
            Spacer(minLength: Theme.Space.xs)
            if a.clientName != nil || a.clientEmail != nil {
                if a.billed {
                    StatusPill(text: "Billed", tone: .paid)
                } else if ended {
                    Button("Invoice") { ask.prefill(a.invoicePrefix + " $") }
                        .buttonStyle(QuietButton(small: true, wide: false))
                        .accessibilityIdentifier("today.bill.\(a.who)")
                } else {
                    StatusPill(text: "Booked", tone: .booked)
                }
            } else if !ended {
                StatusPill(text: "Booked", tone: .booked)
            }
        }
        .padding(.leading, 14).padding(.trailing, 10)
        .frame(minHeight: Theme.Metric.rowHeight)
        .rowSurface()
    }

    /// The event title without the client's name: "Color - Ava Chen" reads "Color" beside "Ava Chen".
    static func what(_ a: Appointment) -> String {
        guard let name = a.clientName, a.title.localizedCaseInsensitiveContains(name) else { return a.title }
        let rest = a.title.replacingOccurrences(of: name, with: "", options: .caseInsensitive)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -\u{2013}\u{2014}:,\u{00B7}"))
        return rest.isEmpty ? a.title : rest
    }

    private var keyboardCard: some View {
        NavigationLink {
            ScrollView { EnableKeyboardSteps().padding(Theme.Metric.cardInset) }
                .background(Theme.Color.bg.ignoresSafeArea())
                .navigationTitle("Keyboard setup")
        } label: {
            HStack(spacing: Theme.Space.s) {
                IconTile(icon: .chat)
                VStack(alignment: .leading, spacing: 2) {
                    Text(keyboard.state.homeTitle)
                        .font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                    Group {
                        if keyboard.state == .needsFullAccess {
                            Text(KeyboardState.finishSetupLine)
                        } else if keyboard.state == .notFirst {
                            Text("Drag it to the top in Settings")
                        } else if !keyboard.state.isOn {
                            Text("Make it your default keyboard")
                        } else if let b = model.broughtBack {
                            Text("Brought back ") + Text(b.money).foregroundStyle(Theme.Color.paid).font(Theme.Font.sans(13, 500))
                                + Text(" from \(b.chats) chat\(b.chats == 1 ? "" : "s")")
                        } else {
                            Text("Invoices you send from chats show up here")
                        }
                    }
                    .font(Theme.Font.label).foregroundStyle(Theme.Color.text2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Color.text3)
            }
            .padding(.leading, 10).padding(.trailing, 14).padding(.vertical, 10)
            .frame(minHeight: Theme.Metric.rowHeight)
            .rowSurface()
        }
        .buttonStyle(PressScale())
        .padding(.horizontal, Theme.Metric.cardInset)
        .accessibilityIdentifier("home.keyboard")
    }

    /// Optional, and never a blocking step. It goes away once the owner answers the system prompt.
    private var calendarCard: some View {
        HStack(spacing: Theme.Space.s) {
            IconTile(icon: .calendar, fill: Color(hex: 0xDAE9FB))
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect Calendar").font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                Text("Who to bill, and events from the keyboard").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Connect") { Task { await calendar.connect() } }
                .buttonStyle(QuietButton(small: true, wide: false))
                .accessibilityIdentifier("home.calendar.connect")
        }
        .padding(.leading, 10).padding(.trailing, 10).padding(.vertical, 10)
        .rowSurface()
        .padding(.horizontal, Theme.Metric.cardInset)
    }

    private func disputesRow(_ n: Int) -> some View {
        NavigationLink { DisputesView() } label: {
            HStack(spacing: Theme.Space.s) {
                IconTile(icon: .bell, fill: Color(hex: 0xFBEBD4))
                Text("Disputes").font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                Spacer()
                StatusPill(text: "\(n) open", tone: .due)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Color.text3)
            }
            .padding(.leading, 10).padding(.trailing, 14)
            .frame(minHeight: Theme.Metric.rowHeight)
            .rowSurface()
        }
        .buttonStyle(PressScale())
        .padding(.horizontal, Theme.Metric.cardInset)
        .accessibilityIdentifier("home.disputes")
    }

    /// Clients as numbered rows: name, what is open or how many visits, and the way in to their invoices.
    private var clientsList: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeader(title: "Clients", note: "\(model.clients.count)").padding(.bottom, 2)
            ForEach(Array(model.clients.prefix(6).enumerated()), id: \.element.id) { i, client in
                NavigationLink {
                    ClientDetailView(client: client, papers: model.papers(for: client))
                } label: {
                    HStack(spacing: Theme.Space.s) {
                        Text(String(format: "1.%d", i + 1)).font(Theme.Font.mono(11)).foregroundStyle(Theme.Color.text3).frame(width: 24, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(client.displayName).font(Theme.Font.sans(15, 500)).foregroundStyle(Theme.Color.text1).lineLimit(1)
                            ClientLine(client: client)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Color.text3)
                    }
                    .padding(.leading, 14).padding(.trailing, 14)
                    .frame(minHeight: Theme.Metric.rowHeight)
                    .rowSurface()
                }
                .buttonStyle(PressScale())
                .accessibilityIdentifier("folder.\(client.displayName)")
            }
            .padding(.horizontal, Theme.Metric.cardInset)
        }
    }

    private var unpaidList: some View {
        // Nudge asks in the Ask bar below: the same confirm and the same call as a reminder chip.
        UnpaidListView(clients: Array(model.unpaidClients.prefix(8))) { ask.run($0) }
            .padding(.horizontal, Theme.Metric.cardInset)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.unpaid")
    }
}

struct ClientLine: View {
    let client: Client

    var body: some View {
        if let open = mainTotal(client.open_amount) {
            Text("\(formatMoney(open.amount, open.currency)) open").font(Theme.Font.label).foregroundStyle(Theme.Color.due).lineLimit(1)
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
        HStack(spacing: Theme.Space.s) {
            IconTile(icon: payment.kind == "invoice" ? .invoice : .link, fill: payment.state == "paid" ? Color(hex: 0xE0F2DC) : .white)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(showClient ? payment.client_name ?? payment.item : payment.item).font(Theme.Font.sans(15, 500)).foregroundStyle(Theme.Color.text1)
                Text(showClient ? payment.item : shortDate(payment.created_at)).font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: Theme.Space.xxs) {
                let m = moneyParts(payment.amount, payment.currency)
                Text(m.whole + m.cents).font(Theme.Font.sans(15, 500)).monospacedDigit().foregroundStyle(Theme.Color.text1)
                status
            }
        }
        .frame(minHeight: Theme.Metric.rowHeight)
    }

    @ViewBuilder private var status: some View {
        switch payment.state {
        case "paid": StatusPill(text: "Paid", tone: .paid)
        case "unpaid" where payment.days_overdue > 0:
            StatusPill(text: "\(payment.days_overdue) day\(payment.days_overdue == 1 ? "" : "s") late", tone: .due)
        case "unpaid": StatusPill(text: "Open", tone: .booked)
        default: StatusPill(text: payment.state.capitalized)
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
        case idle, loading, chips([Chip]), clients([Client]), lookup(LookupResult), unpaid([UnpaidClient]), review(String), confirm(Chip, String), ask(Chip, String), working, result(ActionResult), line(String), error(String)
        /// A money call that may not have run and no lookup found. A tap sends it again with the same key.
        case retry(Chip, String?)
        /// Done, and PayPal can undo it: "Paused ✓" with Undo.
        case undoable(String, Chip)
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
            state = chips.isEmpty ? .line(AskModel.hint) : .chips(chips)
        case .text(let line), .line(let line):
            state = .line(line)
        case .tone(let t):
            state = .line(t.calm ?? "Sounds fine \u{2713}")
        case .review(let message):
            state = .review(message)
        case .payments(let payments):
            state = .unpaid(WhoPaid.clients(payments))
        case .brief(let lines):
            state = .line(lines.joined(separator: "\n"))
        case .clients(let clients):
            state = clients.isEmpty ? .line("No clients yet") : .clients(clients)
        case .lookup(let found):
            state = .lookup(found)
        case .disputes(let disputes):
            let money = disputes.compactMap(\.amount).map { formatMoney($0.value, $0.currency_code) }
            // The answers live on the Disputes page: Reply, Offer, Accept.
            state = .line(disputes.isEmpty ? "No disputes \u{2713}"
                : (["\(disputes.count) open"] + money.prefix(3)).joined(separator: " \u{00B7} ") + ". Answer in Disputes on Home.")
        case .addNote(let note):
            store.notes.insert(Note(text: note), at: 0)
            text = ""
            state = .line("Note saved \u{2713}")
        case .showCalendar:
            let today = store.appointments
            state = .line(today.isEmpty ? "Nothing on your calendar today" : today.map { "\($0.time) \($0.who)" }.joined(separator: " \u{00B7} "))
        }
    }

    /// The owner picked a client's email from Contacts for an invoice that had none.
    /// It is a new chip, and it goes back to the confirm: the email is shown before anything is sent.
    func useContact(email: String, name: String?, for chip: Chip) {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard chip.kind == "invoice", email.contains("@") else { return }
        var payload = chip.payload
        payload["client_email"] = .string(email)
        if BarItems.string(chip, "client_name") == nil, let name, !name.isEmpty { payload["client_name"] = .string(name) }
        state = .confirm(Chip(kind: chip.kind, label: chip.label, payload: payload, needs_confirm: true), email)
    }

    /// An invoice with no email only makes a link. The confirm then offers Contacts.
    static func canAddContact(_ chip: Chip) -> Bool {
        chip.kind == "invoice" && BarItems.string(chip, "client_email") == nil
    }

    private func showUnpaid() {
        state = .loading
        let api = api()
        task = Task {
            do { state = .unpaid(WhoPaid.clients(try await api.payments())) } catch { state = .error(plainLine(error)) }
        }
    }

    func run(_ chip: Chip, confirmed: String? = nil) {
        if chip.kind == "payments" { return showUnpaid() }
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
                case .undoable(let line, let undo): state = .undoable(line, undo)
                }
                text = ""
            } catch APIError.needsConfirm(let r) {
                state = .confirm(chip, r)
            } catch { state = .error(plainLine(error)) }
        }
    }

    /// The neutral line when no action fits: every verb, not only invoices.
    static let hint = "Try: invoice Sam $45 \u{00B7} nudge Ana \u{00B7} refund Sam $20 \u{00B7} who owes me"

    static func resultTitle(_ r: ActionResult) -> String {
        switch r.kind {
        case "invoice": r.emailed ? "Invoice emailed \u{00B7} \(r.money)" : "Invoice link ready \u{00B7} \(r.money)"
        case "subscribe": "Repeat billing ready \u{00B7} \(r.money)"
        default: "Pay link ready \u{00B7} \(r.money)"
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
    /// The most height the "Who hasn't paid" list takes before it scrolls.
    var listHeight: CGFloat = 280
    @FocusState private var focused: Bool
    /// The invoice chip that waits for an email from Contacts.
    @State private var pickingFor: Chip?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.xs) {
                TextField("", text: $model.text, prompt: Text("Ask \(AppConfig.displayName) anything").foregroundStyle(Theme.Color.text3))
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.text1)
                    .submitLabel(.send)
                    .onSubmit(model.submit)
                    .focused($focused)
                    .onChange(of: model.focusRequests) { focused = true }
                    .padding(.leading, Theme.Space.m)
                    .accessibilityIdentifier("ask.field")
                Button(action: model.submit) {
                    Image(systemName: model.state == .loading ? "ellipsis" : "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(TactileButton(kind: .dark, small: true, wide: false))
                .frame(width: 40)
                    .accessibilityLabel("Ask")
            }
            content
        }
        .padding(6)
        .cardSurface()
        .padding(.horizontal, Theme.Metric.cardInset)
        .padding(.top, Theme.Space.xs)
        .padding(.bottom, Theme.Space.xs)
        .background(Theme.Color.bg.ignoresSafeArea(edges: .bottom))
        // Content scrolls under the bar; a short fade shows it goes on instead of a hard cut.
        .background(alignment: .top) {
            LinearGradient(colors: [Theme.Color.bg.opacity(0), Theme.Color.bg], startPoint: .top, endPoint: .bottom)
                .frame(height: Theme.Space.l).offset(y: -Theme.Space.l).allowsHitTesting(false)
        }
        .animation(Theme.Motion.chipAppear, value: model.state)
        .sheet(item: $pickingFor) { chip in
            ContactEmailPicker { email, name in model.useContact(email: email, name: name, for: chip) }.ignoresSafeArea()
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle, .loading:
            EmptyView()
        case .chips(let chips):
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.xs) {
                    ForEach(chips) { chip in
                        AskChip(title: BarItems.title(chip), detail: BarItems.detail(chip, fromCopied: false)) { model.run(chip) }
                            .accessibilityIdentifier("ask.chip.\(chip.kind)")
                    }
                }
                .padding(.horizontal, Theme.Space.xs)
            }
            .padding(.bottom, Theme.Space.xxs)
        case .clients(let clients):
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.xs) {
                    ForEach(clients.prefix(8)) { client in
                        AskChip(title: client.displayName, detail: mainTotal(client.open_amount).map { "\(formatMoney($0.amount, $0.currency)) open" }) {
                            model.prefill((["Invoice", client.name, client.email].compactMap { $0 }).joined(separator: " ") + " $")
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.xs)
            }
            .padding(.bottom, Theme.Space.xxs)
        case .lookup(let found):
            // The keyboard's lookup card: Copy instead of Insert; Remind and New invoice go through the usual confirm.
            LookupCard(result: found, palette: LookupCard.appPalette, insertWord: "Copy", onInsert: { model.copy($0.line) },
                       onRemind: { model.run($0) }, onNewInvoice: { model.prefill(LookupCopy.newInvoiceRequest($0)) },
                       onClose: { model.state = .idle; model.copied = false })
                .padding(.bottom, Theme.Space.xxs)
        case .unpaid(let clients):
            ScrollView {
                UnpaidListView(clients: clients, fill: Theme.Color.bg) { model.run($0) }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: listHeight)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Space.xs).padding(.bottom, Theme.Space.xs)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ask.unpaid")
        case .review(let message):
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(message).font(Theme.Font.body).foregroundStyle(Theme.Color.text1).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("ask.review")
                HStack(spacing: Theme.Space.xs) {
                    AskChip(title: model.copied ? "Copied" : "Copy", detail: nil) { model.copy(message) }
                        .accessibilityIdentifier("ask.review.copy")
                    AskChip(title: "Done", detail: nil) { model.state = .idle; model.copied = false }
                }
            }
            .padding(.horizontal, Theme.Space.xs).padding(.bottom, Theme.Space.xxs)
        case .confirm(let chip, let email):
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.xs) {
                    AskChip(title: BarItems.confirmTitle(chip, recipient: email), detail: nil) { model.run(chip, confirmed: email) }
                        .accessibilityIdentifier("ask.confirm")
                    if AskModel.canAddContact(chip) {
                        AskChip(title: "Add email from Contacts", detail: nil) { pickingFor = chip }
                            .accessibilityIdentifier("ask.contacts")
                    }
                    AskChip(title: "Cancel", detail: nil) { model.state = .idle }
                }
                .padding(.horizontal, Theme.Space.xs)
            }
            .padding(.bottom, Theme.Space.xxs)
        case .ask(let chip, let question):
            HStack(spacing: Theme.Space.xs) {
                AskChip(title: question, detail: nil) { model.run(chip) }
                AskChip(title: "Cancel", detail: nil) { model.state = .idle }
            }
            .padding(.horizontal, Theme.Space.xs).padding(.bottom, Theme.Space.xxs)
        case .retry(let chip, let confirmed):
            HStack(spacing: Theme.Space.xs) {
                AskChip(title: "It didn't go through. Tap to try again.", detail: nil) { model.run(chip, confirmed: confirmed) }
                    .accessibilityIdentifier("ask.retry")
                AskChip(title: "Cancel", detail: nil) { model.state = .idle }
            }
            .padding(.horizontal, Theme.Space.xs).padding(.bottom, Theme.Space.xxs)
        case .line(let line):
            Text(line).font(Theme.Font.label).foregroundStyle(Theme.Color.text2).padding(.horizontal, Theme.Space.m).padding(.bottom, Theme.Space.xs)
                .textSelection(.enabled)
        case .undoable(let line, let undo):
            HStack(spacing: Theme.Space.xs) {
                StatusPill(text: line, tone: .paid).padding(.leading, Theme.Space.s)
                AskChip(title: "Undo", detail: nil) { model.run(undo) }
                    .accessibilityIdentifier("ask.undo")
            }
            .padding(.bottom, Theme.Space.xs)
        case .working:
            Text("Creating…").font(Theme.Font.label).foregroundStyle(Theme.Color.text2).padding(.horizontal, Theme.Space.m).padding(.bottom, Theme.Space.xs)
        case .result(let r):
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.xs) {
                    Text(AskModel.resultTitle(r)).font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                    Spacer(minLength: 0)
                    StatusPill(text: "Ready", tone: .paid)
                }
                Text(r.link).font(Theme.Font.paper(12)).foregroundStyle(Theme.Color.text2).lineLimit(2).textSelection(.enabled)
                    .accessibilityIdentifier("ask.link")
                HStack(spacing: Theme.Space.xs) {
                    Button(model.copied ? "Copied" : "Copy link") { model.copy(r.link) }
                        .buttonStyle(PrimaryButton())
                        .accessibilityIdentifier("ask.copy")
                    Button("Done") { model.state = .idle; model.copied = false }
                        .buttonStyle(QuietButton(wide: false))
                }
            }
            .padding(.horizontal, Theme.Space.m).padding(.bottom, Theme.Space.xs)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ask.result")
        case .error(let e):
            Text(e).font(Theme.Font.label).foregroundStyle(Theme.Color.due).padding(.horizontal, Theme.Space.m).padding(.bottom, Theme.Space.xs)
        }
    }
}

/// A quiet paper chip: a title and an optional grey sub-line.
struct AskChip: View {
    let title: String
    let detail: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.Font.sans(14, 500)).foregroundStyle(Theme.Color.text1)
                if let detail { Text(detail).font(Theme.Font.sans(11.5)).foregroundStyle(Theme.Color.text2) }
            }
            .lineLimit(1)
        }
        .buttonStyle(TactileButton(kind: .quiet, small: true, wide: false))
    }
}
