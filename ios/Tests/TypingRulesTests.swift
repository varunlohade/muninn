import XCTest
@testable import Muninn

final class TypingRulesTests: XCTestCase {
    func testDoubleSpaceAfterAWordMakesAPeriod() {
        XCTAssertTrue(TypingRules.doubleSpaceMakesPeriod(before: "see you ", sinceLastSpace: 0.2))
        XCTAssertTrue(TypingRules.doubleSpaceMakesPeriod(before: "at 5 ", sinceLastSpace: 0.2))
        XCTAssertTrue(TypingRules.doubleSpaceMakesPeriod(before: "(soon) ", sinceLastSpace: 0.2))
    }

    func testDoubleSpaceNeedsAQuickSecondTapAfterAWord() {
        XCTAssertFalse(TypingRules.doubleSpaceMakesPeriod(before: "see you ", sinceLastSpace: 0.6))
        XCTAssertFalse(TypingRules.doubleSpaceMakesPeriod(before: "see you ", sinceLastSpace: nil))
        XCTAssertFalse(TypingRules.doubleSpaceMakesPeriod(before: "done. ", sinceLastSpace: 0.2))
        XCTAssertFalse(TypingRules.doubleSpaceMakesPeriod(before: " ", sinceLastSpace: 0.2))
        XCTAssertFalse(TypingRules.doubleSpaceMakesPeriod(before: "ok,  ", sinceLastSpace: 0.2))
    }

    func testSentencesCapitalizeAtTheStartAndAfterASentenceEnds() {
        for before in ["", "   ", "Thanks. ", "Done!  ", "Really? ", "Hi\n", "Hi\n ", "He said \u{201C}no.\u{201D} ", "(Paid.) "] {
            XCTAssertTrue(TypingRules.autoShift(before: before, type: .sentences), before)
        }
        for before in ["Thanks", "Thanks.", "see you ", "ok, ", "$45 "] {
            XCTAssertFalse(TypingRules.autoShift(before: before, type: .sentences), before)
        }
    }

    func testTheFieldsAutocapitalizationTypeWins() {
        XCTAssertFalse(TypingRules.autoShift(before: "", type: .none))
        XCTAssertFalse(TypingRules.autoShift(before: "Done. ", type: .none))
        XCTAssertTrue(TypingRules.autoShift(before: "abc", type: .allCharacters))
        XCTAssertTrue(TypingRules.autoShift(before: "sam ", type: .words))
        XCTAssertFalse(TypingRules.autoShift(before: "sam", type: .words))
    }

    @MainActor
    func testTwoQuickSpacesOnTheKeysTypeAPeriodAndTurnShiftOn() {
        let host = FakeHost()
        let clock = FakeClock()
        let model = KeyboardModel(deps: .fake(api: FakeAPI(), clock: clock))
        model.host = host
        model.keyboardAppeared()
        let keys = KeyboardGeometry.keys(layout: .letters, width: 390, globe: false, currency: "$")
        func tap(_ id: String) { model.activate(keys.first { $0.id == id }!) }
        XCTAssertEqual(model.shift, .once)
        tap("k.0.o"); tap("k.1.k")
        XCTAssertEqual(model.shift, .off)
        tap("space"); clock.advance(0.2); tap("space")
        XCTAssertEqual(host.text, "Ok. ")
        XCTAssertEqual(model.shift, .once)
        model.keyboardDisappeared()
    }
}
