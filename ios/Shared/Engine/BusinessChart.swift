import Foundation

/// "graph my sales this week", "chart sales by day", "bar chart of top items", "who owes me chart": the owner's own records
/// drawn as a chart. The words are read on the phone. The numbers come from the payments list the keyboard already reads
/// (GET /v1/payments: Muninn's own records, no PayPal call). Read only: nothing is written or sent.
enum BusinessChart {
    enum Request: Equatable {
        /// Paid sales per day over the last 7 days, today last.
        case salesByDay(Chart.Kind)
        /// Paid sales per item, biggest first.
        case topItems(Chart.Kind)
        /// What each client still owes.
        case whoOwes(Chart.Kind)

        /// The words the bar quotes and the card's title.
        var subject: String {
            switch self {
            case .salesByDay: "Sales, last 7 days"
            case .topItems: "Top items"
            case .whoOwes: "Who owes you"
            }
        }
    }

    static let days = 7
    static let maxItems = 6

    static func detect(_ text: String) -> Request? {
        let sentence = SmartDetect.lastSentence(text)
        guard !sentence.isEmpty, sentence.count <= Explain.maxQuestion else { return nil }
        let s = Explain.core(sentence)
        guard has(#"\b(?:graph|chart|plot)\b"#, s) else { return nil }
        let kind: Chart.Kind? = has(#"\bpie\b"#, s) ? .pie : has(#"\bline\b"#, s) ? .line : has(#"\bbar\b"#, s) ? .bar : nil
        if has(#"\b(?:who owes|owes? me|owed|owing|unpaid)\b"#, s) { return .whoOwes(kind ?? .bar) }
        if has(#"\b(?:top|best[ -]?sell\w*)\s+(?:items?|products?|services?|sellers?)\b|\bbest[ -]?sellers?\b"#, s) { return .topItems(kind ?? .bar) }
        if has(#"\b(?:my )?(?:sales|revenue|earnings|income)\b"#, s) { return .salesByDay(kind ?? .bar) }
        return nil
    }

    /// The chart for this request from the owner's payments, or nil when there is nothing to draw.
    static func chart(_ r: Request, payments: [Payment], now: Date, calendar: Calendar = .current) -> Chart.Request? {
        switch r {
        case .salesByDay(let kind):
            let paid = inMainCurrency(payments.filter { $0.state == "paid" })
            guard let currency = paid.first?.currency else { return nil }
            let today = calendar.startOfDay(for: now)
            let starts = (0..<days).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
            let f = DateFormatter()
            f.calendar = calendar
            f.dateFormat = "EEE"
            let items = starts.map { start in
                let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
                let total = paid.filter { p in date(p.created_at).map { $0 >= start && $0 < end } ?? false }.reduce(0) { $0 + cents($1.amount) }
                return Chart.Item(label: f.string(from: start), value: Double(total) / 100)
            }
            guard items.contains(where: { $0.value > 0 }) else { return nil }
            return .data(kind, title: "\(r.subject) (\(symbol(currency)))", items: items)
        case .topItems(let kind):
            let paid = inMainCurrency(payments.filter { $0.state == "paid" })
            guard let currency = paid.first?.currency else { return nil }
            let items = totals(paid, by: { $0.item }).prefix(maxItems).map { Chart.Item(label: $0.key, value: Double($0.cents) / 100) }
            guard !items.isEmpty else { return nil }
            return .data(kind, title: "\(r.subject) (\(symbol(currency)))", items: Array(items))
        case .whoOwes(let kind):
            let unpaid = inMainCurrency(payments.filter { $0.state == "unpaid" })
            guard let currency = unpaid.first?.currency else { return nil }
            let items = totals(unpaid, by: { $0.client_name ?? $0.item }).prefix(maxItems).map { Chart.Item(label: $0.key, value: Double($0.cents) / 100) }
            guard !items.isEmpty else { return nil }
            return .data(kind, title: "\(r.subject) (\(symbol(currency)))", items: Array(items))
        }
    }

    /// The line when there is nothing to draw.
    static func empty(_ r: Request) -> String {
        switch r {
        case .salesByDay: "No paid sales in the last 7 days yet."
        case .topItems: "No paid sales yet."
        case .whoOwes: WhoPaid.empty
        }
    }

    /// One chart cannot mix currencies, so it shows the currency with the most payments.
    private static func inMainCurrency(_ list: [Payment]) -> [Payment] {
        let counts = Dictionary(grouping: list, by: \.currency).mapValues(\.count)
        guard let main = counts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key else { return [] }
        return list.filter { $0.currency == main }
    }

    /// Sums by key, biggest first; ties by name, so the order is stable.
    private static func totals(_ list: [Payment], by key: (Payment) -> String) -> [(key: String, cents: Int)] {
        Dictionary(grouping: list, by: key).map { (key: $0.key, cents: $0.value.reduce(0) { $0 + cents($1.amount) }) }
            .sorted { $0.cents != $1.cents ? $0.cents > $1.cents : $0.key < $1.key }
    }

    private static func cents(_ amount: String) -> Int { Int(((Double(amount) ?? 0) * 100).rounded()) }

    private static func symbol(_ currency: String) -> String { formatMoney("0", currency).replacingOccurrences(of: "0", with: "").trimmingCharacters(in: .whitespaces) }

    private static func date(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }

    private static func has(_ pattern: String, _ s: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
}
