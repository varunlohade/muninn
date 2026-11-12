import AuthenticationServices
import SwiftUI

/// Connect PayPal: the server makes a PayPal sign-up link, the owner signs in on PayPal's own page,
/// and PayPal sends the browser back to the server, which sends it on to `muninn://paypal-connected?code=…`
/// (or `?result=…` when it did not work). The app shows the account that came back; "Use this account" finishes with the code.
@MainActor
final class PayPalConnector: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = PayPalConnector()

    @Published private(set) var status: PayPalStatus?
    @Published private(set) var busy = false
    /// One plain line after a connect, or nil.
    @Published var note: String?
    /// The masked PayPal account waiting for "Use this account", or nil.
    @Published private(set) var confirming: String?
    private var decision: CheckedContinuation<Bool, Never>?
    private var web: ASWebAuthenticationSession?

    /// The server said it cannot connect an own PayPal (503). Connect stays hidden until the next app start.
    @Published private(set) var unavailable = false

    var connected: Bool { status?.connected == true }

    /// Connect shows only once the status is in and the server can connect an own PayPal.
    var canConnect: Bool { status != nil && !connected && !unavailable && status?.connect_ready != false }

    func refresh() async {
        if let s = try? await APIClient.shared().paypalStatus() { status = s }
    }

    /// True when the owner's PayPal is connected at the end.
    @discardableResult
    func connect() async -> Bool {
        busy = true
        note = nil
        defer { busy = false }
        do {
            let start = try await APIClient.shared().paypalConnect()
            guard let url = URL(string: start.action_url) else { note = Self.line(for: "failed"); return false }
            let back = try await open(url, scheme: start.return_scheme)
            if let code = Self.code(of: back) {
                let pending = try await APIClient.shared().paypalPending(code: code)
                if await ask(pending.account ?? "your PayPal account") { try await APIClient.shared().paypalFinish(code: code) }
            } else {
                note = Self.line(for: Self.result(of: back))
            }
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            // A cancel is the owner's choice, so it shows no error.
        } catch APIError.http(503, _) {
            // The server cannot connect an own PayPal yet. Say so once, and hide Connect.
            unavailable = true
            note = Self.offLine
        } catch {
            note = plainLine(error)
        }
        await refresh()
        return connected
    }

    /// Shows the account and waits for the owner's answer.
    private func ask(_ account: String) async -> Bool {
        await withCheckedContinuation { cont in
            decision = cont
            confirming = account
        }
    }

    /// "Use this account" (true) or "Not now" (false).
    func decide(_ use: Bool) {
        confirming = nil
        decision?.resume(returning: use)
        decision = nil
    }

    /// Log out: forget the last user's PayPal state. A connect still waiting gets "no".
    func reset() {
        decide(false)
        web?.cancel()
        web = nil
        status = nil
        note = nil
        busy = false
    }

    func disconnect() async {
        busy = true
        defer { busy = false }
        do {
            try await APIClient.shared().paypalDisconnect()
            note = nil
        } catch {
            note = plainLine(error)
        }
        await refresh()
    }

    private func open(_ url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback { cont.resume(returning: callback) } else { cont.resume(throwing: error ?? ASWebAuthenticationSessionError(.canceledLogin)) }
            }
            s.presentationContextProvider = self
            web = s
            s.start()
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    /// The one-time code the server put on a good return link.
    nonisolated static func code(of url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The `result` the server put on the return link: declined or failed.
    nonisolated static func result(of url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "result" })?.value ?? "failed"
    }

    nonisolated static func line(for result: String) -> String? {
        switch result {
        case "connected": nil
        case "declined": "PayPal was not connected. Allow the permissions on PayPal to connect."
        case "taken": "That PayPal account is already connected to another Muninn account."
        default: "PayPal did not finish. Try again."
        }
    }

    /// The one line while the server cannot connect an own PayPal. The server's 503 says the same.
    nonisolated static let offLine = "Your own PayPal is not open yet. Money runs on the demo PayPal sandbox account."

    /// The PayPal sandbox site: sign in with a sandbox account to see the demo money arrive.
    nonisolated static let sandboxURL = URL(string: "https://www.sandbox.paypal.com")!

    /// Disconnect only forgets the account here. The grant lives on in PayPal until the owner revokes it there.
    nonisolated static let disconnectNote = "New invoices go to the demo account until you connect again. To fully remove access, also revoke Muninn in your PayPal settings."

    /// The Integrations and Home line for this status.
    nonisolated static func summary(_ s: PayPalStatus?) -> String {
        guard let s, s.connected else { return "Demo PayPal (sandbox)" }
        let who = s.account.map { "PayPal connected \u{00B7} \($0)" } ?? "PayPal connected"
        return s.email_confirmed ? who : who + ". Confirm your PayPal email to get paid."
    }
}

/// Home: shown while money runs on the demo account. The pixel sky card, no PayPal logo. Home loads the status.
struct ConnectPayPalCard: View {
    @ObservedObject private var paypal = PayPalConnector.shared

    var body: some View {
        // Only while Connect can work, or to show its one line once. A server that cannot connect shows no card.
        if !paypal.connected, paypal.canConnect || paypal.note != nil {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                PixelBanner(first: "Get paid in any chat.", rest: "Every invoice gets a pay link.") {
                    if paypal.canConnect {
                        Button(paypal.busy ? "One moment\u{2026}" : "Connect PayPal") { Task { await paypal.connect() } }
                            .buttonStyle(TactileButton(kind: .light, small: true, wide: false))
                            .disabled(paypal.busy)
                            .accessibilityIdentifier("home.paypal.connect")
                    }
                }
                if let note = paypal.note {
                    Text(note).font(Theme.Font.label).foregroundStyle(Theme.Color.due).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                }
            }
            .padding(.horizontal, Theme.Metric.cardInset)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.paypal")
        }
    }
}

/// Integrations: the PayPal row. Connect while on the demo account; Disconnect once connected.
struct PayPalIntegrationRow: View {
    @ObservedObject private var paypal = PayPalConnector.shared
    @State private var confirmDisconnect = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Image("PixelThumb").resizable().interpolation(.none).frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        Text("PayPal").font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                        if paypal.connected {
                            Text(PayPalConnector.summary(paypal.status)).font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("paypal.summary")
                        } else {
                            // The demo account lives on PayPal's sandbox site; a tap opens it in Safari.
                            Button { openURL(PayPalConnector.sandboxURL) } label: {
                                HStack(spacing: 3) {
                                    Text(PayPalConnector.summary(paypal.status))
                                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                                }
                                .font(Theme.Font.label).foregroundStyle(Theme.Color.booked)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open the PayPal sandbox site")
                            .accessibilityIdentifier("paypal.summary")
                        }
                    }
                    Spacer(minLength: 0)
                    if paypal.connected {
                        StatusPill(text: "Connected", tone: .paid)
                    } else if paypal.canConnect {
                        AskChip(title: paypal.busy ? "One moment\u{2026}" : "Connect", detail: nil) { Task { await paypal.connect() } }
                            .disabled(paypal.busy)
                            .accessibilityIdentifier("paypal.connect")
                    }
                }
                if let note = paypal.note {
                    Text(note).font(Theme.Font.label).foregroundStyle(Theme.Color.due).fixedSize(horizontal: false, vertical: true)
                } else if paypal.status != nil, !paypal.connected, !paypal.canConnect {
                    Text(PayPalConnector.offLine).font(Theme.Font.label).foregroundStyle(Theme.Color.text2).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("paypal.off")
                }
                if paypal.connected {
                    AskChip(title: "Disconnect", detail: nil) { confirmDisconnect = true }
                        .accessibilityIdentifier("paypal.disconnect")
                }
            }
        }
        .confirmationDialog("Disconnect PayPal?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { Task { await paypal.disconnect() } }
        } message: {
            Text(PayPalConnector.disconnectNote)
        }
        .task { await paypal.refresh() }
    }
}

/// The PayPal account that came back from sign-in. Nothing connects until the owner taps "Use this account".
struct PayPalConfirmSheet: ViewModifier {
    @ObservedObject private var paypal = PayPalConnector.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { paypal.confirming != nil }, set: { if !$0 { paypal.decide(false) } })) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Use this PayPal account?").font(Theme.Font.sans(20)).foregroundStyle(Theme.Color.text1)
                    Spacer()
                    StatusPill(text: "Needs your OK", tone: .due)
                }
                Text(paypal.confirming ?? "").font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                    .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading).cardSurface()
                    .accessibilityIdentifier("paypal.confirm.account")
                Button("Use this account") { paypal.decide(true) }
                    .buttonStyle(PrimaryButton())
                    .accessibilityIdentifier("paypal.confirm.use")
                Button("Not now") { paypal.decide(false) }
                    .font(Theme.Font.sans(15)).foregroundStyle(Theme.Color.text2)
                    .frame(maxWidth: .infinity, minHeight: Theme.Metric.secondaryButton)
            }
            .padding(Theme.Metric.margin)
            .presentationBackground(Theme.Color.bg)
            .presentationDetents([.height(280)])
        }
    }
}

extension View {
    func paypalConfirmSheet() -> some View { modifier(PayPalConfirmSheet()) }
}
