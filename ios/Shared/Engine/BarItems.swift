import Foundation

/// What the suggestion bar shows, slot by slot. Pure: the view maps tones to colors and actions to model calls.
enum BarItems {
    enum Tone: Equatable { case label, secondary, accent, paid, due }

    enum Action: Equatable {
        case useCopied
        case bill(Appointment)
        case chip(Chip)
        case confirm(Chip, recipient: String)
        case cancelConfirm
        case undo
        case openCalm
    }

    struct Item: Equatable, Identifiable {
        let id: String
        var title: String
        var detail: String? = nil
        var tone: Tone = .label
        var action: Action? = nil
    }

    struct State {
        var hasFullAccess: Bool
        var paired: Bool
        var undo: WriteUndo?
        var hasCalmOffer: Bool
        var watch: Watch?
        var bar: BarState
        var copiedAvailable: Bool
        var toBill: Appointment?
        var nextUp: Appointment?
    }

    static func build(_ s: State) -> [Item] {
        if !s.hasFullAccess { return [Item(id: "info", title: "Allow Full Access in Settings for \(AppConfig.keyboardName)", tone: .secondary)] }
        if !s.paired { return [Item(id: "info", title: "Open \(AppConfig.displayName) to pair", tone: .secondary)] }
        if let u = s.undo {
            return [Item(id: "written", title: u.label, tone: .paid), Item(id: "undo", title: "Undo", action: .undo)]
        }
        var out: [Item] = []
        if s.hasCalmOffer {
            out.append(Item(id: "calm", title: "Calm reply", detail: "client sounds upset", action: .openCalm))
        }
        if let w = s.watch {
            out.append(w.paid
                ? Item(id: "paid", title: "\(w.who) paid \(w.money) ✓", tone: .paid)
                : Item(id: "waiting", title: "Sent \(w.money)", detail: "waiting to be paid", tone: .secondary))
        }
        switch s.bar {
        case .idle:
            if s.copiedAvailable { out.append(Item(id: "copied", title: "Use copied message", action: .useCopied)) }
            if let a = s.toBill { out.append(Item(id: "bill", title: "Invoice \(a.who)", action: .bill(a))) }
            if let a = s.nextUp { out.append(Item(id: "next", title: "Next: \(a.who) \(a.time)", tone: .secondary)) }
            out = Array(out.prefix(3))
        case .chips(let chips, let fromCopied):
            for chip in chips.prefix(max(1, 3 - out.count)) {
                out.append(Item(id: chip.kind, title: title(chip), detail: detail(chip, fromCopied: fromCopied), action: .chip(chip)))
            }
        case .working(let text):
            out.append(Item(id: "working", title: text, tone: .secondary))
        case .confirm(let chip, let recipient):
            out.append(Item(id: "confirm", title: "Send to \(recipient)", tone: .accent, action: .confirm(chip, recipient: recipient)))
            out.append(Item(id: "cancel", title: "Cancel", action: .cancelConfirm))
        case .ask(let chip, let question):
            out.append(Item(id: "confirm", title: question, tone: .accent, action: .chip(chip)))
            out.append(Item(id: "cancel", title: "Cancel", action: .cancelConfirm))
        case .done(let text):
            out.append(Item(id: "done", title: text, tone: .secondary))
        case .error(let text):
            out.append(Item(id: "error", title: text, tone: .due))
        }
        return out
    }

    static func string(_ chip: Chip, _ key: String) -> String? {
        if case .string(let v)? = chip.payload[key], !v.isEmpty { return v }
        return nil
    }

    static func title(_ chip: Chip) -> String {
        guard chip.kind == "invoice" || chip.kind == "paylink" else { return chip.label }
        // A chip from the pay shortcut may have no currency. Then the server uses the profile's, and the bar shows the bare amount.
        let money = string(chip, "amount").map { a in string(chip, "currency").map { formatMoney(a, $0) } ?? formatMoney(a, "").trimmingCharacters(in: .whitespaces) } ?? ""
        return [chip.kind == "invoice" ? "Invoice" : "Pay link", money, string(chip, "item") ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The recipient stays visible on an invoice (security review M2).
    static func detail(_ chip: Chip, fromCopied: Bool) -> String? {
        let to = chip.kind == "invoice" ? (string(chip, "client_email") ?? string(chip, "client_name")).map { "→ \($0)" } : nil
        let parts = [to, fromCopied ? "from copied message" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
