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

struct Chip: Decodable, Hashable, Identifiable {
    let kind: String
    let label: String
    let payload: [String: JSONValue]
    let needs_confirm: Bool
    var id: String { kind + label }
}

struct SuggestResponse: Decodable {
    let chips: [Chip]
    let intent: String
    let timings: [String: Int]?
}

struct InvoiceResponse: Decodable { let id: String; let status: String; let pay_link: String?; let amount: String; let currency: String }
struct PayLinkResponse: Decodable { let id: String; let status: String; let approve_link: String? }
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

    var errorDescription: String? {
        switch self {
        case .notPaired: "Not paired"
        case .needsConfirm(let r): "Confirm \(r)"
        case .http(let code, let body): "HTTP \(code): \(body.prefix(120))"
        }
    }
}

struct APIClient {
    var baseURL: String
    var token: String?
    var session: URLSession = .shared

    static func shared() -> APIClient {
        APIClient(baseURL: SharedStore.serverURL, token: SharedStore.deviceToken)
    }

    private func request(_ method: String, _ path: String, body: Encodable? = nil, tap: Bool = false) throws -> URLRequest {
        guard let token else { throw APIError.notPaired }
        guard let url = URL(string: baseURL + path) else { throw APIError.http(0, "bad server URL") }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONEncoder().encode(body)
        }
        if tap {
            r.setValue("tap", forHTTPHeaderField: "X-User-Action")
            r.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
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

    func invoice(_ payload: [String: JSONValue]) async throws -> InvoiceResponse {
        try await send(request("POST", "/v1/actions/invoice", body: payload, tap: true), as: InvoiceResponse.self)
    }

    func payLink(_ payload: [String: JSONValue]) async throws -> PayLinkResponse {
        // The paylink route is strict: send only the fields it accepts.
        let keys: Set = ["amount", "currency", "item", "client_name"]
        let body = payload.filter { keys.contains($0.key) && $0.value != .null }
        return try await send(request("POST", "/v1/actions/paylink", body: body, tap: true), as: PayLinkResponse.self)
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
