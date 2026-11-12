import XCTest
@testable import Muninn

/// The touch decoder: key resizing, adaptation, word decode, and a harness that measures typing errors.
final class TouchDecoderTests: XCTestCase {
    static let model = LanguageModel.bundled()!
    private let caps = KeyboardGeometry.keys(layout: .letters, width: 390, globe: false, currency: "$")
    private var keys: [TouchKey] { KeyboardGeometry.touchKeys(caps) }
    private func key(_ c: Character) -> TouchKey { keys.first { $0.letter == c }! }

    func testTheBundledModelLoadsAndKnowsEnglish() {
        let m = Self.model
        XCTAssertTrue(m.contains("the"))
        XCTAssertTrue(m.contains("invoice"))
        XCTAssertFalse(m.contains("teh"))
        XCTAssertTrue(m.hasPrefix("invo"))
        XCTAssertFalse(m.hasPrefix("qzx"))
        XCTAssertGreaterThan(m.logP("u", after: "q"), m.logP("z", after: "q"))
        XCTAssertGreaterThan(m.logP("e", after: "th"), m.logP("w", after: "th"))
    }

    func testATapInsideAKeysCoreIsNeverChanged() {
        // After "q", the model wants "u"; a tap well inside "y" still types "y", every time.
        let y = key("y")
        for fx in stride(from: 0.21, through: 0.79, by: 0.058) {
            for fy in stride(from: 0.21, through: 0.79, by: 0.058) {
                let p = CGPoint(x: y.frame.minX + fx * y.frame.width, y: y.frame.minY + fy * y.frame.height)
                XCTAssertEqual(TouchDecoder.decode(p, keys: keys, word: "q", model: Self.model)?.key.letter, "y", "\(fx),\(fy)")
            }
        }
    }

    func testAnEdgeTapGoesToTheLikelyLetter() {
        // On the edge between "y" and "u", after "q": "u".
        let y = key("y"), u = key("u")
        let edge = CGPoint(x: (y.frame.maxX + u.frame.minX) / 2 - 3, y: y.frame.midY)
        XCTAssertEqual(KeyboardGeometry.key(at: edge, in: caps)?.kind, .char("y"))
        XCTAssertEqual(TouchDecoder.decode(edge, keys: keys, word: "q", model: Self.model)?.key.letter, "u")
        // With no letter model, the touch alone decides: "y".
        XCTAssertEqual(TouchDecoder.decode(edge, keys: keys, word: "", model: nil)?.key.letter, "y")
    }

    func testTheCandidatesAreTheThreeLikeliestByTouch() {
        let g = key("g")
        let r = TouchDecoder.decode(CGPoint(x: g.frame.midX, y: g.frame.midY), keys: keys, word: "", model: Self.model)!
        XCTAssertEqual(r.candidates.count, 3)
        XCTAssertEqual(r.candidates.first?.letter, "g")
        XCTAssertGreaterThan(r.candidates[0].probability, r.candidates[1].probability)
    }

    func testAdaptationLearnsALowTapAndStaysClamped() {
        var a = TouchAdaptation()
        let s = key("s")
        for _ in 0..<500 { a.learn(CGPoint(x: s.frame.midX + 2 * s.frame.width, y: s.frame.maxY + 3 * s.frame.height), on: s) }
        XCTAssertEqual(a.offset(row: 1).dx, CGFloat(TouchAdaptation.maxX), accuracy: 1e-9)
        XCTAssertEqual(a.offset(row: 1).dy, CGFloat(TouchAdaptation.maxY), accuracy: 1e-9)
        XCTAssertEqual(a.offset(row: 0).dx, 0)
        XCTAssertEqual(TouchAdaptation(stored: a.stored), a)
        XCTAssertEqual(TouchAdaptation(stored: [9, 9, 9, -9, -9, -9]).offset(row: 2).dy, -CGFloat(TouchAdaptation.maxY))
        XCTAssertEqual(TouchAdaptation(stored: [1]), TouchAdaptation())
    }

    func testWordDecodeFixesANearMissAndKeepsRealWords() {
        let m = Self.model
        XCTAssertEqual(TouchDecoder.correctWord("availble", taps: nil, model: m), "available")
        XCTAssertEqual(TouchDecoder.correctWord("tomorow", taps: nil, model: m), "tomorrow")
        XCTAssertNil(TouchDecoder.correctWord("invoice", taps: nil, model: m))
        XCTAssertNil(TouchDecoder.correctWord("arpit", taps: nil, model: m))
        XCTAssertNil(TouchDecoder.correctWord("a", taps: nil, model: m))
        // "thw": the taps say the last key could have been "e".
        let taps: [[TouchDecoder.Candidate]] = [[.init(letter: "t", probability: 0.9)], [.init(letter: "h", probability: 0.9)],
                                                 [.init(letter: "w", probability: 0.55), .init(letter: "e", probability: 0.4)]]
        XCTAssertEqual(TouchDecoder.correctWord("thw", taps: taps, model: m), "the")
    }

    // MARK: harness

    /// Seeded, so the numbers are the same each run.
    private struct Rng {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Double { sqrt(-2 * log(max(next(), 1e-12))) * cos(2 * .pi * next()) }
    }

    private static func edits<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        guard !a.isEmpty else { return b.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]; row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let cur = row[j]
                row[j] = a[i - 1] == b[j - 1] ? prev : min(prev, row[j], row[j - 1]) + 1
                prev = cur
            }
        }
        return row[b.count]
    }

    enum Mode: String, CaseIterable { case plain = "fixed keys", taps = "tap decoder", words = "tap + word decoder", adapted = "tap + word + adaptation" }

    /// Types `sentences` with noisy taps and returns (character error rate, word error rate).
    private func run(_ sentences: [String], mode: Mode, noise: Double, bias: Double, biasX: Double = 0) -> (cer: Double, wer: Double) {
        var rng = Rng(state: 42)
        var adaptation = TouchAdaptation()
        var charErrors = 0, chars = 0, wordErrors = 0, words = 0
        for sentence in sentences {
            var out: [String] = []
            for word in sentence.split(separator: " ") {
                var typed = "", taps: [[TouchDecoder.Candidate]] = []
                for ch in word {
                    let k = key(ch)
                    let p = CGPoint(x: k.frame.midX + (biasX + rng.gaussian() * noise) * k.frame.width,
                                    y: k.frame.midY + (bias + rng.gaussian() * noise) * k.frame.width)
                    guard case .char(let hit)? = KeyboardGeometry.key(at: p, in: caps)?.kind else { continue }
                    if mode == .plain { typed += hit; continue }
                    let r = TouchDecoder.decode(p, keys: keys, word: typed, model: Self.model, adaptation: mode == .adapted ? adaptation : TouchAdaptation())!
                    typed.append(r.key.letter)
                    taps.append(r.candidates)
                    if mode == .adapted { adaptation.learn(p, on: r.key) }
                }
                if mode == .words || mode == .adapted, let w = TouchDecoder.correctWord(typed, taps: taps, model: Self.model) { typed = w }
                out.append(typed)
            }
            charErrors += Self.edits(Array(out.joined(separator: " ")), Array(sentence))
            chars += sentence.count
            wordErrors += Self.edits(out, sentence.split(separator: " ").map(String.init))
            words += sentence.split(separator: " ").count
        }
        return (Double(charErrors) / Double(chars), Double(wordErrors) / Double(words))
    }

    func testHarnessNoisyTapsMakeFewerErrorsWithTheDecoder() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sentences", withExtension: "txt"))
        let sentences = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init)
        XCTAssertEqual(sentences.count, 500)
        for noise in [0.25, 0.35] {
            var results: [Mode: (cer: Double, wer: Double)] = [:]
            for mode in Mode.allCases {
                results[mode] = run(sentences, mode: mode, noise: noise, bias: 0.15)
                print(String(format: "TOUCH-HARNESS noise %.0f%%, %@: CER %.2f%%  WER %.2f%%", noise * 100, mode.rawValue,
                             results[mode]!.cer * 100, results[mode]!.wer * 100))
            }
            XCTAssertLessThan(results[.taps]!.cer, results[.plain]!.cer * 0.8)
            XCTAssertLessThan(results[.words]!.wer, results[.taps]!.wer)
        }
        // Someone whose taps land further low and right than most: adaptation learns it.
        let words = run(sentences, mode: .words, noise: 0.25, bias: 0.4, biasX: 0.2)
        let adapted = run(sentences, mode: .adapted, noise: 0.25, bias: 0.4, biasX: 0.2)
        let plain = run(sentences, mode: .plain, noise: 0.25, bias: 0.4, biasX: 0.2)
        for (name, r) in [("fixed keys", plain), ("tap + word decoder", words), ("tap + word + adaptation", adapted)] {
            print(String(format: "TOUCH-HARNESS noise 25%%, low-right taps, %@: CER %.2f%%  WER %.2f%%", name, r.cer * 100, r.wer * 100))
        }
        XCTAssertLessThan(adapted.cer, words.cer)
    }
}
