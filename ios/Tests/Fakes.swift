import UIKit
@testable import Muninn

/// A text field the model types into. `text` is the whole field; the cursor is at the end.
@MainActor
final class FakeHost: TextHost {
    var text = ""
    var hasFullAccess = true
    var needsGlobeKey = false
    var returnKeyType: UIReturnKeyType = .default
    var autocapitalization: UITextAutocapitalizationType = .sentences
    var autocorrection: UITextAutocorrectionType = .default
    var enablesReturnKeyAutomatically = false

    var contextBeforeInput: String? { text }
    func insert(_ s: String) { text += s }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
    /// Each cursor move, in order. The cursor itself stays at the end of `text`.
    private(set) var cursorMoves: [Int] = []
    func adjustCursor(by offset: Int) { cursorMoves.append(offset) }
    func nextKeyboard() {}
    func playClick() {}
}

/// Answers with canned replies and records every call. Main-actor bound, so the model's tasks and the test never race on it.
@MainActor
final class FakeAPI: AskAPI {
    struct Failure: Error {}

    var suggestReply = SuggestResponse(chips: [], intent: "none", timings: nil)
    var invoiceReply = InvoiceResponse(id: "INV-1", status: "sent", pay_link: "https://fake.pay/INV-1", amount: "45.00", currency: "USD")
    var payLinkReply = PayLinkResponse(id: "PL-1", status: "created", approve_link: "https://fake.pay/PL-1", amount: "45.00", currency: "USD")
    var subscribeReply = SubscribeResponse(id: "I-SUB1", status: "APPROVAL_PENDING", approve_link: "https://fake.pay/I-SUB1", amount: "40.00", currency: "USD", interval: "month")
    var writeReply = WriteResponse(text: "", changed: nil)
    var toneReply = ToneResponse(tone: "ok", calm: nil)
    var paymentsReply: [Payment] = []
    var remindReply = RemindResponse(invoice_id: "INV-1")
    var refundAskReply = RefundResponse(confirm_token: "rf_token_123", summary: "Refund $45 to Sam?", refund_id: nil, amount: nil, currency: nil)
    var refundDoneReply = RefundResponse(confirm_token: nil, summary: nil, refund_id: "RF-1", amount: "45.00", currency: "USD")
    var replyReply = ReplyResponse(reply: "A haircut is $45. Want a slot tomorrow?")
    var askReply = AskResponse(route: "none", confidence: 1, result: .line("Not sure what you need."))
    /// Thrown one by one, first in line, by the next calls that would answer.
    var failures: [Error] = []
    /// When set, invoice() throws needsConfirm unless the payload carries this confirm_recipient.
    var requireConfirm: String?
    /// Keys whose call the fake server finished. A lookup answers only for these; else a 404.
    var stored: Set<String> = []
    /// The next this-many money calls run on the server, then lose the reply to a timeout.
    var lostReplies = 0

    private(set) var calls: [String] = []
    private(set) var asked: [String] = []
    private(set) var suggested: [(text: String, context: String?)] = []
    private(set) var invoiced: [[String: JSONValue]] = []
    private(set) var subscribed: [[String: JSONValue]] = []
    private(set) var refunded: [[String: JSONValue]] = []
    /// The confirm_client of each reminder sent.
    private(set) var reminded: [String?] = []
    private(set) var replied: [String] = []
    /// The Idempotency-Key of each money call, in order.
    private(set) var keys: [String] = []
    /// When set, suggest() runs this before it answers, so a test can change the text mid-request.
    var duringSuggest: (() -> Void)?

    nonisolated init() {}

    func suggest(_ text: String, context: String?) async throws -> SuggestResponse {
        calls.append("suggest"); suggested.append((text, context))
        duringSuggest?()
        return suggestReply
    }

    func ask(_ text: String) async throws -> AskResponse { calls.append("ask"); asked.append(text); try fail(); return askReply }

    private func fail() throws { if !failures.isEmpty { throw failures.removeFirst() } }

    private func loseReply() throws { if lostReplies > 0 { lostReplies -= 1; throw URLError(.timedOut) } }

    private func lookUp(_ kind: String, _ key: String) throws {
        calls.append("lookup:\(kind)"); keys.append(key)
        try fail()
        if !stored.contains(key) { throw APIError.http(404, #"{"error":"not found"}"#) }
    }

    func invoice(_ payload: [String: JSONValue], key: String, lookup: Bool) async throws -> InvoiceResponse {
        if lookup { try lookUp("invoice", key); return invoiceReply }
        calls.append("invoice"); invoiced.append(payload); keys.append(key)
        try fail()
        if let r = requireConfirm, payload["confirm_recipient"] != .string(r) { throw APIError.needsConfirm(recipient: r) }
        stored.insert(key)
        try loseReply()
        return invoiceReply
    }

    func payLink(_ payload: [String: JSONValue], key: String, lookup: Bool) async throws -> PayLinkResponse {
        if lookup { try lookUp("paylink", key); return payLinkReply }
        calls.append("paylink"); keys.append(key); try fail(); stored.insert(key); return payLinkReply
    }

    func subscribe(_ payload: [String: JSONValue], key: String, lookup: Bool) async throws -> SubscribeResponse {
        if lookup { try lookUp("subscribe", key); return subscribeReply }
        calls.append("subscribe"); subscribed.append(payload); keys.append(key)
        try fail()
        stored.insert(key)
        try loseReply()
        return subscribeReply
    }

    func remind(invoiceID: String, confirmClient: String?, key: String, lookup: Bool) async throws -> RemindResponse {
        if lookup { try lookUp("remind", key); return remindReply }
        calls.append("remind:\(invoiceID)"); reminded.append(confirmClient); keys.append(key); try fail(); stored.insert(key); return remindReply
    }

    func refund(_ body: [String: JSONValue], key: String, lookup: Bool) async throws -> RefundResponse {
        if lookup { try lookUp("refund", key); return body["confirm_token"] == nil ? refundAskReply : refundDoneReply }
        calls.append("refund"); refunded.append(body); keys.append(key); try fail()
        return body["confirm_token"] == nil ? refundAskReply : refundDoneReply
    }

    func reply(_ text: String) async throws -> ReplyResponse { calls.append("reply"); replied.append(text); try fail(); return replyReply }
    func fix(_ text: String) async throws -> WriteResponse { calls.append("fix"); return writeReply }
    func refine(_ text: String, tone: String) async throws -> WriteResponse { calls.append("refine"); return writeReply }
    func toneCheck(draft: String, client: String?) async throws -> ToneResponse { calls.append("tone"); return toneReply }
    func payments() async throws -> [Payment] { calls.append("payments"); try fail(); return paymentsReply }

    var explainReply = ExplainResponse(short: "A log is the power you need.", body: "log10(100) = 2", visual_ok: true)
    var visualReply = Data(#"{"title":"Logs","canvas":{"w":800,"h":500},"steps":[]}"#.utf8)
    private(set) var explained: [String] = []
    func explain(_ text: String) async throws -> ExplainResponse { calls.append("explain"); explained.append(text); return explainReply }
    func explainVisual(_ topic: String) async throws -> Data { calls.append("visual"); explained.append(topic); return visualReply }
    var shareReply = "http://localhost/d/AAAAAAAAAAAAAAAAAAAAAA.png"
    private(set) var shared: [Data] = []
    func shareDrawing(_ png: Data) async throws -> String { calls.append("share"); shared.append(png); return shareReply }

    /// The PayPal actions of server/src/actions-more.ts. A call with no confirm_ value answers needsConfirm when `moreNeedsConfirm`.
    var moreReply = MoreResponse(line: "Done \u{2713}", undo: nil)
    var readReply = MoreResponse(line: "Ana $40/mo \u{00B7} active", undo: nil)
    var moreNeedsConfirm = false
    private(set) var moreSent: [(path: String, body: [String: JSONValue])] = []

    func more(_ path: String, _ body: [String: JSONValue], key: String, lookup: Bool) async throws -> MoreResponse {
        if lookup { try lookUp("more", key); return moreReply }
        calls.append("more:\(path)"); moreSent.append((path, body)); keys.append(key)
        try fail()
        if moreNeedsConfirm, !body.keys.contains(where: { $0.hasPrefix("confirm_") }) { throw APIError.needsConfirm(recipient: "Ana") }
        stored.insert(key)
        return moreReply
    }

    func moreRead(_ path: String) async throws -> MoreResponse { calls.append("read:\(path)"); try fail(); return readReply }
}

/// In-memory stand-in for the App Group files and the Keychain token. Paired by default.
final class FakeStore: KeyboardStore {
    var deviceToken: String? = "pkd_fake"
    var keyboardLastSeen: Date?
    var lastPasteboardChange = 0
    var appointments: [Appointment] = []
    var unpaidCount: Int?
    var notes: [Note] = []
    var actionShortcuts: [ActionShortcut] = ActionShortcut.defaults
    var pendingAction: PendingAction?
    var touchOffsets: [Double] = []
    private(set) var drawings: [(png: Data, title: String, scene: Data?)] = []
    func saveDrawing(_ png: Data, title: String, scene: Data?) throws { drawings.append((png, title, scene)) }
    private(set) var learned: [Learned] = []
    func recordLearned(_ l: Learned) { learned.append(l) }
}

/// The phone's calendar and reminders, in memory. `granted` is what the app was allowed.
final class FakeWriter: SmartWriter {
    struct Failure: Error {}
    var granted: Set<SmartChip.Place> = [.calendar, .reminders, .notes]
    var fails = false
    private(set) var events: [String: (title: String, start: Date, end: Date?)] = [:]
    private(set) var reminders: [String: (title: String, due: Date)] = [:]

    func access(_ place: SmartChip.Place, hasFullAccess: Bool) -> SmartAccess {
        guard hasFullAccess else { return .needsFullAccess }
        return granted.contains(place) ? .ready : .needsPermission
    }
    func addEvent(title: String, start: Date, end: Date?) throws -> String {
        if fails { throw Failure() }
        let id = "E\(events.count + 1)"; events[id] = (title, start, end); return id
    }
    func addReminder(title: String, due: Date) throws -> String {
        if fails { throw Failure() }
        let id = "R\(reminders.count + 1)"; reminders[id] = (title, due); return id
    }
    func removeEvent(_ id: String) throws { events[id] = nil }
    func removeReminder(_ id: String) throws { reminders[id] = nil }
}

final class FakePasteboard: Pasteboard {
    var string: String?
    var changeCount = 0
    var hasStrings: Bool { string != nil }

    func copy(_ s: String) { string = s; changeCount += 1 }
    private(set) var png: Data?
    func setPNG(_ png: Data) { self.png = png; changeCount += 1 }
}

/// A clock the test moves by hand. sleep waits until advance() moves `now` past its deadline,
/// so a loop that sleeps does not spin and a debounce really waits.
/// Main-actor bound so tasks that sleep at the same time do not race on the waiters.
@MainActor
final class FakeClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var sleeps: [Duration] = []
    private var waiters: [(id: UUID, until: Date, cont: CheckedContinuation<Void, Error>)] = []

    nonisolated init() {}

    /// Tasks asleep right now.
    var sleeping: Int { waiters.count }

    func advance(_ seconds: TimeInterval) {
        now += seconds
        let due = waiters.filter { $0.until <= now }
        waiters.removeAll { $0.until <= now }
        for w in due { w.cont.resume() }
    }

    /// `sleeps` records only the waits that began, not those of tasks already cancelled.
    func sleep(_ d: Duration) async throws {
        let id = UUID()
        let until = now + Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { cont.resume(throwing: CancellationError()); return }
                sleeps.append(d)
                waiters.append((id, until, cont))
            }
        } onCancel: {
            Task { @MainActor in self.wake(id, throwing: CancellationError()) }
        }
    }

    private func wake(_ id: UUID, throwing error: Error) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).cont.resume(throwing: error)
    }
}

/// A voice that makes no sound: it records each line and finishes only when the test says so.
@MainActor
final class FakeSpeaker: Speaker {
    private(set) var said: [String] = []
    private(set) var stops = 0
    private var pending: (() -> Void)?
    nonisolated init() {}
    /// Like the real one, a new line ends the one before it (its completion runs first).
    func say(_ text: String, done: @escaping () -> Void) { let p = pending; pending = nil; p?(); said.append(text); pending = done }
    func stop() { stops += 1; let p = pending; pending = nil; p?() }
    /// The current line ends.
    func finish() { let p = pending; pending = nil; p?() }
}

@MainActor
extension KeyboardDeps {
    static func fake(api: FakeAPI, store: FakeStore = FakeStore(), pasteboard: FakePasteboard = FakePasteboard(),
                     clock: FakeClock = FakeClock(), writer: FakeWriter = FakeWriter(), speaker: FakeSpeaker = FakeSpeaker()) -> KeyboardDeps {
        KeyboardDeps(api: { api }, store: store, pasteboard: pasteboard,
                     now: { MainActor.assumeIsolated { clock.now } },
                     sleep: { d in try await clock.sleep(d) }, writer: writer, speaker: { speaker })
    }
}

extension Duration {
    var seconds: TimeInterval { Double(components.seconds) + Double(components.attoseconds) * 1e-18 }
}
