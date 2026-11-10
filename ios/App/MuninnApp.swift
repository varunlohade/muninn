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
    @Published var serverURL = SharedStore.serverURL
    @Published var error: String?

    func pair(token: String, server: String) async {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        do {
            _ = try await APIClient(baseURL: server, token: token).summary()
        } catch {
            self.error = "Pairing failed: \(error.localizedDescription)"
            return
        }
        SharedStore.serverURL = server
        let status = SharedStore.setDeviceToken(token)
        guard status == errSecSuccess else { self.error = "Keychain error \(status)"; return }
        serverURL = server
        error = nil
        paired = true
    }

    func unpair() {
        SharedStore.setDeviceToken(nil)
        paired = false
    }

    /// Dev only: `xcrun simctl openurl <sim> "muninn-dev://pair?token=...&server=..."`.
    /// Release builds ignore it, so no web page can pair the app to another server.
    func handle(url: URL) {
        #if DEBUG
        guard url.scheme == "muninn-dev", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let token = items.first(where: { $0.name == "token" })?.value else { return }
        let server = items.first(where: { $0.name == "server" })?.value ?? AppConfig.defaultServerURL
        Task { await pair(token: token, server: server) }
        #endif
    }
}

struct RootView: View {
    @EnvironmentObject var session: Session

    var body: some View {
        NavigationStack {
            Group {
                if session.paired { HomeView() } else { OnboardingView() }
            }
            .background(Theme.Color.bg.ignoresSafeArea())
        }
    }
}
