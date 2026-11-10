import SwiftUI

@main
struct MuninnApp: App {
    @StateObject private var session = Session()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .preferredColorScheme(.dark)
                .onOpenURL { session.handle(url: $0) }
        }
    }
}

@MainActor
final class Session: ObservableObject {
    @Published var paired = SharedStore.deviceToken != nil
    /// True from a fresh start until the last onboarding step. A signed-in relaunch starts false, so onboarding never shows again.
    @Published var onboarding = SharedStore.deviceToken == nil
    @Published var serverURL = SharedStore.serverURL
    @Published var error: String?

    /// One tap: the server checks the Apple identity token and returns the device token. The token never shows on screen.
    func signInWithApple(identityToken: String, nonce: String) async -> Bool {
        let server = SharedStore.serverURL
        do {
            let token = try await APIClient.appleSignIn(baseURL: server, identityToken: identityToken, nonce: nonce)
            return save(token: token, server: server)
        } catch let e as APIError {
            if case .http(let code, _) = e { error = "Sign-in did not work (error \(code)). Try again." } else { error = "Sign-in did not work. Try again." }
        } catch {
            self.error = "Cannot reach Muninn. Check your connection and try again."
        }
        return false
    }

    /// Developer path: pair with a device token from `npm run device`.
    @discardableResult
    func pair(token: String, server: String) async -> Bool {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        do {
            _ = try await APIClient(baseURL: server, token: token).summary()
        } catch {
            self.error = "Pairing failed: \(error.localizedDescription)"
            return false
        }
        return save(token: token, server: server)
    }

    /// Writes the token to the shared Keychain and reads it back. A failed write shows an error; it never passes silently.
    private func save(token: String, server: String) -> Bool {
        SharedStore.serverURL = server
        let status = SharedStore.setDeviceToken(token)
        guard status == errSecSuccess, SharedStore.deviceToken == token else {
            error = "Could not save your sign-in on this phone (Keychain \(status)). Try again."
            return false
        }
        serverURL = server
        // Cached brief and seen payments belong to the old account.
        for key in ["brief_cache", "brief_cache.at", "known_paid_ids"] { UserDefaults.standard.removeObject(forKey: key) }
        error = nil
        paired = true
        return true
    }

    func finishOnboarding() { onboarding = false }

    func unpair() {
        SharedStore.setDeviceToken(nil)
        error = nil
        onboarding = true
        paired = false
    }

    /// Dev only: `xcrun simctl openurl <sim> "muninn-dev://pair?token=...&server=..."`. It goes straight to Home.
    /// Release builds ignore it, so no web page can pair the app to another server.
    func handle(url: URL) {
        #if DEBUG
        guard url.scheme == "muninn-dev", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let token = items.first(where: { $0.name == "token" })?.value else { return }
        let server = items.first(where: { $0.name == "server" })?.value ?? AppConfig.defaultServerURL
        Task { if await pair(token: token, server: server) { finishOnboarding() } }
        #endif
    }
}

struct RootView: View {
    @EnvironmentObject var session: Session

    var body: some View {
        NavigationStack {
            Group {
                if session.paired && !session.onboarding { HomeView().transition(.opacity) } else { OnboardingView().transition(.opacity) }
            }
            .background(Theme.Color.bg.ignoresSafeArea())
        }
    }
}
