import Foundation

/// When the keyboard sends typed text to /v1/suggest, and which reply chips it may show.
///
/// Pure: the caller hands in the text. The only state is the chips the owner turned away,
/// each kept with the text it was turned away on.
struct SuggestPolicy {
    /// With an amount or a money word, two words are already a request: "$45 haircut".
    static let minMoneyWords = 2
    /// Shortcuts start with this. They run on the phone and never go to the server.
    static let shortcutPrefix = ";"
    static let debounce = AppConfig.suggestDebounce

    enum Ask: Equatable {
        /// Same text as last time: leave the bar as it is.
        case keep
        /// Do not send. Old chips no longer fit the text.
        case skip
        /// Send `text` once the fingers rest for `after`.
        case ask(String, after: Duration)
    }

    /// Chip kind → the text it was turned away on.
    private(set) var crossed: [String: String] = [:]
    /// Sentences already sent on the "maybe an action" path, by their first words. Each goes once.
    private(set) var askedSentences: Set<String> = []

    init() {}

    /// `typed` is the trimmed text before the cursor. `prefix` is "Invoice Sam sam@…" after an "Invoice Sam" tap.
    /// `clear`: the phone already read an event, reminder or note. Then a soft money word ("remind me", "buy")
    /// is not enough to ask; an amount or a billing word still is.
    static func ask(_ typed: String, lastAsked: String, prefix: String? = nil, clear: Bool = false) -> Ask {
        guard typed != lastAsked else { return .keep }
        guard !typed.isEmpty, !typed.hasPrefix(shortcutPrefix), SecretScan.scan(typed) == .clean else { return .skip }
        let text = prefix.map { $0 + " " + typed } ?? typed
        let words = text.split(whereSeparator: \.isWhitespace).count
        guard hasMoneySignal(text), words >= minMoneyWords else { return .skip }
        if clear, prefix == nil, !hasStrongMoneySignal(text) { return .skip }
        return .ask(text, after: debounce)
    }

    /// An amount, a price shape or a billing word: money even when the text is also a reminder.
    static func hasStrongMoneySignal(_ text: String) -> Bool {
        let amount = #"[$€£]\s?\d|\d\s?[$€£]|\d(?:[.,]\d{1,2})?\s?(?:usd|eur|gbp|cad|aud|dollars?|bucks|euros?|pounds?)\b"#
        let priceShape = #"\b\d+(?:[.,]\d+)*\s+for\b"#
        let word = #"\b(?:invoic\w*|bill\w*|pay\w*|paid|owe[sd]?|owing|refund\w*|charge[sd]?|price[sd]?|cost\w*|deposit|venmo|paypal|link|quote|fees?)\b"#
        return text.range(of: [amount, priceShape, word].joined(separator: "|"), options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Text with no money signal and no clear on-device match, but action-ish signals ("can we do Ana's thing Friday"):
    /// the last sentence goes to the server once, after the pause. Nil for plain chat, a clear match, or a sentence already sent.
    func maybe(_ typed: String, clear: Bool) -> String? {
        guard !clear, !typed.hasPrefix(Self.shortcutPrefix), !Self.hasMoneySignal(typed), SmartDetect.maybe(typed) else { return nil }
        let sentence = SmartDetect.lastSentence(typed)
        return askedSentences.contains(Self.sentenceKey(sentence)) ? nil : sentence
    }

    /// Called when the maybe request really goes out, after the pause.
    mutating func markAsked(_ sentence: String) {
        askedSentences.insert(Self.sentenceKey(sentence))
    }

    /// A sentence is known by its first three words, so typing on in the same sentence does not ask again.
    static func sentenceKey(_ sentence: String) -> String {
        sentence.lowercased().split(whereSeparator: \.isWhitespace).prefix(3).joined(separator: " ")
    }

    /// The server's gate (server/src/quick.ts): an amount, a price shape, a money word, or another script.
    /// Without one the server answers no chips, so plain chat never leaves the phone.
    static func hasMoneySignal(_ text: String) -> Bool {
        let amount = #"[$€£]\s?\d|\d\s?[$€£]|\d(?:[.,]\d{1,2})?\s?(?:usd|eur|gbp|cad|aud|dollars?|bucks|euros?|pounds?)\b"#
        let priceShape = #"\b\d+(?:[.,]\d+)*\s+for\b|\b(?:do|for)\s+\d"#
        let word = #"\b(?:invoic\w*|bill\w*|pay\w*|paid|owe[sd]?|owing|refund\w*|remind\w*|link|price[sd]?|pricing|cost\w*|charge[sd]?|how much|rates?|quote|fees?|total|due|overdue|late|money|cash|deposit|balance|receipt|venmo|paypal|transfer|tip|reimburse\w*|available|availability|services?|products?|menu|catalog\w*|in stock|sell|buy|plans?|subscriptions?|pause\w*|resume|restart|suspend\w*|disputes?|claim|offer)\b"#
        let otherScript = #"[^\P{L}A-Za-z]"#
        return text.range(of: [amount, priceShape, word, otherScript].joined(separator: "|"),
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The reply's chips to show, or nil when the text moved on since the ask (a stale reply).
    func show(_ chips: [Chip], askedFor: String, current: String) -> [Chip]? {
        guard askedFor == current else { return nil }
        return chips.filter { crossed[$0.kind] == nil }
    }

    /// The owner turned this chip away: it stays away until the text changes.
    mutating func dismiss(_ chip: Chip, on text: String) {
        crossed[chip.kind] = text
    }

    /// Each edit: a turned-away chip may come back once the text is no longer what it was.
    mutating func observe(_ text: String) {
        crossed = crossed.filter { $0.value == text }
    }
}

/// Text that must not go to a server: card numbers, one-time codes, keys and tokens.
enum SecretScan {
    enum Verdict: Equatable { case clean, cardNumber, code, token }

    static func scan(_ text: String) -> Verdict {
        if hasCardNumber(text) { return .cardNumber }
        let words = text.split(whereSeparator: \.isWhitespace)
        if words.contains(where: { $0.count == 6 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) { return .code }
        if text.contains("PRIVATE KEY-----") || words.contains(where: { looksLikeToken(String($0)) }) { return .token }
        return .clean
    }

    /// 13 to 19 digits, single spaces or dashes allowed between them, passing the Luhn check.
    static func hasCardNumber(_ text: String) -> Bool {
        var start = text.startIndex
        while let r = text.range(of: #"[0-9](?:[ -]?[0-9]){12,18}"#, options: .regularExpression, range: start..<text.endIndex) {
            if luhn(text[r].filter(\.isNumber)) { return true }
            start = r.upperBound
        }
        return false
    }

    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            var d = ch.wholeNumberValue ?? 0
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }

    static let keyPrefixes = [
        "sk-", "sk_live_", "sk_test_", "rk_live_", "rk_test_", "whsec_", "xoxb-", "xoxp-", "ghp_", "gho_",
        "github_pat_", "glpat-", "AKIA", "AIza", "ya29.", "npm_", "hf_", "shpat_", "SG.", "pkd_",
    ]

    static func looksLikeToken(_ word: String) -> Bool {
        if word.count >= 16, keyPrefixes.contains(where: { word.hasPrefix($0) }) { return true }
        if word.range(of: #"^eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}$"#, options: .regularExpression) != nil { return true }
        // A long unbroken run of key characters with both letters and digits.
        return word.count >= 32 && word.range(of: #"^[A-Za-z0-9+/=_-]+$"#, options: .regularExpression) != nil
            && word.contains(where: \.isLetter) && word.contains(where: \.isNumber)
    }
}
