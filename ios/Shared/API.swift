import Foundation

/// Any JSON value. Chip payloads go back to the server unchanged.
enum JSONValue: Codable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

struct Chip: Codable, Hashable, Identifiable {
    let kind: String
    let label: String
    let payload: [String: JSONValue]
    let needs_confirm: Bool
    /// The Idempotency-Key of this one chip. A chip decoded from a server reply or built on the phone gets a new
    /// key; every tap of the same chip, and its pending call, sends it, so the server replays instead of sending twice.
    let key: String
    var id: String { kind + label }

    private enum CodingKeys: String, CodingKey { case kind, label, payload, needs_confirm, key }

    init(kind: String, label: String, payload: [String: JSONValue], needs_confirm: Bool, key: String = UUID().uuidString) {
        self.kind = kind
        self.label = label
        self.payload = payload
        self.needs_confirm = needs_confirm
        self.key = key
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        label = try c.decode(String.self, forKey: .label)
        payload = try c.decode([String: JSONValue].self, forKey: .payload)
        needs_confirm = try c.decode(Bool.self, forKey: .needs_confirm)
        // A server reply has no key: each reply gives new chips. A saved pending call keeps its own.
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? UUID().uuidString
    }
}

struct SuggestResponse: Decodable {
    let chips: [Chip]
    let intent: String
    let timings: [String: Int]?
}

/// What /v1/ask sends back: the route the server picked and that route's result.
struct AskResponse {
    enum Result {
        /// A money route: the same chips as suggest. Each one still needs its own tap.
        case chips([Chip])
        /// A rewrite or a reply.
        case text(String)
        case tone(ToneResponse)
        case payments([Payment])
        case brief([String])
        case clients([Client])
        case disputes([Dispute])
        /// The phone saves this note. The server keeps nothing.
        case addNote(String)
        /// The phone shows today's appointments from its own calendar.
        case showCalendar
        /// No route fits: one plain line.
        case line(String)
    }
    let route: String
    let confidence: Double
    let result: Result
}

extension AskResponse: Decodable {
    private enum Keys: String, CodingKey { case route, confidence, result }
    private struct Chips: Decodable { let chips: [Chip] }
    private struct Lines: Decodable { let lines: [String] }
    private struct Line: Decodable { let line: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        route = try c.decode(String.self, forKey: .route)
        confidence = try c.decode(Double.self, forKey: .confidence)
        func get<T: Decodable>(_ type: T.Type) throws -> T { try c.decode(T.self, forKey: .result) }
        switch route {
        case "invoice", "paylink", "remind", "refund": result = .chips(try get(Chips.self).chips)
        case "fix", "refine": result = .text(try get(WriteResponse.self).text)
        case "reply": result = .text(try get(ReplyResponse.self).reply)
        case "tone": result = .tone(try get(ToneResponse.self))
        case "who_paid": result = .payments(try get(PaymentsResponse.self).payments)
        case "brief": result = .brief(try get(Lines.self).lines)
        case "clients": result = .clients(try get(ClientsResponse.self).clients)
        case "disputes": result = .disputes(try get(DisputesResponse.self).disputes)
        case "add_note": result = .addNote(try get(WriteResponse.self).text)
        case "today_calendar": result = .showCalendar
        default: result = .line((try? get(Line.self))?.line ?? "Not sure what you need. Try again with other words.")
        }
    }
}

struct InvoiceResponse: Decodable { let id: String; let status: String; let pay_link: String?; let amount: String; let currency: String }
struct PayLinkResponse: Decodable { let id: String; let status: String; let approve_link: String?; let amount: String?; let currency: String? }
struct RemindResponse: Decodable { let invoice_id: String }
/// A refund runs in two calls. The first gives `confirm_token` and `summary`; the second, with the token, gives `refund_id`.
struct RefundResponse: Decodable { let confirm_token: String?; let summary: String?; let refund_id: String?; let amount: String?; let currency: String? }
struct ReplyResponse: Decodable { let reply: String }
struct WriteResponse: Decodable { let text: String; let changed: Bool? }
/// tone is "upset" (the client), "blunt" (the owner's draft) or "ok". calm is set unless tone is "ok".
struct ToneResponse: Decodable { let tone: String; let calm: String? }
struct NeedsConfirm: Decodable { let needs_confirm: Bool; let recipient: String }

struct Summary: Decodable {
    let earned_today: [String: String]
    let earned_this_week: [String: String]
    let unpaid_count: Int
    let late_count: Int?
    let open_disputes: Int?
}

struct Brief: Decodable { let lines: [String]; let source: String }

struct Client: Decodable, Identifiable, Hashable {
    let name: String?
    let email: String?
    let total_paid: [String: String]
    let open_amount: [String: String]
    let visits: Int
    let last_seen: String?
    let channels: [String]
    var id: String { (email ?? "") + "|" + (name ?? "") }
    var displayName: String { name ?? email ?? "Client" }
}
struct ClientsResponse: Decodable { let clients: [Client] }

struct Transaction: Decodable, Identifiable { let id: String; let date: String; let amount: String; let currency: String; let payer_name: String? }
struct TransactionsResponse: Decodable { let source: String; let transactions: [Transaction] }

struct Money: Decodable, Hashable { let value: String; let currency_code: String }
struct Dispute: Decodable, Identifiable { let id: String; let status: String; let reason: String; let amount: Money?; let due_date: String? }
struct DisputesResponse: Decodable { let disputes: [Dispute] }

struct Integration: Decodable, Identifiable { let id: String; let name: String; let status: String }
struct IntegrationsResponse: Decodable { let integrations: [Integration] }

struct Payment: Decodable, Identifiable, Hashable {
    let kind: String
    let id: String
    let state: String
    let amount: String
    let currency: String
    let item: String
    let client_name: String?
    let link: String?
    let created_at: String
    let days_overdue: Int
}

struct PaymentsResponse: Decodable { let payments: [Payment] }
struct AppleAuthResponse: Decodable { let device_token: String }

/// Same format as the server's formatMoney: "$45", "$45.50", "€12".
func formatMoney(_ amount: String, _ currency: String) -> String {
    let symbols = ["USD": "$", "CAD": "CA$", "AUD": "A$", "EUR": "€", "GBP": "£"]
    let value = amount.hasSuffix(".00") ? String(amount.dropLast(3)) : amount
    return (symbols[currency] ?? currency + " ") + value
}

enum APIError: Error, LocalizedError {
    case notPaired
    case needsConfirm(recipient: String)
    case http(Int, String)
    /// A plain line for the owner, made on the phone.
    case message(String)

    var errorDescription: String? { plainLine(self) }
}

/// One short line for the bar. Never a status code or raw JSON.
func plainLine(_ error: Error) -> String {
    let again = "Something went wrong. Try again."
    switch error {
    case APIError.notPaired: return "Open \(AppConfig.displayName) to pair"
    case APIError.needsConfirm(let r): return "Confirm \(r) first"
    case APIError.message(let s): return s
    case _ where isInProgress(error): return "Still sending. Check again in a minute."
    case APIError.http(let code, let body):
        switch code {
        case 401: return "Open \(AppConfig.displayName) to pair"
        case 429: return "Too many tries. Wait a minute."
        case 502: return "PayPal did not answer. Try again."
        case 400..<500: return serverWords(body) ?? again
        default: return again
        }
    case let e as URLError: return e.code == .timedOut ? "Took too long. Try again." : "No connection. Try again."
    default: return again
    }
}

/// The server is still running a call with this Idempotency-Key.
func isInProgress(_ error: Error) -> Bool {
    if case APIError.http(409, let body) = error { body.contains("in progress") } else { false }
}

/// The server's own short `error` text, as a sentence. Nil for internal wording such as the idempotency key.
private func serverWords(_ body: String) -> String? {
    struct Body: Decodable { let error: String }
    guard let e = try? JSONDecoder().decode(Body.self, from: Data(body.utf8)).error, !e.isEmpty, e.count <= 80,
          !e.localizedCaseInsensitiveContains("idempotency") else { return nil }
    return e.prefix(1).uppercased() + e.dropFirst()
}

struct APIClient {
    var baseURL: String
    var token: String?
    var session: URLSession = .shared

    static func shared() -> APIClient {
        APIClient(baseURL: SharedStore.serverURL, token: SharedStore.deviceToken)
    }

    /// Sign in with Apple: trades the identity token and the raw nonce for a device token. The only call with no token.
    static func appleSignIn(baseURL: String, identityToken: String, nonce: String) async throws -> String {
        guard let url = URL(string: baseURL + "/v1/auth/apple") else { throw APIError.http(0, "bad server URL") }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(["identity_token": identityToken, "nonce": nonce])
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw APIError.http(code, "") }
        return try JSONDecoder().decode(AppleAuthResponse.self, from: data).device_token
    }

    /// `key` is the Idempotency-Key of a money call. A retry passes the same key, so the server runs the action once.
    /// `lookup` asks only for the stored answer of `key`: the server never runs the action, and says 404 when it has none.
    private func request(_ method: String, _ path: String, body: Encodable? = nil, tap: Bool = false, key: String? = nil, lookup: Bool = false) throws -> URLRequest {
        guard let token else { throw APIError.notPaired }
        guard let url = URL(string: baseURL + path) else { throw APIError.message("Server address is wrong") }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Sorted keys: a replay must send the same bytes, or the server refuses the reused key.
            let enc = JSONEncoder()
            enc.outputFormatting = .sortedKeys
            r.httpBody = try enc.encode(body)
        }
        if tap {
            r.setValue("tap", forHTTPHeaderField: "X-User-Action")
            r.setValue(key ?? UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
            if lookup { r.setValue("1", forHTTPHeaderField: "Idempotency-Lookup") }
        }
        return r
    }

    private func send<T: Decodable>(_ r: URLRequest, as: T.Type) async throws -> T {
        let (data, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 409, let nc = try? JSONDecoder().decode(NeedsConfirm.self, from: data), nc.needs_confirm {
            throw APIError.needsConfirm(recipient: nc.recipient)
        }
        guard (200..<300).contains(code) else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func suggest(_ text: String, context: String? = nil) async throws -> SuggestResponse {
        var body = ["text": text]
        if let context { body["context"] = context }
        return try await send(request("POST", "/v1/suggest", body: body), as: SuggestResponse.self)
    }

    /// One free-form request from the Ask bar. The server only routes it; it never moves money.
    func ask(_ text: String) async throws -> AskResponse {
        try await send(request("POST", "/v1/ask", body: ["text": text], tap: true), as: AskResponse.self)
    }

    func invoice(_ payload: [String: JSONValue], key: String, lookup: Bool) async throws -> InvoiceResponse {
        try await send(request("POST", "/v1/actions/invoice", body: payload, tap: true, key: key, lookup: lookup), as: InvoiceResponse.self)
    }

    func payLink(_ payload: [String: JSONValue], key: String, lookup: Bool) async throws -> PayLinkResponse {
        // The paylink route is strict: send only the fields it accepts.
        let keys: Set = ["amount", "currency", "item", "client_name"]
        let body = payload.filter { keys.contains($0.key) && $0.value != .null }
        return try await send(request("POST", "/v1/actions/paylink", body: body, tap: true, key: key, lookup: lookup), as: PayLinkResponse.self)
    }

    func remind(invoiceID: String, confirmClient: String?, key: String, lookup: Bool) async throws -> RemindResponse {
        var body = ["invoice_id": invoiceID]
        if let confirmClient { body["confirm_client"] = confirmClient }
        return try await send(request("POST", "/v1/actions/remind", body: body, tap: true, key: key, lookup: lookup), as: RemindResponse.self)
    }

    /// `body` is {id, amount} to get a confirm token, or {confirm_token} to run the refund.
    func refund(_ body: [String: JSONValue], key: String, lookup: Bool) async throws -> RefundResponse {
        try await send(request("POST", "/v1/actions/refund", body: body, tap: true, key: key, lookup: lookup), as: RefundResponse.self)
    }

    func reply(_ text: String) async throws -> ReplyResponse {
        try await send(request("POST", "/v1/reply", body: ["text": text]), as: ReplyResponse.self)
    }

    // Writing help. Each call starts from a tap, and the server refuses it without the tap header.
    func fix(_ text: String) async throws -> WriteResponse {
        try await send(request("POST", "/v1/write/fix", body: ["text": text], tap: true), as: WriteResponse.self)
    }

    func refine(_ text: String, tone: String) async throws -> WriteResponse {
        try await send(request("POST", "/v1/write/refine", body: ["text": text, "tone": tone], tap: true), as: WriteResponse.self)
    }

    func toneCheck(draft: String, client: String?) async throws -> ToneResponse {
        var body: [String: String] = [:]
        if !draft.isEmpty { body["text"] = draft }
        if let client { body["context"] = client }
        return try await send(request("POST", "/v1/write/tone", body: body, tap: true), as: ToneResponse.self)
    }

    func summary() async throws -> Summary {
        try await send(request("GET", "/v1/summary"), as: Summary.self)
    }

    func payments() async throws -> [Payment] {
        try await send(request("GET", "/v1/payments"), as: PaymentsResponse.self).payments
    }

    func brief() async throws -> Brief { try await send(request("GET", "/v1/brief"), as: Brief.self) }
    func clients() async throws -> [Client] { try await send(request("GET", "/v1/clients"), as: ClientsResponse.self).clients }
    func transactions(range: String = "today") async throws -> TransactionsResponse {
        try await send(request("GET", "/v1/transactions?range=\(range)"), as: TransactionsResponse.self)
    }
    func disputes() async throws -> [Dispute] { try await send(request("GET", "/v1/disputes"), as: DisputesResponse.self).disputes }
    func integrations() async throws -> [Integration] {
        try await send(request("GET", "/v1/integrations"), as: IntegrationsResponse.self).integrations
    }
}

/// "$1,284" and ".50", for numbers set as value plus dimmed cents.
func moneyParts(_ amount: String, _ currency: String) -> (whole: String, cents: String) {
    let symbols = ["USD": "$", "CAD": "CA$", "AUD": "A$", "EUR": "€", "GBP": "£"]
    let parts = amount.split(separator: ".", maxSplits: 1).map(String.init)
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = Locale(identifier: "en_US")
    let whole = f.string(from: NSNumber(value: Int(parts.first ?? "0") ?? 0)) ?? (parts.first ?? "0")
    let cents = parts.count > 1 ? "." + parts[1] : ""
    return ((symbols[currency] ?? currency + " ") + whole, cents)
}

/// The USD total if there is one, else the first currency. Nil when empty.
func mainTotal(_ totals: [String: String]?) -> (amount: String, currency: String)? {
    guard let totals, !totals.isEmpty else { return nil }
    if let usd = totals["USD"] { return (usd, "USD") }
    let k = totals.keys.sorted()[0]
    return (totals[k]!, k)
}
