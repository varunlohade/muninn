import Foundation

/// When the keyboard sends typed text to /v1/suggest, and which reply chips it may show.
///
/// Pure: the caller hands in the text. The only state is the chips the owner turned away,
/// each kept with the text it was turned away on.
struct SuggestPolicy {
    /// Fewer words than this is still typing, not a message. Nothing leaves the phone.
    static let minWords = 3
    /// With an amount or a money word, two words are already a request: "$45 haircut".
    static let minMoneyWords = 2
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

    init() {}

    /// `typed` is the trimmed text before the cursor. `prefix` is "Invoice Sam sam@…" after an "Invoice Sam" tap.
    static func ask(_ typed: String, lastAsked: String, prefix: String? = nil) -> Ask {
        guard typed != lastAsked else { return .keep }
        guard !typed.isEmpty, SecretScan.scan(typed) == .clean else { return .skip }
        let text = prefix.map { $0 + " " + typed } ?? typed
        let words = text.split(whereSeparator: \.isWhitespace).count
        guard words >= (hasMoneySignal(text) ? minMoneyWords : minWords) else { return .skip }
        return .ask(text, after: debounce)
    }

    /// "$45", "45 usd", "€45.50", or a word such as invoice, pay, owe, refund, remind, paid.
    static func hasMoneySignal(_ text: String) -> Bool {
        let amount = #"[$€£]\s?\d|\d(?:[.,]\d{1,2})?\s?(?:usd|eur|gbp|cad|aud|dollars?|bucks|euros?|pounds?)\b"#
        let word = #"\b(?:invoice|pay|paid|owe|owes|owed|refund|remind)\b"#
        return text.range(of: amount + "|" + word, options: [.regularExpression, .caseInsensitive]) != nil
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
