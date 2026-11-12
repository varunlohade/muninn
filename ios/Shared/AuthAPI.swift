import Foundation

/// GET /v1/account: how this account signs in.
struct AccountInfo: Decodable, Equatable {
    let email: String?
    let apple: Bool
    let password: Bool
}

/// POST /v1/auth/email/link. `recovered`: the email already had an account; `device_token` is then that account's token.
struct EmailLinkResponse: Decodable, Equatable { let linked: Bool; let recovered: Bool; let device_token: String? }

/// Sign-in, sign-up, logout and the account (server/src/app.ts). Sign-in calls carry no token.
extension APIClient {
    enum EmailMode: String { case signup, login }

    /// POST /v1/auth/email/signup or /login. Returns the new device token.
    static func emailSignIn(baseURL: String, mode: EmailMode, email: String, password: String) async throws -> String {
        let r = try open("POST", baseURL, "/v1/auth/email/\(mode.rawValue)", body: ["email": email, "password": password])
        return try await APIClient(baseURL: baseURL).send(r, as: DeviceAuthResponse.self).device_token
    }

    /// GET /v1/auth/apple/nonce: a one-time nonce from the server. Nil when the server has none (an older server).
    static func appleNonce(baseURL: String) async -> String? {
        struct Out: Decodable { let nonce: String }
        guard let r = try? open("GET", baseURL, "/v1/auth/apple/nonce") else { return nil }
        return try? await APIClient(baseURL: baseURL).send(r, as: Out.self).nonce
    }

    /// POST /v1/auth/apple: signs in with Apple. Returns the new device token.
    static func appleSignIn(baseURL: String, identityToken: String, nonce: String) async throws -> String {
        let r = try open("POST", baseURL, "/v1/auth/apple", body: ["identity_token": identityToken, "nonce": nonce])
        return try await APIClient(baseURL: baseURL).send(r, as: DeviceAuthResponse.self).device_token
    }

    /// A request with no device token.
    private static func open(_ method: String, _ baseURL: String, _ path: String, body: [String: String]? = nil) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else { throw APIError.message("Server address is wrong") }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.httpMethod = method
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONEncoder().encode(body)
        }
        return r
    }

    func account() async throws -> AccountInfo { try await send(request("GET", "/v1/account"), as: AccountInfo.self) }

    func linkEmail(email: String, password: String) async throws -> EmailLinkResponse {
        try await send(request("POST", "/v1/auth/email/link", body: ["email": email, "password": password]), as: EmailLinkResponse.self)
    }

    /// POST /v1/auth/logout: the server deletes this token, so it stops working at once.
    func logout() async throws {
        struct Out: Decodable { let logged_out: Bool }
        _ = try await send(request("POST", "/v1/auth/logout"), as: Out.self)
    }

    /// DELETE /v1/account, only from a tap: X-User-Action: tap.
    func deleteAccount() async throws {
        struct Out: Decodable { let deleted: Bool }
        _ = try await send(request("DELETE", "/v1/account", tap: true), as: Out.self)
    }
}
