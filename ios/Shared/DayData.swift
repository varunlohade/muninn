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

    static let demo = [
        Note(text: "Prices: cut $45, color $120, blowout $35"),
        Note(text: "Cancellation: 24h notice or 50% fee"),
    ]
}
