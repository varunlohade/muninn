import SwiftUI

/// The whole keyboard: suggestion bar on top, keys below. Used by the extension and the app's Keyboard Lab.
struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        VStack(spacing: 0) {
            SuggestionBar(model: model)
                .frame(height: Theme.Metric.barHeight)
            KeysView(model: model)
                .padding(.horizontal, 3)
                .padding(.bottom, 8)
        }
        .frame(height: Theme.Metric.keyboardHeight)
        .background(Theme.Color.keyboardBed)
    }
}

struct SuggestionBar: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                content
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
        }
        .animation(Theme.chipAppear, value: model.bar)
    }

    @ViewBuilder private var content: some View {
        if !model.hasFullAccess {
            InfoChip(text: "Turn on Full Access in Settings › Keyboards › \(AppConfig.keyboardName)")
        } else if !model.paired {
            InfoChip(text: "Open \(AppConfig.displayName) to pair this keyboard")
        } else {
            switch model.bar {
            case .idle:
                EmptyView()
            case .chips(let chips):
                ForEach(chips) { chip in
                    ChipButton(label: chip.label, prominent: chip.kind == "invoice") { model.tapChip(chip) }
                        .accessibilityIdentifier("chip.\(chip.kind)")
                        .transition(.opacity.combined(with: .offset(y: 5)).combined(with: .scale(scale: 0.96)))
                }
            case .working(let text):
                InfoChip(text: text)
            case .confirm(let chip, let recipient):
                ChipButton(label: "Send to \(recipient)?", prominent: true) { model.confirm(chip, recipient: recipient) }
                    .accessibilityIdentifier("chip.confirm")
                ChipButton(label: "Cancel", prominent: false) { model.cancelConfirm() }
            case .done(let text):
                InfoChip(text: text).accessibilityIdentifier("chip.done")
            case .error(let text):
                InfoChip(text: text, color: Theme.Color.due).accessibilityIdentifier("chip.error")
            }
        }
    }
}

struct ChipButton: View {
    let label: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Font.chip)
                .monospacedDigit()
                .foregroundStyle(Theme.Color.text1)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: Theme.Metric.chipHeight - 6)
                .background(prominent ? Theme.Color.chipPrimary : Theme.Color.chip, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct InfoChip: View {
    let text: String
    var color: Color = Theme.Color.text2

    var body: some View {
        Text(text)
            .font(Theme.Font.secondary)
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: Theme.Metric.chipHeight - 8)
            .background(Theme.Color.surface1, in: Capsule())
    }
}

struct KeysView: View {
    @ObservedObject var model: KeyboardModel

    private let letters = [Array("qwertyuiop"), Array("asdfghjkl"), Array("zxcvbnm")].map { $0.map(String.init) }
    private let symbolRows = [Array("1234567890"), Array("-/:;()$&@\""), Array(".,?!'")].map { $0.map(String.init) }

    var body: some View {
        let rows = model.symbols ? symbolRows : letters
        VStack(spacing: Theme.Metric.rowGap) {
            KeyRow(keys: rows[0], model: model)
            KeyRow(keys: rows[1], model: model)
                .padding(.horizontal, model.symbols ? 0 : 18)
            HStack(spacing: Theme.Metric.keyGap) {
                if model.symbols {
                    Spacer(minLength: 0)
                } else {
                    FnKey(systemImage: model.shifted ? "shift.fill" : "shift", label: "shift") { model.shifted.toggle() }
                        .frame(width: 44)
                }
                KeyRow(keys: rows[2], model: model)
                FnKey(systemImage: "delete.left", label: "delete") { model.tapDelete() }
                    .frame(width: 44)
            }
            HStack(spacing: Theme.Metric.keyGap) {
                FnKey(text: model.symbols ? "ABC" : "123", label: "more") { model.symbols.toggle() }
                    .frame(width: 50)
                    .accessibilityIdentifier("muninn.more")
                if model.host?.needsGlobeKey ?? true {
                    FnKey(systemImage: "globe", label: "next keyboard") { model.host?.nextKeyboard() }
                        .frame(width: 44)
                }
                FnKey(text: "space", label: "space", fill: Theme.Color.key) { model.tapSpace() }
                FnKey(text: "return", label: "return") { model.tapReturn() }
                    .frame(width: 88)
            }
        }
    }
}

struct KeyRow: View {
    let keys: [String]
    @ObservedObject var model: KeyboardModel

    var body: some View {
        HStack(spacing: Theme.Metric.keyGap) {
            ForEach(keys, id: \.self) { k in
                Button { model.tapKey(k) } label: {
                    Text(model.shifted && !model.symbols ? k.uppercased() : k)
                        .font(Theme.Font.key)
                        .foregroundStyle(Theme.Color.text1)
                        .frame(maxWidth: .infinity, minHeight: Theme.Metric.keyHeight)
                        .background(Theme.Color.key, in: RoundedRectangle(cornerRadius: Theme.Metric.keyRadius))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(k)
            }
        }
    }
}

struct FnKey: View {
    var text: String? = nil
    var systemImage: String? = nil
    let label: String
    var fill: Color = Theme.Color.keyFn
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage { Image(systemName: systemImage) } else { Text(text ?? "") }
            }
            .font(Theme.Font.keyFn)
            .foregroundStyle(Theme.Color.text1)
            .frame(maxWidth: .infinity, minHeight: Theme.Metric.keyHeight)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.Metric.keyRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
