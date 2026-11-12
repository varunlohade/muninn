import Foundation

/// What the suggestion bar shows, slot by slot. Pure: the view maps tones to colors and actions to model calls.
enum BarItems {
    enum Tone: Equatable { case label, secondary, accent, paid, due }

    enum Action: Equatable {
        case useCopied
        case bill(Appointment)
        case chip(Chip)
        case confirm(Chip, recipient: String)
        /// Runs the same chip again with the same key, after a check found it never went through.
        case retry(Chip, confirmed: String?)
        case cancelConfirm
        case undo
        case openCalm
        /// On-device actions: add an event, a reminder or a note, then undo it.
        case smart(SmartChip)
        case undoSmart
        case whoPaid
        case today
        case notes
        /// A word from the prediction row: it replaces the word being typed.
        case predict(String)
        /// The meaning or answer goes into the message; a chart opens its drawing.
        case explain
        /// Opens the card with more about the meaning or answer.
        case explainMore
    }

    struct Item: Equatable, Identifiable {
        let id: String
        var title: String
        var detail: String? = nil
        var tone: Tone = .label
        var action: Action? = nil
        /// The typed words that caused the chip. The bar shows them quoted, in the accent color, before the title.
        var trigger: String? = nil
        /// A shorter title to sit beside the trigger when the full one does not fit: "Add to calendar".
        var short: String? = nil
    }

    /// A smart chip and whether its store can take it now.
    struct Smart {
        let chip: SmartChip
        let access: SmartAccess
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
        var smart: [Smart] = []
        /// The line after a smart chip was added; Undo removes it.
        var added: String?
        /// Nothing is typed: the bar shows ready chips.
        var fieldEmpty = false
        /// The typed words a money chip came from, for a server that sends no trigger: "$45 for the haircut".
        var moneyTrigger: String?
        /// "btw" → "by the way" (and "Explain more"), or a chart's "Draw it": the answer to what the last sentence asks.
        /// It comes before every other chip.
        var explain: [Item] = []
        var ready = ReadyChips.Input()
        /// The word row while a word is typed. It shows only when no chip does.
        var predictions: [Predictions.Slot] = []
        var now = Date()
    }

    static func build(_ s: State) -> [Item] {
        // The word row works on the phone alone. The setup line waits for an empty field.
        if !s.hasFullAccess || !s.paired {
            // A dictionary meaning works offline, so it shows even before Full Access or pairing.
            if !s.explain.isEmpty { return s.explain }
            if !s.predictions.isEmpty { return predictionItems(s.predictions) }
            guard s.fieldEmpty else { return [] }
            return [Item(id: "info", title: s.hasFullAccess ? "Open \(AppConfig.displayName) to pair" : "Allow Full Access in Settings for \(AppConfig.keyboardName)", tone: .secondary)]
        }
        if let u = s.undo {
            return [Item(id: "written", title: u.label, tone: .paid), Item(id: "undo", title: "Undo", action: .undo)]
        }
        if let a = s.added {
            return [Item(id: "added", title: a, tone: .paid), Item(id: "undo", title: "Undo", action: .undoSmart)]
        }
        var out: [Item] = []
        if s.hasCalmOffer {
            out.append(Item(id: "calm", title: "Calm reply", detail: "client sounds upset", action: .openCalm))
        }
        if case .idle = s.bar, s.fieldEmpty {
            return Array((out + ReadyChips.build(s.ready)).prefix(3))
        }
        let smart = smartItems(s.smart, now: s.now)
        if let w = s.watch {
            out.append(w.paid
                ? Item(id: "paid", title: "\(w.who) paid \(w.money) ✓", tone: .paid)
                : Item(id: "waiting", title: "Waiting on \(w.money) \u{00B7} \(w.who)", tone: .secondary))
        }
        switch s.bar {
        case .idle:
            // A chip about the typed words gets the room; the day's chips wait for an empty field.
            out += s.explain
            out += smart
            let aboutTyping = !smart.isEmpty || !s.explain.isEmpty
            if !aboutTyping, s.copiedAvailable { out.append(Item(id: "copied", title: "Use copied message", action: .useCopied)) }
            if !aboutTyping, let a = s.toBill { out.append(Item(id: "bill", title: "Invoice \(a.who)", action: .bill(a))) }
            if !aboutTyping, let a = s.nextUp { out.append(Item(id: "next", title: "Next: \(a.who) \(a.time)", tone: .secondary)) }
            out = Array(out.prefix(3))
            if out.isEmpty { out = predictionItems(s.predictions) }
        case .chips(let chips, let fromCopied):
            for chip in chips.prefix(max(1, 3 - out.count)) {
                out.append(Item(id: chip.kind, title: title(chip), detail: detail(chip, fromCopied: fromCopied), action: .chip(chip),
                                trigger: chip.trigger ?? (fromCopied ? nil : s.moneyTrigger)))
            }
            out = Array((out + smart).prefix(max(3, out.count)))
        case .working(let text):
            out.append(Item(id: "working", title: text, tone: .secondary))
        case .confirm(let chip, let recipient):
            out.append(Item(id: "confirm", title: confirmTitle(chip, recipient: recipient), tone: .accent, action: .confirm(chip, recipient: recipient)))
            out.append(Item(id: "cancel", title: "Cancel", action: .cancelConfirm))
        case .ask(let chip, let question):
            out.append(Item(id: "confirm", title: question, tone: .accent, action: .chip(chip)))
            out.append(Item(id: "cancel", title: "Cancel", action: .cancelConfirm))
        case .done(let text):
            out.append(Item(id: "done", title: text, tone: .secondary))
        case .undoable(let text, let undo):
            out.append(Item(id: "done", title: text, tone: .paid))
            out.append(Item(id: "undo", title: "Undo", action: .chip(undo)))
        case .error(let text):
            out.append(Item(id: "error", title: text, tone: .due))
        case .retry(let chip, let confirmed):
            out.append(Item(id: "retry", title: "It didn't go through. Tap to try again.", tone: .due, action: .retry(chip, confirmed: confirmed)))
        }
        return out
    }

    static func predictionItems(_ slots: [Predictions.Slot]) -> [Item] {
        slots.enumerated().map { Item(id: "predict.\($0.offset)", title: $0.element.title, action: .predict($0.element.word)) }
    }

    /// Each smart chip, or the one line that says which permission it waits for. The line opens nothing: a keyboard cannot.
    static func smartItems(_ list: [Smart], now: Date) -> [Item] {
        var out: [Item] = []
        for s in list {
            let item: Item
            switch s.access {
            case .ready:
                item = Item(id: s.chip.id, title: s.chip.label(now: now), action: .smart(s.chip), trigger: s.chip.trigger, short: s.chip.shortLabel)
            case .needsFullAccess:
                item = Item(id: "allow.full", title: "Allow Full Access for \(AppConfig.keyboardName)", tone: .secondary)
            case .needsPermission:
                let place = s.chip.place == .calendar ? "Calendar" : "Reminders"
                item = Item(id: "allow.\(place)", title: "Allow \(place) in \(AppConfig.displayName)", tone: .secondary)
            }
            if !out.contains(where: { $0.id == item.id }) { out.append(item) }
        }
        return out
    }

    static func string(_ chip: Chip, _ key: String) -> String? {
        if case .string(let v)? = chip.payload[key], !v.isEmpty { return v }
        return nil
    }

    /// A chip from the pay shortcut may have no currency. Then the server uses the profile's, and the bar shows the bare amount.
    private static func money(_ chip: Chip) -> String {
        string(chip, "amount").map { a in string(chip, "currency").map { formatMoney(a, $0) } ?? formatMoney(a, "").trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// An invoice with no email only makes a link, so it says so: "Invoice link $45 Haircut".
    static func title(_ chip: Chip) -> String {
        guard chip.kind == "invoice" || chip.kind == "paylink" else { return chip.label }
        let verb = chip.kind == "paylink" ? "Pay link" : string(chip, "client_email") == nil ? "Invoice link" : "Invoice"
        return [verb, money(chip), string(chip, "item") ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// How a repeat bill's interval reads: "monthly".
    static let every = ["week": "weekly", "month": "monthly", "year": "yearly"]

    /// Every invoice, repeat bill and reminder, and a pay link the server is unsure of, takes one confirm tap before anything is sent.
    static func asksFirst(_ chip: Chip) -> Bool {
        ["invoice", "subscribe", "remind"].contains(chip.kind) || (chip.kind == "paylink" && chip.needs_confirm)
            || (ChipActions.moreActions[chip.kind] != nil && chip.needs_confirm)
    }

    /// Who an invoice goes to: the email, else the client name, else nobody named. A reminder: the client it names.
    static func recipient(_ chip: Chip) -> String {
        switch chip.kind {
        case "invoice", "subscribe": string(chip, "client_email") ?? string(chip, "client_name") ?? ""
        case "remind": string(chip, "client_name") ?? ""
        default: if case .object(let c)? = chip.payload["confirm"], case .string(let who)? = c["confirm_client"] ?? c["confirm_recipient"] { who } else { "" }
        }
    }

    /// The confirm shows what the tap does and who gets told: "Email Sam (sam@x.com) a $45 invoice?",
    /// "Make a $45 invoice link for Sam? No email goes out.", "Make a $45 pay link?", "Email Ana a reminder for $90?",
    /// "Repeat $40 monthly to Sam?". Only an invoice with an email is sent.
    static func confirmTitle(_ chip: Chip, recipient: String) -> String {
        // A PayPal action brings its own question from the server, built from the same values the server checks.
        if ChipActions.moreActions[chip.kind] != nil, let question = string(chip, "question") { return question }
        if chip.kind == "remind" {
            return recipient.isEmpty || money(chip).isEmpty ? chip.label + "?" : "Email \(recipient) a reminder for \(money(chip))?"
        }
        if chip.kind == "invoice" {
            let name = string(chip, "client_name")
            if recipient.contains("@") {
                let who = name.map { "\($0) (\(recipient))" } ?? recipient
                return "Email \(who) a \(money(chip)) invoice?"
            }
            let who = name ?? (recipient.isEmpty ? nil : recipient)
            return "Make a \(money(chip)) invoice link\(who.map { " for \($0)" } ?? "")? No email goes out."
        }
        if chip.kind == "subscribe" {
            let words = ["Repeat", money(chip), string(chip, "interval").flatMap { every[$0] } ?? ""] + (recipient.isEmpty ? [] : ["to", recipient])
            return words.filter { !$0.isEmpty }.joined(separator: " ") + "?"
        }
        return ["Make a", money(chip), "pay link"].filter { !$0.isEmpty }.joined(separator: " ") + "?"
    }

    /// The recipient stays visible on an invoice (security review M2).
    static func detail(_ chip: Chip, fromCopied: Bool) -> String? {
        let to = chip.kind == "invoice" ? (string(chip, "client_email") ?? string(chip, "client_name")).map { "→ \($0)" } : nil
        let parts = [to, fromCopied ? "from copied message" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
