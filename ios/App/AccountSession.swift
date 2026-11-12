import Foundation

/// Sign-in with Apple or email, log out and delete. docs/AUTH-AND-WIPE.md lists what log out wipes.
extension Session {
    /// "Continue with Apple" on the sign-in step: POST /v1/auth/apple. Nil on success, else one plain line.
    func signInWithApple(identityToken: String, nonce: String) async -> String? {
        do {
            let token = try await APIClient.appleSignIn(baseURL: signInServer, identityToken: identityToken, nonce: nonce)
            guard save(token: token, server: signInServer) else { return error }
            SharedStore.appleLinked = true
            appleLinked = true
            signInNext = false
            return nil
        } catch {
            return Self.appleLine(error)
        }
    }

    /// "Continue with email": sign up or log in. Nil on success, else one plain line.
    func signInWithEmail(_ mode: APIClient.EmailMode, email: String, password: String) async -> String? {
        do {
            let token = try await APIClient.emailSignIn(baseURL: signInServer, mode: mode, email: email, password: password)
            guard save(token: token, server: signInServer) else { return error }
            signInNext = false
            return nil
        } catch {
            return Self.authLine(error)
        }
    }

    /// Settings, "Add an email": adds an email and password to this account. If the email had its own account, the app switches to it.
    func linkEmail(email: String, password: String) async -> String? {
        do {
            let r = try await APIClient.shared().linkEmail(email: email, password: password)
            if r.recovered {
                guard let token = r.device_token, save(token: token, server: SharedStore.serverURL) else { return "Could not save your account on this phone. Try again." }
                notice = "Welcome back. You are in the account for \(email)."
            }
            return nil
        } catch {
            return Self.authLine(error)
        }
    }

    /// Log out: the server ends this token, then the phone forgets everything of this user and opens the sign-in step.
    /// The wipe runs even when the server cannot be reached, so the phone never keeps the old user's data.
    func logout() async {
        try? await APIClient.shared().logout()
        await wipeAndSignOut()
    }

    /// Delete account: the server deletes every row of this user (DELETE /v1/account, from a tap). Nil on success, then the same wipe as log out.
    func deleteAccount() async -> String? {
        do {
            try await APIClient.shared().deleteAccount()
        } catch {
            return plainLine(error)
        }
        await wipeAndSignOut()
        return nil
    }

    /// Every store in docs/AUTH-AND-WIPE.md, then back to sign-in.
    func wipeAndSignOut() async {
        PayPalConnector.shared.reset()
        CalendarModel.shared.reset()
        await LocalWipe.device()
        appleLinked = false
        notice = nil
        error = nil
        serverURL = SharedStore.serverURL
        account += 1
        signInNext = true
        logouts += 1
        onboarding = true
        paired = false
    }

    /// One plain line for a failed Apple sign-in. A refused Apple token is not a wrong password.
    nonisolated static func appleLine(_ error: Error) -> String {
        if case APIError.http(401, _) = error { return "Apple sign-in didn't work. Try again." }
        return authLine(error)
    }

    /// The server refused this phone's token (expired or ended elsewhere): the same wipe as log out, back to sign-in.
    /// A late answer for an older token, or a second one while the wipe runs, does nothing.
    func tokenRejected(_ token: String) async {
        guard !signingOut, paired, token == SharedStore.deviceToken else { return }
        signingOut = true
        await wipeAndSignOut()
        signingOut = false
    }

    /// One plain line for a failed sign-in: wrong password, too many tries, a weak password, an email that has an account.
    nonisolated static func authLine(_ error: Error) -> String {
        switch error {
        case APIError.http(401, _): return "Wrong email or password."
        case APIError.http(429, _): return "Too many tries. Wait a few minutes, then try again."
        case APIError.http(409, let body) where body.contains("log in"): return "This email already has an account. Log in instead."
        case APIError.http(400, _): return plainLine(error)
        case is URLError: return "Cannot reach \(AppConfig.displayName). Check your connection and try again."
        default: return plainLine(error)
        }
    }
}
