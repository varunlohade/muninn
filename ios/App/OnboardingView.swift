import AuthenticationServices
import CryptoKit
import SwiftUI

/// One scene of the "try it" intro: the owner does one thing with the real keyboard and sees the result.
/// To add a scene (Fix, Refine, Tone check), add one value to `IntroScene.all`. The flow needs no other change.
struct IntroScene: Identifiable {
    let id: String
    /// One line that says what to do.
    let prompt: String
    /// What the main button types for the owner.
    let example: String
    /// One line shown when the scene succeeds.
    let result: String
    /// True once the keyboard has done its work. It gets the keyboard model and the text in the message field.
    let succeeded: @MainActor (KeyboardModel, String) -> Bool

    static let all: [IntroScene] = [
        IntroScene(id: "paylink", prompt: "Type a price, or tap the button.", example: "$45 for the cut",
                   result: "A real PayPal link, in one tap.", succeeded: { model, _ in model.watch != nil }),
    ]
}

/// One short flow: Continue with Apple, turn on the keyboard, try it, Home.
/// Each step fits one screen and has one main button. The mark stays on screen and moves between steps.
struct OnboardingView: View {
    enum Step: Int, CaseIterable { case signIn, keyboard, tryIt }
    static let tryTimeout: Duration = .seconds(8)

    @EnvironmentObject var session: Session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// The real keyboard view and model, typing into a string on this screen. Its calls go to the real server.
    @StateObject private var typing = LabHost()
    @State private var step: Step = .signIn
    @State private var checked = false
    @State private var busy = false
    @State private var nonce = ""
    @State private var showDevPairing = false
    @State private var sceneIndex = 0
    @State private var tryTimedOut = false
    @State private var tryTimer: Task<Void, Never>?

    private var title: String {
        switch step {
        case .signIn: "Get paid from any chat"
        case .keyboard: "Turn on the keyboard"
        case .tryIt: checked ? "Got it" : "Try it"
        }
    }
    private var line: String {
        switch step {
        case .signIn: "\(AppConfig.displayName) suggests the invoice while you type."
        case .keyboard: "Three taps in Settings. Then come back."
        case .tryIt: tryLine
        }
    }
    private var stepMotion: Animation { reduceMotion ? Theme.Motion.crossfade : Theme.Motion.onboardingStep }
    private var slide: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                              removal: .move(edge: .leading).combined(with: .opacity))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                StepDots(count: Step.allCases.count, current: step.rawValue)
                    .padding(.top, 16)
                Spacer(minLength: 0).frame(maxHeight: step == .signIn ? .infinity : 36)
                mark
                VStack(spacing: 10) {
                    Text(title).font(Theme.Font.title).foregroundStyle(Theme.Color.text1)
                    Text(line).font(Theme.Font.body).foregroundStyle(Theme.Color.text2)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    if step == .keyboard { keyboardSteps.padding(.top, 18) }
                    if step == .tryIt { messageField.padding(.top, 18) }
                }
                .padding(.top, 24)
                .id(step == .tryIt ? scene.id : "\(step)")
                .transition(slide)
                Spacer(minLength: 16).frame(maxHeight: .infinity)
                if let error = session.error {
                    Text(error).font(Theme.Font.label).foregroundStyle(Theme.Color.due)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 12)
                        .accessibilityIdentifier("onboarding.error")
                }
                actions
                    .id(step)
                    .transition(.opacity)
                    .disabled(busy || checked)
            }
            .padding(.horizontal, Theme.Metric.cardInset)
            .padding(.bottom, step == .tryIt ? 4 : 12)
            if step == .tryIt {
                KeyboardView(model: typing.model)
                    .background(Theme.SystemKeyboard.dark.bed.ignoresSafeArea(edges: .bottom))
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showDevPairing) {
            DevPairingSheet { showDevPairing = false; Task { await complete(.signIn) } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, step == .keyboard, Self.keyboardAdded, !checked { Task { await complete(.keyboard) } }
        }
        // The keyboard did its work (for scene 1, the chip put a pay link in the message): the scene is done.
        .onChange(of: typing.model.watch) { _, _ in checkScene() }
        .onChange(of: typing.model.bar) { _, _ in checkScene() }
        .onChange(of: typing.text) { _, _ in checkScene() }
    }

    /// The mark is one view for the whole flow. It is large on the first screen, then moves up and shrinks.
    /// A finished step stamps a green check on it.
    private var mark: some View {
        let size: CGFloat = step == .signIn ? 104 : 64
        return ZStack {
            MarkView(size: size)
            if checked {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(Theme.Color.paidInk)
                    .frame(width: size, height: size)
                    .background(Theme.Color.paidChip, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.Color.paidChipEdge, lineWidth: 1))
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .contentShape(Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppConfig.displayName)
        .accessibilityIdentifier("onboarding.mark")
        // Hidden developer path: hold the mark on the first screen to pair with a device token.
        .onLongPressGesture(minimumDuration: 0.8) { if step == .signIn { session.error = nil; showDevPairing = true } }
    }

    private var keyboardSteps: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(["Tap Keyboards.", "Turn on \(AppConfig.keyboardName).", "Turn on Allow Full Access."].enumerated()), id: \.offset) { i, text in
                    HStack(spacing: 12) {
                        Text("\(i + 1)").font(Theme.Font.count).foregroundStyle(Theme.Color.text1)
                            .frame(width: 28, height: 28).background(Theme.Color.button, in: Circle())
                        Text(text).font(Theme.Font.body).foregroundStyle(Theme.Color.text1)
                    }
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: 4) {
            switch step {
            case .signIn:
                SignInWithAppleButton(.continue) { request in
                    session.error = nil
                    nonce = Self.randomNonce()
                    request.requestedScopes = []
                    request.nonce = Self.sha256(nonce)
                } onCompletion: { result in
                    Task { await appleFinished(result) }
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 52)
                .clipShape(Capsule())
                .opacity(busy ? 0.5 : 1)
                .accessibilityIdentifier("onboarding.apple")
                quietButton("", action: {}).hidden()
            case .keyboard:
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(PrimaryButton())
                quietButton("Not now") { Task { await advance(from: .keyboard) } }
                    .accessibilityIdentifier("onboarding.later")
            case .tryIt:
                Button(tryNeedsRetry ? "Try again" : "Type \u{201C}\(scene.example)\u{201D}") { typeExample() }
                    .buttonStyle(PrimaryButton())
                    .opacity(tryBusy ? 0 : 1)
                    .disabled(tryBusy)
                    .accessibilityIdentifier("onboarding.example")
                quietButton("Skip") { sceneIndex = IntroScene.all.count - 1; Task { await advance(from: .tryIt) } }
                    .accessibilityIdentifier("onboarding.skip")
            }
        }
    }

    // MARK: try it

    /// The message the owner is "typing". The keyboard below writes into it, and the chip adds the pay link.
    private var messageField: some View {
        Text(typing.text.isEmpty ? "Message" : typing.text)
            .font(Theme.Font.body)
            .foregroundStyle(typing.text.isEmpty ? Theme.Color.text3 : Theme.Color.text1)
            .lineLimit(4).truncationMode(.middle)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .padding(.horizontal, 18).padding(.vertical, 14)
            .background(checked ? Theme.Color.paidChip : Theme.Color.button, in: RoundedRectangle(cornerRadius: Theme.Metric.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Metric.radius, style: .continuous).strokeBorder(checked ? Theme.Color.paidChipEdge : Theme.Color.edge, lineWidth: 1))
            // The whole bubble keeps its full height, so a long link never spills out of it.
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("onboarding.message")
    }

    private var scene: IntroScene { IntroScene.all[sceneIndex] }
    private var sceneDone: Bool { scene.succeeded(typing.model, typing.text) }

    private func checkScene() {
        if step == .tryIt, !checked, sceneDone { Task { await complete(.tryIt) } }
    }

    private var tryLine: String {
        if sceneDone { return scene.result }
        switch typing.model.bar {
        case .chips, .confirm: return "Now tap the chip on the keyboard."
        case .working: return "One moment\u{2026}"
        case .error: return "That did not work. Try again."
        default:
            if tryTimedOut { return "No suggestion this time. Try again." }
            return typing.text.isEmpty ? scene.prompt : "\(AppConfig.displayName) is reading\u{2026}"
        }
    }
    private var tryNeedsRetry: Bool {
        if case .error = typing.model.bar { return true }
        return tryTimedOut
    }
    /// The chip is on the keyboard or the link is on its way, so the main button steps aside.
    private var tryBusy: Bool {
        if sceneDone { return true }
        switch typing.model.bar {
        case .chips, .confirm, .working: return true
        default: return false
        }
    }

    /// Types the example for the owner. Also the retry: it clears the field first, so the keyboard asks again.
    private func typeExample() {
        tryTimedOut = false
        typing.model.bar = .idle
        typing.text = ""
        typing.model.textChanged()
        typing.text = scene.example
        typing.model.textChanged()
        tryTimer?.cancel()
        tryTimer = Task {
            try? await Task.sleep(for: Self.tryTimeout)
            guard !Task.isCancelled, step == .tryIt, !tryBusy else { return }
            withAnimation(Theme.Motion.crossfade) { tryTimedOut = true }
        }
    }

    private func quietButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(Theme.Font.body).foregroundStyle(Theme.Color.text2)
            .frame(maxWidth: .infinity, minHeight: 44)
    }

    private func appleFinished(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .failure(let e):
            // A cancel is the user's choice, so it shows no error.
            if (e as? ASAuthorizationError)?.code != .canceled { session.error = "Apple sign-in did not finish. Try again." }
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let token = cred.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else {
                session.error = "Apple sign-in did not finish. Try again."
                return
            }
            busy = true
            let ok = await session.signInWithApple(identityToken: token, nonce: nonce)
            busy = false
            if ok { await complete(.signIn) }
        }
    }

    /// The step is done: stamp the check, hold it a moment, then move on.
    private func complete(_ done: Step) async {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(reduceMotion ? Theme.Motion.crossfade : Theme.Motion.stamp) { checked = true }
        // The last step holds longer, so the owner can read the link.
        try? await Task.sleep(for: done == .tryIt ? Theme.Motion.onboardingLinkHold : Theme.Motion.onboardingCheckHold)
        await advance(from: done)
    }

    private func advance(from done: Step) async {
        withAnimation(stepMotion) {
            checked = false
            session.error = nil
            if done == .tryIt, sceneIndex + 1 < IntroScene.all.count {
                // Next scene: a clean message and a clean keyboard bar.
                tryTimer?.cancel()
                tryTimedOut = false
                typing.model.keyboardDisappeared()
                typing.model.watch = nil
                typing.model.bar = .idle
                typing.text = ""
                typing.model.textChanged()
                sceneIndex += 1
            } else if let next = next(after: done) {
                if next == .tryIt { typing.model.isDark = true; typing.model.refreshAccess() }
                step = next
            } else {
                tryTimer?.cancel()
                typing.model.keyboardDisappeared()
                session.finishOnboarding()
            }
        }
    }

    /// Skips the keyboard step when the keyboard is already on.
    private func next(after done: Step) -> Step? {
        switch done {
        case .signIn: Self.keyboardAdded ? .tryIt : .keyboard
        case .keyboard: .tryIt
        case .tryIt: nil
        }
    }

    /// iOS lists the enabled keyboards in the AppleKeyboards preference. The heartbeat also proves Full Access.
    static var keyboardAdded: Bool {
        let ids = UserDefaults.standard.stringArray(forKey: "AppleKeyboards") ?? []
        let ours = (Bundle.main.bundleIdentifier ?? "") + ".keyboard"
        return ids.contains(ours) || SharedStore.keyboardLastSeen != nil
    }

    private static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// One dot per step. The current one is a longer pill.
struct StepDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Theme.Color.text1 : i < current ? Theme.Color.text2 : Theme.Color.tick)
                    .frame(width: i == current ? 22 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(count)")
        .accessibilityIdentifier("onboarding.step.\(current + 1)")
    }
}

/// Developer path, opened by holding the mark. It pairs with a device token from `npm run device`.
struct DevPairingSheet: View {
    @EnvironmentObject var session: Session
    @State private var server = SharedStore.serverURL
    @State private var token = ""
    @State private var busy = false
    let onPaired: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Developer pairing").font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
            TextField("", text: $server, prompt: Text("Server URL").foregroundStyle(Theme.Color.text3))
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .modifier(FieldStyle())
            if let demo = AppConfig.demoServerURL {
                HStack(spacing: 8) {
                    ServerOption(title: "This Mac", selected: server == "http://localhost:8787") { server = "http://localhost:8787" }
                    ServerOption(title: "Demo server", selected: server == demo) { server = demo }
                        .accessibilityIdentifier("server.demo")
                }
            }
            SecureField("", text: $token, prompt: Text("Device token (pkd_…)").foregroundStyle(Theme.Color.text3))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .textContentType(.oneTimeCode)
                .modifier(FieldStyle())
                .accessibilityIdentifier("token")
            if let error = session.error {
                Text(error).font(Theme.Font.label).foregroundStyle(Theme.Color.due)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pair.error")
            }
            Button(busy ? "Pairing…" : "Pair") {
                busy = true
                Task {
                    let ok = await session.pair(token: token, server: server)
                    busy = false
                    if ok { onPaired() }
                }
            }
            .buttonStyle(PrimaryButton())
            .disabled(token.isEmpty || busy)
            Spacer(minLength: 0)
        }
        .padding(Theme.Metric.cardPadding)
        .padding(.top, 8)
        .background(Theme.Color.bg.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

struct EnableKeyboardSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepCard(number: 2, title: "Turn on the keyboard") {
                ForEach(Array([
                    "Open Settings › General › Keyboard › Keyboards.",
                    "Tap Add New Keyboard and pick \(AppConfig.keyboardName).",
                    "Tap \(AppConfig.keyboardName) and turn on Allow Full Access. The keyboard needs it to reach the network.",
                    "In any chat, tap the globe key to switch to \(AppConfig.keyboardName).",
                ].enumerated()), id: \.offset) { _, step in
                    Text(step).font(Theme.Font.body).foregroundStyle(Theme.Color.text2).fixedSize(horizontal: false, vertical: true)
                }
                OpenSettingsButton()
            }
            StepCard(number: 3, title: "Optional: skip the paste prompt") {
                Text("To use a client's copied message, iOS asks each time. To stop the prompt, open Settings › \(AppConfig.displayName) › Paste from Other Apps and pick Allow.")
                    .font(Theme.Font.body).foregroundStyle(Theme.Color.text2).fixedSize(horizontal: false, vertical: true)
                OpenSettingsButton()
            }
            .accessibilityIdentifier("step.paste")
        }
    }
}

struct OpenSettingsButton: View {
    var body: some View {
        Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
        .buttonStyle(PrimaryButton())
    }
}

struct ServerOption: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.label)
                .foregroundStyle(selected ? Theme.Color.bg : Theme.Color.text2)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(selected ? Theme.Color.text1 : Theme.Color.button, in: Capsule())
        }
        .buttonStyle(PressScale())
    }
}

struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("\(number)").font(Theme.Font.count).foregroundStyle(Theme.Color.text1)
                        .frame(width: 28, height: 28).background(Theme.Color.button, in: Circle())
                    Text(title).font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                }
                content
            }
        }
    }
}

struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Color.text1)
            .padding(.horizontal, 18)
            .frame(height: 48)
            .background(Theme.Color.button, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.Color.edge, lineWidth: 1))
    }
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.cardTitle)
            .foregroundStyle(Theme.Color.bg)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Theme.Color.text1, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}
