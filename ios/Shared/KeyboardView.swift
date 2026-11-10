import SwiftUI

/// The whole keyboard: an iOS-style predictive bar with our chips, then the system-replica keys.
struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    typealias M = Theme.SystemKeyboard

    var body: some View {
        let p = model.isDark ? M.dark : M.light
        ZStack(alignment: .top) {
            p.bed
            SystemKeysView(model: model)
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
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { Rectangle().fill(palette.divider).frame(width: 1, height: M.dividerHeight) }
                Slot(item: item, palette: palette)
                    .accessibilityIdentifier("chip.\(item.id)")
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, M.barHeight - 2 * 23.8)
        .animation(Theme.Motion.chipAppear, value: items.map(\.id))
    }

    private var items: [Item] {
        if !model.hasFullAccess { return [Item(id: "info", title: "Allow Full Access in Settings for \(AppConfig.keyboardName)", tint: palette.secondaryLabel)] }
        if !model.paired { return [Item(id: "info", title: "Open \(AppConfig.displayName) to pair", tint: palette.secondaryLabel)] }
        var out: [Item] = []
        if let w = model.watch {
            out.append(w.paid
                ? Item(id: "paid", title: "\(w.who) paid \(w.money) ✓", tint: Theme.Color.paid)
                : Item(id: "waiting", title: "Sent \(w.money)", detail: "waiting to be paid", tint: palette.secondaryLabel))
        }
        switch model.bar {
        case .idle:
            if model.copiedAvailable { out.append(Item(id: "copied", title: "Use copied message", action: model.useCopied)) }
        case .chips(let chips, let fromCopied):
            for chip in chips.prefix(3 - min(out.count, 1)) {
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
        let money = string(chip, "amount").flatMap { a in string(chip, "currency").map { formatMoney(a, $0) } } ?? ""
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
