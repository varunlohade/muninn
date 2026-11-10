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

/// The one-tap rewrites in the Refine panel. The raw value is the server's tone name.
enum RefineTone: String, CaseIterable, Identifiable {
    case professional, friendly, shorter, firmer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .professional: "More professional"
        case .friendly: "Friendlier"
        case .shorter: "Shorter"
        case .firmer: "Firmer"
        }
    }
}

/// A rewrite the owner can look at before it replaces `original`, the text before the cursor.
struct WritePreview: Equatable {
    let kind: String
    let title: String
    let original: String
    let text: String
}

enum WritePanel: Equatable {
    case menu
    case busy(String)
    case preview(WritePreview)
    case message(String)
}

/// The last replacement, kept for a few seconds so one tap puts the old text back.
struct WriteUndo: Equatable {
    let label: String
    let original: String
    let replacement: String
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
    @Published var writeOpen = false
    @Published var writePanel: WritePanel = .menu
    @Published var undo: WriteUndo?
    /// A sentence is before the cursor, so the bar offers Fix.
    @Published var fixable = false
    /// A calm reply for an upset copied message, ready to preview.
    @Published var calmOffer: WritePreview?
    /// "fix", "refine" or "tone" after a rewrite went into the field, and the trigger of the last shortcut. The intro watches both.
    @Published var lastWrite: String?
    @Published var lastShortcut: String?
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
    /// False in the intro scenes about writing, where a payment chip would get in the way. Then typing sends nothing.
    var suggestsWhileTyping = true
    var api: () -> APIClient = APIClient.shared
    private var suggestTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var lastSent = ""
    private var actions: [ActionShortcut] = ActionShortcut.defaults
    private var writeTask: Task<Void, Never>?
    private var undoTask: Task<Void, Never>?
    /// The last text Fix returned or found clean, so the chip does not offer the same text twice.
    private var lastFixed = ""
    static let undoWindow: Duration = .seconds(5)
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
            if expandShortcut() { break }
            tapSpace()
        case .ret:
            if expandShortcut() { break }
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
        reloadShortcuts()
        guard paired else { return }
        appointments = SharedStore.appointments
        // hasStrings and changeCount do not trigger the paste prompt; only reading the string does.
        let pasteboard = UIPasteboard.general
        copiedAvailable = pasteboard.hasStrings && pasteboard.changeCount != SharedStore.lastPasteboardChange
        if let watch, !watch.paid { startPolling() }
    }

    func keyboardDisappeared() {
        notesOpen = false
        resetWriting()
        pollTask?.cancel()
        if watch?.paid == true { watch = nil }
    }

    // MARK: notes

    private var typed: String { (host?.contextBeforeInput ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    func toggleNotes() {
        host?.playClick()
        writeOpen = false
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
        updateFixable()
        if let u = undo, !(host?.contextBeforeInput ?? "").hasSuffix(u.replacement) { undo = nil }
        guard paired, suggestsWhileTyping else { return }
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
            self.checkCopiedTone(String(copied.prefix(1000)))
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

    // MARK: writing help (Fix, Refine, Tone check). Text leaves the phone only on a tap.

    /// The paragraph before the cursor: `text` goes to the server, `original` is what a rewrite replaces.
    private var draft: (text: String, original: String) {
        let before = host?.contextBeforeInput ?? ""
        let start = before.lastIndex(where: \.isNewline).map { before.index(after: $0) } ?? before.startIndex
        let original = String(before[start...].drop(while: \.isWhitespace))
        return (original.trimmingCharacters(in: .whitespaces), original)
    }

    private func updateFixable() {
        let text = draft.text
        fixable = paired && text != lastFixed && text.split(separator: " ").count >= 3
    }

    /// Deletes exactly `original` before the cursor and types `new`. False when the text is no longer there.
    private func replace(_ original: String, with new: String) -> Bool {
        guard let host, (host.contextBeforeInput ?? "").hasSuffix(original) else { return false }
        for _ in 0..<original.count { host.deleteBackward() }
        host.insert(new)
        lastSent = typed
        updateAutoShift()
        return true
    }

    private func apply(_ p: WritePreview, label: String) {
        guard replace(p.original, with: p.text) else { bar = .error("The text changed. Try again."); return }
        lastFixed = p.text
        fixable = false
        bar = .idle
        lastWrite = p.kind
        undo = WriteUndo(label: label, original: p.original, replacement: p.text)
        undoTask?.cancel()
        undoTask = Task { [weak self] in
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            self?.undo = nil
        }
    }

    func undoWrite() {
        guard let u = undo else { return }
        host?.playClick()
        undoTask?.cancel()
        undo = nil
        if replace(u.replacement, with: u.original) { lastFixed = u.original.trimmingCharacters(in: .whitespaces) }
    }

    /// Tap on the Fix chip, or the fix shortcut.
    func fix() {
        let d = draft
        guard !d.text.isEmpty else { return }
        host?.playClick()
        suggestTask?.cancel()
        writeTask?.cancel()
        bar = .working("Fixing\u{2026}")
        writeTask = Task { [weak self] in
            do {
                guard let res = try await self?.api().fix(d.text), let self, !Task.isCancelled else { return }
                if res.text == d.text {
                    self.lastFixed = d.text
                    self.fixable = false
                    self.bar = .done("Looks good \u{2713}")
                } else {
                    self.apply(WritePreview(kind: "fix", title: "Fix", original: d.original, text: res.text), label: "Fixed \u{2713}")
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.bar = .error("Could not fix that. Try again.")
            }
        }
    }

    func toggleWrite() {
        host?.playClick()
        notesOpen = false
        writeTask?.cancel()
        writePanel = .menu
        writeOpen.toggle()
    }

    var canWrite: Bool { !draft.text.isEmpty }

    func refine(_ tone: RefineTone) {
        let d = draft
        guard !d.text.isEmpty else { return }
        runPanel("Writing\u{2026}") { api in
            let res = try await api.refine(d.text, tone: tone.rawValue)
            return .preview(WritePreview(kind: "refine", title: tone.title, original: d.original, text: res.text))
        }
    }

    /// Tap on Tone check: is the draft blunt? If so, show a calm version.
    func checkTone() {
        let d = draft
        guard !d.text.isEmpty else { return }
        runPanel("Checking the tone\u{2026}") { api in
            let res = try await api.toneCheck(draft: d.text, client: nil)
            guard res.tone != "ok", let calm = res.calm else { return .message("The tone is fine \u{2713}") }
            return .preview(WritePreview(kind: "tone", title: "Calmer version", original: d.original, text: calm))
        }
    }

    private func runPanel(_ label: String, _ work: @escaping (APIClient) async throws -> WritePanel) {
        host?.playClick()
        writeTask?.cancel()
        writePanel = .busy(label)
        writeTask = Task { [weak self] in
            do {
                guard let api = self?.api() else { return }
                let next = try await work(api)
                guard let self, !Task.isCancelled else { return }
                self.writePanel = next
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.writePanel = .message("That did not work. Try again.")
            }
        }
    }

    func backToWriteMenu() {
        host?.playClick()
        writeTask?.cancel()
        writePanel = .menu
    }

    /// Tap on the preview: it replaces the text before the cursor.
    func usePreview() {
        guard case .preview(let p) = writePanel else { return }
        host?.playClick()
        writeOpen = false
        writePanel = .menu
        if calmOffer == p { calmOffer = nil }
        apply(p, label: "Replaced \u{2713}")
    }

    /// The owner tapped "Use copied message". If the client sounds upset, offer a calm reply.
    private func checkCopiedTone(_ copied: String) {
        let d = draft
        calmOffer = nil
        writeTask?.cancel()
        writeTask = Task { [weak self] in
            guard let res = try? await self?.api().toneCheck(draft: d.text, client: copied), let self, !Task.isCancelled,
                  res.tone != "ok", let calm = res.calm else { return }
            self.calmOffer = WritePreview(kind: "tone", title: "Calm reply", original: d.original, text: calm)
        }
    }

    func openCalmOffer() {
        guard let p = calmOffer else { return }
        host?.playClick()
        notesOpen = false
        writePanel = .preview(p)
        writeOpen = true
    }

    /// A clean slate: between intro scenes, and when the keyboard goes away.
    func resetWriting() {
        writeTask?.cancel()
        undoTask?.cancel()
        writeOpen = false
        writePanel = .menu
        undo = nil
        calmOffer = nil
        lastWrite = nil
        lastShortcut = nil
        lastFixed = ""
    }

    // MARK: shortcuts

    func reloadShortcuts() {
        notes = SharedStore.notes
        actions = SharedStore.actionShortcuts
    }

    /// The intro's shortcut scene types ";prices". This makes sure the demo price note answers to it.
    func addDemoShortcut() {
        let demo = Note.demo[0]
        var all = SharedStore.notes
        if !all.contains(where: { $0.trigger == demo.trigger }) {
            if let i = all.firstIndex(where: { $0.text == demo.text }) { all[i].trigger = demo.trigger } else { all.insert(demo, at: 0) }
            SharedStore.notes = all
        }
        reloadShortcuts()
    }

    /// Runs on space and return. If the last word is a trigger, the shortcut replaces it and the key is used up.
    private func expandShortcut() -> Bool {
        guard hasFullAccess, let host else { return false }
        let before = host.contextBeforeInput ?? ""
        let words = before.split(omittingEmptySubsequences: false, whereSeparator: \.isWhitespace)
        guard let last = words.last, last.count >= 2 else { return false }
        let key = last.lowercased()
        func remove(_ count: Int) { for _ in 0..<count { host.deleteBackward() } }
        func finish() {
            lastShortcut = key
            lastSent = typed
            updateAutoShift()
            updateFixable()
        }

        if let note = notes.first(where: { $0.trigger == key }) {
            remove(last.count)
            host.insert(note.text)
            finish()
            return true
        }
        let on = actions.filter(\.enabled)
        if let a = on.first(where: { $0.trigger == key }) {
            switch a.action {
            case .pay: return false
            case .late:
                remove(last.count)
                finish()
                showLate()
            case .fix:
                remove(last.count + (words.count > 1 && before.dropLast(last.count).last == " " ? 1 : 0))
                finish()
                fix()
            }
            return true
        }
        if words.count >= 2, let pay = on.first(where: { $0.action == .pay }), words[words.count - 2].lowercased() == pay.trigger,
           before.hasSuffix(" " + last), let amount = Shortcuts.amount(String(last)) {
            remove(last.count + 1 + pay.trigger.count)
            finish()
            offerPayLink(amount.value, currency: amount.currency)
            return true
        }
        return false
    }

    /// The pay shortcut only offers the chip. Money moves on the owner's tap, through the same path as a suggested chip.
    private func offerPayLink(_ amount: String, currency: String?) {
        guard paired else { return }
        suggestTask?.cancel()
        var payload: [String: JSONValue] = ["amount": .string(amount), "item": .string("Payment")]
        if let currency { payload["currency"] = .string(currency) }
        bar = .chips([Chip(kind: "paylink", label: "Pay link", payload: payload, needs_confirm: false)], fromCopied: false)
    }

    private func showLate() {
        guard paired else { return }
        suggestTask?.cancel()
        bar = .working("Checking who owes you\u{2026}")
        suggestTask = Task { [weak self] in
            do {
                guard let payments = try await self?.api().payments(), let self, !Task.isCancelled else { return }
                self.bar = .done(Self.lateLine(payments))
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.bar = .error("Could not check. Try again.")
            }
        }
    }

    /// "Ana $90 · 2d late, Sam $45 +1 more"
    static func lateLine(_ payments: [Payment]) -> String {
        let unpaid = payments.filter { $0.kind == "invoice" && $0.state == "unpaid" }.sorted { $0.days_overdue > $1.days_overdue }
        guard !unpaid.isEmpty else { return "Nobody owes you \u{2713}" }
        let shown = unpaid.prefix(2).map { p in
            "\(p.client_name ?? "Client") \(formatMoney(p.amount, p.currency))" + (p.days_overdue > 0 ? " \u{00B7} \(p.days_overdue)d late" : "")
        }
        return shown.joined(separator: ", ") + (unpaid.count > 2 ? " +\(unpaid.count - 2) more" : "")
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
