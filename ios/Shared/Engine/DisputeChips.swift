import Foundation

/// One open PayPal dispute as /v1/disputes-open sends it: "Sam $45 · reply by Thu".
struct OpenDispute: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let amount: String?
    let currency: String?
    let line: String
}
struct OpenDisputesResponse: Decodable { let disputes: [OpenDispute] }

/// The three answers to a dispute, as chips in the server's own shape ({body, confirm, question}, server/src/actions-more.ts).
/// The server checks the buyer and the amount again, so a wrong value only brings the confirm back.
enum DisputeChips {
    private static func chip(_ kind: String, _ label: String, body: [String: JSONValue], confirm: [String: JSONValue], question: String) -> Chip {
        Chip(kind: kind, label: label, payload: ["body": .object(body), "confirm": .object(confirm), "question": .string(question)], needs_confirm: true)
    }

    private static func money(_ d: OpenDispute) -> String? {
        guard let a = d.amount, let c = d.currency else { return nil }
        return formatMoney(a, c)
    }

    /// Nil for an empty message.
    static func reply(_ d: OpenDispute, message: String) -> Chip? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let quote = text.count > 60 ? String(text.prefix(57)) + "\u{2026}" : text
        return chip("dispute_reply", "Reply in dispute \u{00B7} \(d.name)", body: ["dispute_id": .string(d.id), "message": .string(text)],
                    confirm: ["confirm_client": .string(d.name)], question: "Send this to \(d.name) in PayPal's dispute? \"\(quote)\"")
    }

    /// Nil when PayPal shows no amount for the dispute.
    static func accept(_ d: OpenDispute) -> Chip? {
        guard let amount = d.amount, let currency = d.currency, let m = money(d) else { return nil }
        return chip("dispute_accept", "Accept claim \(m) \u{00B7} \(d.name)", body: ["dispute_id": .string(d.id)],
                    confirm: ["confirm_client": .string(d.name), "confirm_amount": .string(amount), "confirm_currency": .string(currency)],
                    question: "Accept \(d.name)'s claim and refund \(m)? Can't undo.")
    }

    enum OfferError: Error, Equatable { case notAnAmount, moreThanDispute(String) }

    /// "20", "$20", "20.50". Never more than the dispute.
    static func offer(_ d: OpenDispute, typed: String) -> Result<Chip, OfferError> {
        let raw = typed.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        guard let currency = d.currency, let all = d.amount.flatMap({ Decimal(string: $0) }), let m = money(d),
              raw.range(of: #"^\d{1,7}(\.\d{1,2})?$"#, options: .regularExpression) != nil, let value = Decimal(string: raw), value > 0
        else { return .failure(.notAnAmount) }
        guard value <= all else { return .failure(.moreThanDispute(m)) }
        let amount = String(format: "%.2f", NSDecimalNumber(decimal: value).doubleValue)
        let offer = formatMoney(amount, currency)
        return .success(chip("dispute_offer", "Offer \(offer) \u{00B7} \(d.name)",
                             body: ["dispute_id": .string(d.id), "amount": .string(amount), "currency": .string(currency)],
                             confirm: ["confirm_client": .string(d.name), "confirm_amount": .string(amount), "confirm_currency": .string(currency)],
                             question: "Offer \(d.name) a \(offer) refund to close the dispute?"))
    }
}
