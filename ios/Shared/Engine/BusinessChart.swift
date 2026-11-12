import Foundation

/// "graph my sales this week", "chart sales by day", "bar chart of top items", "who owes me chart": the owner's own records
/// drawn as a chart. The words are read on the phone. The numbers come from the payments list the keyboard already reads
/// (GET /v1/payments: Muninn's own records, no PayPal call). Read only: nothing is written or sent.
/// A projection ("graph my projections", "show revenue next 3 months", "chart?") reads money in by month from PayPal
/// (GET /v1/chart, server/src/chart.ts) and draws it with a marked estimate.
enum BusinessChart {
    enum Request: Equatable {
        /// Paid sales per day over the last 7 days, today last.
        case salesByDay(Chart.Kind)
        /// Paid sales per item, biggest first.
        case topItems(Chart.Kind)
        /// What each client still owes.
        case whoOwes(Chart.Kind)
        /// Money in by month from PayPal: `back` full months, the month so far, and `ahead` estimated months.
        case projection(back: Int, ahead: Int)

        /// The words the bar quotes and the card's title.
        var subject: String {
            switch self {
            case .salesByDay: "Sales, last 7 days"
            case .topItems: "Top items"
            case .whoOwes: "Who owes you"
            case .projection: "Money in by month"
            }
        }
    }

    static let days = 7
    static let maxItems = 6

    static func detect(_ text: String) -> Request? {
        let sentence = SmartDetect.lastSentence(text)
        guard !sentence.isEmpty, sentence.count <= Explain.maxQuestion else { return nil }
        let s = Explain.core(sentence)
        let chartWord = has(#"\b(?:graph|chart|plot)s?\b"#, s)
        let kind: Chart.Kind? = has(#"\bpie\b"#, s) ? .pie : has(#"\bline\b"#, s) ? .line : has(#"\bbar\b"#, s) ? .bar : nil
        if chartWord, has(#"\b(?:who owes|owes? me|owed|owing|unpaid)\b"#, s) { return .whoOwes(kind ?? .bar) }
        if chartWord, has(#"\b(?:top|best[ -]?sell\w*)\s+(?:items?|products?|services?|sellers?)\b|\bbest[ -]?sellers?\b"#, s) { return .topItems(kind ?? .bar) }
        if let p = projection(s, chartWord: chartWord, strong: true) { return p }
        if chartWord, has(#"\b(?:my )?(?:sales|revenue|earnings|income)\b"#, s) { return .salesByDay(kind ?? .bar) }
        return projection(s, chartWord: chartWord, strong: false)
    }

    /// A projection ask. Strong: a bare chart word ("chart?"), a forecast word, or months ahead or back ("bar chart of last 6 months",
    /// "show revenue next 3 months"); these win over the 7-day sales chart. Weak: a chart word next to a money word ("money chart?"),
    /// asked only after the owner's other charts. A chart word alone in a sentence ("the plot of the film", "graph paper") is chat
    /// and stays on the phone. "your chart" is someone else's chart. Also strong: "make me a projection", "project my sales for 3 months",
    /// "forecast next quarter", "how much will I make in the next 3 months", "can it make a graph … in the keyboard".
    private static func projection(_ s: String, chartWord: Bool, strong: Bool) -> Request? {
        guard !has(#"\byour\b"#, s) else { return nil }
        let sales = #"\b(?:sales|revenue|income|earnings|takings|turnover|money)\b"#
        let count = "(\\d{1,2}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"
        let months = has("\\b(?:(?:last|past|next|coming|for) \(count) months?|(?:next|coming) month|(?:this|next|last) quarter|monthly|by month|per month)\\b", s)
        let future = has(#"\b(?:projections?|projected|forecasts?|predict\w*|trend\w*)\b"#, s)
        let asked: Bool
        if strong {
            let alone = has(#"^(?:(?:a|the|my) )?(?:(?:bar|line) )?(?:chart|graph)(?: please)?$"#, s)
            let forecast = has(#"^(?:my )?(?:(?:sales|revenue|income|earnings) )?(?:projections?|forecasts?)$|^(?:sales|revenue|income|earnings) trends?$"#, s)
            let trending = has(#"^how (?:are|is) (?:my )?(?:sales|revenue|income|earnings) (?:doing|trending|going)\b"#, s)
            let show = has(#"^(?:show|draw|forecast|project|predict|visuali[sz]e)\b"#, s) && has(sales, s)
            // "project my sales for 3 months": the verb is the forecast.
            let verb = has(#"^(?:forecast|project|predict)\b"#, s) && has(sales, s)
            // "make me a projection for next 3 months".
            let make = has(#"^(?:make|build|create|give|do|run)(?: me| us)? (?:a |an |my )?(?:(?:sales|revenue|money) )?(?:projections?|forecasts?)\b"#, s)
            // "can it make a graph … in the keyboard": asking what the keyboard can draw.
            let meta = has(#"^(?:can|could|will|would) (?:it|this|this keyboard|the keyboard|muninn) (?:make|draw|show|do)\b"#, s) && (chartWord || future)
            // "how much will I make in the next 3 months".
            let howMuch = has(#"^how much (?:will|would|could|might|can) (?:i|we) (?:make|earn|bring in|take in|sell|get)\b"#, s) && months
            asked = alone || forecast || trending || verb || make || meta || howMuch || (future && months)
                || (chartWord && (future || months)) || (show && (future || months))
        } else {
            asked = chartWord && has(sales, s)
        }
        guard asked else { return nil }
        func number(_ dir: String) -> Int? {
            guard let re = try? NSRegularExpression(pattern: "\\b(?:\(dir)) \(count) months?\\b"),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
            let words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
            return words.firstIndex(of: String(s[r])).map { $0 + 1 } ?? Int(s[r])
        }
        return .projection(back: min(12, max(2, number("last|past") ?? 6)), ahead: min(6, max(1, number("next|coming|for") ?? 3)))
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
        case .projection:
            // Drawn from GET /v1/chart, not from the payments list.
            return nil
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
        case .projection: "No sales in PayPal yet."
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
