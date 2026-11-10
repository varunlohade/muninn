import SwiftUI

/// Saved replies, prices and policies. They live in the App Group, so the keyboard can insert them.
struct NotesView: View {
    @State private var notes = SharedStore.notes
    @State private var editing: Note?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Notes").font(Theme.Font.title).foregroundStyle(Theme.Color.text1)
                    Spacer()
                    Button { editing = Note(text: "") } label: { IconCircle(systemImage: "plus") }
                        .buttonStyle(PressScale())
                        .accessibilityLabel("Add note")
                        .accessibilityIdentifier("notes.new")
                }
                .padding(.leading, Theme.Metric.margin)
                .padding(.trailing, Theme.Metric.cardInset)
                Text("Tap the notes button on the keyboard to insert one in any chat. Notes stay on this phone.")
                    .font(Theme.Font.label).foregroundStyle(Theme.Color.text2).padding(.horizontal, Theme.Metric.margin)
                ForEach(notes) { note in
                    Button { editing = note } label: {
                        Card(padding: 18) {
                            Text(note.text).font(Theme.Font.body).foregroundStyle(Theme.Color.text1)
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .buttonStyle(PressScale())
                    .padding(.horizontal, Theme.Metric.cardInset)
                }
                if notes.isEmpty {
                    Text("No notes yet").font(Theme.Font.label).foregroundStyle(Theme.Color.text3).padding(.horizontal, Theme.Metric.margin)
                }
            }
            .padding(.top, 8)
        }
        .background(Theme.Color.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in notes = SharedStore.notes }
        .sheet(item: $editing) { note in
            NoteEditor(note: note, isNew: !notes.contains { $0.id == note.id }, save: save, delete: delete)
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
    let save: (Note) -> Void
    let delete: (Note) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextEditor(text: $note.text)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.text1)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .frame(height: 160)
                    .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: Theme.Metric.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Metric.radius, style: .continuous).strokeBorder(Theme.Color.edge, lineWidth: 1))
                    .accessibilityIdentifier("note.text")
                if !isNew {
                    Button("Delete note", role: .destructive) { delete(note); dismiss() }
                        .font(Theme.Font.label).padding(.horizontal, 8)
                        .accessibilityIdentifier("note.delete")
                }
                Spacer()
            }
            .padding(Theme.Metric.cardInset)
            .background(Theme.Color.bg.ignoresSafeArea())
            .navigationTitle(isNew ? "New note" : "Edit note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        note.text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        save(note)
                        dismiss()
                    }
                    .disabled(note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("note.save")
                }
            }
        }
    }
}
