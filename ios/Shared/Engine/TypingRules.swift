import UIKit

/// How the keys behave as the owner types, like the iOS keyboard. Pure: text and times in, a decision out.
enum TypingRules {
    static let doubleSpaceWindow: TimeInterval = 0.45

    /// A second space soon after the first, right after a word, turns into ". ".
    static func doubleSpaceMakesPeriod(before: String, sinceLastSpace: TimeInterval?) -> Bool {
        guard let gap = sinceLastSpace, gap < doubleSpaceWindow, before.hasSuffix(" "),
              let prev = before.dropLast().last else { return false }
        return prev.isLetter || prev.isNumber || ")\"'\u{201D}\u{2019}".contains(prev)
    }

    /// Shift turns on by itself where the field's autocapitalizationType says a capital comes next.
    static func autoShift(before: String, type: UITextAutocapitalizationType) -> Bool {
        switch type {
        case .none: return false
        case .allCharacters: return true
        case .words: return before.isEmpty || before.last?.isWhitespace == true
        default:
            guard let last = before.last else { return true }
            if last.isNewline { return true }
            guard last == " " else { return false }
            var rest = Substring(before)
            while let c = rest.last, c == " " { rest.removeLast() }
            while let c = rest.last, ")\"'\u{201D}\u{2019}".contains(c) { rest.removeLast() }
            guard let end = rest.last else { return true }
            return end.isNewline || ".!?".contains(end)
        }
    }
}
