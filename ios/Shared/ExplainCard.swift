import SwiftUI

/// The explain card, in place of the keys: the answer, an example or a few lines, then Back, Show visually and Insert.
/// A white card on paper, then quiet Back and Show visually and the dark Insert.
struct ExplainCardView: View {
    @ObservedObject var model: KeyboardModel
    let offer: ExplainOffer
    let palette: Theme.SystemKeyboard.Palette
    typealias M = Theme.SystemKeyboard

    var body: some View {
        VStack(spacing: M.keyGap) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                twoTone("\u{201C}\(offer.subject)\u{201D}", offer.line, ink: Theme.Color.text2, ink2: Theme.Color.text1)
                    .font(Theme.Font.sans(17, 500))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("explain.line")
                ForEach(Array(details.enumerated()), id: \.offset) { _, line in
                    Text(line).font(Theme.Font.sans(15)).foregroundStyle(Theme.Color.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .cardSurface()
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
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 6)
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

/// A wide tactile button, like the Rewrite panel's. `accent` is the one main action (dark).
struct ExplainButton: View {
    let title: String
    let id: String
    var accent = false
    let palette: Theme.SystemKeyboard.Palette
    let action: () -> Void
    typealias M = Theme.SystemKeyboard

    var body: some View {
        Button(title, action: action)
            .buttonStyle(TactileButton(kind: accent ? .dark : .quiet))
            .frame(height: M.keyHeight)
            .accessibilityIdentifier(id)
    }
}
