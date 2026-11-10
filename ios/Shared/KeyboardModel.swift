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

@MainActor
final class KeyboardModel: ObservableObject {
    @Published var bar: BarState = .idle
    @Published var shifted = true
    @Published var symbols = false
    @Published var hasFullAccess = false
    @Published var paired = false
    @Published var lastLatencyMs: Int?

    weak var host: TextHost?
    var api: () -> APIClient = APIClient.shared
    private var suggestTask: Task<Void, Never>?
    private var lastSent = ""
    private let log = Logger(subsystem: "com.orseliyas.muninn", category: "keyboard")

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

    /// When the keyboard appears: if the owner copied new text (e.g. a client's message), send it once as context.
    /// The pasteboard is never read without Full Access, and each changeCount is used at most once.
    func keyboardAppeared() {
        refreshAccess()
        guard hasFullAccess, paired else { return }
        let pasteboard = UIPasteboard.general
        guard pasteboard.changeCount != SharedStore.lastPasteboardChange else { return }
        SharedStore.lastPasteboardChange = pasteboard.changeCount
        guard pasteboard.hasStrings,
              let copied = pasteboard.string?.trimmingCharacters(in: .whitespacesAndNewlines), !copied.isEmpty else { return }
        let text = (host?.contextBeforeInput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        suggestTask?.cancel()
        requestSuggest(text: text, context: String(copied.prefix(1000)), debounce: false)
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
        Task {
            do {
                let insertion: String
                let separator: String
                switch chip.kind {
                case "invoice":
                    var payload = chip.payload
                    if let confirmed { payload["confirm_recipient"] = .string(confirmed) }
                    let res = try await api().invoice(payload)
                    guard let link = res.pay_link else { bar = .error("No link came back"); return }
                    // Item comes from the server-built chip, amount from the server's reply.
                    let item = if case .string(let v)? = chip.payload["item"] { v } else { "your order" }
                    insertion = "Here's your invoice for \(item) (\(formatMoney(res.amount, res.currency))): \(link)"
                    separator = "\n"
                case "paylink":
                    guard let link = try await api().payLink(chip.payload).approve_link else { bar = .error("No link came back"); return }
                    insertion = link
                    separator = " "
                default:
                    bar = .done("Open \(AppConfig.displayName) for this one")
                    return
                }
                let before = host?.contextBeforeInput ?? ""
                let needsGap = !(before.last?.isWhitespace ?? true)
                host?.insert((needsGap ? separator : "") + insertion)
                lastSent = (host?.contextBeforeInput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                bar = .done(chip.kind == "invoice" ? "Invoice sent · link added" : "Link added")
            } catch APIError.needsConfirm(let recipient) {
                bar = .confirm(chip, recipient: recipient)
            } catch {
                bar = .error(error.localizedDescription)
            }
        }
    }
}
