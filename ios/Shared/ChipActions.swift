import Foundation

/// What a tapped chip produced: the link, and the line we insert or show.
struct ActionResult: Equatable {
    let id: String
    let kind: String
    let link: String
    let money: String
    let who: String
    /// "Here's your invoice for Haircut ($45): <link>" for an invoice, the bare link for a pay link.
    let message: String
}

/// One place that runs a chip's action, for the keyboard and the app's Ask bar.
/// Throws APIError.needsConfirm when the server wants the recipient confirmed first.
enum ChipActions {
    static func run(_ chip: Chip, confirmed: String?, api: APIClient) async throws -> ActionResult {
        let who = if case .string(let v)? = chip.payload["client_name"] { v } else { "Client" }
        switch chip.kind {
        case "invoice":
            var payload = chip.payload
            if let confirmed { payload["confirm_recipient"] = .string(confirmed) }
            let res = try await api.invoice(payload)
            guard let link = res.pay_link else { throw APIError.http(0, "No link came back") }
            // Item comes from the server-built chip, amount from the server's reply.
            let item = if case .string(let v)? = chip.payload["item"] { v } else { "your order" }
            let money = formatMoney(res.amount, res.currency)
            return ActionResult(id: res.id, kind: "invoice", link: link, money: money, who: who,
                                message: "Here's your invoice for \(item) (\(money)): \(link)")
        case "paylink":
            let res = try await api.payLink(chip.payload)
            guard let link = res.approve_link else { throw APIError.http(0, "No link came back") }
            // A ";pay 45" chip has no currency: the server uses the profile's, and says which in its reply.
            let money = if let a = res.amount, let c = res.currency { formatMoney(a, c) }
                else if case .string(let a)? = chip.payload["amount"], case .string(let c)? = chip.payload["currency"] { formatMoney(a, c) } else { "" }
            return ActionResult(id: res.id, kind: "paylink", link: link, money: money, who: who, message: link)
        default:
            throw APIError.http(0, "Open \(AppConfig.displayName) for this one")
        }
    }
}
