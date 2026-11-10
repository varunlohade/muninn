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

struct InvoiceResponse: Decodable { let id: String; let status: String; let pay_link: String? }
struct PayLinkResponse: Decodable { let id: String; let status: String; let approve_link: String? }
struct NeedsConfirm: Decodable { let needs_confirm: Bool; let recipient: String }

struct Summary: Decodable {
    let earned_today: [String: String]
    let earned_this_week: [String: String]
    let unpaid_count: Int
}

struct Payment: Decodable, Identifiable {
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

    func suggest(_ text: String) async throws -> SuggestResponse {
        try await send(request("POST", "/v1/suggest", body: ["text": text]), as: SuggestResponse.self)
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
}
