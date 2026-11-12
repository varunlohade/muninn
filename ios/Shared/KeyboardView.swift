import SwiftUI

/// The whole keyboard: an iOS-style predictive bar with our chips, then the system-replica keys.
struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    typealias M = Theme.SystemKeyboard

    var body: some View {
        let p = model.isDark ? M.dark : M.light
        VStack(spacing: 0) {
            if let clients = model.whoPaid { WhoPaidStrip(model: model, clients: clients, palette: p) }
            if let found = model.lookup {
                LookupCard(result: found, palette: p, onInsert: model.insertLookup, onRemind: model.remindFromLookup,
                           onNewInvoice: model.newInvoiceFromLookup, onClose: model.closeLookup)
                    .id(found.query + found.match)
            }
            keyboard(p)
        }
        .frame(height: Self.height(whoPaid: model.whoPaid, lookup: model.lookup != nil, visual: model.visualOpen))
        .background(p.bed)
        .environment(\.colorScheme, model.isDark ? .dark : .light)
    }

    /// The keyboard grows by the list's height while "Who hasn't paid" or a lookup card is open. The keys keep their size and place.
    /// The visual panel takes a taller keyboard of its own, so the drawing has room.
    static func height(whoPaid: [UnpaidClient]?, lookup: Bool = false, visual: Bool = false) -> CGFloat {
        (visual ? M.visualHeight : M.height) + (whoPaid.map { WhoPaidStrip.height(rows: $0.count) } ?? 0) + (lookup ? LookupCard.height : 0)
    }

    private func keyboard(_ p: M.Palette) -> some View {
        ZStack(alignment: .top) {
            // The keys stay on the system grey. Every panel, and the bar above it, sits on paper.
            if model.panelOpen { Theme.Color.bg } else { p.bed }
            if model.catalog.open && model.explainPanel == nil && !model.notesOpen && !model.writeOpen { DottedGrid() }
            if let panel = model.explainPanel {
                Group {
                    switch panel {
                    case .card(let offer): ExplainCardView(model: model, offer: offer, palette: p)
                    case .visual(let state): VisualPanelView(model: model, state: state, palette: p)
                    }
                }
                .padding(.top, M.barHeight).padding(.bottom, M.bottomInset)
            } else if model.notesOpen {
                NotesPanel(model: model, palette: p).padding(.top, M.barHeight).padding(.bottom, M.bottomInset)
            } else if model.writeOpen {
                WritePanelView(model: model, palette: p).padding(.top, M.barHeight).padding(.bottom, M.bottomInset)
            } else if model.catalog.open {
                CatalogPanel(model: model, palette: p).padding(.top, M.barHeight).padding(.bottom, M.bottomInset)
            } else if let c = model.confirmPanel {
                ConfirmPanel(model: model, chip: c.chip, recipient: c.recipient).padding(.top, M.barHeight).padding(.bottom, M.bottomInset)
            } else {
                SystemKeysView(model: model)
            }
            // The bar never reports more than the keyboard's width, so a crowded bar can never shift the keys.
            SuggestionBar(model: model, palette: p)
                .frame(maxWidth: .infinity)
                .frame(height: M.barHeight)
                .clipped()
        }
        .frame(height: model.keyboardHeight)
    }
}

/// "Who hasn't paid", compact, above the keys: the total, then one row per client with Remind.
/// Remind puts the confirm in the bar below, the same one a reminder chip gets.
struct WhoPaidStrip: View {
    @ObservedObject var model: KeyboardModel
    let clients: [UnpaidClient]
    let palette: Theme.SystemKeyboard.Palette
    typealias M = Theme.SystemKeyboard

    static let headerHeight: CGFloat = 36
    static let rowHeight: CGFloat = 44
    /// Two rows show; more scroll.
    static func height(rows: Int) -> CGFloat { headerHeight + CGFloat(min(rows, 2)) * (rowHeight + M.keyGap) + Theme.Space.xxs }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.xs) {
                Text(WhoPaid.header(clients)).font(Theme.Font.sans(15, 500)).foregroundStyle(palette.label).lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityIdentifier("whopaid.header")
                Spacer()
                Button(action: model.closeWhoPaid) {
                    Image(systemName: "xmark").font(M.icon).foregroundStyle(palette.secondaryLabel)
                        .frame(width: 44, height: Self.headerHeight).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("whopaid.close")
            }
            .padding(.leading, Theme.Space.s)
            .frame(height: Self.headerHeight)
            ScrollView {
                VStack(spacing: M.keyGap) {
                    ForEach(clients) { c in row(c) }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, M.sideInset)
        .padding(.bottom, Theme.Space.xxs)
        .frame(height: Self.height(rows: clients.count))
    }

    private func row(_ c: UnpaidClient) -> some View {
        HStack(spacing: Theme.Space.xs) {
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).font(Theme.Font.sans(15, 500)).foregroundStyle(Theme.Color.text1).lineLimit(1).minimumScaleFactor(0.7)
                Text("\(c.item), \(c.veryLate ? "very late, " : "")\(c.late.lowercased())").font(Theme.Font.sans(12))
                    .foregroundStyle(c.daysLate > 0 ? Theme.Color.due : Theme.Color.text2).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(c.money).font(Theme.Font.sans(15, 500)).monospacedDigit().foregroundStyle(Theme.Color.text1)
            if let chip = c.remind {
                Button("Nudge") { model.tapChip(chip) }
                    .buttonStyle(TactileButton(kind: .quiet, small: true, wide: false))
                    .accessibilityIdentifier("whopaid.remind.\(c.name)")
            }
        }
        .padding(.leading, Theme.Space.s).padding(.trailing, 6)
        .frame(height: Self.rowHeight)
        .rowSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("whopaid.row.\(c.name)")
    }
}

/// Sits where iOS shows predictive text, at the same height. Actions show as task cards ("Invoice $45 / Sam");
/// the word row stays plain text like Apple's. Nothing here animates beyond a quick fade: people see it all day.
struct SuggestionBar: View {
    @ObservedObject var model: KeyboardModel
    let palette: Theme.SystemKeyboard.Palette
    typealias M = Theme.SystemKeyboard

    var body: some View {
        let items = model.barItems
        HStack(spacing: 0) {
            if let panel = model.explainPanel {
                Text(panelSubject(panel)).font(Theme.Font.sans(16, 500)).foregroundStyle(Theme.Color.text1)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.leading, Theme.Space.s)
                    .accessibilityLabel(panelTitle(panel))
                    .accessibilityIdentifier("explain.title")
                Spacer(minLength: Theme.Space.xxs)
                barButton("keyboard", id: "explain.close", label: "Keyboard", action: model.closeExplain)
            } else if model.notesOpen {
                panelTitle("Notes")
                Spacer()
                barButton("plus", id: "notes.add", label: "Save typed text as a note", action: model.saveNote)
                    .disabled(!model.canSaveNote)
                    .opacity(model.canSaveNote ? 1 : 0.3)
            } else if model.writeOpen {
                panelTitle("Rewrite")
                Spacer()
            } else if model.catalog.open {
                catalogHeader
            } else if let c = model.confirmPanel {
                Text(ConfirmPanel.title(c.chip, recipient: c.recipient, question: confirmQuestion(items)))
                    .font(Theme.Font.sans(19)).tracking(-0.2).foregroundStyle(Theme.Color.text1)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.leading, Theme.Space.s)
                    .accessibilityIdentifier("confirm.title")
                Spacer(minLength: Theme.Space.xs)
                StatusPill(text: "Needs your OK", tone: .due).padding(.trailing, Theme.Space.xs)
            } else if items.allSatisfy({ $0.id.hasPrefix("predict.") }) && !items.isEmpty {
                // The word row: plain, centred, with 1 pt dividers, like Apple's.
                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Rectangle().fill(palette.divider).frame(width: 1, height: M.dividerHeight) }
                        Word(item: item, palette: palette) { if let a = item.action { model.perform(a) } }
                            .accessibilityIdentifier("chip.\(item.id)")
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                // No scroll view: the bar holds at most three, the first stays whole and later cards shorten their words.
                // (Inside a keyboard, XCUITest and VoiceOver misplace cards in a horizontal scroll view.)
                HStack(spacing: Theme.Space.xs) {
                    // Three cards need the room; the raven sits out.
                    if items.count < 3 { PixelRaven(scale: 1.7).padding(.trailing, 2) }
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        TaskChip(item: item, palette: palette, action: item.action.map { a in { model.perform(a) } })
                            // Actions keep their room before plain lines such as "Waiting on $45".
                            .layoutPriority(Double(items.count - i) + (item.action == nil ? 0 : 10))
                            .accessibilityIdentifier("chip.\(item.id)")
                            .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Space.xs)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .clipped()
            }
            if showsFix, let plan = model.fixPlan {
                Button(action: model.fix) {
                    Text(plan.title).font(Theme.Font.sans(14, 500)).lineLimit(1).fixedSize()
                }
                .buttonStyle(TactileButton(kind: .quiet, small: true, wide: false))
                .padding(.horizontal, 4)
                .accessibilityLabel(plan.title)
                .accessibilityIdentifier("chip.fix")
                .transition(.opacity)
            }
            if model.paired && !model.notesOpen && !model.catalog.open && !confirming && !explaining {
                barButton(model.writeOpen ? "keyboard" : "wand.and.stars", id: "write.toggle", label: model.writeOpen ? "Keyboard" : "Rewrite", action: model.toggleWrite)
            }
            // Notes live in the App Group, which the keyboard reaches only with Full Access.
            if model.hasFullAccess && !model.writeOpen && !model.catalog.open && !confirming && !explaining {
                barButton(model.notesOpen ? "keyboard" : "note.text", id: "notes.toggle", label: model.notesOpen ? "Keyboard" : "Notes", action: model.toggleNotes)
            }
            // The catalog cache lives in the App Group, which needs Full Access too. Open, the panel's back button closes it.
            if model.paired && !model.writeOpen && !model.notesOpen && !model.catalog.open && !confirming && !explaining {
                barButton("tag", id: "catalog.toggle", label: "Catalog", action: model.toggleCatalog)
            }
        }
        .padding(.trailing, 2)
        .animation(Theme.Motion.chipAppear, value: items.map(\.id))
        .animation(Theme.Motion.chipAppear, value: showsFix)
    }

    /// The catalog's head, per M1-4: back, the name and count, then Share.
    private var catalogHeader: some View {
        let c = model.catalog
        return HStack(spacing: Theme.Space.xs) {
            Button(action: model.toggleCatalog) {
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(TactileButton(kind: .quiet, small: true, wide: false))
            .frame(width: 40)
            .accessibilityLabel("Keyboard")
            .accessibilityIdentifier("catalog.toggle")
            Text("Catalog").font(Theme.Font.sans(16, 500)).foregroundStyle(Theme.Color.text1)
            if c.selection.count > 0 {
                Text("\(c.selection.count) selected").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                    .accessibilityIdentifier("catalog.count")
            }
            Spacer(minLength: 0)
            if !c.items.isEmpty {
                Button(c.selection.count > 1 ? "Share \(c.selection.count)" : "Share", action: model.insertCatalog)
                    .buttonStyle(TactileButton(kind: .dark, small: true, wide: false))
                    .disabled(c.selection.count == 0)
                    .accessibilityLabel(c.selection.count > 1 ? "Insert \(c.selection.count)" : "Insert")
                    .accessibilityIdentifier("catalog.insert")
            }
        }
        .padding(.horizontal, Theme.Space.s)
    }

    private func panelTitle(_ text: String) -> some View {
        Text(text).font(Theme.Font.sans(16, 500)).foregroundStyle(Theme.Color.text1).padding(.leading, Theme.Space.s)
    }

    /// The bar's own confirm question, for VoiceOver and the tests: "Email Sam (sam@x.com) a $45 invoice?".
    private func confirmQuestion(_ items: [BarItems.Item]) -> String { items.first { $0.id == "confirm" }?.title ?? "" }

    /// A confirm question takes the whole bar beside Cancel, so the amount and the recipient stay readable.
    private var confirming: Bool {
        switch model.bar {
        case .confirm, .ask: return !model.notesOpen && !model.writeOpen
        default: return false
        }
    }

    /// An explain answer or panel takes the bar; Rewrite, Notes, Catalog and Fix wait.
    private var explaining: Bool { model.explainPanel != nil || model.explainOffer != nil }

    /// The panel's header: the quoted word or the chart's name.
    private func panelSubject(_ p: ExplainPanel) -> String {
        switch p {
        case .card(let o): "\u{201C}\(o.subject)\u{201D}"
        case .visual(let v): v.subject
        }
    }

    private func panelTitle(_ p: ExplainPanel) -> String {
        switch p {
        case .card: "Explain"
        case .visual(let v):
            if case .drawing(let n, let m) = v.status { "\u{201C}\(v.subject)\u{201D} \u{00B7} step \(n) of \(m)" } else { "\u{201C}\(v.subject)\u{201D}" }
        }
    }

    /// Fix sits beside the chips, so it never takes a chip's place.
    private var showsFix: Bool {
        guard model.fixable, !explaining, model.undo == nil, !model.notesOpen, !model.writeOpen, !model.catalog.open else { return false }
        switch model.bar {
        case .idle, .chips: return true
        default: return false
        }
    }

    private func barButton(_ systemImage: String, id: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(M.icon).foregroundStyle(model.panelOpen ? Theme.Color.text1 : palette.label)
                .frame(width: 34).frame(maxHeight: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    /// One word of the prediction row.
    struct Word: View {
        let item: BarItems.Item
        let palette: Theme.SystemKeyboard.Palette
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(item.title).font(M.prediction).foregroundStyle(palette.label).lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.horizontal, Theme.Space.xs)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// A task card: an icon tile, the action, and what it is about. A line with no action is plain text.
    struct TaskChip: View {
        let item: BarItems.Item
        let palette: Theme.SystemKeyboard.Palette
        let action: (() -> Void)?

        /// Second steps (Explain more, Undo, Cancel) are small quiet buttons, so the main card and they both fit.
        static let small: Set<String> = ["explain.more", "undo", "cancel"]

        var body: some View {
            if let action, Self.small.contains(item.id) {
                Button(item.title, action: action)
                    .buttonStyle(TactileButton(kind: .quiet, small: true, wide: false))
            } else if let action {
                Button(action: action) {
                    // A long answer is cut to one short line; the whole text is still read out.
                    TaskCardLabel(icon: Self.icon(item), iconFill: Self.fill(item), title: Self.short(item.title, 24), detail: sub.map { Self.short($0, 30) },
                                  titleColor: tint)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ChipPress())
                .accessibilityLabel([item.title, item.detail].compactMap { $0 }.joined(separator: ", "))
            } else {
                Text(item.title).font(Theme.Font.sans(14, 500)).foregroundStyle(tint)
                    .lineLimit(item.id == "error" || item.id == "retry" ? 2 : 1).minimumScaleFactor(0.75)
                    .padding(.horizontal, Theme.Space.xxs)
                    .frame(maxHeight: .infinity)
            }
        }

        /// The detail, else the typed words that caused the chip, quoted.
        private var sub: String? { item.detail ?? item.trigger.map { "\u{201C}\(Self.short($0, 22))\u{201D}" } }

        static func short(_ t: String, _ n: Int) -> String { t.count > n ? String(t.prefix(n - 2)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : t }

        private var tint: Color {
            switch item.tone {
            case .label, .accent: Theme.Color.text1
            case .secondary: Theme.Color.text2
            case .paid: Theme.Color.paid
            case .due: Theme.Color.due
            }
        }

        static func icon(_ item: BarItems.Item) -> PixelIcon.Name {
            switch item.id {
            case "invoice", "bill": .invoice
            case "paylink", "copied": .link
            case "remind", "whopaid": .bell
            case "subscribe", "today", "next": .calendar
            case "catalog": .tag
            case "notes": .note
            case "paid", "done", "added", "written": .check
            case "calm": .chat
            default: item.id.hasPrefix("explain") ? .spark : .spark
            }
        }

        static func fill(_ item: BarItems.Item) -> Color {
            switch icon(item) {
            case .bell, .tag, .note: Color(hex: 0xF4D35E)
            case .check: Color(hex: 0xA6E39A)
            case .calendar: Color(hex: 0xDAE9FB)
            case .spark: Color(hex: 0xF7D49B)
            default: .white
            }
        }
    }
}

/// The confirm panel, per M1-5: the question with "Needs your OK" above (in the bar), To / For / Pays-with rows,
/// then Edit and the action. Edit cancels, so the owner can change the message. Nothing is sent before the dark button.
struct ConfirmPanel: View {
    @ObservedObject var model: KeyboardModel
    let chip: Chip
    let recipient: String

    var body: some View {
        let question = model.barItems.first { $0.id == "confirm" }?.title ?? BarItems.confirmTitle(chip, recipient: recipient)
        VStack(spacing: Theme.Space.s) {
            VStack(spacing: 0) {
                ForEach(Array(Self.rows(chip, recipient: recipient).enumerated()), id: \.offset) { i, r in
                    if i > 0 { Dashed() }
                    HStack(spacing: 0) {
                        Text(r.label).font(Theme.Font.sans(12.5)).foregroundStyle(Theme.Color.text2).frame(width: 78, alignment: .leading)
                        Text(r.value).font(Theme.Font.sans(14, 500)).foregroundStyle(Theme.Color.text1).lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: Theme.Space.xs)
                        if let d = r.detail {
                            Text(d).font(Theme.Font.sans(12.5)).monospacedDigit().foregroundStyle(Theme.Color.text2).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                    .frame(height: 40)
                }
            }
            .padding(.horizontal, 14)
            .cardSurface()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("confirm.card")
            HStack(spacing: Theme.Space.xs) {
                Button("Edit") { model.perform(.cancelConfirm) }
                    .buttonStyle(TactileButton(kind: .quiet))
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("chip.cancel")
                Button(Self.verb(chip)) { model.perform(.confirm(chip, recipient: recipient)) }
                    .buttonStyle(TactileButton(kind: .dark))
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                    .frame(minWidth: 0)
                    .accessibilityLabel(question)
                    .accessibilityIdentifier("chip.confirm")
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.top, Theme.Space.xs)
    }

    private struct Dashed: View {
        var body: some View {
            GeometryReader { g in
                Path { $0.move(to: .zero); $0.addLine(to: CGPoint(x: g.size.width, y: 0)) }
                    .stroke(Theme.Color.dash, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .frame(height: 1)
        }
    }

    private static func s(_ chip: Chip, _ key: String) -> String? { BarItems.string(chip, key) }

    private static func money(_ chip: Chip) -> String? {
        s(chip, "amount").map { formatMoney($0, s(chip, "currency") ?? "USD") }
    }

    /// The bar's short question: "Email Sam a $45 invoice?" when the To row shows the email. Else the bar's own question.
    static func title(_ chip: Chip, recipient: String, question: String) -> String {
        if chip.kind == "invoice", recipient.contains("@"), let m = money(chip) {
            let who = s(chip, "client_name").flatMap { $0.split(separator: " ").first.map(String.init) } ?? recipient
            return "Email \(who) a \(m) invoice?"
        }
        return question
    }

    static func verb(_ chip: Chip) -> String {
        switch chip.kind {
        case "invoice": s(chip, "client_email") != nil || BarItems.recipient(chip).contains("@") ? "Send invoice" : "Make invoice link"
        case "remind": "Send nudge"
        case "subscribe": "Start repeat billing"
        case "paylink": "Make pay link"
        default: "Confirm"
        }
    }

    struct Row { let label: String; let value: String; let detail: String? }

    static func rows(_ chip: Chip, recipient: String) -> [Row] {
        let name = s(chip, "client_name"), email = s(chip, "client_email") ?? (recipient.contains("@") ? recipient : nil)
        var out: [Row] = []
        if let who = name ?? (recipient.isEmpty ? nil : recipient) {
            out.append(Row(label: "To", value: who, detail: email == who ? nil : email))
        }
        switch chip.kind {
        case "remind":
            out.append(Row(label: "For", value: s(chip, "item") ?? "Unpaid invoice", detail: money(chip)))
            out.append(Row(label: "Sends", value: "Reminder email", detail: "From PayPal"))
        case "subscribe":
            out.append(Row(label: "For", value: s(chip, "item") ?? "Repeat payment", detail: money(chip)))
            out.append(Row(label: "Repeats", value: s(chip, "interval").flatMap { BarItems.every[$0] }?.capitalized ?? "Yes", detail: "PayPal"))
        case "invoice", "paylink":
            out.append(Row(label: "For", value: s(chip, "item")?.capitalized ?? (chip.kind == "paylink" ? "Payment" : "Invoice"), detail: money(chip)))
            out.append(Row(label: "Pays with", value: "PayPal link", detail: chip.kind == "invoice" ? (email == nil ? "No email goes out" : "Emailed now") : nil))
        default:
            out.append(Row(label: "Does", value: chip.label, detail: money(chip)))
        }
        return out
    }
}

/// The owner's notes, in place of the keys. A tap inserts the note at the cursor.
struct NotesPanel: View {
    @ObservedObject var model: KeyboardModel
    let palette: Theme.SystemKeyboard.Palette
    typealias M = Theme.SystemKeyboard

    var body: some View {
        ScrollView {
            VStack(spacing: M.keyGap) {
                ForEach(Array(model.notes.enumerated()), id: \.element.id) { i, note in
                    Button { model.insertNote(note) } label: {
                        HStack(spacing: Theme.Space.s) {
                            IconTile(icon: .note, fill: Color(hex: 0xF4D35E), size: 28)
                            Text(note.text).font(Theme.Font.sans(15)).foregroundStyle(Theme.Color.text1)
                                .lineLimit(2).multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: M.keyHeight - 4)
                        .padding(.horizontal, Theme.Space.xs).padding(.vertical, 6)
                        .rowSurface()
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("note.\(i)")
                }
                if model.notes.isEmpty {
                    Text("No notes yet. Type a reply, then tap +.").font(Theme.Font.sans(15)).foregroundStyle(Theme.Color.text2).padding(.top, Theme.Space.xl)
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.top, 2)
        }
    }
}

/// Rewrite, in place of the keys: five one-tap rewrites and a grammar fix. The result shows first; a tap puts it in the message.
struct WritePanelView: View {
    @ObservedObject var model: KeyboardModel
    let palette: Theme.SystemKeyboard.Palette
    typealias M = Theme.SystemKeyboard

    var body: some View {
        Group {
            switch model.writePanel {
            case .menu: menu
            case .busy(let text): note(text)
            case .message(let text): VStack(spacing: M.rowGap) { note(text); wide("Back", id: "write.back", action: model.backToWriteMenu) }
            case .preview(let p): preview(p)
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var menu: some View {
        VStack(spacing: M.rowGap) {
            if model.canWrite {
                HStack(spacing: M.keyGap) { option(.polite); option(.shorter) }
                HStack(spacing: M.keyGap) { option(.professional); option(.friendly) }
                HStack(spacing: M.keyGap) {
                    option(.firmer)
                    wide("Fix grammar", id: "write.grammar", action: model.fixGrammar)
                }
            } else {
                note("Type a message first. Then pick how to rewrite it.")
            }
        }
    }

    private func option(_ tone: RefineTone) -> some View {
        wide(tone.title, id: "write.\(tone.rawValue)") { model.refine(tone) }
    }

    private func preview(_ p: WritePreview) -> some View {
        VStack(spacing: M.keyGap) {
            Button(action: model.usePreview) {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(p.title).font(Theme.Font.sans(12.5)).foregroundStyle(Theme.Color.text2)
                    Text(p.text).font(Theme.Font.sans(16)).foregroundStyle(Theme.Color.text1)
                        .multilineTextAlignment(.leading).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
                .cardSurface()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("write.preview")
            HStack(spacing: M.keyGap) {
                wide("Back", id: "write.back", action: model.backToWriteMenu)
                wide("Replace", id: "write.use", accent: true, action: model.usePreview)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Theme.Font.sans(15)).foregroundStyle(Theme.Color.text2).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("write.note")
    }

    private func wide(_ title: String, id: String, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(TactileButton(kind: accent ? .dark : .quiet))
            .frame(maxHeight: M.keyHeight + 9)
            .accessibilityIdentifier(id)
    }
}

extension KeyboardModel {
    /// A panel replaces the keys: explain, notes, rewrite, catalog or the confirm.
    var panelOpen: Bool { explainPanel != nil || notesOpen || writeOpen || catalog.open || confirmPanel != nil }

    /// The invoice, reminder or repeat bill waiting for the owner's OK, shown as a panel in place of the keys.
    var confirmPanel: (chip: Chip, recipient: String)? {
        guard explainPanel == nil, !notesOpen, !writeOpen, !catalog.open, case .confirm(let chip, let recipient) = bar else { return nil }
        return (chip, recipient)
    }
}
