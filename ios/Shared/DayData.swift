import Foundation

/// One of today's calendar events, cut down to what the keyboard may see: time, title, matched client.
struct Appointment: Codable, Equatable, Identifiable {
    let start: Date
    let end: Date
    let title: String
    var clientName: String?
    var clientEmail: String?
    /// The client already has an invoice or pay link from today.
    var billed = false

    var id: String { "\(start.timeIntervalSince1970)|\(title)" }
    /// "Sam" for the bar and the Bill button; the event title when no client matched.
    var who: String { clientName?.split(separator: " ").first.map(String.init) ?? clientEmail ?? title }
    var time: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f.string(from: start)
    }
    /// The words that start the invoice flow for this client.
    var invoicePrefix: String { (["Invoice", clientName, clientEmail].compactMap { $0 }).joined(separator: " ") }
}

struct Note: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
    /// Typing this, then space or return, puts the note in the message. Nil means no shortcut.
    var trigger: String?

    static let demo = [
        Note(text: "Prices: cut $45, color $120, blowout $35", trigger: ";prices"),
        Note(text: "Cancellation: 24h notice or 50% fee"),
    ]
}

/// A built-in keyboard action. The owner can change its trigger or turn it off.
struct ActionShortcut: Codable, Equatable, Identifiable {
    enum Action: String, Codable, CaseIterable { case pay, late, fix }
    let action: Action
    var trigger: String
    var enabled = true

    var id: String { action.rawValue }
    var title: String {
        switch action {
        case .pay: "Pay link"
        case .late: "Who owes you"
        case .fix: "Fix the text"
        }
    }
    /// How to type it, with the current trigger.
    var usage: String { action == .pay ? "\(trigger) 45" : trigger }
    var detail: String {
        switch action {
        case .pay: "Offers a PayPal link for the amount. You still tap to send."
        case .late: "Shows unpaid invoices in the keyboard bar."
        case .fix: "Fixes spelling and grammar before the cursor."
        }
    }

    static let defaults = [
        ActionShortcut(action: .pay, trigger: ";pay"),
        ActionShortcut(action: .late, trigger: ";late"),
        ActionShortcut(action: .fix, trigger: ";fix"),
    ]
}

enum Shortcuts {
    /// Triggers are one lowercase word.
    static func normalize(_ raw: String) -> String {
        raw.lowercased().filter { !$0.isWhitespace }
    }

    /// Nil when the trigger can be saved. `taken` holds every other trigger.
    static func problem(_ trigger: String, taken: Set<String>) -> String? {
        if trigger.count < 2 { return "Use 2 characters or more." }
        if trigger.count > 20 { return "Use 20 characters or fewer." }
        if taken.contains(trigger) { return "Another shortcut uses \(trigger)." }
        return nil
    }

    /// "45", "$45" or "45.50" as a pay link payload. Nil when it is not an amount.
    static func amount(_ word: String) -> (value: String, currency: String?)? {
        let currency = ["$": "USD", "€": "EUR", "£": "GBP"][String(word.prefix(1))]
        let digits = currency == nil ? word : String(word.dropFirst())
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), (1...5).contains(parts[0].count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              parts.count == 1 || parts[1].count <= 2, let whole = Int(parts[0]) else { return nil }
        let cents = parts.count == 2 ? String(parts[1]).padding(toLength: 2, withPad: "0", startingAt: 0) : "00"
        guard whole > 0 || cents != "00" else { return nil }
        return ("\(whole).\(cents)", currency)
    }
}
