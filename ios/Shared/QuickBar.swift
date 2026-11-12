import SwiftUI

/// One slot's words, verb first: "Invoice Sam" then the key value "$45" in medium weight.
/// An optional quoted trigger sits before it in a lighter tone: "“tomorrow 3pm” → Add to calendar".
struct QuickLabel: Equatable {
    var trigger: String? = nil
    var verb: String
    var value: String? = nil

    static func of(_ item: BarItems.Item) -> QuickLabel {
        if case .chip(let chip)? = item.action { return of(chip, item: item) }
        if case .smart? = item.action { return QuickLabel(trigger: item.trigger, verb: item.short ?? item.title) }
        if item.id == "explain", let t = item.trigger { return QuickLabel(trigger: t, verb: item.title) }
        if let d = item.detail, item.action != nil, d.count <= 14 { return QuickLabel(verb: item.title, value: d) }
        return QuickLabel(verb: item.title)
    }

    private static func of(_ chip: Chip, item: BarItems.Item) -> QuickLabel {
        let s = { (k: String) in BarItems.string(chip, k) }
        let first = s("client_name").flatMap { $0.split(separator: " ").first.map(String.init) }
        let money = s("amount").map { formatMoney($0, s("currency") ?? "") .trimmingCharacters(in: .whitespaces) }
        switch chip.kind {
        case "invoice": return QuickLabel(verb: ["Invoice", first].compactMap { $0 }.joined(separator: " "), value: money)
        case "paylink": return QuickLabel(verb: "Pay link", value: money)
        case "remind": return QuickLabel(verb: ["Nudge", first].compactMap { $0 }.joined(separator: " "), value: money.map { "\u{00B7} \($0)" })
        case "subscribe":
            let every = s("interval").flatMap { ["week": "/wk", "month": "/mo", "year": "/yr"][$0] } ?? ""
            return QuickLabel(verb: ["Repeat", first].compactMap { $0 }.joined(separator: " "), value: money.map { $0 + every })
        default: return QuickLabel(verb: item.title)
        }
    }
}

/// The QuickType-based bar (B3, the owner's pick): the system's height and 17 pt type, one line per slot, thin dividers,
/// no cards. Each slot is as wide as its words, from the left. The action slot is accent-coloured. At most three slots.
struct QuickRow: View {
    @ObservedObject var model: KeyboardModel
    let items: [BarItems.Item]
    let palette: Theme.SystemKeyboard.Palette
    typealias M = Theme.SystemKeyboard

    var body: some View {
        let shown = Array(items.prefix(3))
        let primary = shown.firstIndex { $0.action != nil && !$0.id.hasPrefix("predict.") && Self.isAction($0) }
        HStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
                if i > 0 { Rectangle().fill(palette.divider).frame(width: 1, height: M.dividerHeight) }
                slot(item, accent: i == primary)
                    .accessibilityIdentifier("chip.\(item.id)")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    /// Money and setup actions are the ones that do something; Undo, Cancel and words are not accented.
    static func isAction(_ item: BarItems.Item) -> Bool {
        switch item.action {
        case .chip, .bill, .smart, .explain, .confirm, .retry, .useCopied, .whoPaid: return true
        default: return false
        }
    }

    @ViewBuilder private func slot(_ item: BarItems.Item, accent: Bool) -> some View {
        let label = QuickLabel.of(item)
        let tint = accent ? palette.accent : color(item.tone)
        let text = (label.trigger.map { Text("\u{201C}\(Self.short($0))\u{201D} \u{2192} ").foregroundColor(palette.secondaryLabel) } ?? Text(""))
            + Text(label.verb).foregroundColor(tint)
            + Text(label.value.map { " " + $0 } ?? "").fontWeight(.medium).foregroundColor(tint)
        Button { if let a = item.action { model.perform(a) } } label: {
            text.font(M.prediction)
                .lineLimit(1).truncationMode(.tail)
                .padding(.horizontal, 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.action == nil)
        .accessibilityLabel([item.title, item.detail].compactMap { $0 }.joined(separator: ", "))
    }

    private func color(_ tone: BarItems.Tone) -> Color {
        switch tone {
        case .label, .accent: palette.label
        case .secondary: palette.secondaryLabel
        case .paid: Theme.Color.paid
        case .due: Theme.Color.due
        }
    }

    static func short(_ t: String) -> String { t.count > 14 ? String(t.prefix(13)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : t }
}
