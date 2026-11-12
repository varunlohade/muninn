import XCTest
@testable import Muninn

/// The word row: typed word in quotes, the fix, completions; chips win.
final class PredictionsTests: XCTestCase {
    func testTheTypedWordIsOnlyAPlainWordAtTheCursor() {
        XCTAssertEqual(Predictions.typedWord("see you tom"), "tom")
        XCTAssertEqual(Predictions.typedWord("I don't"), "don't")
        XCTAssertNil(Predictions.typedWord("see you "))
        XCTAssertNil(Predictions.typedWord(""))
        XCTAssertNil(Predictions.typedWord("it is $45"))
        XCTAssertNil(Predictions.typedWord("mail sam@x"))
    }

    func testSlotsAreTypedThenFixThenCompletions() {
        let s = Predictions.slots(typed: "tomorow", correction: "tomorrow", completions: ["tomorrows"])
        XCTAssertEqual(s.map(\.title), ["\u{201C}tomorow\u{201D}", "tomorrow", "tomorrows"])
        XCTAssertEqual(s.map(\.word), ["tomorow", "tomorrow", "tomorrows"])
    }

    func testSlotsSkipRepeatsAndFollowTheCapital() {
        let s = Predictions.slots(typed: "Th", correction: nil, completions: ["the", "th", "that", "this"])
        XCTAssertEqual(s.map(\.word), ["Th", "The", "That"])
    }

    func testLearnedWordsComeFirst() {
        let s = Predictions.slots(typed: "sa", correction: nil, completions: ["said", "same"], learned: ["samm"])
        XCTAssertEqual(s.map(\.word), ["sa", "samm", "said"])
    }

    func testCompletionsAreTheCommonestWords() {
        let m = TouchDecoderTests.model
        XCTAssertEqual(Set(m.completions("th", limit: 3)), ["the", "that", "this"])
        XCTAssertEqual(m.completions("invoi", limit: 3).first, "invoice")
        XCTAssertEqual(m.completions("qzx", limit: 3), [])
    }

    private func state(_ bar: BarState = .idle) -> BarItems.State {
        var s = BarItems.State(hasFullAccess: true, paired: true, undo: nil, hasCalmOffer: false, watch: nil, bar: bar,
                               copiedAvailable: false, toBill: nil, nextUp: nil)
        s.predictions = Predictions.slots(typed: "hel", correction: nil, completions: ["hello", "help"])
        return s
    }

    func testTheBarShowsPredictionsWhenNoChipIsThere() {
        let items = BarItems.build(state())
        XCTAssertEqual(items.map(\.title), ["\u{201C}hel\u{201D}", "hello", "help"])
        XCTAssertEqual(items.map(\.action), [.predict("hel"), .predict("hello"), .predict("help")])
    }

    func testChipsWinOverPredictions() {
        var s = state()
        s.copiedAvailable = true
        XCTAssertEqual(BarItems.build(s).map(\.id), ["copied"])
        let chip = Chip(kind: "paylink", label: "Pay link", payload: ["amount": .string("45.00")], needs_confirm: false)
        XCTAssertEqual(BarItems.build(state(.chips([chip], fromCopied: false))).map(\.id), ["paylink"])
    }

    @MainActor
    func testTappingAPredictionReplacesTheWordAndAddsASpace() {
        let host = FakeHost()
        let model = KeyboardModel(deps: .fake(api: FakeAPI()))
        model.host = host
        model.keyboardAppeared()
        host.text = "see you tomor"
        model.textChanged()
        XCTAssertEqual(model.predictions.first?.word, "tomor")
        model.perform(.predict("tomorrow"))
        XCTAssertEqual(host.text, "see you tomorrow ")
        XCTAssertEqual(model.predictions, [])
        // The typed word, tapped, is kept: space no longer fixes it.
        host.text = "do teh"
        model.textChanged()
        model.perform(.predict("teh"))
        XCTAssertEqual(host.text, "do teh ")
        model.keyboardDisappeared()
    }
}
