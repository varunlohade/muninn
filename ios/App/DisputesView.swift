import SwiftUI

/// Open disputes, each with Reply, Offer and Accept. Every answer asks first, with the question the keyboard shows,
/// and runs through the same ChipActions path, so the server checks the buyer and the amount again.
@MainActor
final class DisputesModel: ObservableObject {
    enum Kind: Equatable { case reply, offer }
    enum Step: Equatable { case idle, typing(Kind), confirm(Chip), working(String), done(String), error(String) }

    @Published private(set) var items: [OpenDispute] = []
    @Published private(set) var loaded = false
    /// The dispute whose answer is in progress.
    @Published private(set) var active: String?
    @Published private(set) var step: Step = .idle
    @Published var draft = ""

    private let load: () async throws -> [OpenDispute]
    private let api: () -> KeyboardAPI

    init(load: @escaping () async throws -> [OpenDispute] = { try await APIClient.shared().openDisputes() },
         api: @escaping () -> KeyboardAPI = { APIClient.shared() }) {
        self.load = load
        self.api = api
    }

    func reload() async {
        items = (try? await load()) ?? items
        loaded = true
    }

    func start(_ d: OpenDispute, _ kind: Kind) {
        active = d.id
        draft = ""
        step = .typing(kind)
    }

    func accept(_ d: OpenDispute) {
        guard let chip = DisputeChips.accept(d) else { return }
        active = d.id
        step = .confirm(chip)
    }

    /// The typed message or amount becomes a chip; nothing is sent until the confirm tap.
    func next(_ d: OpenDispute, _ kind: Kind) {
        switch kind {
        case .reply:
            guard let chip = DisputeChips.reply(d, message: draft) else { return }
            step = .confirm(chip)
        case .offer:
            switch DisputeChips.offer(d, typed: draft) {
            case .success(let chip): step = .confirm(chip)
            case .failure(.notAnAmount): step = .error("Type an amount, like 20")
            case .failure(.moreThanDispute(let m)): step = .error("Offer \(m) or less, or accept the claim")
            }
        }
    }

    func send(_ chip: Chip, to d: OpenDispute) {
        step = .working(ChipActions.working[chip.kind] ?? "Sending\u{2026}")
        let api = api()
        Task {
            do {
                switch try await ChipActions.run(chip, confirmed: d.name, api: api, key: chip.key) {
                case .line(let line), .undoable(let line, _): step = .done(line)
                default: step = .done("Done \u{2713}")
                }
            } catch APIError.needsConfirm {
                step = .confirm(chip)
            } catch {
                step = .error(plainLine(error))
            }
        }
    }

    /// After a sent answer, the list reads PayPal again: an accepted claim leaves it.
    func close() {
        let sent = if case .done = step { true } else { false }
        active = nil
        step = .idle
        draft = ""
        if sent { Task { await reload() } }
    }
}

struct DisputesView: View {
    @StateObject private var model = DisputesModel()

    var body: some View {
        List(model.items) { d in
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(d.line).font(Theme.Font.body).foregroundStyle(Theme.Color.text1)
                    .accessibilityIdentifier("dispute.line.\(d.id)")
                if model.active == d.id { answer(d) } else { buttons(d) }
            }
            .padding(.vertical, Theme.Space.xxs)
            .listRowBackground(Theme.Color.bg)
        }
        .overlay {
            if model.loaded && model.items.isEmpty {
                Text("No open disputes \u{2713}").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.Color.bg.ignoresSafeArea())
        .navigationTitle("Disputes")
        .animation(Theme.Motion.chipAppear, value: model.step)
        .task { await model.reload() }
    }

    private func buttons(_ d: OpenDispute) -> some View {
        HStack(spacing: Theme.Space.xs) {
            AskChip(title: "Reply", detail: nil) { model.start(d, .reply) }.accessibilityIdentifier("dispute.reply")
            AskChip(title: "Offer", detail: nil) { model.start(d, .offer) }.accessibilityIdentifier("dispute.offer")
            if d.amount != nil {
                AskChip(title: "Accept", detail: nil) { model.accept(d) }.accessibilityIdentifier("dispute.accept")
            }
        }
    }

    @ViewBuilder private func answer(_ d: OpenDispute) -> some View {
        switch model.step {
        case .idle:
            buttons(d)
        case .typing(let kind):
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                TextField("", text: $model.draft, prompt: Text(kind == .reply ? "Message to \(d.name)" : "Amount, like 20").foregroundStyle(Theme.Color.text3),
                          axis: kind == .reply ? .vertical : .horizontal)
                    .font(Theme.Font.body).foregroundStyle(Theme.Color.text1)
                    .keyboardType(kind == .offer ? .decimalPad : .default)
                    .accessibilityIdentifier("dispute.field")
                HStack(spacing: Theme.Space.xs) {
                    AskChip(title: "Next", detail: nil) { model.next(d, kind) }.accessibilityIdentifier("dispute.next")
                    AskChip(title: "Cancel", detail: nil) { model.close() }
                }
            }
        case .confirm(let chip):
            // The question can quote a long reply, so it wraps above the two chips.
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(BarItems.confirmTitle(chip, recipient: d.name)).font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.xs) {
                    AskChip(title: "Send", detail: nil) { model.send(chip, to: d) }.accessibilityIdentifier("dispute.confirm")
                    AskChip(title: "Cancel", detail: nil) { model.close() }
                }
            }
        case .working(let line):
            Text(line).font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
        case .done(let line):
            HStack(spacing: Theme.Space.xs) {
                Text(line).font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.paid).accessibilityIdentifier("dispute.done")
                AskChip(title: "Done", detail: nil) { model.close() }
            }
        case .error(let line):
            HStack(spacing: Theme.Space.xs) {
                Text(line).font(Theme.Font.label).foregroundStyle(Theme.Color.due)
                AskChip(title: "Back", detail: nil) { model.close() }
            }
        }
    }
}
