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
    /// A second tap the server asked for, such as "Refund $45 to Sam?". `chip` runs it.
    case ask(Chip, question: String)
    case done(String)
    case error(String)
    /// A money call a check never found: a tap sends the same chip again with its same key.
    case retry(Chip, confirmed: String?)
    /// Done, with Undo beside it: "Paused ✓ · Undo". `undo` runs the reverse.
    case undoable(String, undo: Chip)
}

/// The one-tap rewrites in the Rewrite panel. The raw value is the server's tone name.
enum RefineTone: String, CaseIterable, Identifiable {
    case polite, shorter, professional, friendly, firmer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .polite: "More polite"
        case .shorter: "Shorter"
        case .professional: "More professional"
        case .friendly: "Friendlier"
        case .firmer: "Firm (for late payers)"
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

/// A smart chip one tap added, and what Undo removes.
struct SmartAdded: Equatable {
    enum Item: Equatable { case event(String), reminder(String), note(UUID) }
    let chip: SmartChip
    let label: String
    let item: Item
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
    /// The "Who hasn't paid" list, open above the keys. Nil when closed.
    @Published var whoPaid: [UnpaidClient]?
    /// The card a lookup chip opened ("invoice for sam"), above the keys.
    @Published var lookup: LookupResult?
    @Published var notes: [Note] = []
    @Published var writeOpen = false
    @Published var writePanel: WritePanel = .menu
    @Published var undo: WriteUndo?
    /// What Fix would change in the text before the cursor. Nil when it looks clean.
    @Published var fixPlan: FixPlan?
    var fixable: Bool { fixPlan != nil }
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
    /// Events, reminders and notes read from the typed text on the phone.
    @Published var smart: [SmartChip] = []
    /// The line after a smart chip was added, kept for the Undo window.
    @Published var added: SmartAdded?
    /// Nothing is typed, so the bar shows ready chips.
    @Published var fieldEmpty = true
    @Published var unpaidCount: Int?

    weak var host: TextHost?
    /// False in the intro scenes about writing, where a payment chip would get in the way. Then typing sends nothing.
    var suggestsWhileTyping = true
    private let deps: KeyboardDeps
    private var suggestTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    /// The message the shown chips came from. A reply chip answers it.
    private var chipSource: String?
    private var lastSent = ""
    private var suggest = SuggestPolicy()
    private var actions: [ActionShortcut] = ActionShortcut.defaults
    private var writeTask: Task<Void, Never>?
    private var undoTask: Task<Void, Never>?
    private var smartTask: Task<Void, Never>?
    private var addedTask: Task<Void, Never>?
    /// Smart chips added from the current text, so they do not come back after the tap.
    private var smartDone: Set<SmartChip> = []
    /// Device chips the server gave for a sentence, kept while the owner types on in that sentence.
    private var serverSmart: (sentence: String, chips: [SmartChip])?
    /// The last text Fix returned or found clean, so the chip does not offer the same text twice.
    private var lastFixed = ""
    static let undoWindow: Duration = .seconds(5)
    /// The appointment whose "Invoice Sam" chip started the current request, and the ones invoiced from here.
    private var billing: Appointment?
    private var billedHere: Set<String> = []
    private let log = Logger(subsystem: "com.orseliyas.muninn", category: "keyboard")
    static let pollInterval: Duration = .seconds(10)
    static let pasteTimeout: TimeInterval = 8

    init(deps: KeyboardDeps = .live()) {
        self.deps = deps
    }

    func refreshAccess() {
        hasFullAccess = host?.hasFullAccess ?? false
        paired = hasFullAccess && deps.store.deviceToken != nil
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
            let now = deps.now()
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
        let now = deps.now()
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
        let sleep = deps.sleep
        deleteTask = Task { [weak self] in
            try? await sleep(.milliseconds(500))
            var n = 0
            while !Task.isCancelled, let self {
                if n < 20 { self.host?.deleteBackward() } else { self.deleteWord() }
                self.afterEdit()
                n += 1
                try? await sleep(.milliseconds(n < 20 ? 100 : 250))
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
        shift = on ? .once : .off
    }

    // MARK: lifecycle

    /// On appear: note that the keyboard is on, offer copied text (without reading it), resume watching.
    func keyboardAppeared() {
        refreshAccess()
        layout = .letters
        updateAutoShift()
        guard hasFullAccess else { copiedAvailable = false; return }
        deps.store.keyboardLastSeen = deps.now()
        reloadShortcuts()
        guard paired else { return }
        reloadSnapshot()
        // hasStrings and changeCount do not trigger the paste prompt; only reading the string does.
        let pasteboard = deps.pasteboard
        copiedAvailable = pasteboard.hasStrings && pasteboard.changeCount != deps.store.lastPasteboardChange
        resumePending()
        if let watch, !watch.paid { startPolling() }
    }

    /// A money call the keyboard closed on may have gone out. Look it up with the same key; a lookup never sends.
    private func resumePending() {
        guard let p = deps.store.pendingAction else { return }
        guard p.expires > deps.now() else { deps.store.pendingAction = nil; return }
        if case .working = bar { return }
        let api = deps.api()
        let store = deps.store
        let sleep = deps.sleep
        actionTask?.cancel()
        actionTask = Task { [weak self] in
            do {
                let outcome = try await ChipActions.run(p.chip, confirmed: p.confirmed, api: api, key: p.key, lookup: true, sleep: sleep)
                // A tap on another chip since then cleared it: that tap owns the bar.
                guard let self, !Task.isCancelled, store.pendingAction == p else { return }
                store.pendingAction = nil
                switch outcome {
                case .sent(let r):
                    // The link goes in only where the owner left it, and never into an empty field.
                    if !p.before.isEmpty, (self.host?.contextBeforeInput ?? "") == p.before {
                        self.place(r.message, gap: r.kind == "invoice" ? "\n" : " ", readAt: p.before)
                    } else if r.kind == "invoice" {
                        self.bar = .done(r.emailed ? "Invoice emailed to \(r.who) \u{2713}" : "Invoice link ready \u{2713}")
                    } else {
                        self.offerInsert(r.message)
                    }
                    if r.kind != "subscribe" { self.watch = Watch(id: r.id, who: r.who, money: r.money) }
                    self.startPolling()
                case .line(let text):
                    self.bar = .done(text)
                case .undoable(let text, let undo):
                    self.bar = .undoable(text, undo: undo)
                case .insert, .ask:
                    break
                }
            } catch {
                guard !Task.isCancelled, store.pendingAction == p else { return }
                // Not found or refused: it never went out, so drop it with no line. Offline or in progress: the next appear looks again.
                if !(error is URLError), !isInProgress(error) { store.pendingAction = nil }
            }
        }
    }

    /// What the app last wrote for the ready chips: today's appointments and the unpaid count.
    private func reloadSnapshot() {
        appointments = deps.store.appointments
        unpaidCount = deps.store.unpaidCount
    }

    func keyboardDisappeared() {
        notesOpen = false
        whoPaid = nil
        resetWriting()
        pollTask?.cancel()
        actionTask?.cancel()
        if case .working = bar { bar = .idle }
        if watch?.paid == true { watch = nil }
    }

    // MARK: notes

    private var typed: String { (host?.contextBeforeInput ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    func toggleNotes() {
        host?.playClick()
        writeOpen = false
        if !notesOpen { notes = deps.store.notes }
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
        deps.store.notes = notes
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
        if case .ask = bar { return }
        let text = typed
        let wasEmpty = fieldEmpty
        fieldEmpty = text.isEmpty
        // Empty again, as after a send: the ready chips read the app's latest snapshot.
        if text.isEmpty, !wasEmpty { reloadSnapshot() }
        let clear = detectSmart(text)
        suggest.observe(text)
        switch SuggestPolicy.ask(text, lastAsked: lastSent, prefix: billing?.invoicePrefix, clear: clear) {
        case .keep:
            return
        case .skip:
            suggestTask?.cancel()
            lastSent = text
            if text.isEmpty { billing = nil }
            bar = .idle
            if let sentence = suggest.maybe(text, clear: clear) {
                requestSuggest(text: sentence, context: nil, debounce: SuggestPolicy.debounce, sentAs: text, maybe: true)
            }
        case .ask(let sent, let after):
            suggestTask?.cancel()
            requestSuggest(text: sent, context: nil, debounce: after, sentAs: text)
        }
    }

    /// Tap on "Use copied message". Reading may show the system paste prompt once, so the read runs
    /// off the main thread with a timeout; the keyboard never waits on it.
    func useCopied() {
        let pasteboard = deps.pasteboard
        deps.store.lastPasteboardChange = pasteboard.changeCount
        copiedAvailable = false
        suggestTask?.cancel()
        bar = .working("Reading copied message…")
        suggestTask = Task { [weak self] in
            let copied = await Self.readPasteboard(pasteboard, timeout: Self.pasteTimeout)
            guard let self, !Task.isCancelled else { return }
            guard let copied = copied?.trimmingCharacters(in: .whitespacesAndNewlines), !copied.isEmpty else {
                self.bar = .error("Copied text not available")
                return
            }
            let text = (self.host?.contextBeforeInput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.bar = .idle
            self.requestSuggest(text: text, context: String(copied.prefix(1000)), debounce: nil)
            self.checkCopiedTone(String(copied.prefix(1000)))
        }
    }

    nonisolated static func readPasteboard(_ pasteboard: Pasteboard, timeout: TimeInterval) async -> String? {
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
            DispatchQueue.global(qos: .userInitiated).async { once.resume(pasteboard.string) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
        }
    }

    var toBill: Appointment? { AppointmentRules.toBill(appointments, now: deps.now(), billed: billedHere) }

    var nextUp: Appointment? { AppointmentRules.nextUp(appointments, now: deps.now()) }

    /// Tap on "Invoice Sam": from now on the client goes in front of the typed amount and item.
    func invoiceAppointment(_ a: Appointment) {
        let typed = (host?.contextBeforeInput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        suggestTask?.cancel()
        billing = a
        guard !typed.isEmpty else { bar = .done("Type the amount for \(a.who)"); return }
        bar = .working("Invoice for \(a.who)…")
        requestSuggest(text: a.invoicePrefix + " " + typed, context: nil, debounce: nil, sentAs: typed)
    }

    /// On every pause, on the phone: events, reminders and notes in the typed text. True when something clear was found.
    private func detectSmart(_ text: String) -> Bool {
        smartTask?.cancel()
        if text.isEmpty { smart = []; smartDone = []; serverSmart = nil; return false }
        let found = SmartDetect.detect(text, now: deps.now(), clients: appointments.compactMap(\.clientName))
        let kept = serverSmart.flatMap { s in SuggestPolicy.sentenceKey(SmartDetect.lastSentence(text)) == s.sentence ? s.chips : nil } ?? []
        let shown = Array((found + kept.filter { k in !found.contains { $0.id == k.id } }).filter { !smartDone.contains($0) }.prefix(SmartDetect.maxChips))
        guard shown != smart else { return !found.isEmpty }
        let sleep = deps.sleep
        smartTask = Task { [weak self] in
            try? await sleep(SuggestPolicy.debounce)
            guard let self, !Task.isCancelled else { return }
            self.smart = shown
        }
        return !found.isEmpty
    }

    /// `maybe`: the sentence had no clear match on the phone; the server's device chips may answer it.
    private func requestSuggest(text: String, context: String?, debounce: Duration?, sentAs: String? = nil, maybe: Bool = false) {
        let typedAt = ContinuousClock.now
        let askedFor = sentAs ?? text
        lastSent = askedFor
        let sleep = deps.sleep
        suggestTask = Task { [weak self] in
            if let debounce { try? await sleep(debounce) }
            guard let self, !Task.isCancelled else { return }
            if maybe { self.suggest.markAsked(text) }
            do {
                let res = try await self.deps.api().suggest(text, context: context)
                guard !Task.isCancelled else { return }
                let device = res.chips.filter { Self.deviceKinds.contains($0.kind) }
                if !device.isEmpty, self.typed == askedFor {
                    let more = device.compactMap { Self.smartChip($0, sentence: text, now: self.deps.now()) }.filter { !self.smartDone.contains($0) }
                    self.serverSmart = (SuggestPolicy.sentenceKey(text), more)
                    self.smart = Array((self.smart + more.filter { m in !self.smart.contains { $0.id == m.id } }).prefix(SmartDetect.maxChips))
                }
                if maybe { return }
                guard let chips = self.suggest.show(res.chips.filter { !Self.deviceKinds.contains($0.kind) }, askedFor: askedFor, current: self.typed) else {
                    // The text moved on while the server thought. Ask again for what is there now.
                    self.log.notice("MUNINN_SUGGEST stale reply dropped")
                    if case .working = self.bar { self.bar = .idle }
                    self.textChanged()
                    return
                }
                let ms = Int((ContinuousClock.now - typedAt) / .milliseconds(1))
                self.lastLatencyMs = ms
                self.log.notice("MUNINN_TIMING keystroke_to_chip_ms=\(ms, privacy: .public) chips=\(chips.count, privacy: .public) server_ms=\(res.timings?["total_ms"] ?? -1, privacy: .public) copied=\(context != nil, privacy: .public)")
                if chips.isEmpty, let a = self.billing {
                    self.bar = .done("Type the amount for \(a.who)")
                } else {
                    self.bar = chips.isEmpty ? .idle : .chips(chips, fromCopied: context != nil)
                }
                self.chipSource = context ?? text
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                // A maybe ask is a guess the owner never asked for: a failure stays quiet.
                guard !Task.isCancelled, !maybe else { return }
                self.lastSent = ""
                self.bar = .error(plainLine(error))
            }
        }
    }

    /// Kinds the server answers on the "maybe an action" path. They run on the phone, never on the server.
    static let deviceKinds: Set<String> = ["event", "reminder", "note", "followup"]

    /// A server device chip as a smart chip. The phone fills a time the server left out from its own reading of the sentence.
    static func smartChip(_ c: Chip, sentence: String, now: Date, calendar cal: Calendar = .current) -> SmartChip? {
        let title = BarItems.string(c, "title") ?? ""
        let when = SmartDetect.findWhen(sentence, now: now, cal: cal)
        let iso = { (key: String) in BarItems.string(c, key).flatMap { ISO8601DateFormatter().date(from: $0) } }
        let trigger = c.trigger ?? when.map { String(sentence[$0.range]) } ?? String(sentence.prefix(24))
        let at9 = { (d: Date) in cal.date(bySettingHour: 9, minute: 0, second: 0, of: d) ?? d }
        switch c.kind {
        case "event":
            guard !title.isEmpty, let start = iso("start") ?? when?.date else { return nil }
            let end = iso("end") ?? ((when?.hasTime ?? true) ? start.addingTimeInterval(3600) : nil)
            return SmartChip(action: .event(title: title, start: start, end: end), trigger: trigger)
        case "reminder", "followup":
            guard !title.isEmpty else { return nil }
            let due = iso("due") ?? when.map { $0.hasTime ? $0.date : at9($0.date) } ?? at9(now.addingTimeInterval(86_400))
            return SmartChip(action: .reminder(title: title, due: due), trigger: trigger)
        case "note":
            guard let text = BarItems.string(c, "text") else { return nil }
            return SmartChip(action: .note(text: text), trigger: trigger)
        default:
            return nil
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
        let d = draft
        guard paired, d.text != lastFixed, d.text.split(separator: " ").count >= 3 else { fixPlan = nil; return }
        fixPlan = localFix(d)
    }

    /// The on-device fix for the draft. The chip and its tap both use this, so the tap does exactly what the chip said.
    private func localFix(_ d: (text: String, original: String)) -> FixPlan? {
        FixCheck.plan(d.text, names: appointments.compactMap(\.clientName), skipLast: d.original.last?.isLetter ?? false)
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
        fixPlan = nil
        bar = .idle
        lastWrite = p.kind
        undo = WriteUndo(label: label, original: p.original, replacement: p.text)
        undoTask?.cancel()
        let sleep = deps.sleep
        undoTask = Task { [weak self] in
            try? await sleep(Self.undoWindow)
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

    /// Tap on the Fix chip, or the fix shortcut. Typos, capitals and spacing are fixed on the phone.
    /// The shortcut on text with none of those asks the server for a grammar fix.
    func fix() {
        let d = draft
        guard !d.text.isEmpty else { return }
        host?.playClick()
        suggestTask?.cancel()
        writeTask?.cancel()
        if let plan = localFix(d) {
            apply(WritePreview(kind: "fix", title: plan.title, original: d.original, text: plan.fixed), label: plan.done)
            return
        }
        bar = .working("Fixing\u{2026}")
        writeTask = Task { [weak self] in
            do {
                guard let res = try await self?.deps.api().fix(d.text), let self, !Task.isCancelled else { return }
                if res.text == d.text {
                    self.lastFixed = d.text
                    self.fixPlan = nil
                    self.bar = .done("Looks good \u{2713}")
                } else {
                    self.apply(WritePreview(kind: "fix", title: "Fix grammar", original: d.original, text: res.text), label: "Fixed grammar \u{2713}")
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

    /// Tap on Fix grammar in the Rewrite panel: the server fixes grammar and spelling, and the result shows first.
    func fixGrammar() {
        let d = draft
        guard !d.text.isEmpty else { return }
        runPanel("Checking the grammar\u{2026}") { api in
            let res = try await api.fix(d.text)
            guard res.text != d.text else { return .message("The grammar looks good \u{2713}") }
            return .preview(WritePreview(kind: "fix", title: "Fix grammar", original: d.original, text: res.text))
        }
    }

    private func runPanel(_ label: String, _ work: @escaping (KeyboardAPI) async throws -> WritePanel) {
        host?.playClick()
        writeTask?.cancel()
        writePanel = .busy(label)
        writeTask = Task { [weak self] in
            do {
                guard let api = self?.deps.api() else { return }
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
            guard let res = try? await self?.deps.api().toneCheck(draft: d.text, client: copied), let self, !Task.isCancelled,
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
        notes = deps.store.notes
        actions = deps.store.actionShortcuts
    }

    /// The intro's shortcut scene types ";prices". This makes sure the demo price note answers to it.
    func addDemoShortcut() {
        let demo = Note.demo[0]
        var all = deps.store.notes
        if !all.contains(where: { $0.trigger == demo.trigger }) {
            if let i = all.firstIndex(where: { $0.text == demo.text }) { all[i].trigger = demo.trigger } else { all.insert(demo, at: 0) }
            deps.store.notes = all
        }
        reloadShortcuts()
    }

    /// Runs on space and return. If the last word is a trigger, the shortcut replaces it and the key is used up.
    private func expandShortcut() -> Bool {
        guard hasFullAccess, let host,
              let m = ShortcutEngine.match(before: host.contextBeforeInput ?? "", notes: notes, actions: actions) else { return false }
        for _ in 0..<m.delete { host.deleteBackward() }
        if case .insert(let text) = m.action { host.insert(text) }
        lastShortcut = m.trigger
        lastSent = typed
        updateAutoShift()
        updateFixable()
        switch m.action {
        case .insert: break
        case .late: openWhoPaid()
        case .fix: fix()
        case .payLink(let amount, let currency): offerPayLink(amount, currency: currency)
        }
        return true
    }

    /// The pay shortcut only offers the chip. Money moves on the owner's tap, through the same path as a suggested chip.
    private func offerPayLink(_ amount: String, currency: String?) {
        guard paired else { return }
        suggestTask?.cancel()
        var payload: [String: JSONValue] = ["amount": .string(amount), "item": .string("Payment")]
        if let currency { payload["currency"] = .string(currency) }
        bar = .chips([Chip(kind: "paylink", label: "Pay link", payload: payload, needs_confirm: false)], fromCopied: false)
    }

    /// The "Who paid?" chip and the late shortcut: the list opens above the keys. Each card's Remind goes through the bar's confirm.
    func openWhoPaid() {
        guard paired else { return }
        suggestTask?.cancel()
        bar = .working("Checking who owes you\u{2026}")
        suggestTask = Task { [weak self] in
            do {
                guard let payments = try await self?.deps.api().payments(), let self, !Task.isCancelled else { return }
                let clients = WhoPaid.clients(payments, keeping: self.whoPaid ?? [])
                self.whoPaid = clients.isEmpty ? nil : clients
                self.bar = clients.isEmpty ? .done(WhoPaid.empty) : .idle
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.bar = .error("Could not check. Try again.")
            }
        }
    }

    func closeWhoPaid() {
        host?.playClick()
        whoPaid = nil
    }

    // MARK: lookup ("invoice for sam")

    /// The typed words the open lookup came from. Insert puts the line in their place.
    private var lookupTrigger: String?

    /// A lookup chip opens its card above the keys. Nothing is sent.
    func openLookup(_ chip: Chip) {
        guard let r = LookupResult(chip: chip) else { return }
        host?.playClick()
        whoPaid = nil
        lookup = r
        lookupTrigger = chip.trigger
        bar = .idle
    }

    func closeLookup() {
        host?.playClick()
        lookup = nil
    }

    /// Types the record's line. The typed lookup words were for Muninn, not the client, so the line takes their place.
    func insertLookup(_ rec: LookupResult.Record) {
        lookup = nil
        if let t = lookupTrigger, typed.hasSuffix(t), replace(t, with: rec.line) { bar = .idle; return }
        place(rec.line, gap: " ", readAt: host?.contextBeforeInput ?? "")
    }

    /// The same Remind chip and confirm as everywhere else.
    func remindFromLookup(_ chip: Chip) {
        lookup = nil
        tapChip(chip)
    }

    /// No record yet: start the "Invoice Sam" flow. The owner types the amount, and the invoice chip still asks to confirm.
    func newInvoiceFromLookup(_ name: String) {
        lookup = nil
        if let t = lookupTrigger, typed.hasSuffix(t) { _ = replace(t, with: "") }
        let at = deps.now()
        invoiceAppointment(Appointment(start: at, end: at, title: name, clientName: name))
    }

    /// "Ana $90 · 2d late, Sam $45 +1 more"
    nonisolated static func lateLine(_ payments: [Payment]) -> String {
        let unpaid = payments.filter { $0.kind == "invoice" && $0.state == "unpaid" }.sorted { $0.days_overdue > $1.days_overdue }
        guard !unpaid.isEmpty else { return "Nobody owes you \u{2713}" }
        let shown = unpaid.prefix(2).map { p in
            "\(p.client_name ?? "Client") \(formatMoney(p.amount, p.currency))" + (p.days_overdue > 0 ? " \u{00B7} \(p.days_overdue)d late" : "")
        }
        return shown.joined(separator: ", ") + (unpaid.count > 2 ? " +\(unpaid.count - 2) more" : "")
    }

    // MARK: bar

    var barItems: [BarItems.Item] {
        let writer = deps.writer
        return BarItems.build(.init(hasFullAccess: hasFullAccess, paired: paired, undo: undo, hasCalmOffer: calmOffer != nil, watch: watch,
                                    bar: bar, copiedAvailable: copiedAvailable, toBill: toBill, nextUp: nextUp,
                                    smart: smart.map { BarItems.Smart(chip: $0, access: writer.access($0.place, hasFullAccess: hasFullAccess)) },
                                    added: added?.label, fieldEmpty: fieldEmpty, moneyTrigger: SmartDetect.moneyTrigger(typed),
                                    ready: .init(copiedAvailable: copiedAvailable, toBill: toBill, nextUp: nextUp, today: appointments,
                                                 unpaidCount: unpaidCount, watch: watch),
                                    now: deps.now()))
    }

    func perform(_ action: BarItems.Action) {
        switch action {
        case .useCopied: useCopied()
        case .bill(let a): invoiceAppointment(a)
        case .chip(let chip): tapChip(chip)
        case .confirm(let chip, let recipient): confirm(chip, recipient: recipient)
        case .retry(let chip, let confirmed): run(chip, confirmed: confirmed)
        case .cancelConfirm: cancelConfirm()
        case .undo: undoWrite()
        case .openCalm: openCalmOffer()
        case .smart(let chip): tapSmart(chip)
        case .undoSmart: undoSmart()
        case .whoPaid: openWhoPaid()
        case .today: showToday()
        case .notes: toggleNotes()
        }
    }

    // MARK: smart chips (on the phone, no server)

    /// One tap adds it: the chip is the confirm. The bar then shows what was added, with Undo for a few seconds.
    func tapSmart(_ chip: SmartChip) {
        guard deps.writer.access(chip.place, hasFullAccess: hasFullAccess) == .ready else { return }
        host?.playClick()
        let item: SmartAdded.Item
        do {
            switch chip.action {
            case .event(let title, let start, let end): item = .event(try deps.writer.addEvent(title: title, start: start, end: end))
            case .reminder(let title, let due): item = .reminder(try deps.writer.addReminder(title: title, due: due))
            case .invoiceLater(let client, let due): item = .reminder(try deps.writer.addReminder(title: "Invoice \(client)", due: due))
            case .note(let text):
                let note = Note(text: text)
                notes = [note] + deps.store.notes
                deps.store.notes = notes
                item = .note(note.id)
            }
        } catch {
            bar = .error("Could not add that. Try again.")
            return
        }
        smartDone.insert(chip)
        smart.removeAll { $0 == chip }
        added = SmartAdded(chip: chip, label: chip.doneLabel(now: deps.now()), item: item)
        addedTask?.cancel()
        let sleep = deps.sleep
        addedTask = Task { [weak self] in
            try? await sleep(Self.undoWindow)
            guard !Task.isCancelled else { return }
            self?.added = nil
        }
    }

    /// Removes what the last smart tap added, and offers the chip again.
    func undoSmart() {
        guard let a = added else { return }
        host?.playClick()
        addedTask?.cancel()
        added = nil
        switch a.item {
        case .event(let id): try? deps.writer.removeEvent(id)
        case .reminder(let id): try? deps.writer.removeReminder(id)
        case .note(let id):
            notes = deps.store.notes.filter { $0.id != id }
            deps.store.notes = notes
        }
        smartDone.remove(a.chip)
        if !smart.contains(a.chip) { smart.insert(a.chip, at: 0) }
    }

    /// "9:20 Sam · 11:00 Ava", from the snapshot the app wrote.
    private func showToday() {
        bar = .done(appointments.isEmpty ? "Nothing on your calendar today" : appointments.map { "\($0.time) \($0.who)" }.joined(separator: " \u{00B7} "))
    }

    // MARK: actions

    func tapChip(_ chip: Chip) {
        // A new tap ends any call left from before: it is never sent or shown again.
        deps.store.pendingAction = nil
        if chip.kind == "payments" { return openWhoPaid() }
        if chip.kind == "lookup" { return openLookup(chip) }
        if chip.kind == Self.insertKind, case .string(let text)? = chip.payload["text"] {
            place(text, gap: " ", readAt: host?.contextBeforeInput ?? "")
            return
        }
        if BarItems.asksFirst(chip) {
            bar = .confirm(chip, recipient: BarItems.recipient(chip))
            return
        }
        run(chip, confirmed: nil)
    }

    func confirm(_ chip: Chip, recipient: String) { run(chip, confirmed: recipient) }

    /// Cancel turns the chip away: it stays off the bar until the text changes.
    func cancelConfirm() {
        if case .confirm(let chip, _) = bar { suggest.dismiss(chip, on: typed) }
        if case .ask(let chip, _) = bar { suggest.dismiss(chip, on: typed) }
        bar = .idle
        lastSent = ""
    }

    private func run(_ chip: Chip, confirmed: String?) {
        suggestTask?.cancel()
        actionTask?.cancel()
        bar = .working(Self.workingLine(chip))
        // What the field held at the tap. The result goes in only if the field still holds it.
        let before = host?.contextBeforeInput ?? ""
        let source = chipSource
        let api = deps.api()
        let sleep = deps.sleep
        let store = deps.store
        let sendsMoney = ChipActions.sendsMoney.contains(chip.kind)
        let key = chip.key
        // Kept until the server answers, so closing the keyboard mid-call does not lose a sent invoice.
        if sendsMoney {
            store.pendingAction = PendingAction(chip: chip, confirmed: confirmed, before: before, key: key, expires: deps.now() + PendingAction.ttl)
        }
        actionTask = Task { [weak self] in
            do {
                let outcome: ChipOutcome
                do {
                    outcome = try await ChipActions.run(chip, confirmed: confirmed, source: source, api: api, key: key, sleep: sleep,
                                                        stillSending: { self?.bar = .working("Still sending\u{2026}") })
                } catch where sendsMoney && ChipActions.mayHaveRun(error) {
                    // It may have run on the server. Keep the pending call and its key, and only look it up.
                    guard let self, !Task.isCancelled else { return }
                    self.bar = .working("Not sure it went through. Checking\u{2026}")
                    guard let found = try await ChipActions.check(chip, confirmed: confirmed, api: api, key: key, sleep: sleep) else {
                        guard !Task.isCancelled else { return }
                        // The pending call stays: the next appear looks it up again, in case it lands late.
                        self.bar = .retry(chip, confirmed: confirmed)
                        return
                    }
                    outcome = found
                }
                guard let self, !Task.isCancelled else { return }
                if sendsMoney { store.pendingAction = nil }
                switch outcome {
                case .sent(let r):
                    self.place(r.message, gap: r.kind == "invoice" ? "\n" : " ", readAt: before)
                    // A repeat bill is not in the payments list, so there is nothing to watch.
                    if r.kind != "subscribe" { self.watch = Watch(id: r.id, who: r.who, money: r.money) }
                    if let billing = self.billing { self.billedHere.insert(billing.id) }
                    self.billing = nil
                    self.startPolling()
                case .insert(let text):
                    self.place(text, gap: " ", readAt: before)
                case .line(let text):
                    self.bar = .done(text)
                case .ask(let question, let next):
                    self.bar = .ask(next, question: question)
                case .undoable(let text, let undo):
                    self.bar = .undoable(text, undo: undo)
                }
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch APIError.needsConfirm(let recipient) {
                guard let self, !Task.isCancelled else { return }
                if sendsMoney { store.pendingAction = nil }
                self.bar = .confirm(chip, recipient: recipient)
            } catch {
                guard let self, !Task.isCancelled else { return }
                // Still in progress: keep it, so the next appear checks again with the same key.
                if sendsMoney, !isInProgress(error) { store.pendingAction = nil }
                self.bar = .error(plainLine(error))
            }
        }
    }

    static let insertKind = "insert"

    private static func workingLine(_ chip: Chip) -> String {
        switch chip.kind {
        case "invoice": "Creating invoice\u{2026}"
        case "paylink": "Creating link\u{2026}"
        case "subscribe": "Setting up repeat billing\u{2026}"
        case "remind": "Sending reminder\u{2026}"
        case "refund": chip.payload["confirm_token"] == nil ? "Checking refund\u{2026}" : "Refunding\u{2026}"
        case "payments": "Checking who owes you\u{2026}"
        case "reply": "Writing reply\u{2026}"
        default: ChipActions.working[chip.kind] ?? "One moment\u{2026}"
        }
    }

    /// Types `text` if the field still ends as it did at the tap. If the owner moved on, the text waits as a chip.
    private func place(_ text: String, gap: String, readAt before: String) {
        guard let host, (host.contextBeforeInput ?? "") == before else { return offerInsert(text) }
        let needsGap = !(before.last?.isWhitespace ?? true)
        host.insert((needsGap ? gap : "") + text)
        lastSent = typed
        bar = .idle
    }

    /// The text waits as a chip: it goes in only on a tap.
    private func offerInsert(_ text: String) {
        bar = .chips([Chip(kind: Self.insertKind, label: "Tap to add", payload: ["text": .string(text)], needs_confirm: false)], fromCopied: false)
    }

    /// Light polling, only while the keyboard is visible: at most one /v1/payments call every 10 s.
    private func startPolling() {
        pollTask?.cancel()
        let sleep = deps.sleep
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await sleep(Self.pollInterval)
                guard let self, !Task.isCancelled, let w = self.watch, !w.paid else { return }
                guard let payments = try? await self.deps.api().payments() else { continue }
                if payments.first(where: { $0.id == w.id })?.state == "paid" {
                    self.watch?.paid = true
                    return
                }
            }
        }
    }
}
