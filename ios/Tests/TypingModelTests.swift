import XCTest
@testable import Muninn

/// The keys as a person types on them: trackpad, autocorrect, predictions.
@MainActor
final class TypingModelTests: XCTestCase {
    private var host: FakeHost!
    private var clock: FakeClock!
    private var model: KeyboardModel!
    private let keys = KeyboardGeometry.keys(layout: .letters, width: 390, globe: false, currency: "$")

    override func setUp() async throws {
        host = FakeHost()
        clock = FakeClock()
        model = KeyboardModel(deps: .fake(api: FakeAPI(), clock: clock))
        model.host = host
        model.keyboardAppeared()
    }

    override func tearDown() async throws {
        model.keyboardDisappeared()
        model = nil
    }

    private func key(_ id: String) -> KeyCap { keys.first { $0.id == id }! }

    private func until(_ what: String, _ cond: () -> Bool) async {
        for _ in 0..<500 where !cond() { await Task.yield() }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    func testHoldingSpaceMovesTheCursorAndTypesNoSpace() async {
        host.text = "see you soon"
        let finger = NSObject()
        let id = ObjectIdentifier(finger)
        model.touchBegan(id, key("space"), at: CGPoint(x: 200, y: 200))
        await until("hold timer") { clock.sleeping > 0 }
        clock.advance(KeyboardModel.spaceHoldDelay.seconds)
        await until("trackpad") { model.trackpad }
        model.touchMoved(id, key("space"), at: CGPoint(x: 200 - 2 * KeyboardModel.cursorStep - 1, y: 200))
        model.touchMoved(id, key("k.0.q"), at: CGPoint(x: 200 - KeyboardModel.cursorStep + 1, y: 120))
        model.touchEnded(id)
        XCTAssertEqual(host.cursorMoves, [-2, 1])
        XCTAssertEqual(host.text, "see you soon")
        XCTAssertFalse(model.trackpad)
    }

    func testAQuickSpaceTapStillTypesASpace() async {
        host.text = "see"
        let finger = NSObject()
        model.touchBegan(ObjectIdentifier(finger), key("space"), at: CGPoint(x: 200, y: 200))
        model.touchEnded(ObjectIdentifier(finger))
        XCTAssertEqual(host.text, "see ")
        XCTAssertFalse(model.trackpad)
        XCTAssertEqual(host.cursorMoves, [])
    }
}
