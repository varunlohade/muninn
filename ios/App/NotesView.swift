import SwiftUI

/// Saved replies, prices and policies. They live in the App Group, so the keyboard can insert them.
struct NotesView: View {
    @State private var notes = SharedStore.notes
    @State private var editing: Note?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.cardGap) {
                HStack(alignment: .top) {
                    twoTone("Notes.", "Replies you send often, one tap from any chat.")
                        .font(Theme.Font.title).tracking(-0.3).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Theme.Space.s)
                    Button { editing = Note(text: "") } label: { IconCircle(systemImage: "plus", size: 40) }
                        .buttonStyle(PressScale())
                        .accessibilityLabel("Add note")
                        .accessibilityIdentifier("notes.new")
                }
                .padding(.leading, Theme.Metric.cardInset + 2)
                .padding(.trailing, Theme.Metric.cardInset)
                Text("Tap the notes button on the keyboard to insert one in any chat. Notes stay on this phone.")
                    .font(Theme.Font.label).foregroundStyle(Theme.Color.text2).padding(.horizontal, Theme.Metric.cardInset + 2)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(notes) { note in
                    Button { editing = note } label: {
                        HStack(alignment: .top, spacing: Theme.Space.s) {
                            IconTile(icon: .note, fill: Color(hex: 0xF4D35E))
                            Text(note.text).font(Theme.Font.sans(15)).foregroundStyle(Theme.Color.text1)
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 5)
                            if let t = note.trigger { StatusPill(text: t) }
                        }
                        .padding(10)
                        .rowSurface()
                    }
                    .buttonStyle(PressScale())
                    .padding(.horizontal, Theme.Metric.cardInset)
                }
                if notes.isEmpty {
                    Text("No notes yet. Tap + to save your prices, hours or address.").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(Theme.Space.m)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Metric.rowRadius, style: .continuous)
                            .strokeBorder(Theme.Color.dash, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .padding(.horizontal, Theme.Metric.cardInset)
                }
            }
            .padding(.top, Theme.Space.xs)
            .padding(.bottom, Theme.Space.l)
        }
        .background(Theme.Color.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in notes = SharedStore.notes }
        .sheet(item: $editing) { note in
            NoteEditor(note: note, isNew: !notes.contains { $0.id == note.id }, taken: NoteEditor.taken(notes, except: note), save: save, delete: delete)
        }
    }

    private func save(_ note: Note) {
        if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i] = note } else { notes.insert(note, at: 0) }
        SharedStore.notes = notes
    }

    private func delete(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        SharedStore.notes = notes
    }
}

struct NoteEditor: View {
    @State var note: Note
    let isNew: Bool
    /// Triggers of the other notes and of the built-in actions.
    let taken: Set<String>
    let save: (Note) -> Void
    let delete: (Note) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var trigger = ""

    static func taken(_ notes: [Note], except note: Note) -> Set<String> {
        Set(notes.filter { $0.id != note.id }.compactMap(\.trigger) + SharedStore.actionShortcuts.map(\.trigger))
    }

    private var cleanTrigger: String { Shortcuts.normalize(trigger) }
    private var triggerProblem: String? { cleanTrigger.isEmpty ? nil : Shortcuts.problem(cleanTrigger, taken: taken) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                TextField("", text: $trigger, prompt: Text("Shortcut, like ;prices (optional)").foregroundStyle(Theme.Color.text3))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .modifier(FieldStyle())
                    .accessibilityIdentifier("note.trigger")
                Text(triggerProblem ?? "Type the shortcut, then space. The keyboard puts this note in the message.")
                    .font(Theme.Font.label).foregroundStyle(triggerProblem == nil ? Theme.Color.text2 : Theme.Color.due)
                    .padding(.horizontal, Theme.Space.xs).fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $note.text)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.text1)
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Space.s)
                    .frame(height: 160)
                    .cardSurface()
                    .accessibilityIdentifier("note.text")
                if !isNew {
                    Button("Delete note", role: .destructive) { delete(note); dismiss() }
                        .font(Theme.Font.label).padding(.horizontal, Theme.Space.xs)
                        .accessibilityIdentifier("note.delete")
                }
                Spacer()
            }
            .padding(Theme.Metric.cardInset)
            .background(Theme.Color.bg.ignoresSafeArea())
            .onAppear { trigger = note.trigger ?? "" }
            .navigationTitle(isNew ? "New note" : "Edit note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        note.text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        note.trigger = cleanTrigger.isEmpty ? nil : cleanTrigger
                        save(note)
                        dismiss()
                    }
                    .disabled(note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || triggerProblem != nil)
                    .accessibilityIdentifier("note.save")
                }
            }
        }
    }
}
