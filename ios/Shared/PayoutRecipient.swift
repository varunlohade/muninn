import Foundation

/// "send $20 to Ritika" with no email or phone on file: the server's payout chip carries `needs_recipient`.
/// The owner types the email or phone on this phone; it goes into the chip's body and confirm, and in place of
/// {to} in the question. The recipient only ever comes from what the owner typed here.
enum PayoutRecipient {
    static func needed(_ chip: Chip) -> Bool {
        chip.kind == "payout" && chip.payload["needs_recipient"] == .bool(true)
    }

    /// "Type Ritika's email or phone".
    static func prompt(_ chip: Chip) -> String {
        BarItems.string(chip, "ask") ?? "Type their email or phone"
    }

    /// A typed email, lowercased, or a phone number with only digits and a leading +. Nil for anything else.
    static func parse(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("@") {
            let e = t.lowercased()
            return e.range(of: #"^[^\s@]+@[^\s@]+\.[a-z]{2,}$"#, options: .regularExpression) != nil ? e : nil
        }
        let digits = t.filter { !" ().-".contains($0) }
        return digits.range(of: #"^\+?[0-9]{7,15}$"#, options: .regularExpression) != nil ? digits : nil
    }

    /// The same chip with the recipient in its body, its confirm and its question. It then confirms like any payout.
    static func filled(_ chip: Chip, with to: String) -> Chip {
        var payload = chip.payload
        if case .object(var body)? = payload["body"] {
            body[to.contains("@") ? "recipient_email" : "recipient_phone"] = .string(to)
            payload["body"] = .object(body)
        }
        if case .object(var confirm)? = payload["confirm"] {
            confirm["confirm_recipient"] = .string(to)
            payload["confirm"] = .object(confirm)
        }
        if let q = BarItems.string(chip, "question") { payload["question"] = .string(q.replacingOccurrences(of: "{to}", with: to)) }
        payload["needs_recipient"] = nil
        payload["ask"] = nil
        return Chip(kind: chip.kind, label: chip.label, payload: payload, needs_confirm: true)
    }
}
