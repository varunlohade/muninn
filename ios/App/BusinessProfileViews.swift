import SwiftUI

/// "What does your business do?": three examples and free text. Onboarding and Settings both ask it.
struct BusinessQuestion: View {
    @Binding var text: String
    static let examples = ["Barber shop", "Freelance app developer", "Bakery"]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.xs) { chips(Self.examples) }
                VStack(spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.xs) { chips([Self.examples[0], Self.examples[2]]) }
                    chips([Self.examples[1]])
                }
            }
            TextField("", text: $text, prompt: Text("Or say it in your words").foregroundStyle(Theme.Color.text3))
                .submitLabel(.done)
                .modifier(FieldStyle())
                .accessibilityIdentifier("business.text")
        }
    }

    private func chips(_ names: [String]) -> some View {
        ForEach(names, id: \.self) { name in
            AskChip(title: name, detail: nil) { text = name }
                .accessibilityIdentifier("business.example")
        }
    }
}

/// The Settings row that opens "Your business".
struct BusinessRow: View {
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            IconTile(icon: .tag, fill: Color(hex: 0xF4D35E))
            VStack(alignment: .leading, spacing: 2) {
                Text("Your business").font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                Text("What you sell, so \"how much?\" reads right.").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Color.text3)
        }
        .padding(.leading, 10).padding(.trailing, 14).padding(.vertical, 10)
        .frame(minHeight: Theme.Metric.rowHeight)
        .rowSurface()
    }
}

/// What the business does. The keyboard reads a client's "how much?" as a question about it.
struct BusinessView: View {
    @State private var saved: String?
    @State private var text = ""
    @State private var busy = false
    @State private var note: String?
    @State private var failed = false

    var body: some View {
        SettingPage(title: "Your business", help: "What does your business do? The keyboard reads a client's \"how much?\" the way you mean it.") {
            BusinessQuestion(text: $text)
            if let note {
                Text(note).font(Theme.Font.label).foregroundStyle(failed ? Theme.Color.due : Theme.Color.paid)
                    .padding(.horizontal, Theme.Space.xs).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("business.note")
            }
            Button(busy ? "Saving\u{2026}" : "Save") { Task { await save() } }
                .buttonStyle(PrimaryButton())
                .disabled(busy || clean.isEmpty || clean == saved)
                .opacity(busy || clean.isEmpty || clean == saved ? 0.4 : 1)
                .accessibilityIdentifier("business.save")
        }
        .task {
            guard let p = try? await APIClient.shared().profile() else { return }
            saved = p.description
            text = p.description ?? ""
        }
    }

    private var clean: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            saved = try await APIClient.shared().setBusiness(clean)?.description
            failed = false
            note = "Saved \u{2713}"
        } catch {
            failed = true
            note = plainLine(error)
        }
    }
}
