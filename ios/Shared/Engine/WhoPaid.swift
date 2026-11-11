import Foundation

/// One client who owes money: one card in the "Who hasn't paid" list.
struct UnpaidClient: Equatable, Identifiable {
    let name: String
    /// The total this client owes in `currency`, as "120.00".
    let amount: String
    let currency: String
    let item: String
    /// Days late of the most overdue invoice. 0 when nothing is late yet.
    let daysLate: Int
    /// The pay link of the most overdue payment.
    let link: String?
    /// The reminder for the most overdue invoice. It is one chip with one key, so every tap on this card replays the same call.
    let remind: Chip?

    var id: String { name + "|" + currency }
    var money: String { formatMoney(amount, currency) }
    var veryLate: Bool { daysLate >= WhoPaid.veryLateDays }
    /// "2 days late", or "Open" when the invoice is not late yet.
    var late: String { daysLate > 0 ? "\(daysLate) day\(daysLate == 1 ? "" : "s") late" : "Open" }
}

/// The "Who hasn't paid" list, for the Ask bar, Home and the keyboard. Pure.
enum WhoPaid {
    static let veryLateDays = 14

    private static func cents(_ amount: String) -> Int { Int((Double(amount) ?? 0) * 100 + 0.5) }
    private static func value(_ cents: Int) -> String { String(format: "%.2f", Double(cents) / 100) }

    /// One card per client and currency, most days late first. `keeping` is the list shown before:
    /// a card whose invoice did not change keeps its reminder chip, so a reload never gives one reminder a second key.
    static func clients(_ payments: [Payment], keeping old: [UnpaidClient] = []) -> [UnpaidClient] {
        let kept = Dictionary(old.compactMap { c in c.remind.flatMap { chip in BarItems.string(chip, "invoice_id").map { ($0, chip) } } },
                              uniquingKeysWith: { a, _ in a })
        let unpaid = payments.filter { $0.state == "unpaid" }
        return Dictionary(grouping: unpaid) { ($0.client_name ?? $0.id) + "|" + $0.currency }.values.map { group in
            let byLate = group.sorted { $0.days_overdue != $1.days_overdue ? $0.days_overdue > $1.days_overdue : $0.created_at < $1.created_at }
            let top = byLate[0]
            let name = top.client_name ?? top.item
            let chip = byLate.first { $0.kind == "invoice" && $0.client_name != nil }.map { p in
                kept[p.id] ?? Chip(kind: "remind", label: "Remind \(name) \u{00B7} \(formatMoney(p.amount, p.currency))",
                                   payload: ["invoice_id": .string(p.id), "client_name": .string(name), "amount": .string(p.amount), "currency": .string(p.currency)],
                                   needs_confirm: true)
            }
            return UnpaidClient(name: name, amount: value(group.reduce(0) { $0 + cents($1.amount) }), currency: top.currency,
                                item: top.item + (group.count > 1 ? " +\(group.count - 1) more" : ""),
                                daysLate: top.days_overdue, link: top.link, remind: chip)
        }
        .sorted { a, b in
            if a.daysLate != b.daysLate { return a.daysLate > b.daysLate }
            if cents(a.amount) != cents(b.amount) { return cents(a.amount) > cents(b.amount) }
            return a.id < b.id
        }
    }

    /// "$165 unpaid · 2 clients". One total per currency, in the order of the list.
    static func header(_ clients: [UnpaidClient]) -> String {
        guard !clients.isEmpty else { return empty }
        var order: [String] = []
        var totals: [String: Int] = [:]
        for c in clients {
            if totals[c.currency] == nil { order.append(c.currency) }
            totals[c.currency, default: 0] += cents(c.amount)
        }
        let money = order.map { formatMoney(value(totals[$0] ?? 0), $0) }.joined(separator: " + ")
        let people = Set(clients.map(\.name)).count
        return "\(money) unpaid \u{00B7} \(people) client\(people == 1 ? "" : "s")"
    }

    static let empty = "Everyone's paid \u{2713}"
}
