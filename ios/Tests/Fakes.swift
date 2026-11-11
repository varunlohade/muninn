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
    var enablesReturnKeyAutomatically = false

    var contextBeforeInput: String? { text }
    func insert(_ s: String) { text += s }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
    func nextKeyboard() {}
    func playClick() {}
}

/// Answers with canned replies and records every call. Main-actor bound, so the model's tasks and the test never race on it.
@MainActor
final class FakeAPI: KeyboardAPI {
    struct Failure: Error {}

    var suggestReply = SuggestResponse(chips: [], intent: "none", timings: nil)
    var invoiceReply = InvoiceResponse(id: "INV-1", status: "sent", pay_link: "https://fake.pay/INV-1", amount: "45.00", currency: "USD")
    var payLinkReply = PayLinkResponse(id: "PL-1", status: "created", approve_link: "https://fake.pay/PL-1", amount: "45.00", currency: "USD")
    var writeReply = WriteResponse(text: "", changed: nil)
    var toneReply = ToneResponse(tone: "ok", calm: nil)
    var paymentsReply: [Payment] = []
    /// When set, invoice() throws needsConfirm unless the payload carries this confirm_recipient.
    var requireConfirm: String?

    private(set) var calls: [String] = []
    private(set) var suggested: [(text: String, context: String?)] = []
    private(set) var invoiced: [[String: JSONValue]] = []
    /// When set, suggest() runs this before it answers, so a test can change the text mid-request.
    var duringSuggest: (() -> Void)?

    nonisolated init() {}

    func suggest(_ text: String, context: String?) async throws -> SuggestResponse {
        calls.append("suggest"); suggested.append((text, context))
        duringSuggest?()
        return suggestReply
    }

    func invoice(_ payload: [String: JSONValue]) async throws -> InvoiceResponse {
        calls.append("invoice"); invoiced.append(payload)
        if let r = requireConfirm, payload["confirm_recipient"] != .string(r) { throw APIError.needsConfirm(recipient: r) }
        return invoiceReply
    }

    func payLink(_ payload: [String: JSONValue]) async throws -> PayLinkResponse { calls.append("paylink"); return payLinkReply }
    func fix(_ text: String) async throws -> WriteResponse { calls.append("fix"); return writeReply }
    func refine(_ text: String, tone: String) async throws -> WriteResponse { calls.append("refine"); return writeReply }
    func toneCheck(draft: String, client: String?) async throws -> ToneResponse { calls.append("tone"); return toneReply }
    func payments() async throws -> [Payment] { calls.append("payments"); return paymentsReply }
}

/// In-memory stand-in for the App Group files and the Keychain token. Paired by default.
final class FakeStore: KeyboardStore {
    var deviceToken: String? = "pkd_fake"
    var keyboardLastSeen: Date?
    var lastPasteboardChange = 0
    var appointments: [Appointment] = []
    var notes: [Note] = []
    var actionShortcuts: [ActionShortcut] = ActionShortcut.defaults
}

final class FakePasteboard: Pasteboard {
    var string: String?
    var changeCount = 0
    var hasStrings: Bool { string != nil }

    func copy(_ s: String) { string = s; changeCount += 1 }
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

@MainActor
extension KeyboardDeps {
    static func fake(api: FakeAPI, store: FakeStore = FakeStore(), pasteboard: FakePasteboard = FakePasteboard(),
                     clock: FakeClock = FakeClock()) -> KeyboardDeps {
        KeyboardDeps(api: { api }, store: store, pasteboard: pasteboard,
                     now: { MainActor.assumeIsolated { clock.now } },
                     sleep: { d in try await clock.sleep(d) })
    }
}
