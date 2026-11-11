import CryptoKit
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

/// The Idempotency-Key a chip uses until `expires`.
struct ChipKey: Codable, Equatable {
    let key: String
    let expires: Date
}

/// A money call that has not answered yet. `before` is what the field held at the tap.
struct PendingAction: Codable, Equatable {
    let chip: Chip
    let confirmed: String?
    let before: String
    let key: String
    let expires: Date
}

/// The key belongs to the chip in its field, not the tap: the same chip over the same text within `ttl` sends
/// the same key, so the server replays its stored answer instead of sending a second invoice.
enum ChipKeys {
    static let ttl: TimeInterval = 600

    /// `before` is the field text before the cursor, so the same chip typed to another client gets another key.
    static func key(for chip: Chip, confirmed: String?, before: String, in store: KeyboardStore, now: Date) -> String {
        var keys = store.chipKeys.filter { $0.value.expires > now }
        let id = fingerprint(chip, confirmed: confirmed, before: before)
        let k = keys[id] ?? ChipKey(key: UUID().uuidString, expires: now + ttl)
        keys[id] = k
        store.chipKeys = keys
        return k.key
    }

    /// Kind, payload (amount, currency, item, email, client name), recipient and a hash of the field text.
    private static func fingerprint(_ chip: Chip, confirmed: String?, before: String) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let value: JSONValue = .object(["kind": .string(chip.kind), "payload": .object(chip.payload),
                                        "confirmed": confirmed.map { .string($0) } ?? .null, "before": .string(hex(Data(before.utf8)))])
        return hex((try? enc.encode(value)) ?? Data())
    }

    private static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
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
/// `lookup` asks the server only for the stored answer of `key` and never runs the action (refunds always run).
enum ChipActions {
    static let retryDelay: Duration = .milliseconds(1200)
    static let inProgressDelay: Duration = .seconds(2)
    static let inProgressTries = 3
    /// Chips whose call moves money or messages a client. Only these keep a key and a pending call.
    static let sendsMoney: Set = ["invoice", "paylink", "remind", "refund"]
    private static let networkFailures: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
    ]

    /// `source` is the message a reply answers. `key` is the Idempotency-Key; every retry sends it, so the
    /// server never runs a money action twice. `sleep` waits before a retry. `stillSending` runs while the
    /// server is still busy with the same key.
    static func run(_ chip: Chip, confirmed: String?, source: String? = nil, api: KeyboardAPI, key: String = UUID().uuidString, lookup: Bool = false,
                    sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                    stillSending: @MainActor () -> Void = {}) async throws -> ChipOutcome {
        func once<T>(_ work: () async throws -> T) async throws -> T {
            do { return try await work() } catch let e as URLError where networkFailures.contains(e.code) {
                try await sleep(retryDelay)
                return try await work()
            }
        }
        func call<T>(_ work: () async throws -> T) async throws -> T {
            for _ in 0..<inProgressTries {
                do { return try await once(work) } catch let e where isInProgress(e) {
                    await stillSending()
                    try await sleep(inProgressDelay)
                }
            }
            return try await once(work)
        }
        let who = string(chip, "client_name") ?? "Client"
        switch chip.kind {
        case "invoice":
            var payload = chip.payload
            // The confirm tap showed the amount and the recipient; the server checks both against the payload.
            if let confirmed {
                if case .string? = payload["client_email"] { payload["confirm_recipient"] = .string(confirmed) }
                payload["confirm_amount"] = payload["amount"]
            }
            let res = try await call { try await api.invoice(payload, key: key, lookup: lookup) }
            guard let link = res.pay_link else { throw APIError.message("No link came back. Try again.") }
            // Item comes from the server-built chip, amount from the server's reply.
            let item = string(chip, "item") ?? "your order"
            let money = formatMoney(res.amount, res.currency)
            return .sent(ActionResult(id: res.id, kind: "invoice", link: link, money: money, who: who,
                                      message: "Here's your invoice for \(item) (\(money)): \(link)"))
        case "paylink":
            let res = try await call { try await api.payLink(chip.payload, key: key, lookup: lookup) }
            guard let link = res.approve_link else { throw APIError.message("No link came back. Try again.") }
            // A ";pay 45" chip has no currency: the server uses the profile's, and says which in its reply.
            let money = if let a = res.amount, let c = res.currency { formatMoney(a, c) }
                else if let a = string(chip, "amount"), let c = string(chip, "currency") { formatMoney(a, c) } else { "" }
            return .sent(ActionResult(id: res.id, kind: "paylink", link: link, money: money, who: who, message: link))
        case "remind":
            guard let id = string(chip, "invoice_id") else { throw APIError.message("Open \(AppConfig.displayName) for this one") }
            _ = try await call { try await api.remind(invoiceID: id, key: key, lookup: lookup) }
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
