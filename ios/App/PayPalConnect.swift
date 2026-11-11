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

    var connected: Bool { status?.connected == true }

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

    /// Disconnect only forgets the account here. The grant lives on in PayPal until the owner revokes it there.
    nonisolated static let disconnectNote = "New invoices go to the demo account until you connect again. To fully remove access, also revoke Muninn in your PayPal settings."

    /// The Integrations and Home line for this status.
    nonisolated static func summary(_ s: PayPalStatus?) -> String {
        guard let s, s.connected else { return "Demo PayPal (sandbox)" }
        let who = s.account.map { "PayPal connected \u{00B7} \($0)" } ?? "PayPal connected"
        return s.email_confirmed ? who : who + ". Confirm your PayPal email to get paid."
    }
}

/// Home: shown while money runs on the demo account. Text only, no PayPal logo. Home loads the status.
struct ConnectPayPalCard: View {
    @ObservedObject private var paypal = PayPalConnector.shared

    var body: some View {
        if let s = paypal.status, !s.connected {
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(spacing: Theme.Space.s) {
                        IconCircle(systemImage: "dollarsign")
                        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                            Text("Connect PayPal").font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                            Text("You are on the demo account. Connect your PayPal to get paid.").font(Theme.Font.label)
                                .foregroundStyle(Theme.Color.text2).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        AskChip(title: paypal.busy ? "One moment\u{2026}" : "Connect", detail: nil) { Task { await paypal.connect() } }
                            .disabled(paypal.busy)
                            .accessibilityIdentifier("home.paypal.connect")
                    }
                    if let note = paypal.note {
                        Text(note).font(Theme.Font.label).foregroundStyle(Theme.Color.due).fixedSize(horizontal: false, vertical: true)
                    }
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

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    IconCircle(systemImage: "dollarsign")
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        Text("PayPal").font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                        Text(PayPalConnector.summary(paypal.status)).font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("paypal.summary")
                    }
                    Spacer(minLength: 0)
                    if paypal.connected {
                        Image(systemName: "checkmark").foregroundStyle(Theme.Color.paid).accessibilityLabel("Connected")
                    } else if paypal.status != nil {
                        AskChip(title: paypal.busy ? "One moment\u{2026}" : "Connect", detail: nil) { Task { await paypal.connect() } }
                            .disabled(paypal.busy)
                            .accessibilityIdentifier("paypal.connect")
                    }
                }
                if let note = paypal.note {
                    Text(note).font(Theme.Font.label).foregroundStyle(Theme.Color.due).fixedSize(horizontal: false, vertical: true)
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
            VStack(spacing: Theme.Space.m) {
                Text("Use this PayPal account?").font(Theme.Font.title).foregroundStyle(Theme.Color.text1)
                Text(paypal.confirming ?? "").font(Theme.Font.body).foregroundStyle(Theme.Color.text2)
                    .accessibilityIdentifier("paypal.confirm.account")
                Button("Use this account") { paypal.decide(true) }
                    .buttonStyle(PrimaryButton())
                    .accessibilityIdentifier("paypal.confirm.use")
                Button("Not now") { paypal.decide(false) }
                    .font(Theme.Font.body).foregroundStyle(Theme.Color.text2)
                    .frame(maxWidth: .infinity, minHeight: Theme.Metric.secondaryButton)
            }
            .padding(Theme.Metric.margin)
            .presentationDetents([.height(280)])
        }
    }
}

extension View {
    func paypalConfirmSheet() -> some View { modifier(PayPalConfirmSheet()) }
}
