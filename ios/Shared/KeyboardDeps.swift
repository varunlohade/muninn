import Foundation
import UIKit
import UniformTypeIdentifiers

/// The server calls the keyboard makes. APIClient is the real one; tests pass a fake.
protocol KeyboardAPI {
    func suggest(_ text: String, context: String?) async throws -> SuggestResponse
    /// `lookup`: return the stored answer for `key`, or throw a 404. Never runs the action.
    func invoice(_ payload: [String: JSONValue], key: String, lookup: Bool) async throws -> InvoiceResponse
    func payLink(_ payload: [String: JSONValue], key: String, lookup: Bool) async throws -> PayLinkResponse
    func subscribe(_ payload: [String: JSONValue], key: String, lookup: Bool) async throws -> SubscribeResponse
    /// `confirmClient`: the client the confirm tap showed. The server sends no reminder without it.
    func remind(invoiceID: String, confirmClient: String?, key: String, lookup: Bool) async throws -> RemindResponse
    func refund(_ body: [String: JSONValue], key: String, lookup: Bool) async throws -> RefundResponse
    func reply(_ text: String) async throws -> ReplyResponse
    func fix(_ text: String) async throws -> WriteResponse
    func refine(_ text: String, tone: String) async throws -> WriteResponse
    func toneCheck(draft: String, client: String?) async throws -> ToneResponse
    func payments() async throws -> [Payment]
    func more(_ path: String, _ body: [String: JSONValue], key: String, lookup: Bool) async throws -> MoreResponse
    func moreRead(_ path: String) async throws -> MoreResponse
    func explain(_ text: String) async throws -> ExplainResponse
    func explainVisual(_ topic: String) async throws -> Data
    func chart(back: Int, ahead: Int) async throws -> ChartData
    func shareDrawing(_ png: Data) async throws -> String
}

/// The intro demo has no PayPal actions beyond its scripted ones.
extension KeyboardAPI {
    func more(_ path: String, _ body: [String: JSONValue], key: String, lookup: Bool) async throws -> MoreResponse {
        throw APIError.message("Open \(AppConfig.displayName) for this one")
    }
    func moreRead(_ path: String) async throws -> MoreResponse { throw APIError.message("Open \(AppConfig.displayName) for this one") }
    func explain(_ text: String) async throws -> ExplainResponse { throw APIError.message("No explain in the intro") }
    func explainVisual(_ topic: String) async throws -> Data { throw APIError.message("No explain in the intro") }
    func shareDrawing(_ png: Data) async throws -> String { throw APIError.message("No sharing in the intro") }
    func chart(back: Int, ahead: Int) async throws -> ChartData { throw APIError.message("Open \(AppConfig.displayName) for this one") }
}

extension APIClient: KeyboardAPI {}

/// What the keyboard reads and writes on the device. SharedKeyboardStore is the real one.
protocol KeyboardStore: AnyObject {
    var deviceToken: String? { get }
    var keyboardLastSeen: Date? { get set }
    var lastPasteboardChange: Int { get set }
    var appointments: [Appointment] { get }
    var unpaidCount: Int? { get }
    var notes: [Note] { get set }
    var actionShortcuts: [ActionShortcut] { get }
    /// A money call still waiting for its answer, kept when the keyboard closes.
    var pendingAction: PendingAction? { get set }
    /// The touch decoder's learned tap offsets.
    var touchOffsets: [Double] { get set }
    /// An exported visual explanation, kept in the App Group.
    func saveDrawing(_ png: Data, title: String, scene: Data?) throws
    /// A word, answer or chart the owner opened in the keyboard.
    func recordLearned(_ l: Learned)
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
    var unpaidCount: Int? { SharedStore.unpaidCount }
    var notes: [Note] {
        get { SharedStore.notes }
        set { SharedStore.notes = newValue }
    }
    var actionShortcuts: [ActionShortcut] { SharedStore.actionShortcuts }
    var pendingAction: PendingAction? {
        get { SharedStore.pendingAction }
        set { SharedStore.pendingAction = newValue }
    }
    var touchOffsets: [Double] {
        get { SharedStore.touchOffsets }
        set { SharedStore.touchOffsets = newValue }
    }
    func saveDrawing(_ png: Data, title: String, scene: Data?) throws { try SharedStore.saveDrawing(png, title: title, scene: scene) }
    func recordLearned(_ l: Learned) { SharedStore.learned = [l] + SharedStore.learned.filter { $0.id != l.id } }
}

/// The parts of UIPasteboard the keyboard uses. Only reading `string` can show the paste prompt.
protocol Pasteboard: AnyObject {
    var hasStrings: Bool { get }
    var changeCount: Int { get }
    var string: String? { get }
    /// Puts an image on the pasteboard, so it pastes into a chat. Needs Full Access in the keyboard.
    func setPNG(_ png: Data)
}

extension UIPasteboard: Pasteboard {
    func setPNG(_ png: Data) { setData(png, forPasteboardType: UTType.png.identifier) }
}

/// Everything KeyboardModel reaches outside itself, except the text host.
struct KeyboardDeps {
    var api: () -> KeyboardAPI
    var store: KeyboardStore
    var pasteboard: Pasteboard
    var now: () -> Date
    var sleep: (Duration) async throws -> Void
    /// The phone's calendar and reminders, for smart chips.
    var writer: SmartWriter = EventKitWriter()
    /// The catalog the app cached in the App Group.
    var catalog: CatalogCache = .live
    /// Puts a catalog photo on the pasteboard. Needs Full Access.
    var copyImage: (Data) -> Void = { data in
        let png = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        UIPasteboard.general.setData(data, forPasteboardType: png ? "public.png" : "public.jpeg")
    }

    /// The voice for "Play with voice". Only a tap starts it; tests pass a silent fake.
    var speaker: @MainActor () -> Speaker = { SystemSpeaker() }

    static func live() -> KeyboardDeps {
        KeyboardDeps(api: { APIClient.shared() }, store: SharedKeyboardStore(), pasteboard: UIPasteboard.general,
                     now: Date.init, sleep: { try await Task.sleep(for: $0) })
    }
}
