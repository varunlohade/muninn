import XCTest
@testable import Muninn

/// The one-pass LanguageModel init builds the same model as the old two-pass one.
/// OldLanguageModel is the old code, kept here only until this check has run on a few builds.
final class LanguageModelTests: XCTestCase {
    func testSameAsOldOnBundledWords() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "en-words", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let old = OldLanguageModel(text: text), new = LanguageModel(text: text)
        XCTAssertEqual(new.sorted, old.sorted)
        XCTAssertEqual(new.logFreq, old.logFreq)
        for w in ["the", "hello", "zzz", "don't", "invoice"] { XCTAssertEqual(new.contains(w), old.contains(w), w) }
        for p in ["", "a", "th", "inv", "pay", "q", "don", "zzzz"] {
            XCTAssertEqual(new.completions(p, limit: 3), old.completions(p, limit: 3), p)
            XCTAssertEqual(new.hasPrefix(p), old.hasPrefix(p), p)
        }
        for ctx in ["", "t", "th", "the", "invoi", "don'", "x9y"] {
            for ch in LanguageModel.letters { XCTAssertEqual(new.logP(ch, after: ctx), old.logP(ch, after: ctx), "\(ctx) \(ch)") }
        }
    }

    /// Odd lines: comments, empty fields, extra tabs, CRLF, a curly apostrophe, an accent, a repeated word.
    func testSameAsOldOnOddLines() {
        let text = "# c\ta\t1\na\tb\tc\n\tfoo\t5\nbar\t\t9\r\nbaz\t7\n\nqux\t1e2\nn\u{2019}t\t50\ncafé\t30\nbaz\t90\nx\t1\r\ny\t2"
        let old = OldLanguageModel(text: text), new = LanguageModel(text: text)
        XCTAssertEqual(new.logFreq, old.logFreq)
        XCTAssertEqual(new.sorted, old.sorted)
        for ctx in ["", "ca", "n", "ba", "q"] {
            for ch in LanguageModel.letters { XCTAssertEqual(new.logP(ch, after: ctx), old.logP(ch, after: ctx), "\(ctx) \(ch)") }
        }
    }
}

// MARK: the old init, for the check above only

private final class OldLanguageModel: @unchecked Sendable {
    static let letters: [Character] = Array("abcdefghijklmnopqrstuvwxyz'")
    private static let size = 28, start = 27, next = 27

    /// ln(probability) of each word, from AOSP's 0-255 log scale.
    let logFreq: [String: Float]
    /// The words in order, for prefix search.
    let sorted: [String]

    private var counts: [[Float]] = []
    private var totals: [[Float]] = []
    /// How strongly a short context backs off to a shorter one (Dirichlet smoothing).
    private let smoothing: Float = 4

    /// `text`: lines of "word<TAB>f"; lines starting with # are skipped.
    init(text: String) {
        var freq: [String: Float] = [:]
        var weighted: [(String, Float)] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "\t")
            guard parts.count == 2, let f = Float(parts[1]) else { continue }
            let w = String(parts[0])
            freq[w] = (f - 255) / 8.59 * Float(M_LN2)
            // Half the log slope: common words count more, but "the" does not drown the rest.
            weighted.append((w, 1 + pow(2, (f - 100) / 17.18)))
        }
        logFreq = freq
        sorted = freq.keys.sorted()
        let n = Self.size, k = Self.next
        counts = [n * n * n * k, n * n * k, n * k, k].map { [Float](repeating: 0, count: $0) }
        totals = [n * n * n, n * n, n, 1].map { [Float](repeating: 0, count: $0) }
        for (w, weight) in weighted {
            var h = [Self.start, Self.start, Self.start]
            for ch in w {
                guard let c = Self.index(ch) else { break }
                add(h, c, weight)
                h = [h[1], h[2], c]
            }
        }
    }

    static func index(_ ch: Character) -> Int? {
        switch ch {
        case "a"..."z": return Int(ch.asciiValue! - 97)
        case "'", "\u{2019}": return 26
        default: return nil
        }
    }

    func contains(_ word: String) -> Bool { logFreq[word] != nil }

    /// Some word starts with `prefix`.
    func hasPrefix(_ prefix: String) -> Bool {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < prefix { lo = mid + 1 } else { hi = mid }
        }
        return lo < sorted.count && sorted[lo].hasPrefix(prefix)
    }

    /// The commonest words that start with `prefix` and are longer than it, commonest first.
    func completions(_ prefix: String, limit: Int) -> [String] {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < prefix { lo = mid + 1 } else { hi = mid }
        }
        var best: [(String, Float)] = []
        var i = lo
        while i < sorted.count, sorted[i].hasPrefix(prefix) {
            let w = sorted[i], f = logFreq[w]!
            i += 1
            guard w.count > prefix.count else { continue }
            if best.count < limit || f > best[best.count - 1].1 {
                best.append((w, f))
                best.sort { $0.1 > $1.1 }
                if best.count > limit { best.removeLast() }
            }
        }
        return best.map(\.0)
    }

    /// ln P(letter | the letters of the word so far). `word` is the current word up to the cursor, lowercased.
    func logP(_ letter: Character, after word: String) -> Double {
        guard let c = Self.index(letter) else { return log(1e-4) }
        var h = [Self.start, Self.start, Self.start]
        for ch in word.suffix(3) {
            guard let i = Self.index(ch) else { h = [Self.start, Self.start, Self.start]; continue }
            h = [h[1], h[2], i]
        }
        // Back off from the 3-letter context to none, smoothing each order with the one below.
        let n = Self.size, k = Self.next
        var p = 1 / Float(k)
        let ctx = [h[0] * n * n + h[1] * n + h[2], h[1] * n + h[2], h[2], 0]
        for order in (0..<4).reversed() {
            let t = totals[order][ctx[order]]
            p = (counts[order][ctx[order] * k + c] + smoothing * p) / (t + smoothing)
        }
        return Double(log(p))
    }

    private func add(_ h: [Int], _ c: Int, _ w: Float) {
        let n = Self.size, k = Self.next
        let ctx = [h[0] * n * n + h[1] * n + h[2], h[1] * n + h[2], h[2], 0]
        for order in 0..<4 {
            counts[order][ctx[order] * k + c] += w
            totals[order][ctx[order]] += w
        }
    }
}
