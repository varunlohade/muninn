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

/// Where a chip's result goes.
enum ChipOutcome: Equatable {
    /// An invoice or pay link went out: type the message, then watch for payment.
    case sent(ActionResult)
    /// Text to type into the field, such as a reply with prices.
    case insert(String)
    /// One line for the bar: a reminder sent, who owes you, a refund done.
    case line(String)
    /// The server wants one more tap. `chip` does the second step.
    case ask(String, chip: Chip)
}

/// One place that runs a chip's action, for the keyboard and the app's Ask bar.
/// Throws APIError.needsConfirm when the server wants the recipient confirmed first.
enum ChipActions {
    static let retryDelay: Duration = .milliseconds(1200)
    private static let networkFailures: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
    ]

    /// `source` is the message a reply answers. `sleep` waits before the one quiet retry.
    static func run(_ chip: Chip, confirmed: String?, source: String? = nil, api: KeyboardAPI,
                    sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async throws -> ChipOutcome {
        // One key per tap. The retry sends the same key, so the server never runs a money action twice.
        let key = UUID().uuidString
        func call<T>(_ work: () async throws -> T) async throws -> T {
            do { return try await work() } catch let e as URLError where networkFailures.contains(e.code) {
                try await sleep(retryDelay)
                return try await work()
            }
        }
        let who = string(chip, "client_name") ?? "Client"
        switch chip.kind {
        case "invoice":
            var payload = chip.payload
            if let confirmed { payload["confirm_recipient"] = .string(confirmed) }
            let res = try await call { try await api.invoice(payload, key: key) }
            guard let link = res.pay_link else { throw APIError.message("No link came back. Try again.") }
            // Item comes from the server-built chip, amount from the server's reply.
            let item = string(chip, "item") ?? "your order"
            let money = formatMoney(res.amount, res.currency)
            return .sent(ActionResult(id: res.id, kind: "invoice", link: link, money: money, who: who,
                                      message: "Here's your invoice for \(item) (\(money)): \(link)"))
        case "paylink":
            let res = try await call { try await api.payLink(chip.payload, key: key) }
            guard let link = res.approve_link else { throw APIError.message("No link came back. Try again.") }
            // A ";pay 45" chip has no currency: the server uses the profile's, and says which in its reply.
            let money = if let a = res.amount, let c = res.currency { formatMoney(a, c) }
                else if let a = string(chip, "amount"), let c = string(chip, "currency") { formatMoney(a, c) } else { "" }
            return .sent(ActionResult(id: res.id, kind: "paylink", link: link, money: money, who: who, message: link))
        case "remind":
            guard let id = string(chip, "invoice_id") else { throw APIError.message("Open \(AppConfig.displayName) for this one") }
            _ = try await call { try await api.remind(invoiceID: id, key: key) }
            return .line("Reminder sent \u{2713}")
        case "refund":
            if let token = string(chip, "confirm_token") {
                let res = try await call { try await api.refund(["confirm_token": .string(token)], key: key) }
                let money = if let a = res.amount, let c = res.currency { " " + formatMoney(a, c) } else { "" }
                return .line("Refunded\(money) \u{2713}")
            }
            let body = chip.payload.filter { ["id", "amount"].contains($0.key) && $0.value != .null }
            let res = try await call { try await api.refund(body, key: key) }
            guard let token = res.confirm_token else { throw APIError.message("Open \(AppConfig.displayName) for this one") }
            let question = res.summary ?? chip.label
            return .ask(question, chip: Chip(kind: "refund", label: question, payload: ["confirm_token": .string(token)], needs_confirm: false))
        case "payments":
            return .line(KeyboardModel.lateLine(try await call { try await api.payments() }))
        case "reply":
            guard let source, !source.isEmpty else { throw APIError.message("Copy the client's message first") }
            return .insert(try await call { try await api.reply(source) }.reply)
        default:
            throw APIError.message("Open \(AppConfig.displayName) for this one")
        }
    }

    private static func string(_ chip: Chip, _ key: String) -> String? {
        if case .string(let v)? = chip.payload[key] { v } else { nil }
    }
}
