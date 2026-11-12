import SwiftUI

/// The explain card, in place of the keys: the answer, an example or a few lines, then Back, Show visually and Insert.
/// Muninn's keyboard look (key-coloured card, accent Insert), kept in its own file for the redesign.
struct ExplainCardView: View {
    @ObservedObject var model: KeyboardModel
    let offer: ExplainOffer
    let palette: Theme.SystemKeyboard.Palette
    typealias M = Theme.SystemKeyboard

    var body: some View {
        VStack(spacing: M.keyGap) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                (Text("\u{201C}\(offer.subject)\u{201D}  ").foregroundColor(palette.accent) + Text(offer.line).foregroundColor(palette.label))
                    .font(M.mode.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("explain.line")
                ForEach(Array(details.enumerated()), id: \.offset) { _, line in
                    Text(line).font(M.mode).foregroundStyle(palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(palette.key, in: RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("explain.card")

            HStack(spacing: M.keyGap) {
                ExplainButton(title: "Back", id: "explain.back", palette: palette, action: model.closeExplain)
                if showsVisual {
                    ExplainButton(title: "Show visually", id: "explain.visual", palette: palette, action: model.showVisual)
                }
                ExplainButton(title: "Insert", id: "explain.insert", accent: true, palette: palette, action: model.insertExplain)
            }
        }
        .padding(.horizontal, M.sideInset)
        .padding(.vertical, 4)
    }

    private var details: [String] {
        switch offer {
        case .meaning(let m): ["\u{201C}\(m.example)\u{201D}"]
        case .answer(_, let r): r.body.components(separatedBy: "\n").filter { !$0.isEmpty }
        case .chart, .business: []
        }
    }

    /// A drawing needs the server. A dictionary term gets none; an answer gets one when the server says it helps.
    private var showsVisual: Bool {
        if case .answer(_, let r) = offer { return r.visual_ok && model.paired }
        return false
    }
}

/// A wide key-shaped button, like the Rewrite panel's. `accent` is the one main action.
struct ExplainButton: View {
    let title: String
    let id: String
    var accent = false
    let palette: Theme.SystemKeyboard.Palette
    let action: () -> Void
    typealias M = Theme.SystemKeyboard

    var body: some View {
        Button(action: action) {
            Text(title).font(M.mode.weight(accent ? .semibold : .regular)).foregroundStyle(accent ? .white : palette.label)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: M.keyHeight, maxHeight: M.keyHeight)
                .background(accent ? palette.accent : palette.key, in: RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}
