import Foundation

/// What a payment chip's link does to the field. A command to Muninn ("invoice sam $45") gives way to a message
/// for the client. Chat to the client ("$45 for the haircut") stays as typed and only gets the link.
enum ChipText {
    /// Delete `delete` characters before the cursor, then type `insert`.
    struct Edit: Equatable {
        let delete: Int
        let insert: String
        /// What a "Tap to add" chip types when the field moved on: never a replace, only an append.
        let fallback: String
    }

    private static let lead = #"^(?:(?:hey|ok|okay|please|pls|plz|muninn)[\s,]+)*"#
    private static let commands = [
        // "invoice sam $45", "bill ana $40", "charge sam 45", "nudge ana". Not "invoice is attached" or "bill was $40".
        #"(?:invoice|bill|charge|remind|nudge|chase)\s+(?!(?:is|was|has|have|will|should|sent|attached|coming|went|for\s+(?:the|this|that)\b)\b)\S"#,
        // "send invoice to sam", "make a pay link for 50", "create invoice for sam".
        #"(?:send|make|create|generate|new|draft|prepare|do)\s+(?:me\s+)?(?:an?\s+|the\s+)?(?:pay(?:ment)?\s*link|invoice|bill|payment\s+request)\b"#,
        // "pay link $45 haircut", "paylink 50", "request $45 from sam".
        #"(?:pay(?:ment)?\s*link|request)\s+(?:for\s+)?(?:[$€£]?\s?\d|from\b|to\b)"#,
    ]

    /// True when the sentence tells Muninn what to do, not the client.
    static func isCommand(_ sentence: String) -> Bool {
        let s = sentence.trimmingCharacters(in: .whitespaces)
        return commands.contains { SmartDetect.has(s, lead + $0) }
    }

    /// "Hi Sam, here's the invoice for the haircut ($45): <link>"
    static func clientMessage(kind: String, who: String, item: String?, money: String, link: String) -> String {
        let hi = who.isEmpty || who == "Client" ? "Hi" : "Hi \(who)"
        let what = kind == "invoice" ? "the invoice" : "the payment link"
        let item = item.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty || $0 == "Payment" ? nil : $0 }
        let forItem = item.map { " for the \(lowerFirst($0))" } ?? ""
        let amount = money.isEmpty ? "" : " (\(money))"
        return "\(hi), here's \(what)\(forItem)\(amount): \(link)"
    }

    /// `before` is the text before the cursor at the tap. Only its last sentence can go, and only when it is a command.
    static func edit(before: String, kind: String, who: String, item: String?, money: String, link: String, gap: String) -> Edit {
        let sentence = SmartDetect.lastSentence(before)
        let trailing = before.reversed().prefix(while: \.isWhitespace).count
        if !sentence.isEmpty, isCommand(sentence), before.dropLast(trailing).hasSuffix(sentence) {
            let message = clientMessage(kind: kind, who: who, item: item, money: money, link: link)
            return Edit(delete: sentence.count + trailing, insert: message, fallback: message)
        }
        if before.contains(link) { return Edit(delete: 0, insert: "", fallback: link) }
        let needsGap = !(before.last?.isWhitespace ?? true)
        return Edit(delete: 0, insert: (needsGap ? gap : "") + link, fallback: link)
    }

    /// "Haircut" reads "the haircut"; "SEO" stays.
    private static func lowerFirst(_ s: String) -> String {
        let chars = Array(s)
        guard chars.count > 1, chars[0].isUppercase, chars[1].isLowercase else { return s }
        return chars[0].lowercased() + String(chars.dropFirst())
    }
}
