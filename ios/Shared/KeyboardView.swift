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
    @State private var expanded = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                content
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
        }
        .animation(Theme.Motion.chipAppear, value: model.bar)
        .animation(Theme.Motion.chipAppear, value: model.copiedAvailable)
        .onChange(of: model.bar) { expanded = false }
    }

    @ViewBuilder private var content: some View {
        if !model.hasFullAccess {
            InfoChip(text: "Turn on Full Access in Settings › Keyboards › \(AppConfig.keyboardName)")
        } else if !model.paired {
            InfoChip(text: "Open \(AppConfig.displayName) to pair this keyboard")
        } else {
            if let watch = model.watch {
                WatchChip(watch: watch).accessibilityIdentifier(watch.paid ? "chip.paid" : "chip.waiting")
            }
            if model.copiedAvailable {
                PillButton(action: model.useCopied) {
                    Image(systemName: "doc.on.clipboard").font(Theme.KeyboardFont.secondary)
                    Text("Use copied message").font(Theme.KeyboardFont.chipKey)
                }
                .accessibilityIdentifier("chip.copied")
            }
            switch model.bar {
            case .idle:
                EmptyView()
            case .chips(let chips, let fromCopied):
                let shown = expanded || chips.count <= 2 ? chips : Array(chips.prefix(2))
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, chip in
                    SuggestionChip(chip: chip, hint: fromCopied ? "from copied message" : nil) { model.tapChip(chip) }
                        .accessibilityIdentifier("chip.\(chip.kind)")
                        .transition(.opacity.combined(with: .offset(y: 5)).combined(with: .scale(scale: 0.96))
                            .animation(Theme.Motion.chipAppear.delay(Double(i) * Theme.Motion.chipStagger)))
                }
                if chips.count > 2 && !expanded {
                    PillButton(action: { expanded = true }) { Image(systemName: "ellipsis").font(Theme.KeyboardFont.chipKey) }
                        .accessibilityLabel("More suggestions")
                }
            case .working(let text):
                InfoChip(text: text)
            case .confirm(let chip, let recipient):
                PillButton(action: { model.confirm(chip, recipient: recipient) }) {
                    Text("Send to").font(Theme.KeyboardFont.chipText).foregroundStyle(Theme.Color.text2)
                    Text(recipient).font(Theme.KeyboardFont.chipKey)
                }
                .accessibilityIdentifier("chip.confirm")
                PillButton(action: model.cancelConfirm) { Text("Cancel").font(Theme.KeyboardFont.chipText) }
            case .done(let text):
                InfoChip(text: text).accessibilityIdentifier("chip.done")
            case .error(let text):
                InfoChip(text: text, color: Theme.Color.due).accessibilityIdentifier("chip.error")
            }
        }
    }
}

/// v3 chip: flat card pill, 1 px inner edge, weight steps instead of a "·" meta string.
struct PillButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) { label }
                .foregroundStyle(Theme.Color.text1)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: Theme.Metric.chipHeight)
                .background(Theme.Color.card, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.Color.chipEdge, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
    }
}

struct SuggestionChip: View {
    let chip: Chip
    let hint: String?
    let action: () -> Void

    private func string(_ key: String) -> String? {
        if case .string(let v)? = chip.payload[key], !v.isEmpty { return v }
        return nil
    }

    var body: some View {
        PillButton(action: action) {
            switch chip.kind {
            case "invoice", "paylink":
                Image(systemName: chip.kind == "invoice" ? "doc.text" : "link").font(Theme.KeyboardFont.secondary).foregroundStyle(Theme.Color.text2)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Text(chip.kind == "invoice" ? "Invoice" : "Pay link").font(Theme.KeyboardFont.chipKey)
                        if let a = string("amount"), let c = string("currency") {
                            Text(formatMoney(a, c)).font(Theme.KeyboardFont.chipValue)
                        }
                        if let item = string("item") {
                            Text(item).font(Theme.KeyboardFont.chipText).foregroundStyle(Theme.Color.text2)
                        }
                        // The recipient stays visible on an invoice chip (security review M2).
                        if chip.kind == "invoice", let to = string("client_email") ?? string("client_name") {
                            Text("→ \(to)").font(Theme.KeyboardFont.chipText).foregroundStyle(Theme.Color.text3)
                        }
                    }
                    if let hint {
                        Text(hint).font(Theme.KeyboardFont.hint).foregroundStyle(Theme.Color.text3)
                    }
                }
            default:
                Text(chip.label).font(Theme.KeyboardFont.chipKey)
            }
        }
    }
}

/// "Sent · waiting" flips to green "Sam paid $45 ✓" when /v1/payments says paid.
struct WatchChip: View {
    let watch: Watch
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            face(paid: false)
                .rotation3DEffect(.degrees(watch.paid && !reduceMotion ? -180 : 0), axis: (1, 0, 0), perspective: 0.6)
                .opacity(watch.paid ? 0 : 1)
            face(paid: true)
                .rotation3DEffect(.degrees(watch.paid || reduceMotion ? 0 : 180), axis: (1, 0, 0), perspective: 0.6)
                .opacity(watch.paid ? 1 : 0)
        }
        .animation(reduceMotion ? Theme.Motion.crossfade : Theme.Motion.chipFlip, value: watch.paid)
    }

    private func face(paid: Bool) -> some View {
        HStack(spacing: 5) {
            if paid {
                Text("\(watch.who) paid").font(Theme.KeyboardFont.chipKey).foregroundStyle(Theme.Color.paidChipText)
                Text(watch.money).font(Theme.KeyboardFont.chipValue).foregroundStyle(Theme.Color.paidChipText)
                Image(systemName: "checkmark").font(Theme.KeyboardFont.chipKey).foregroundStyle(Theme.Color.paid)
            } else {
                Image(systemName: "clock").font(Theme.KeyboardFont.secondary).foregroundStyle(Theme.Color.text2)
                Text("Sent").font(Theme.KeyboardFont.chipKey).foregroundStyle(Theme.Color.text1)
                Text(watch.money).font(Theme.KeyboardFont.chipValue).foregroundStyle(Theme.Color.text1)
                Text("waiting").font(Theme.KeyboardFont.chipText).foregroundStyle(Theme.Color.text2)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: Theme.Metric.chipHeight)
        .background(paid ? Theme.Color.paidChip : Theme.Color.card, in: Capsule())
        .overlay(Capsule().strokeBorder(paid ? Theme.Color.paidChipEdge : Theme.Color.chipEdge, lineWidth: 1))
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(configuration.isPressed ? Theme.Motion.press : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct InfoChip: View {
    let text: String
    var color: Color = Theme.Color.text2

    var body: some View {
        Text(text)
            .font(Theme.KeyboardFont.secondary)
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: Theme.Metric.chipHeight)
            .background(Theme.Color.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.Color.chipEdge, lineWidth: 1))
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
                        .font(Theme.KeyboardFont.key)
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
            .font(Theme.KeyboardFont.keyFn)
            .foregroundStyle(Theme.Color.text1)
            .frame(maxWidth: .infinity, minHeight: Theme.Metric.keyHeight)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.Metric.keyRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
