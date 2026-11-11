import Foundation

/// What the bar offers when nothing is typed: up to 3 chips from data the keyboard already holds. No server call.
enum ReadyChips {
    struct Input {
        var copiedAvailable = false
        var toBill: Appointment?
        var nextUp: Appointment?
        var today: [Appointment] = []
        /// Unpaid invoices in the app's last snapshot. Nil when the app has not written one yet.
        var unpaidCount: Int?
        var watch: Watch?
    }

    static func build(_ i: Input) -> [BarItems.Item] {
        typealias Item = BarItems.Item
        var out: [Item] = []
        if i.copiedAvailable { out.append(Item(id: "copied", title: "Use copied message", action: .useCopied)) }
        if let a = i.toBill { out.append(Item(id: "bill", title: "Invoice \(a.who)", action: .bill(a))) }
        if let a = i.nextUp {
            let known = (a.clientName ?? a.clientEmail) != nil
            out.append(known
                ? Item(id: "next", title: "Next: \(a.who) \(a.time) \u{00B7} Invoice", action: .bill(a))
                : Item(id: "next", title: "Next: \(a.who) \(a.time)", tone: .secondary))
        }
        switch i.unpaidCount {
        case nil: out.append(Item(id: "whopaid", title: "Who paid?", action: .whoPaid))
        case let n? where n > 0: out.append(Item(id: "whopaid", title: "Who paid? \u{00B7} \(n) unpaid", action: .whoPaid))
        default: break
        }
        if let w = i.watch {
            out.append(w.paid
                ? Item(id: "paid", title: "\(w.who) paid \u{2713}", tone: .paid)
                : Item(id: "waiting", title: "Waiting on \(w.money)", tone: .secondary))
        }
        if !i.today.isEmpty {
            let n = i.today.count
            out.append(Item(id: "today", title: "Today \u{00B7} \(n) appointment\(n == 1 ? "" : "s")", action: .today))
        }
        out.append(Item(id: "notes", title: "Notes", action: .notes))
        return Array(out.prefix(3))
    }
}
