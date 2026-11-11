import AuthenticationServices
import CryptoKit
import SwiftUI

/// One scene of the "try it" intro: the owner does one thing with the real keyboard and sees the result.
/// To add a scene, add one value to `IntroScene.all`. The flow needs no other change.
struct IntroScene: Identifiable {
    let id: String
    var title = "Try it"
    /// One line that says what to do.
    let prompt: String
    /// What the main button types for the owner.
    let example: String
    /// The main button's label. Nil shows the example itself.
    var button: String? = nil
    /// What to do next, once the example is in the message. Nil means the keyboard brings a chip by itself.
    var hint: (@MainActor (KeyboardModel) -> String)? = nil
    /// One line shown when the scene succeeds.
    let result: String
    /// Runs before the example is typed.
    var prepare: @MainActor (KeyboardModel) -> Void = { _ in }
    /// True once the keyboard has done its work. It gets the keyboard model and the text in the message field.
    let succeeded: @MainActor (KeyboardModel, String) -> Bool

    /// The steps through the Refine panel, for the scenes that use it.
    @MainActor private static func panelHint(_ pick: String) -> (KeyboardModel) -> String {
        { model in
            guard model.writeOpen else { return "Now tap the wand on the keyboard." }
            switch model.writePanel {
            case .menu: return "Tap \(pick)."
            case .busy: return "One moment\u{2026}"
            case .preview: return "Tap Replace to use it."
            case .message: return "Tap Back, then try again."
            }
        }
    }

    @MainActor static let all: [IntroScene] = [
        IntroScene(id: "paylink", prompt: "Type a price, or tap the button.", example: "$45 for the cut",
                   result: "A real PayPal link, in one tap.", succeeded: { model, _ in model.watch != nil }),
        IntroScene(id: "fix", title: "Fix", prompt: "Type fast. Mistakes are fine.", example: "i can do tuesday at 3 if that work for you",
                   button: "Type a rushed message", hint: { _ in "Now tap Fix on the keyboard." },
                   result: "Spelling and grammar, fixed in one tap.", succeeded: { model, _ in model.lastWrite == "fix" }),
        IntroScene(id: "refine", title: "Refine", prompt: "Change how a message sounds.", example: "You have not paid yet. Pay today.",
                   button: "Type a blunt reminder", hint: panelHint("Friendlier"),
                   result: "Same message, better tone.", succeeded: { model, _ in model.lastWrite == "refine" }),
        IntroScene(id: "tone", title: "Tone check", prompt: "Check a message before you send it.", example: "This is the third time I ask. Where is my money?",
                   button: "Type an angry message", hint: panelHint("Tone check"),
                   result: "Calm and professional, before you send.", succeeded: { model, _ in model.lastWrite == "tone" }),
        IntroScene(id: "shortcuts", title: "Shortcuts", prompt: "A few keys can type a whole reply.", example: ";prices",
                   hint: { _ in "Now tap space on the keyboard." },
                   result: "Make your own in Shortcuts.", prepare: { $0.addDemoShortcut() },
                   succeeded: { model, _ in model.lastShortcut != nil }),
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
    @Environment(\.colorScheme) private var colorScheme
    /// The real keyboard view and model, typing into a string on this screen. Its calls go to the real server.
    @StateObject private var typing = LabHost()
    @State private var step: Step = .signIn
    @State private var checked = false
    @State private var busy = false
    @State private var nonce = ""
    #if DEBUG
    @State private var showDevPairing = false
    #endif
    @State private var sceneIndex = 0
    @State private var tryTimedOut = false
    @State private var tryTimer: Task<Void, Never>?

    private var title: String {
        switch step {
        case .signIn: "Get paid from any chat"
        case .keyboard: "Turn on the keyboard"
        case .tryIt: checked ? "Got it" : scene.title
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
                    .padding(.top, Theme.Space.s)
                Spacer(minLength: 0).frame(maxHeight: step == .signIn ? .infinity : Theme.Space.xl)
                mark
                VStack(spacing: Theme.Space.xs) {
                    Text(title).font(Theme.Font.title).foregroundStyle(Theme.Color.text1)
                    Text(line).font(Theme.Font.body).foregroundStyle(Theme.Color.text2)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    if step == .keyboard { keyboardSteps.padding(.top, Theme.Space.m) }
                    if step == .tryIt { messageField.padding(.top, Theme.Space.m) }
                }
                .padding(.top, Theme.Space.l)
                .id(step == .tryIt ? scene.id : "\(step)")
                .transition(slide)
                Spacer(minLength: Theme.Space.l).frame(maxHeight: .infinity)
                if let error = session.error {
                    Text(error).font(Theme.Font.label).foregroundStyle(Theme.Color.due)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, Theme.Space.s)
                        .accessibilityIdentifier("onboarding.error")
                }
                actions
                    .id(step)
                    .transition(.opacity)
                    .disabled(busy || checked)
            }
            .padding(.horizontal, Theme.Metric.cardInset)
            .padding(.bottom, step == .tryIt ? Theme.Space.xs : Theme.Space.m)
            if step == .tryIt {
                KeyboardView(model: typing.model)
                    .background((colorScheme == .dark ? Theme.SystemKeyboard.dark : Theme.SystemKeyboard.light).bed.ignoresSafeArea(edges: .bottom))
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        #if DEBUG
        .sheet(isPresented: $showDevPairing) {
            DevPairingSheet { showDevPairing = false; Task { await complete(.signIn) } }
        }
        #endif
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, step == .keyboard, Self.keyboardAdded, !checked { Task { await complete(.keyboard) } }
        }
        // The keyboard did its work (for scene 1, the chip put a pay link in the message): the scene is done.
        .onChange(of: typing.model.watch) { _, _ in checkScene() }
        .onChange(of: typing.model.bar) { _, _ in checkScene() }
        .onChange(of: typing.text) { _, _ in checkScene() }
        .onChange(of: typing.model.lastWrite) { _, _ in checkScene() }
        .onChange(of: typing.model.lastShortcut) { _, _ in checkScene() }
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
        #if DEBUG
        // Hidden developer path, Debug builds only: hold the mark on the first screen to pair with a device token.
        .onLongPressGesture(minimumDuration: 0.8) { if step == .signIn { session.error = nil; showDevPairing = true } }
        #endif
    }

    private var keyboardSteps: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(Array(["Tap Keyboards.", "Turn on \(AppConfig.keyboardName).", "Turn on Allow Full Access."].enumerated()), id: \.offset) { i, text in
                    HStack(spacing: Theme.Space.s) {
                        Text("\(i + 1)").font(Theme.Font.count).foregroundStyle(Theme.Color.text1)
                            .frame(width: Theme.Space.xl, height: Theme.Space.xl).background(Theme.Color.button, in: Circle())
                        Text(text).font(Theme.Font.body).foregroundStyle(Theme.Color.text1)
                    }
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: Theme.Space.xs) {
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
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: Theme.Metric.primaryButton)
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
                Button(tryNeedsRetry ? "Try again" : scene.button ?? "Type \u{201C}\(scene.example)\u{201D}") { typeExample() }
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
            .frame(maxWidth: .infinity, minHeight: Theme.Space.l, alignment: .leading)
            .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.m)
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
        case .chips, .confirm, .ask: return "Now tap the chip on the keyboard."
        case .working: return "One moment\u{2026}"
        case .error: return "That did not work. Try again."
        default:
            if tryTimedOut { return "No suggestion this time. Try again." }
            if typing.text.isEmpty { return scene.prompt }
            return scene.hint?(typing.model) ?? "\(AppConfig.displayName) is reading\u{2026}"
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
        case .chips, .confirm, .ask, .working: return true
        default: return false
        }
    }

    /// Types the example for the owner. Also the retry: it clears the field first, so the keyboard asks again.
    private func typeExample() {
        tryTimedOut = false
        typing.model.resetWriting()
        typing.model.bar = .idle
        typing.text = ""
        typing.model.textChanged()
        typing.model.suggestsWhileTyping = scene.hint == nil
        scene.prepare(typing.model)
        typing.text = scene.example
        typing.model.textChanged()
        tryTimer?.cancel()
        // Only a scene that waits for a chip can time out. The others wait for the owner.
        guard scene.hint == nil else { return }
        tryTimer = Task {
            try? await Task.sleep(for: Self.tryTimeout)
            guard !Task.isCancelled, step == .tryIt, !tryBusy else { return }
            withAnimation(Theme.Motion.crossfade) { tryTimedOut = true }
        }
    }

    private func quietButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(Theme.Font.body).foregroundStyle(Theme.Color.text2)
            .frame(maxWidth: .infinity, minHeight: Theme.Metric.secondaryButton)
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
        // Several changes can report the same success. Only the first one counts, or the intro would jump scenes.
        guard !checked else { return }
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
                typing.model.resetWriting()
                typing.model.bar = .idle
                typing.text = ""
                typing.model.textChanged()
                sceneIndex += 1
            } else if let next = next(after: done) {
                if next == .tryIt { typing.model.isDark = colorScheme == .dark; typing.model.refreshAccess() }
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
        HStack(spacing: Theme.Space.xs) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Theme.Color.text1 : i < current ? Theme.Color.text2 : Theme.Color.tick)
                    .frame(width: i == current ? Theme.Space.l : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(count)")
        .accessibilityIdentifier("onboarding.step.\(current + 1)")
    }
}

#if DEBUG
/// Developer path, opened by holding the mark. It pairs with a device token from `npm run device`. Debug builds only.
struct DevPairingSheet: View {
    @EnvironmentObject var session: Session
    @State private var server = SharedStore.serverURL
    @State private var token = ""
    @State private var busy = false
    let onPaired: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Developer pairing").font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
            TextField("", text: $server, prompt: Text("Server URL").foregroundStyle(Theme.Color.text3))
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .modifier(FieldStyle())
            if let demo = AppConfig.demoServerURL {
                HStack(spacing: Theme.Space.xs) {
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
        .padding(.top, Theme.Space.xs)
        .background(Theme.Color.bg.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
#endif

struct EnableKeyboardSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.cardGap) {
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

#if DEBUG
struct ServerOption: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.label)
                .foregroundStyle(selected ? Theme.Color.bg : Theme.Color.text2)
                .padding(.horizontal, Theme.Space.m)
                .frame(height: Theme.Metric.iconButton)
                .background(selected ? Theme.Color.text1 : Theme.Color.button, in: Capsule())
        }
        .buttonStyle(PressScale())
    }
}
#endif

struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Text("\(number)").font(Theme.Font.count).foregroundStyle(Theme.Color.text1)
                        .frame(width: Theme.Space.xl, height: Theme.Space.xl).background(Theme.Color.button, in: Circle())
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
            .padding(.horizontal, Theme.Space.m)
            .frame(height: Theme.Metric.secondaryButton)
            .background(Theme.Color.button, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.Color.edge, lineWidth: 1))
    }
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.cardTitle)
            .foregroundStyle(Theme.Color.bg)
            .frame(maxWidth: .infinity, minHeight: Theme.Metric.primaryButton)
            .background(Theme.Color.text1, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}
