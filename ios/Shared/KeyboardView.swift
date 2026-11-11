import SwiftUI

/// The whole keyboard: an iOS-style predictive bar with our chips, then the system-replica keys.
struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    typealias M = Theme.SystemKeyboard

    var body: some View {
        let p = model.isDark ? M.dark : M.light
        VStack(spacing: 0) {
            if let clients = model.whoPaid { WhoPaidStrip(model: model, clients: clients, palette: p) }
            keyboard(p)
        }
        .frame(height: Self.height(whoPaid: model.whoPaid))
        .background(p.bed)
        .environment(\.colorScheme, model.isDark ? .dark : .light)
    }

    /// The keyboard grows by the list's height while "Who hasn't paid" is open. The keys keep their size and place.
    static func height(whoPaid: [UnpaidClient]?) -> CGFloat {
        M.height + (whoPaid.map { WhoPaidStrip.height(rows: $0.count) } ?? 0)
    }

    private func keyboard(_ p: M.Palette) -> some View {
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
                Text(WhoPaid.header(clients)).font(M.mode.weight(.medium)).foregroundStyle(palette.label).lineLimit(1).minimumScaleFactor(0.7)
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
            VStack(alignment: .leading, spacing: 0) {
                Text("\(c.name) \(c.money)").font(M.mode).foregroundStyle(palette.label).lineLimit(1).minimumScaleFactor(0.7)
                Text("\(c.item) \u{00B7} \(c.veryLate ? "very late, " : "")\(c.late)").font(M.predictionSmall)
                    .foregroundStyle(c.daysLate > 0 ? Theme.Color.due : palette.secondaryLabel).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let chip = c.remind {
                Button { model.tapChip(chip) } label: {
                    Text("Remind").font(M.mode.weight(.medium)).foregroundStyle(palette.accent)
                        .padding(.horizontal, Theme.Space.s).frame(height: Self.rowHeight).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("whopaid.remind.\(c.name)")
            }
        }
        .padding(.leading, Theme.Space.s)
        .frame(height: Self.rowHeight)
        .background(palette.key, in: RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("whopaid.row.\(c.name)")
    }
}

/// Sits where iOS shows predictive text: same height, centred text, 1 pt dividers. Empty when there is nothing to say.
struct SuggestionBar: View {
    @ObservedObject var model: KeyboardModel
    let palette: Theme.SystemKeyboard.Palette
    typealias M = Theme.SystemKeyboard

    var body: some View {
        let items = model.barItems
        HStack(spacing: 0) {
            if model.notesOpen {
                Text("Notes").font(M.prediction.weight(.medium)).foregroundStyle(palette.label).padding(.leading, Theme.Space.s)
                Spacer()
                barButton("plus", id: "notes.add", label: "Save typed text as a note", action: model.saveNote)
                    .disabled(!model.canSaveNote)
                    .opacity(model.canSaveNote ? 1 : 0.3)
            } else if model.writeOpen {
                Text("Refine").font(M.prediction.weight(.medium)).foregroundStyle(palette.label).padding(.leading, Theme.Space.s)
                Spacer()
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Rectangle().fill(palette.divider).frame(width: 1, height: M.dividerHeight) }
                        Slot(item: item, palette: palette, action: item.action.map { a in { model.perform(a) } },
                             width: confirming && item.id == "cancel" ? 80 : nil)
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
            if model.paired && !model.notesOpen && !confirming {
                Rectangle().fill(palette.divider).frame(width: 1, height: M.dividerHeight)
                barButton(model.writeOpen ? "keyboard" : "wand.and.stars", id: "write.toggle", label: model.writeOpen ? "Keyboard" : "Refine", action: model.toggleWrite)
            }
            // Notes live in the App Group, which the keyboard reaches only with Full Access.
            if model.hasFullAccess && !model.writeOpen && !confirming {
                Rectangle().fill(palette.divider).frame(width: 1, height: M.dividerHeight)
                barButton(model.notesOpen ? "keyboard" : "note.text", id: "notes.toggle", label: model.notesOpen ? "Keyboard" : "Notes", action: model.toggleNotes)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, M.barHeight - 2 * 23.8)
        .animation(Theme.Motion.chipAppear, value: items.map(\.id))
        .animation(Theme.Motion.chipAppear, value: showsFix)
    }

    /// A confirm question takes the whole bar beside Cancel, so the amount and the recipient stay readable.
    private var confirming: Bool {
        switch model.bar {
        case .confirm, .ask: return !model.notesOpen && !model.writeOpen
        default: return false
        }
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

    struct Slot: View {
        let item: BarItems.Item
        let palette: Theme.SystemKeyboard.Palette
        let action: (() -> Void)?
        /// A fixed width, or nil to share the bar with the other slots.
        var width: CGFloat? = nil

        var body: some View {
            Button { action?() } label: {
                VStack(spacing: 0) {
                    Text(item.title).font(item.detail == nil ? M.prediction : M.prediction.weight(.medium))
                        .foregroundStyle(tint)
                        .lineLimit(item.id == "confirm" ? 2 : 1).minimumScaleFactor(item.id == "confirm" ? 0.8 : 0.6)
                        .multilineTextAlignment(.center)
                    if let d = item.detail {
                        Text(d).font(M.predictionSmall).foregroundStyle(palette.secondaryLabel).lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                .padding(.horizontal, Theme.Space.xs)
                .frame(maxWidth: width ?? .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(action == nil)
        }

        private var tint: Color {
            switch item.tone {
            case .label: palette.label
            case .secondary: palette.secondaryLabel
            case .accent: palette.accent
            case .paid: Theme.Color.paid
            case .due: Theme.Color.due
            }
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
                            .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
                            .background(palette.key, in: RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("note.\(i)")
                }
                if model.notes.isEmpty {
                    Text("No notes yet. Type a reply, then tap +.").font(M.mode).foregroundStyle(palette.secondaryLabel).padding(.top, Theme.Space.xl)
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
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(p.title).font(M.predictionSmall.weight(.semibold)).foregroundStyle(palette.secondaryLabel)
                    Text(p.text).font(M.mode).foregroundStyle(palette.label)
                        .multilineTextAlignment(.leading).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
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
