import SwiftUI

/// One short flow: the intro, turn on the keyboard, make it the default, allow Calendar & Reminders, Get started, Sign in with PayPal,
/// "What does your business do?", Home. Sign in with PayPal is the Connect PayPal flow; the demo account skips it.
/// After the intro, each step fits one screen and has one main button.
struct OnboardingView: View {
    enum Step: Int, CaseIterable { case intro, keyboard, makeDefault, calendar, start, paypal, business }

    @EnvironmentObject var session: Session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var setup = KeyboardSetup.shared
    @Environment(\.colorScheme) private var colorScheme
    /// iOS ends the app when the owner turns on the keyboard in Settings. The next launch goes on after the intro, not back into it.
    private static let introSeenKey = "intro_seen"
    @State private var step: Step = UserDefaults.standard.bool(forKey: introSeenKey) ? keyboardStep : .intro
    @State private var business = ""
    @State private var checked = false
    @State private var busy = false
    @State private var keyboardUp = false
    @ObservedObject private var paypal = PayPalConnector.shared
    #if DEBUG
    @State private var showDevPairing = false
    #endif

    private var title: String {
        switch step {
        case .intro: ""
        case .keyboard: "Turn on the keyboard"
        case .makeDefault: KeyboardState.needsFullAccess.homeTitle
        case .calendar: "Allow Calendar & Reminders"
        case .start: "Get paid from any chat"
        case .paypal: "Sign in with PayPal"
        case .business: "What does your business do?"
        }
    }
    private var line: String {
        switch step {
        case .intro: ""
        case .keyboard: "Three taps in Settings. Then come back."
        case .makeDefault: "Switch to \(AppConfig.displayName) once below, so the app sees it."
        case .calendar: "The keyboard adds the events and reminders you type. They stay on this phone."
        case .start: "\(AppConfig.displayName) suggests the invoice while you type."
        case .paypal: paypal.note ?? (paypal.status != nil && !paypal.canConnect ? PayPalConnector.offLine
            : "Invoices and pay links go to your own PayPal. Or try the demo account first.")
        case .business: "So the keyboard knows what your business does."
        }
    }
    private var stepMotion: Animation { reduceMotion ? Theme.Motion.crossfade : Theme.Motion.onboardingStep }
    private var slide: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                              removal: .move(edge: .leading).combined(with: .opacity))
    }

    var body: some View {
        Group {
            if step == .intro {
                // "I already have an account" goes straight to sign-in; Home offers the keyboard setup afterwards.
                HeroView(addKeyboard: { Task { await advance(from: .intro) } },
                         haveAccount: {
                             UserDefaults.standard.set(true, forKey: Self.introSeenKey)
                             withAnimation(stepMotion) { step = .start }
                         })
                    .transition(.opacity)
            } else {
                steps.transition(.opacity)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        // After a log out the app opens on the sign-in step.
        .onAppear { if session.signInNext { step = .start } }
        // An owner who already said what the business does (a reconnect, a recovered account) is not asked again.
        .task(id: step) {
            if step == .paypal { await paypal.refresh() }
            guard step == .business, let p = try? await APIClient.shared().profile(), !(p.description ?? "").isEmpty else { return }
            session.finishOnboarding()
        }
        #if DEBUG
        .sheet(isPresented: $showDevPairing) {
            DevPairingSheet { showDevPairing = false; Task { await complete(.start) } }
        }
        #endif
        // RootView checks the keyboard each time the app comes back from Settings; the guide checks each second.
        // Each step moves on by itself once it sees its part done. Order in the list never holds a step.
        .onChange(of: setup.state) { _, state in
            if step == .keyboard, state != .notAdded, !checked { Task { await complete(.keyboard) } }
            if step == .makeDefault, state.isOn, !checked { Task { await complete(.makeDefault) } }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Wordmark(size: 24)
                Spacer()
                StepDots(count: Step.allCases.count, current: step.rawValue)
            }
            .padding(.top, Theme.Space.s)
            // The middle scrolls, so the "Type here" keyboard never pushes the mark under the clock.
            ScrollView {
            VStack(alignment: .leading, spacing: 0) {
            mark.padding(.top, step == .start ? 72 : Theme.Space.xl)
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                // The signature two-tone headline: the step in ink, what it does in ink 2.
                twoTone(title.hasSuffix(".") ? title : title + ".", line)
                    // With the try-it keyboard up, a smaller title keeps the steps in view.
                    .font(step == .start ? Theme.Font.headline : step == .makeDefault && keyboardUp ? Theme.Font.sans(20, 400) : Theme.Font.title)
                    .tracking(-0.3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("onboarding.title")
                if step == .keyboard { keyboardSteps }
                if step == .makeDefault { Card { KeyboardDefaultGuide() } }
                if step == .business { BusinessQuestion(text: $business) }
                if step == .start {
                    // What the keyboard offers in a chat, as a task card.
                    TaskCardLabel(icon: .invoice, title: "Invoice $45", detail: "Sam, via PayPal", height: 52)
                        .rotationEffect(.degrees(-3), anchor: .leading)
                        .padding(.leading, Theme.Space.xs)
                        .accessibilityHidden(true)
                }
                if step == .paypal { PixelBanner(first: "Get paid in any chat.", rest: "Every invoice gets a pay link.").accessibilityHidden(true) }
            }
            .padding(.top, Theme.Space.l)
            .id(step)
            .transition(slide)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Theme.Space.l)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            if let error = session.error {
                Text(error).font(Theme.Font.label).foregroundStyle(Theme.Color.due)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Theme.Space.s)
                    .accessibilityIdentifier("onboarding.error")
            }
            actions
                .id(step)
                .transition(.opacity)
                .disabled(busy || checked)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, Theme.Space.s)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.bg.ignoresSafeArea())
    }

    /// The mark is one view for the whole flow: the raven on a paper tile, larger on Get started.
    /// A finished step stamps a green check on it.
    private var mark: some View {
        let size: CGFloat = step == .start ? 88 : 56
        return ZStack {
            MarkView(size: size)
            if checked {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(Theme.Color.paid)
                    .frame(width: size, height: size)
                    .background(Theme.Color.paidChip, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppConfig.displayName)
        .accessibilityIdentifier("onboarding.mark")
        #if DEBUG
        // Hidden developer path, Debug builds only: hold the mark on the last screen to pair with a device token.
        .onLongPressGesture(minimumDuration: 0.8) { if step == .start { session.error = nil; showDevPairing = true } }
        #endif
    }

    private var keyboardSteps: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            NumberedSteps(lines: KeyboardState.settingsSteps)
            Text(KeyboardState.settingsFallback).font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: Theme.Space.xs) {
            switch step {
            case .start:
                // Sign in with Apple or email (SignInView.swift). "Try without an account" is the old "Get started".
                SignInOptions(onSignedIn: { await complete(.start) }, onTry: { await getStarted() })
                    .opacity(busy ? 0.5 : 1)
            case .keyboard:
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(PrimaryButton())
                quietButton("Not now") { Task { await advance(from: .keyboard, skipped: true) } }
                    .accessibilityIdentifier("onboarding.later")
            case .makeDefault:
                if let open = setup.state.settingsButton {
                    Button(open) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(PrimaryButton())
                    .accessibilityIdentifier("onboarding.default.settings")
                } else {
                    Button("Next") { Task { await complete(.makeDefault) } }
                        .buttonStyle(PrimaryButton())
                        .accessibilityIdentifier("onboarding.default.next")
                }
                // iOS tells the app about Full Access only once the keyboard opens. If it never does, the owner's word goes on.
                if setup.state == .needsFullAccess {
                    quietButton("It's done") { setup.ownerSaysDone() }
                        .accessibilityIdentifier("onboarding.default.done")
                } else if !setup.state.isOn {
                    quietButton("Not now") { Task { await advance(from: .makeDefault) } }
                        .accessibilityIdentifier("onboarding.default.later")
                }
            case .calendar:
                Button("Allow Calendar & Reminders") { Task { await CalendarModel.shared.connect(); await advance(from: .calendar) } }
                    .buttonStyle(PrimaryButton())
                    .accessibilityIdentifier("onboarding.calendar")
                quietButton("Not now") { Task { await advance(from: .calendar) } }
                    .accessibilityIdentifier("onboarding.calendar.later")
            case .paypal:
                // Skippable: the demo account works, and Home offers Connect again.
                if paypal.canConnect {
                    Button(paypal.busy ? "One moment\u{2026}" : "Sign in with PayPal") { Task { if await paypal.connect() { await complete(.paypal) } } }
                        .buttonStyle(PrimaryButton())
                        .opacity(paypal.busy ? 0.5 : 1)
                        .disabled(paypal.busy)
                        .accessibilityIdentifier("onboarding.paypal")
                    quietButton("Use demo account") { Task { await advance(from: .paypal) } }
                        .accessibilityIdentifier("onboarding.paypal.demo")
                } else {
                    // The server cannot connect an own PayPal: the demo account is the way on.
                    Button("Use demo account") { Task { await advance(from: .paypal) } }
                        .buttonStyle(PrimaryButton())
                        .accessibilityIdentifier("onboarding.paypal.demo")
                }
            case .business:
                Button(busy ? "Saving\u{2026}" : "Next") { Task { await saveBusiness() } }
                    .buttonStyle(PrimaryButton())
                    .disabled(cleanBusiness.isEmpty)
                    .opacity(busy || cleanBusiness.isEmpty ? 0.5 : 1)
                    .accessibilityIdentifier("onboarding.business")
                quietButton("Not now") { Task { await advance(from: .business) } }
                    .accessibilityIdentifier("onboarding.business.later")
            case .intro:
                EmptyView()
            }
        }
    }

    private func quietButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(Theme.Font.sans(15)).foregroundStyle(Theme.Color.text2)
            .frame(maxWidth: .infinity, minHeight: Theme.Metric.secondaryButton)
    }

    /// Makes the device account. A failure leaves the button in place with one plain line above it.
    private func getStarted() async {
        session.error = nil
        busy = true
        let ok = await session.getStarted()
        busy = false
        if ok { await complete(.start) }
    }

    private var cleanBusiness: String { business.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Saves the answer on the server. A failure keeps the step with one plain line; Settings can set it later.
    private func saveBusiness() async {
        session.error = nil
        busy = true
        defer { busy = false }
        do {
            _ = try await APIClient.shared().setBusiness(cleanBusiness)
            await complete(.business)
        } catch {
            session.error = plainLine(error)
        }
    }

    /// The step is done: stamp the check, hold it a moment, then move on.
    private func complete(_ done: Step) async {
        // Several changes can report the same success. Only the first one counts, or the intro would jump scenes.
        guard !checked else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(reduceMotion ? Theme.Motion.crossfade : Theme.Motion.stamp) { checked = true }
        try? await Task.sleep(for: Theme.Motion.onboardingCheckHold)
        await advance(from: done)
    }

    private func advance(from done: Step, skipped: Bool = false) async {
        withAnimation(stepMotion) {
            checked = false
            session.error = nil
            if done == .intro { UserDefaults.standard.set(true, forKey: Self.introSeenKey) }
            if let next = skipped && done == .keyboard ? Self.afterKeyboard : next(after: done) { step = next } else { session.finishOnboarding() }
        }
    }

    /// Skips the add step when the keyboard is already added. "Not now" on the add step also skips the default step.
    private func next(after done: Step) -> Step? {
        switch done {
        case .intro: Self.keyboardStep
        case .keyboard: KeyboardSetup.shared.state.isOn ? Self.afterKeyboard : .makeDefault
        case .makeDefault: Self.afterKeyboard
        case .calendar: .start
        case .start: .paypal
        case .paypal: .business
        case .business: nil
        }
    }

    /// The calendar step shows only while Calendar or Reminders has never been asked.
    @MainActor static var afterKeyboard: Step { CalendarModel.shared.neverAsked ? .calendar : .start }

    /// Added but not seen with Full Access yet: the finish step. Already on: past both keyboard steps.
    @MainActor static var keyboardStep: Step {
        switch KeyboardSetup.shared.state {
        case .notAdded: .keyboard
        case .needsFullAccess: .makeDefault
        case .notFirst, .ready: afterKeyboard
        }
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
                    .fill(i == current ? Theme.Color.text1 : i < current ? Theme.Color.text3 : Theme.Color.tick)
                    .frame(width: i == current ? 18 : 6, height: 6)
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
    @ObservedObject private var setup = KeyboardSetup.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.cardGap) {
            // No step number here: the guide numbers its own steps.
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(setup.state.homeTitle)
                        .font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                    if setup.state == .needsFullAccess {
                        Text(KeyboardState.finishSetupLine).font(Theme.Font.body).foregroundStyle(Theme.Color.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    KeyboardDefaultGuide()
                    OpenSettingsButton()
                    if setup.state == .needsFullAccess {
                        Button("It's done") { setup.ownerSaysDone() }
                            .buttonStyle(QuietButton())
                            .accessibilityIdentifier("keyboard.done")
                    }
                }
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
                .background(selected ? Theme.Color.text1 : Theme.Color.button, in: RoundedRectangle(cornerRadius: Theme.Metric.buttonRadius, style: .continuous))
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
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text("\(number)").font(Theme.Font.mono(11)).foregroundStyle(Theme.Color.text3)
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
            .cardSurface(radius: Theme.Metric.buttonRadius, fill: Theme.Color.surface, lifted: false)
    }
}

/// The main action: the tactile dark button.
struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { TactileButton().makeBody(configuration: configuration) }
}

/// The second action: the quiet paper button.
struct QuietButton: ButtonStyle {
    var small = false
    var wide = true
    func makeBody(configuration: Configuration) -> some View { TactileButton(kind: .quiet, small: small, wide: wide).makeBody(configuration: configuration) }
}
