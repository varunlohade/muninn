import SwiftUI

/// The whole keyboard: an iOS-style predictive bar with our chips, then the system-replica keys.
struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    typealias M = Theme.SystemKeyboard

    var body: some View {
        let p = model.isDark ? M.dark : M.light
        ZStack(alignment: .top) {
            p.bed
            if model.notesOpen {
                NotesPanel(model: model, palette: p).padding(.top, M.barHeight).padding(.bottom, M.bottomInset)
            } else if model.writeOpen {
                WritePanelView(model: model, palette: p).padding(.top, M.barHeight).padding(.bottom, M.bottomInset)
            } else {
                SystemKeysView(model: model)
            }
            SuggestionBar(model: model, palette: p)
                .frame(height: M.barHeight)
        }
        .frame(height: M.height)
        .environment(\.colorScheme, model.isDark ? .dark : .light)
    }
}

/// Sits where iOS shows predictive text: same height, centred text, 1 pt dividers. Empty when there is nothing to say.
struct SuggestionBar: View {
    @ObservedObject var model: KeyboardModel
    let palette: Theme.SystemKeyboard.Palette
    typealias M = Theme.SystemKeyboard

    struct Item: Identifiable {
        let id: String
        var title: String
        var detail: String? = nil
        var tint: Color? = nil
        var action: (() -> Void)? = nil
    }

    var body: some View {
        let items = self.items
        HStack(spacing: 0) {
            if model.notesOpen {
                Text("Notes").font(M.prediction.weight(.medium)).foregroundStyle(palette.label).padding(.leading, 12)
                Spacer()
                barButton("plus", id: "notes.add", label: "Save typed text as a note", action: model.saveNote)
                    .disabled(!model.canSaveNote)
                    .opacity(model.canSaveNote ? 1 : 0.3)
            } else if model.writeOpen {
                Text("Refine").font(M.prediction.weight(.medium)).foregroundStyle(palette.label).padding(.leading, 12)
                Spacer()
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Rectangle().fill(palette.divider).frame(width: 1, height: M.dividerHeight) }
                        Slot(item: item, palette: palette)
                            .accessibilityIdentifier("chip.\(item.id)")
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            if showsFix {
                Rectangle().fill(palette.divider).frame(width: 1, height: M.dividerHeight)
                Button(action: model.fix) {
                    Text("Fix").font(M.prediction.weight(.medium)).foregroundStyle(palette.accent)
                        .frame(width: 48).frame(maxHeight: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fix spelling and grammar")
                .accessibilityIdentifier("chip.fix")
                .transition(.opacity)
            }
            if model.paired && !model.notesOpen {
                Rectangle().fill(palette.divider).frame(width: 1, height: M.dividerHeight)
                barButton(model.writeOpen ? "keyboard" : "wand.and.stars", id: "write.toggle", label: model.writeOpen ? "Keyboard" : "Refine", action: model.toggleWrite)
            }
            // Notes live in the App Group, which the keyboard reaches only with Full Access.
            if model.hasFullAccess && !model.writeOpen {
                Rectangle().fill(palette.divider).frame(width: 1, height: M.dividerHeight)
                barButton(model.notesOpen ? "keyboard" : "note.text", id: "notes.toggle", label: model.notesOpen ? "Keyboard" : "Notes", action: model.toggleNotes)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, M.barHeight - 2 * 23.8)
        .animation(Theme.Motion.chipAppear, value: items.map(\.id))
        .animation(Theme.Motion.chipAppear, value: showsFix)
    }

    /// Fix sits beside the chips, so it never takes a chip's place.
    private var showsFix: Bool {
        guard model.fixable, model.undo == nil, !model.notesOpen, !model.writeOpen else { return false }
        switch model.bar {
        case .idle, .chips: return true
        default: return false
        }
    }

    private func barButton(_ systemImage: String, id: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(M.icon).foregroundStyle(palette.label)
                .frame(width: 40).frame(maxHeight: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private var items: [Item] {
        if !model.hasFullAccess { return [Item(id: "info", title: "Allow Full Access in Settings for \(AppConfig.keyboardName)", tint: palette.secondaryLabel)] }
        if !model.paired { return [Item(id: "info", title: "Open \(AppConfig.displayName) to pair", tint: palette.secondaryLabel)] }
        if let u = model.undo {
            return [Item(id: "written", title: u.label, tint: Theme.Color.paid), Item(id: "undo", title: "Undo", action: model.undoWrite)]
        }
        var out: [Item] = []
        if model.calmOffer != nil {
            out.append(Item(id: "calm", title: "Calm reply", detail: "client sounds upset", action: model.openCalmOffer))
        }
        if let w = model.watch {
            out.append(w.paid
                ? Item(id: "paid", title: "\(w.who) paid \(w.money) ✓", tint: Theme.Color.paid)
                : Item(id: "waiting", title: "Sent \(w.money)", detail: "waiting to be paid", tint: palette.secondaryLabel))
        }
        switch model.bar {
        case .idle:
            if model.copiedAvailable { out.append(Item(id: "copied", title: "Use copied message", action: model.useCopied)) }
            if let a = model.toBill { out.append(Item(id: "bill", title: "Invoice \(a.who)", action: { model.invoiceAppointment(a) })) }
            if let a = model.nextUp { out.append(Item(id: "next", title: "Next: \(a.who) \(a.time)", tint: palette.secondaryLabel)) }
            out = Array(out.prefix(3))
        case .chips(let chips, let fromCopied):
            for chip in chips.prefix(max(1, 3 - out.count)) {
                out.append(Item(id: chip.kind, title: Self.title(chip), detail: Self.detail(chip, fromCopied: fromCopied), action: { model.tapChip(chip) }))
            }
        case .working(let text):
            out.append(Item(id: "working", title: text, tint: palette.secondaryLabel))
        case .confirm(let chip, let recipient):
            out.append(Item(id: "confirm", title: "Send to \(recipient)", tint: palette.accent, action: { model.confirm(chip, recipient: recipient) }))
            out.append(Item(id: "cancel", title: "Cancel", action: model.cancelConfirm))
        case .done(let text):
            out.append(Item(id: "done", title: text, tint: palette.secondaryLabel))
        case .error(let text):
            out.append(Item(id: "error", title: text, tint: Theme.Color.due))
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

    struct Slot: View {
        let item: Item
        let palette: Theme.SystemKeyboard.Palette

        var body: some View {
            Button { item.action?() } label: {
                VStack(spacing: 0) {
                    Text(item.title).font(item.detail == nil ? M.prediction : M.prediction.weight(.medium))
                        .foregroundStyle(item.tint ?? palette.label)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    if let d = item.detail {
                        Text(d).font(M.predictionSmall).foregroundStyle(palette.secondaryLabel).lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(item.action == nil)
        }
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
                        Text(note.text).font(M.mode).foregroundStyle(palette.label)
                            .lineLimit(2).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, minHeight: M.keyHeight - 20, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(palette.key, in: RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("note.\(i)")
                }
                if model.notes.isEmpty {
                    Text("No notes yet. Type a reply, then tap +.").font(M.mode).foregroundStyle(palette.secondaryLabel).padding(.top, 40)
                }
            }
            .padding(.horizontal, M.sideInset)
        }
    }
}

/// Refine, in place of the keys: four one-tap rewrites and a tone check. The result shows first; a tap puts it in the message.
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
        .padding(.horizontal, M.sideInset)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var menu: some View {
        VStack(spacing: M.rowGap) {
            if model.canWrite {
                ForEach([[RefineTone.professional, .friendly], [.shorter, .firmer]], id: \.first) { row in
                    HStack(spacing: M.keyGap) {
                        ForEach(row) { tone in wide(tone.title, id: "write.\(tone.rawValue)") { model.refine(tone) } }
                    }
                }
                wide("Tone check", id: "write.tone", action: model.checkTone)
            } else {
                note("Type a message first. Then pick how it should sound.")
            }
        }
    }

    private func preview(_ p: WritePreview) -> some View {
        VStack(spacing: M.keyGap) {
            Button(action: model.usePreview) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.title).font(M.predictionSmall.weight(.semibold)).foregroundStyle(palette.secondaryLabel)
                    Text(p.text).font(M.mode).foregroundStyle(palette.label)
                        .multilineTextAlignment(.leading).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(palette.key, in: RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
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
        Text(text).font(M.mode).foregroundStyle(palette.secondaryLabel).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("write.note")
    }

    private func wide(_ title: String, id: String, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(M.mode).foregroundStyle(accent ? .white : palette.label)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: M.keyHeight, maxHeight: M.keyHeight + 9)
                .background(accent ? palette.accent : palette.key, in: RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}
