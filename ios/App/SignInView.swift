import AuthenticationServices
import CryptoKit
import SwiftUI

/// The sign-in step: "Continue with Apple" or "Continue with email". PayPal is not a way in; it is linked later.
/// "Try without an account" keeps the device account for a quick look.
struct SignInOptions: View {
    @EnvironmentObject var session: Session
    @Environment(\.colorScheme) private var colorScheme
    /// Runs once the phone holds the new token.
    let onSignedIn: () async -> Void
    let onTry: () async -> Void
    @State private var nonce: String?
    @State private var sent = ""
    @State private var busy = false
    @State private var error: String?
    @State private var emailOpen = false

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            if let error {
                Text(error).font(Theme.Font.label).foregroundStyle(Theme.Color.due)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("signin.apple.error")
            }
            SignInWithAppleButton(.continue) { request in
                error = nil
                sent = nonce ?? AppleNonce.random()
                nonce = nil
                request.requestedScopes = []
                request.nonce = AppleNonce.sha256(sent)
            } onCompletion: { result in
                Task { await finished(result) }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: Theme.Metric.primaryButton)
            .clipShape(Capsule())
            .opacity(busy ? 0.5 : 1)
            .disabled(busy)
            .accessibilityIdentifier("signin.apple")
            Button("Continue with email") { error = nil; emailOpen = true }
                .buttonStyle(PrimaryButton())
                .accessibilityIdentifier("signin.email")
            Button("Try without an account") { Task { await onTry() } }
                .font(Theme.Font.body).foregroundStyle(Theme.Color.text2)
                .frame(maxWidth: .infinity, minHeight: Theme.Metric.secondaryButton)
                .accessibilityIdentifier("onboarding.start")
        }
        .task(id: nonce == nil) { if nonce == nil { nonce = await AppleNonce.fetch(baseURL: session.signInServer) } }
        .sheet(isPresented: $emailOpen) {
            EmailAuthForm { emailOpen = false; Task { await onSignedIn() } }
        }
    }

    private func finished(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .failure(let e):
            if (e as? ASAuthorizationError)?.code != .canceled { error = "Apple sign-in did not finish. Try again." }
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let token = cred.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else {
                error = "Apple sign-in did not finish. Try again."
                return
            }
            busy = true
            error = await session.signInWithApple(identityToken: token, nonce: sent)
            busy = false
            if error == nil { await onSignedIn() }
        }
    }
}

/// Sign up or log in with an email and a password. The server's answer becomes one plain line under the button.
struct EmailAuthForm: View {
    @EnvironmentObject var session: Session
    var mode: APIClient.EmailMode = .signup
    /// Settings, "Add an email": links to the signed-in account instead of signing in.
    var link = false
    let onDone: () -> Void
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var picked: APIClient.EmailMode?

    private var current: APIClient.EmailMode { picked ?? mode }
    private var cleanEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var ready: Bool { cleanEmail.contains("@") && !password.isEmpty && !busy }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(link ? "Add an email" : current == .signup ? "Create your account" : "Log in")
                .font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
            if !link {
                Picker("", selection: Binding(get: { current }, set: { picked = $0; error = nil })) {
                    Text("Create account").tag(APIClient.EmailMode.signup)
                    Text("Log in").tag(APIClient.EmailMode.login)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("signin.mode")
            }
            TextField("", text: $email, prompt: Text("Email").foregroundStyle(Theme.Color.text3))
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                .textContentType(.username)
                .modifier(FieldStyle())
                .accessibilityIdentifier("signin.field.email")
            SecureField("", text: $password, prompt: Text("Password").foregroundStyle(Theme.Color.text3))
                .textContentType(current == .signup || link ? .newPassword : .password)
                .modifier(FieldStyle())
                .accessibilityIdentifier("signin.field.password")
            if current == .signup || link {
                Text("At least 8 characters.").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
            }
            if let error {
                Text(error).font(Theme.Font.label).foregroundStyle(Theme.Color.due)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("signin.error")
            }
            Button(busy ? "One moment\u{2026}" : link ? "Add email" : current == .signup ? "Create account" : "Log in") {
                Task { await submit() }
            }
            .buttonStyle(PrimaryButton())
            .opacity(ready ? 1 : 0.5)
            .disabled(!ready)
            .accessibilityIdentifier("signin.submit")
            Spacer(minLength: 0)
        }
        .padding(Theme.Metric.cardPadding)
        .padding(.top, Theme.Space.xs)
        .background(Theme.Color.bg.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func submit() async {
        error = nil
        busy = true
        error = link ? await session.linkEmail(email: cleanEmail, password: password)
            : await session.signInWithEmail(current, email: cleanEmail, password: password)
        busy = false
        if error == nil { password = ""; onDone() }
    }
}

/// The Sign in with Apple nonce. The server gives a one-time nonce (GET /v1/auth/apple/nonce); an older server has none,
/// and then the phone makes a random one.
enum AppleNonce {
    static func fetch(baseURL: String) async -> String {
        await APIClient.appleNonce(baseURL: baseURL) ?? random()
    }

    static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
