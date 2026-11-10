import Foundation
import UIKit
import os

/// What the keyboard needs from its host. The extension maps it to textDocumentProxy.
/// The app's debug screen maps it to a plain string.
@MainActor
protocol TextHost: AnyObject {
    var contextBeforeInput: String? { get }
    var hasFullAccess: Bool { get }
    var needsGlobeKey: Bool { get }
    var returnKeyType: UIReturnKeyType { get }
    var autocapitalization: UITextAutocapitalizationType { get }
    var enablesReturnKeyAutomatically: Bool { get }
    func insert(_ text: String)
    func deleteBackward()
    func nextKeyboard()
    func playClick()
}

enum ShiftState { case off, once, locked }

/// What the return key says, from the field's returnKeyType. Non-default types get the blue key, like iOS.
struct ReturnStyle: Equatable {
    let title: String?
    let accent: Bool

    init(_ type: UIReturnKeyType) {
        switch type {
        case .go: title = "go"
        case .google, .yahoo, .search: title = "search"
        case .join: title = "join"
        case .next: title = "next"
        case .route: title = "route"
        case .send: title = "send"
        case .done: title = "done"
        case .emergencyCall: title = "Emergency"
        case .continue: title = "continue"
        default: title = nil
        }
        accent = title != nil && type != .next && type != .continue
    }
}

enum BarState: Equatable {
    case idle
    case chips([Chip], fromCopied: Bool)
    case working(String)
    case confirm(Chip, recipient: String)
    case done(String)
    case error(String)
}

/// A sent invoice or pay link the keyboard watches until it is paid.
struct Watch: Equatable {
    let id: String
    let who: String
    let money: String
    var paid = false
}

@MainActor
final class KeyboardModel: ObservableObject {
    @Published var bar: BarState = .idle
    @Published var watch: Watch?
    @Published var copiedAvailable = false
    /// Today's appointments, as the main app last wrote them. The keyboard never reads the calendar.
    @Published var appointments: [Appointment] = []
    @Published var notesOpen = false
    @Published var notes: [Note] = []
    @Published var layout: KeyLayout = .letters
    @Published var shift: ShiftState = .once
    @Published var isDark = false
    @Published var pressedKeys: Set<String> = []
    @Published var calloutKeyID: String?
    @Published var returnStyle = ReturnStyle(.default)
    @Published var hasFullAccess = false
    @Published var paired = false
    @Published var lastLatencyMs: Int?

    weak var host: TextHost?
    var api: () -> APIClient = APIClient.shared
    private var suggestTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var lastSent = ""
    /// The appointment whose "Invoice Sam" chip started the current request, and the ones invoiced from here.
    private var billing: Appointment?
    private var billedHere: Set<String> = []
    private let log = Logger(subsystem: "com.orseliyas.muninn", category: "keyboard")
    static let pollInterval: Duration = .seconds(10)
    static let pasteTimeout: TimeInterval = 8

    func refreshAccess() {
        hasFullAccess = host?.hasFullAccess ?? false
        paired = hasFullAccess && SharedStore.deviceToken != nil
        returnStyle = ReturnStyle(host?.returnKeyType ?? .default)
    }

    // MARK: keys (touch model of the system keyboard)

    private var active: [ObjectIdentifier: KeyCap] = [:]
    private var lastShiftTap: Date?
    private var lastSpaceTap: Date?
    private var deleteTask: Task<Void, Never>?

    func display(_ c: String) -> String { layout == .letters && shift != .off ? c.uppercased() : c }

    func touchBegan(_ id: ObjectIdentifier, _ key: KeyCap) {
        host?.playClick()
        // A new touch commits any letter still held by another finger, like iOS.
        for (other, k) in active where other != id { if case .char = k.kind { commit(k); release(other) } }
        active[id] = key
        pressedKeys.insert(key.id)
        if case .char = key.kind { calloutKeyID = key.id }
        if key.kind == .delete { deleteDown() }
    }

    func touchMoved(_ id: ObjectIdentifier, _ key: KeyCap) {
        guard let current = active[id], current.id != key.id, case .char = current.kind, case .char = key.kind else { return }
        pressedKeys.remove(current.id)
        active[id] = key
        pressedKeys.insert(key.id)
        calloutKeyID = key.id
    }

    func touchEnded(_ id: ObjectIdentifier) {
        guard let key = active[id] else { return }
        release(id)
        if key.kind == .delete { deleteTask?.cancel(); return }
        commit(key)
    }

    func touchCancelled(_ id: ObjectIdentifier) {
        if active[id]?.kind == .delete { deleteTask?.cancel() }
        release(id)
    }

    /// VoiceOver activation and tests without touches.
    func activate(_ key: KeyCap) {
        host?.playClick()
        if key.kind == .delete { host?.deleteBackward(); afterEdit(); return }
        commit(key)
    }

    private func release(_ id: ObjectIdentifier) {
        if let k = active.removeValue(forKey: id) {
            pressedKeys.remove(k.id)
            if calloutKeyID == k.id { calloutKeyID = nil }
        }
    }

    private func commit(_ key: KeyCap) {
        switch key.kind {
        case .char(let c):
            host?.insert(display(c))
            if shift == .once && layout == .letters { shift = .off }
            if layout != .letters && c == "'" { layout = .letters }
            lastSpaceTap = nil
            afterEdit()
        case .shift:
            let now = Date()
            if shift == .locked { shift = .off }
            else if let last = lastShiftTap, now.timeIntervalSince(last) < 0.35 { shift = .locked }
            else { shift = shift == .off ? .once : .off }
            lastShiftTap = now
        case .mode(let to):
            layout = to
        case .space:
            tapSpace()
        case .ret:
            host?.insert("\n")
            lastSpaceTap = nil
            afterEdit()
        case .globe:
            host?.nextKeyboard()
        case .delete:
            break
        }
    }

    /// Double space after a word types ". ", like iOS. Space in 123 or #+= goes back to letters.
    private func tapSpace() {
        let now = Date()
        let before = host?.contextBeforeInput ?? ""
        if let last = lastSpaceTap, now.timeIntervalSince(last) < 0.45, before.hasSuffix(" "),
           let prev = before.dropLast().last, prev.isLetter || prev.isNumber {
            host?.deleteBackward()
            host?.insert(". ")
            lastSpaceTap = nil
        } else {
            host?.insert(" ")
            lastSpaceTap = now
        }
        if layout != .letters { layout = .letters }
        afterEdit()
    }

    /// Delete fires on touch down, repeats after 0.5 s, then speeds up to whole words.
    private func deleteDown() {
        host?.deleteBackward()
        afterEdit()
        deleteTask?.cancel()
        deleteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            var n = 0
            while !Task.isCancelled, let self {
                if n < 20 { self.host?.deleteBackward() } else { self.deleteWord() }
                self.afterEdit()
                n += 1
                try? await Task.sleep(for: .milliseconds(n < 20 ? 100 : 250))
            }
        }
    }

    private func deleteWord() {
        let before = host?.contextBeforeInput ?? ""
        var count = 0
        var seenWord = false
        for ch in before.reversed() {
            if ch.isWhitespace { if seenWord { break } } else { seenWord = true }
            count += 1
        }
        for _ in 0..<max(count, 1) { host?.deleteBackward() }
    }

    private func afterEdit() { textChanged() }

    /// Auto-capitalization follows the field's autocapitalizationType. Caps lock stays until tapped.
    func updateAutoShift() {
        guard shift != .locked else { return }
        let raw = host?.contextBeforeInput ?? ""
        let on: Bool
        switch host?.autocapitalization ?? .sentences {
        case .none: on = false
        case .allCharacters: on = true
        case .words: on = raw.isEmpty || raw.last?.isWhitespace == true
        default: on = raw.trimmingCharacters(in: .whitespaces).isEmpty || [". ", "! ", "? ", "\n"].contains { raw.hasSuffix($0) }
        }
        if layout == .letters { shift = on ? .once : .off }
    }

    // MARK: lifecycle

    /// On appear: note that the keyboard is on, offer copied text (without reading it), resume watching.
    func keyboardAppeared() {
        refreshAccess()
        layout = .letters
        updateAutoShift()
        guard hasFullAccess else { copiedAvailable = false; return }
        SharedStore.keyboardLastSeen = Date()
        guard paired else { return }
        appointments = SharedStore.appointments
        // hasStrings and changeCount do not trigger the paste prompt; only reading the string does.
        let pasteboard = UIPasteboard.general
        copiedAvailable = pasteboard.hasStrings && pasteboard.changeCount != SharedStore.lastPasteboardChange
        if let watch, !watch.paid { startPolling() }
    }

    func keyboardDisappeared() {
        notesOpen = false
        pollTask?.cancel()
        if watch?.paid == true { watch = nil }
    }

    // MARK: notes

    private var typed: String { (host?.contextBeforeInput ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    func toggleNotes() {
        host?.playClick()
        if !notesOpen { notes = SharedStore.notes }
        notesOpen.toggle()
    }

    /// A note goes into the field as it is. It is not sent for suggestions.
    func insertNote(_ note: Note) {
        host?.playClick()
        let before = host?.contextBeforeInput ?? ""
        host?.insert((before.last?.isWhitespace ?? true ? "" : " ") + note.text)
        lastSent = typed
        notesOpen = false
        updateAutoShift()
    }

    var canSaveNote: Bool { !typed.isEmpty && !notes.contains { $0.text == typed } }

    /// "+" keeps the text before the cursor as a new note, on this device.
    func saveNote() {
        guard canSaveNote else { return }
        host?.playClick()
        notes.insert(Note(text: typed), at: 0)
        SharedStore.notes = notes
    }

    // MARK: suggestions

    /// Called on every edit, from our keys and from textDidChange.
    func textChanged() {
        refreshAccess()
        updateAutoShift()
        guard paired else { return }
        if case .working = bar { return }
        if case .confirm = bar { return }
        let text = (host?.contextBeforeInput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != lastSent else { return }
        suggestTask?.cancel()
        guard !text.isEmpty else { lastSent = ""; billing = nil; bar = .idle; return }
        requestSuggest(text: billing.map { $0.invoicePrefix + " " + text } ?? text, context: nil, debounce: true, sentAs: text)
    }

    /// Tap on "Use copied message". Reading may show the system paste prompt once, so the read runs
    /// off the main thread with a timeout; the keyboard never waits on it.
    func useCopied() {
        let pasteboard = UIPasteboard.general
        SharedStore.lastPasteboardChange = pasteboard.changeCount
        copiedAvailable = false
        suggestTask?.cancel()
        bar = .working("Reading copied message…")
        suggestTask = Task { [weak self] in
            let copied = await Self.readPasteboard(timeout: Self.pasteTimeout)
            guard let self, !Task.isCancelled else { return }
            guard let copied = copied?.trimmingCharacters(in: .whitespacesAndNewlines), !copied.isEmpty else {
                self.bar = .error("Copied text not available")
                return
            }
            let text = (self.host?.contextBeforeInput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.bar = .idle
            self.requestSuggest(text: text, context: String(copied.prefix(1000)), debounce: false)
        }
    }

    nonisolated static func readPasteboard(timeout: TimeInterval) async -> String? {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var cont: CheckedContinuation<String?, Never>?
            init(_ c: CheckedContinuation<String?, Never>) { cont = c }
            func resume(_ v: String?) {
                lock.lock(); let c = cont; cont = nil; lock.unlock()
                c?.resume(returning: v)
            }
        }
        return await withCheckedContinuation { cont in
            let once = Once(cont)
            DispatchQueue.global(qos: .userInitiated).async { once.resume(UIPasteboard.general.string) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
        }
    }

    /// The latest ended appointment with a known client and no invoice today.
    var toBill: Appointment? {
        let now = Date()
        return appointments.last { $0.end <= now && !$0.billed && !billedHere.contains($0.id) && ($0.clientName ?? $0.clientEmail) != nil }
    }

    var nextUp: Appointment? {
        let now = Date()
        return appointments.first { $0.start > now }
    }

    /// Tap on "Invoice Sam": from now on the client goes in front of the typed amount and item.
    func invoiceAppointment(_ a: Appointment) {
        let typed = (host?.contextBeforeInput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        suggestTask?.cancel()
        billing = a
        guard !typed.isEmpty else { bar = .done("Type the amount for \(a.who)"); return }
        bar = .working("Invoice for \(a.who)…")
        requestSuggest(text: a.invoicePrefix + " " + typed, context: nil, debounce: false, sentAs: typed)
    }

    private func requestSuggest(text: String, context: String?, debounce: Bool, sentAs: String? = nil) {
        let typedAt = ContinuousClock.now
        lastSent = sentAs ?? text
        suggestTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: AppConfig.suggestDebounce) }
            guard let self, !Task.isCancelled else { return }
            do {
                let res = try await self.api().suggest(text, context: context)
                guard !Task.isCancelled else { return }
                let ms = Int((ContinuousClock.now - typedAt) / .milliseconds(1))
                self.lastLatencyMs = ms
                self.log.notice("MUNINN_TIMING keystroke_to_chip_ms=\(ms, privacy: .public) chips=\(res.chips.count, privacy: .public) server_ms=\(res.timings?["total_ms"] ?? -1, privacy: .public) copied=\(context != nil, privacy: .public)")
                if res.chips.isEmpty, let a = self.billing {
                    self.bar = .done("Type the amount for \(a.who)")
                } else {
                    self.bar = res.chips.isEmpty ? .idle : .chips(res.chips, fromCopied: context != nil)
                }
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                guard !Task.isCancelled else { return }
                self.lastSent = ""
                self.bar = .error(error.localizedDescription)
            }
        }
    }

    // MARK: actions

    func tapChip(_ chip: Chip) {
        if chip.kind == "invoice", chip.needs_confirm, case .string(let email)? = chip.payload["client_email"] {
            bar = .confirm(chip, recipient: email)
            return
        }
        run(chip, confirmed: nil)
    }

    func confirm(_ chip: Chip, recipient: String) { run(chip, confirmed: recipient) }

    func cancelConfirm() { bar = .idle; lastSent = "" }

    private func run(_ chip: Chip, confirmed: String?) {
        suggestTask?.cancel()
        bar = .working(chip.kind == "invoice" ? "Creating invoice…" : "Creating link…")
        Task {
            do {
                let r = try await ChipActions.run(chip, confirmed: confirmed, api: api())
                let before = host?.contextBeforeInput ?? ""
                let needsGap = !(before.last?.isWhitespace ?? true)
                host?.insert((needsGap ? (r.kind == "invoice" ? "\n" : " ") : "") + r.message)
                lastSent = (host?.contextBeforeInput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                bar = .idle
                watch = Watch(id: r.id, who: r.who, money: r.money)
                if let billing { billedHere.insert(billing.id) }
                billing = nil
                startPolling()
            } catch APIError.needsConfirm(let recipient) {
                bar = .confirm(chip, recipient: recipient)
            } catch {
                bar = .error(error.localizedDescription)
            }
        }
    }

    /// Light polling, only while the keyboard is visible: at most one /v1/payments call every 10 s.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled, let w = self.watch, !w.paid else { return }
                guard let payments = try? await self.api().payments() else { continue }
                if payments.first(where: { $0.id == w.id })?.state == "paid" {
                    self.watch?.paid = true
                    return
                }
            }
        }
    }
}
