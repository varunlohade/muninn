import SwiftUI
import UIKit

// The intro: one short scene per feature. Each scene runs the real keyboard or the real Ask bar on canned answers.
// It plays before sign-in, so nothing here can reach the server or PayPal.

/// The intro's stand-in server. It answers from memory and makes no network call.
struct DemoAPI: AskAPI {
    var askResult: AskResponse.Result = .line("")
    var fixed = ""

    static let invoiceLink = "https://paypal.com/invoice/INV2-DEMO"
    static let payLink = "https://paypal.com/pay/DEMO45"
    static let repeatLink = "https://paypal.com/subscribe/DEMO40"
    static let reviewMessage = "Thanks for coming in! If you have a minute, a review would mean a lot: https://g.page/r/your-shop/review"
    static let unpaid = [
        Payment(kind: "invoice", id: "DEMO-1", state: "unpaid", amount: "120.00", currency: "USD", item: "Color", client_name: "Jordan",
                link: invoiceLink, created_at: "2026-01-02T10:00:00Z", days_overdue: 2),
        Payment(kind: "invoice", id: "DEMO-2", state: "unpaid", amount: "45.00", currency: "USD", item: "Haircut", client_name: "Maya",
                link: invoiceLink, created_at: "2026-01-01T10:00:00Z", days_overdue: 16),
    ]

    private func string(_ payload: [String: JSONValue], _ key: String) -> String? {
        if case .string(let v)? = payload[key] { v } else { nil }
    }

    func ask(_ text: String) async throws -> AskResponse { AskResponse(route: "demo", confidence: 1, result: askResult) }
    func suggest(_ text: String, context: String?) async throws -> SuggestResponse { SuggestResponse(chips: [], intent: "none", timings: nil) }
    func invoice(_ payload: [String: JSONValue], key: String, lookup: Bool) async throws -> InvoiceResponse {
        InvoiceResponse(id: "DEMO-INV", status: "SENT", pay_link: Self.invoiceLink, amount: string(payload, "amount") ?? "45.00", currency: "USD")
    }
    func payLink(_ payload: [String: JSONValue], key: String, lookup: Bool) async throws -> PayLinkResponse {
        PayLinkResponse(id: "DEMO-PAY", status: "CREATED", approve_link: Self.payLink, amount: string(payload, "amount"), currency: "USD")
    }
    func subscribe(_ payload: [String: JSONValue], key: String, lookup: Bool) async throws -> SubscribeResponse {
        SubscribeResponse(id: "DEMO-SUB", status: "APPROVAL_PENDING", approve_link: Self.repeatLink, amount: string(payload, "amount") ?? "40.00",
                          currency: "USD", interval: string(payload, "interval") ?? "month")
    }
    func remind(invoiceID: String, confirmClient: String?, key: String, lookup: Bool) async throws -> RemindResponse { RemindResponse(invoice_id: invoiceID) }
    func refund(_ body: [String: JSONValue], key: String, lookup: Bool) async throws -> RefundResponse { throw APIError.message("") }
    func reply(_ text: String) async throws -> ReplyResponse { ReplyResponse(reply: "") }
    func fix(_ text: String) async throws -> WriteResponse { WriteResponse(text: fixed, changed: true) }
    func refine(_ text: String, tone: String) async throws -> WriteResponse { WriteResponse(text: text, changed: false) }
    func toneCheck(draft: String, client: String?) async throws -> ToneResponse { ToneResponse(tone: "ok", calm: nil) }
    func payments() async throws -> [Payment] { Self.unpaid }
}

/// The intro's device storage: kept in memory, gone when the intro ends.
final class DemoStore: KeyboardStore {
    let deviceToken: String? = "demo"
    var keyboardLastSeen: Date?
    var lastPasteboardChange = 0
    var appointments: [Appointment] = []
    var unpaidCount: Int?
    var notes: [Note] = Note.demo
    let actionShortcuts = ActionShortcut.defaults
    var pendingAction: PendingAction?
    var touchOffsets: [Double] = []
}

/// The intro never looks at the real pasteboard.
final class DemoPasteboard: Pasteboard {
    let hasStrings = false
    let changeCount = 0
    let string: String? = nil
}

/// One intro scene. To add a feature, add one value to `all`.
struct IntroScene: Identifiable {
    enum Surface {
        case chat(ChatSkin, contact: String, lines: [ChatLine])
        /// The Ask bar in the Muninn app.
        case app
    }
    let id: String
    let title: String
    let line: String
    let surface: Surface
    var askResult: AskResponse.Result = .line("")
    var fixed = ""
    var appointments: [Appointment] = []
    /// "In WhatsApp": where the scene plays.
    var place: String {
        if case .chat(let skin, _, _) = surface { "In \(skin.app)" } else { "In \(AppConfig.displayName)" }
    }
    /// What happens on screen, step by step.
    let script: @MainActor (IntroPlayer) async throws -> Void

    private static func chip(_ kind: String, _ label: String, _ payload: [String: JSONValue], confirm: Bool = false) -> Chip {
        Chip(kind: kind, label: label, payload: payload, needs_confirm: confirm)
    }
    private static let haircut: [String: JSONValue] = ["amount": .string("45.00"), "currency": .string("USD"), "item": .string("Haircut"), "client_name": .string("Sam")]
    private static let repeatChip = chip("subscribe", "Repeat $40 monthly \u{00B7} Sam",
                                         ["amount": .string("40.00"), "currency": .string("USD"), "interval": .string("month"), "item": .string("Repeat payment"),
                                          "client_name": .string("Sam")], confirm: true)

    @MainActor static let all: [IntroScene] = [
        IntroScene(id: "paylink", title: "Invoice or pay link", line: "Type a price in any chat. Tap the chip. The PayPal link goes in.",
                   surface: .chat(.iMessage, contact: "Sam", lines: [.them("How much for the cut?")])) { p in
            let pay = chip("paylink", "Pay link $45 \u{00B7} Haircut", haircut)
            try await p.type("$45 for the haircut")
            p.keyboard.bar = .chips([chip("invoice", "Invoice $45 \u{00B7} Haircut", haircut, confirm: true), pay], fromCopied: false)
            try await p.pause(350)
            try await p.tapBar(0.55)
            p.keyboard.perform(.chip(pay))
            try await p.pause(650)
            p.send()
            try await p.pause(500)
            p.keyboard.watch?.paid = true
        },
        IntroScene(id: "remind", title: "Reminders", line: "Type who to remind. You confirm. PayPal sends it.",
                   surface: .chat(.telegram, contact: "Jordan", lines: [.stamp("9 days ago"), .me("Here's your invoice for Color ($120): \(DemoAPI.invoiceLink)")])) { p in
            let remind = chip("remind", "Remind Jordan \u{00B7} $120",
                              ["invoice_id": .string("DEMO-1"), "client_name": .string("Jordan"), "amount": .string("120.00"), "currency": .string("USD")], confirm: true)
            try await p.type("remind Jordan")
            p.keyboard.bar = .chips([remind], fromCopied: false)
            try await p.pause(350)
            try await p.tapBar(0.4)
            p.keyboard.perform(.chip(remind))
            try await p.pause(650)
            try await p.tapBar(0.35)
            p.confirmBar()
        },
        IntroScene(id: "ask", title: "Ask Muninn", line: "Ask in plain words in the app. See who hasn't paid.",
                   surface: .app, askResult: .payments(DemoAPI.unpaid)) { p in
            try await p.type("who hasn't paid")
            try await p.pause(250)
            p.ask.submit()
        },
        IntroScene(id: "write", title: "Fix and Rewrite", line: "Type fast. Fix shows the typos. Rewrite makes it polite or short.",
                   surface: .chat(.marketplace, contact: "Dana", lines: [.them("Is this still available?")]),
                   fixed: "Yes it's available, can you pick it up today?") { p in
            try await p.type("yes it's availble, can u pick it up today")
            try await p.pause(300)
            try await p.tapBar(0.72)
            p.keyboard.fix()
            try await p.pause(800)
            try await p.tapBar(0.84)
            p.keyboard.toggleWrite()
        },
        IntroScene(id: "notes", title: "Notes", line: "Save a reply once. Drop it into any chat.",
                   surface: .chat(.whatsApp, contact: "Priya", lines: [.them("What are your prices?")])) { p in
            try await p.pause(500)
            try await p.tapBar(0.94)
            p.keyboard.toggleNotes()
            try await p.pause(700)
            try await p.tapKeyboard(x: 0.5, y: Theme.SystemKeyboard.barHeight + 20)
            if let note = p.keyboard.notes.first { p.keyboard.insertNote(note) }
            try await p.pause(600)
            p.send()
        },
        IntroScene(id: "calendar", title: "Calendar", line: "After an appointment, the keyboard offers the invoice.",
                   surface: .chat(.instagram, contact: "Sam", lines: [.them("Thanks for today!")]),
                   appointments: [Appointment(start: Date().addingTimeInterval(-3600), end: Date().addingTimeInterval(-600), title: "Haircut", clientName: "Sam")]) { p in
            let invoice = chip("invoice", "Invoice $45 \u{00B7} Haircut", haircut, confirm: true)
            try await p.pause(500)
            try await p.tapBar(0.4)
            if let a = p.keyboard.toBill { p.keyboard.perform(.bill(a)) }
            try await p.pause(450)
            try await p.type("45")
            p.keyboard.bar = .chips([invoice], fromCopied: false)
            try await p.pause(350)
            try await p.tapBar(0.4)
            p.keyboard.perform(.chip(invoice))
            try await p.pause(600)
            try await p.tapBar(0.35)
            p.confirmBar()
            try await p.pause(600)
            p.send()
        },
        IntroScene(id: "repeat", title: "Repeat billing", line: "Bill a client every week, month or year. You confirm first.",
                   surface: .app, askResult: .chips([repeatChip])) { p in
            try await p.type("bill Sam $40 monthly")
            try await p.pause(250)
            p.ask.submit()
            try await p.pause(650)
            p.ask.run(repeatChip)
            try await p.pause(800)
            p.ask.run(repeatChip, confirmed: "Sam")
        },
        IntroScene(id: "review", title: "Review link", line: "Save your review link once. Ask, copy, paste in any chat.",
                   surface: .app, askResult: .review(DemoAPI.reviewMessage)) { p in
            try await p.type("ask for a review")
            try await p.pause(250)
            p.ask.submit()
        },
    ]
}

/// One scene's own keyboard, Ask bar and message field. Each scene starts clean.
@MainActor
final class IntroStage: ObservableObject, TextHost {
    @Published var text = ""
    let keyboard: KeyboardModel
    let ask: AskModel

    init(_ scene: IntroScene, dark: Bool) {
        let api = DemoAPI(askResult: scene.askResult, fixed: scene.fixed)
        let store = DemoStore()
        store.appointments = scene.appointments
        keyboard = KeyboardModel(deps: KeyboardDeps(api: { api }, store: store, pasteboard: DemoPasteboard(), now: Date.init, sleep: { try await Task.sleep(for: $0) }))
        ask = AskModel(api: { api }, store: store)
        keyboard.host = self
        keyboard.suggestsWhileTyping = false
        keyboard.isDark = dark
        keyboard.keyboardAppeared()
    }

    var contextBeforeInput: String? { text }
    var hasFullAccess: Bool { true }
    var needsGlobeKey: Bool { false }
    var returnKeyType: UIReturnKeyType { .default }
    var autocapitalization: UITextAutocapitalizationType { .sentences }
    var autocorrection: UITextAutocorrectionType { .default }
    var enablesReturnKeyAutomatically: Bool { false }
    func playClick() {}
    func insert(_ s: String) { text += s }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
    func adjustCursor(by offset: Int) {}
    func nextKeyboard() {}
}

/// Plays the scenes in order: about 3 s each, then the next. A tap skips ahead.
@MainActor
final class IntroPlayer: ObservableObject {
    @Published private(set) var index = 0
    @Published private(set) var stage: IntroStage
    /// What the owner "sent" in this scene.
    @Published private(set) var sent: [String] = []
    /// Where the finger is, in the keyboard: x from 0 to 1, y in points from its top.
    @Published private(set) var touch: CGPoint?
    /// The scene has shown everything.
    @Published private(set) var settled = false

    static let typeDelay = 26
    static let endHold = 900
    /// DEBUG "-introHold": a scene stays until a tap, so a test can take its picture.
    private let holds = ProcessInfo.processInfo.arguments.contains("-introHold")
    private var dark = false
    private var task: Task<Void, Never>?
    private var finish: () -> Void = {}

    init() { stage = IntroStage(IntroScene.all[0], dark: false) }

    var scene: IntroScene { IntroScene.all[index] }
    var keyboard: KeyboardModel { stage.keyboard }
    var ask: AskModel { stage.ask }

    func start(dark: Bool, finish: @escaping () -> Void) {
        self.dark = dark
        self.finish = finish
        play(0)
    }

    /// A tap: on to the next scene now. After the last one, the intro ends.
    func next() {
        if index + 1 < IntroScene.all.count { play(index + 1) } else { stop(); finish() }
    }

    func stop() { task?.cancel() }

    private func play(_ i: Int) {
        task?.cancel()
        stage.keyboard.keyboardDisappeared()
        index = i
        stage = IntroStage(IntroScene.all[i], dark: dark)
        sent = []
        touch = nil
        settled = false
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.scene.script(self)
                try await self.pause(Self.endHold)
                self.settled = true
                if !self.holds { self.next() }
            } catch {}
        }
    }

    // MARK: script steps

    func pause(_ ms: Int) async throws { try await Task.sleep(for: .milliseconds(ms)) }

    /// Types into the chat, or into the Ask bar on an app scene.
    func type(_ text: String) async throws {
        for ch in text {
            if case .app = scene.surface { ask.text.append(ch) } else { stage.text.append(ch); keyboard.textChanged() }
            try await pause(Self.typeDelay)
        }
    }

    /// A finger on the bar at `x` (0 to 1).
    func tapBar(_ x: CGFloat) async throws { try await tapKeyboard(x: x, y: 24) }

    func tapKeyboard(x: CGFloat, y: CGFloat) async throws {
        withAnimation(Theme.Motion.press) { touch = CGPoint(x: x, y: y) }
        try await pause(280)
        withAnimation(Theme.Motion.crossfade) { touch = nil }
    }

    /// The confirm tap on the keyboard bar. It runs the model's own confirm, with the recipient the bar shows.
    func confirmBar() {
        if case .confirm(let chip, let recipient) = keyboard.bar { keyboard.perform(.confirm(chip, recipient: recipient)) }
    }

    /// The message leaves the field and lands in the chat.
    func send() {
        guard !stage.text.isEmpty else { return }
        withAnimation(Theme.Motion.chipFlip) { sent.append(stage.text) }
        stage.text = ""
        keyboard.textChanged()
    }
}

struct IntroView: View {
    let done: () -> Void
    @StateObject private var player = IntroPlayer()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    typealias K = Theme.SystemKeyboard

    var body: some View {
        let scene = player.scene
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    HStack(spacing: Theme.Space.xxs) {
                        ForEach(IntroScene.all.indices, id: \.self) { i in
                            Capsule().fill(i == player.index ? Theme.Color.text1 : i < player.index ? Theme.Color.text2 : Theme.Color.tick).frame(height: 4)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Feature \(player.index + 1) of \(IntroScene.all.count)")
                    Button("Skip") { player.stop(); done() }
                        .font(Theme.Font.body).foregroundStyle(Theme.Color.text2)
                        .frame(minWidth: Theme.Metric.iconButton, minHeight: Theme.Metric.iconButton)
                        .accessibilityIdentifier("onboarding.skip")
                }
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    // The other app is named in words only.
                    Text(scene.place).font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                        .accessibilityIdentifier("intro.place")
                    Text(scene.title).font(Theme.Font.title).foregroundStyle(Theme.Color.text1)
                        .accessibilityIdentifier(player.settled ? "intro.done.\(scene.id)" : "intro.playing.\(scene.id)")
                    Text(scene.line).font(Theme.Font.body).foregroundStyle(Theme.Color.text2)
                        .lineLimit(2, reservesSpace: true).minimumScaleFactor(0.85)
                }
                .padding(.horizontal, Theme.Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(scene.id)
                .transition(.opacity)
                .allowsHitTesting(false)
                StageView(player: player, stage: player.stage, scene: scene)
                    .id(scene.id)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, Theme.Metric.cardInset)
            .padding(.bottom, Theme.Space.xs)
            KeyboardView(model: player.keyboard)
                .overlay(alignment: .topLeading) {
                    GeometryReader { g in
                        if let t = player.touch {
                            Circle().fill(Theme.Color.text1.opacity(0.22)).overlay(Circle().strokeBorder(Theme.Color.text1.opacity(0.35), lineWidth: 1))
                                .frame(width: 40, height: 40)
                                .position(x: t.x * g.size.width, y: t.y)
                                .transition(.scale(scale: 1.5).combined(with: .opacity))
                        }
                    }
                }
                .background((colorScheme == .dark ? K.dark : K.light).bed.ignoresSafeArea(edges: .bottom))
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.bg.ignoresSafeArea())
        // Skip is the only control. Everywhere else, a tap goes on to the next scene.
        .contentShape(Rectangle())
        .onTapGesture { player.next() }
        .animation(reduceMotion ? nil : Theme.Motion.crossfade, value: player.index)
        .onAppear { player.start(dark: colorScheme == .dark, finish: done) }
        .onDisappear { player.stop() }
        .onChange(of: colorScheme) { _, scheme in player.keyboard.isDark = scheme == .dark }
    }
}

/// The scene's surface: a chat in another app, or the Ask bar in Muninn.
private struct StageView: View {
    @ObservedObject var player: IntroPlayer
    @ObservedObject var stage: IntroStage
    let scene: IntroScene

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Metric.radius, style: .continuous)
        Group {
            switch scene.surface {
            case .chat(let skin, let contact, let lines): ChatView(skin: skin, contact: contact, lines: lines, sent: player.sent, draft: stage.text)
            case .app: app
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.Color.edge, lineWidth: 1))
    }

    /// The Muninn app: its name, then the real Ask bar on the scene's canned answer.
    private var app: some View {
        GeometryReader { g in
            VStack(spacing: 0) {
                HStack(spacing: Theme.Space.xs) {
                    MarkView(size: Theme.Space.xl)
                    Text(AppConfig.displayName).font(Theme.Font.urbanist(17, 600)).foregroundStyle(Theme.Color.text1)
                    Spacer()
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.top, Theme.Space.s)
                Spacer(minLength: 0)
                AskBar(model: stage.ask, listHeight: max(120, g.size.height - 112))
            }
        }
        .background(Theme.Color.bg)
    }
}
