import Foundation
import UIKit

/// The server calls the keyboard makes. APIClient is the real one; tests pass a fake.
protocol KeyboardAPI {
    func suggest(_ text: String, context: String?) async throws -> SuggestResponse
    func invoice(_ payload: [String: JSONValue], key: String) async throws -> InvoiceResponse
    func payLink(_ payload: [String: JSONValue], key: String) async throws -> PayLinkResponse
    func remind(invoiceID: String, key: String) async throws -> RemindResponse
    func refund(_ body: [String: JSONValue], key: String) async throws -> RefundResponse
    func reply(_ text: String) async throws -> ReplyResponse
    func fix(_ text: String) async throws -> WriteResponse
    func refine(_ text: String, tone: String) async throws -> WriteResponse
    func toneCheck(draft: String, client: String?) async throws -> ToneResponse
    func payments() async throws -> [Payment]
}

extension APIClient: KeyboardAPI {}

/// What the keyboard reads and writes on the device. SharedKeyboardStore is the real one.
protocol KeyboardStore: AnyObject {
    var deviceToken: String? { get }
    var keyboardLastSeen: Date? { get set }
    var lastPasteboardChange: Int { get set }
    var appointments: [Appointment] { get }
    var notes: [Note] { get set }
    var actionShortcuts: [ActionShortcut] { get }
}

final class SharedKeyboardStore: KeyboardStore {
    var deviceToken: String? { SharedStore.deviceToken }
    var keyboardLastSeen: Date? {
        get { SharedStore.keyboardLastSeen }
        set { SharedStore.keyboardLastSeen = newValue }
    }
    var lastPasteboardChange: Int {
        get { SharedStore.lastPasteboardChange }
        set { SharedStore.lastPasteboardChange = newValue }
    }
    var appointments: [Appointment] { SharedStore.appointments }
    var notes: [Note] {
        get { SharedStore.notes }
        set { SharedStore.notes = newValue }
    }
    var actionShortcuts: [ActionShortcut] { SharedStore.actionShortcuts }
}

/// The parts of UIPasteboard the keyboard uses. Only reading `string` can show the paste prompt.
protocol Pasteboard: AnyObject {
    var hasStrings: Bool { get }
    var changeCount: Int { get }
    var string: String? { get }
}

extension UIPasteboard: Pasteboard {}

/// Everything KeyboardModel reaches outside itself, except the text host.
struct KeyboardDeps {
    var api: () -> KeyboardAPI
    var store: KeyboardStore
    var pasteboard: Pasteboard
    var now: () -> Date
    var sleep: (Duration) async throws -> Void

    static func live() -> KeyboardDeps {
        KeyboardDeps(api: { APIClient.shared() }, store: SharedKeyboardStore(), pasteboard: UIPasteboard.general,
                     now: Date.init, sleep: { try await Task.sleep(for: $0) })
    }
}
