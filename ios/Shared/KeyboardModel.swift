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
    func insert(_ text: String)
    func deleteBackward()
    func nextKeyboard()
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
    @Published var shifted = true
    @Published var symbols = false
    @Published var hasFullAccess = false
    @Published var paired = false
    @Published var lastLatencyMs: Int?

    weak var host: TextHost?
    var api: () -> APIClient = APIClient.shared
    private var suggestTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var lastSent = ""
    private let log = Logger(subsystem: "com.orseliyas.muninn", category: "keyboard")
    static let pollInterval: Duration = .seconds(10)
    static let pasteTimeout: TimeInterval = 8

    func refreshAccess() {
        hasFullAccess = host?.hasFullAccess ?? false
        paired = hasFullAccess && SharedStore.deviceToken != nil
    }

    // MARK: keys

    func tapKey(_ s: String) {
        host?.insert(shifted && !symbols ? s.uppercased() : s)
        if shifted && !symbols { shifted = false }
        textChanged()
    }

    func tapSpace() { host?.insert(" "); textChanged() }
    func tapReturn() { host?.insert("\n"); textChanged() }
    func tapDelete() { host?.deleteBackward(); textChanged() }

    // MARK: lifecycle

    /// On appear: note that the keyboard is on, offer copied text (without reading it), resume watching.
    func keyboardAppeared() {
        refreshAccess()
        guard hasFullAccess else { copiedAvailable = false; return }
        SharedStore.keyboardLastSeen = Date()
        guard paired else { return }
        // hasStrings and changeCount do not trigger the paste prompt; only reading the string does.
        let pasteboard = UIPasteboard.general
        copiedAvailable = pasteboard.hasStrings && pasteboard.changeCount != SharedStore.lastPasteboardChange
        if let watch, !watch.paid { startPolling() }
    }

    func keyboardDisappeared() {
        pollTask?.cancel()
        if watch?.paid == true { watch = nil }
    }

    // MARK: suggestions

    /// Called on every edit, from our keys and from textDidChange.
    func textChanged() {
        refreshAccess()
        guard paired else { return }
        if case .working = bar { return }
        if case .confirm = bar { return }
        let raw = host?.contextBeforeInput ?? ""
        shifted = raw.isEmpty || [". ", "! ", "? ", "\n"].contains { raw.hasSuffix($0) }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != lastSent else { return }
        suggestTask?.cancel()
        guard !text.isEmpty else { lastSent = ""; bar = .idle; return }
        requestSuggest(text: text, context: nil, debounce: true)
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

    private func requestSuggest(text: String, context: String?, debounce: Bool) {
        let typedAt = ContinuousClock.now
        lastSent = text
        suggestTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: AppConfig.suggestDebounce) }
            guard let self, !Task.isCancelled else { return }
            do {
                let res = try await self.api().suggest(text, context: context)
                guard !Task.isCancelled else { return }
                let ms = Int((ContinuousClock.now - typedAt) / .milliseconds(1))
                self.lastLatencyMs = ms
                self.log.notice("MUNINN_TIMING keystroke_to_chip_ms=\(ms, privacy: .public) chips=\(res.chips.count, privacy: .public) server_ms=\(res.timings?["total_ms"] ?? -1, privacy: .public) copied=\(context != nil, privacy: .public)")
                self.bar = res.chips.isEmpty ? .idle : .chips(res.chips, fromCopied: context != nil)
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
        let who = if case .string(let v)? = chip.payload["client_name"] { v } else { "Client" }
        Task {
            do {
                let insertion: String
                let separator: String
                let id: String
                let money: String
                switch chip.kind {
                case "invoice":
                    var payload = chip.payload
                    if let confirmed { payload["confirm_recipient"] = .string(confirmed) }
                    let res = try await api().invoice(payload)
                    guard let link = res.pay_link else { bar = .error("No link came back"); return }
                    // Item comes from the server-built chip, amount from the server's reply.
                    let item = if case .string(let v)? = chip.payload["item"] { v } else { "your order" }
                    money = formatMoney(res.amount, res.currency)
                    insertion = "Here's your invoice for \(item) (\(money)): \(link)"
                    separator = "\n"
                    id = res.id
                case "paylink":
                    let res = try await api().payLink(chip.payload)
                    guard let link = res.approve_link else { bar = .error("No link came back"); return }
                    money = if case .string(let a)? = chip.payload["amount"], case .string(let c)? = chip.payload["currency"] { formatMoney(a, c) } else { "" }
                    insertion = link
                    separator = " "
                    id = res.id
                default:
                    bar = .done("Open \(AppConfig.displayName) for this one")
                    return
                }
                let before = host?.contextBeforeInput ?? ""
                let needsGap = !(before.last?.isWhitespace ?? true)
                host?.insert((needsGap ? separator : "") + insertion)
                lastSent = (host?.contextBeforeInput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                bar = .idle
                watch = Watch(id: id, who: who, money: money)
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
