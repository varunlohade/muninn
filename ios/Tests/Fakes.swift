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

/// Answers with canned replies and records every call.
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

    func suggest(_ text: String, context: String?) async throws -> SuggestResponse {
        calls.append("suggest"); suggested.append((text, context))
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

/// A clock the test moves by hand. sleep records the wait, gives other tasks a turn, and returns.
/// Main-actor bound so tasks that sleep at the same time do not race on `sleeps`.
@MainActor
final class FakeClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var sleeps: [Duration] = []

    nonisolated init() {}

    func advance(_ seconds: TimeInterval) { now += seconds }

    func sleep(_ d: Duration) async throws {
        sleeps.append(d)
        await Task.yield()
        try Task.checkCancellation()
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
