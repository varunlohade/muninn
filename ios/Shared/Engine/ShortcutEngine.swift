import Foundation

/// Which shortcut, if any, the last word before the cursor triggers on space or return. Pure: the caller applies it.
enum ShortcutEngine {
    struct Match: Equatable {
        enum Action: Equatable {
            case insert(String)
            case late
            case fix
            case payLink(amount: String, currency: String?)
        }
        /// Characters to delete before the cursor first.
        let delete: Int
        let action: Action
        /// The last word, lowercased. The intro watches it.
        let trigger: String
    }

    static func match(before: String, notes: [Note], actions: [ActionShortcut]) -> Match? {
        let words = before.split(omittingEmptySubsequences: false, whereSeparator: \.isWhitespace)
        guard let last = words.last, last.count >= 2 else { return nil }
        let key = last.lowercased()

        if let note = notes.first(where: { $0.trigger == key }) {
            return Match(delete: last.count, action: .insert(note.text), trigger: key)
        }
        let on = actions.filter(\.enabled)
        if let a = on.first(where: { $0.trigger == key }) {
            switch a.action {
            case .pay: return nil
            case .late: return Match(delete: last.count, action: .late, trigger: key)
            case .fix:
                let space = words.count > 1 && before.dropLast(last.count).last == " " ? 1 : 0
                return Match(delete: last.count + space, action: .fix, trigger: key)
            }
        }
        if words.count >= 2, let pay = on.first(where: { $0.action == .pay }), words[words.count - 2].lowercased() == pay.trigger,
           before.hasSuffix(" " + last), let amount = Shortcuts.amount(String(last)) {
            return Match(delete: last.count + 1 + pay.trigger.count,
                         action: .payLink(amount: amount.value, currency: amount.currency), trigger: key)
        }
        return nil
    }
}
