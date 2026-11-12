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

    private func type(_ s: String) {
        for ch in s {
            if ch == " " { model.activate(key("space")); continue }
            model.activate(keys.first { $0.kind == .char(String(ch).lowercased()) }!)
        }
    }

    func testSpaceFixesATypoAndBackspacePutsItBack() {
        type("i can do teh ")
        XCTAssertEqual(host.text, "I can do the ")
        model.activate(key("delete"))
        XCTAssertEqual(host.text, "I can do teh")
        model.activate(key("space"))
        XCTAssertEqual(host.text, "I can do teh ")
    }

    func testAFieldWithAutocorrectOffKeepsTheTypo() {
        host.autocorrection = .no
        type("i do teh ")
        XCTAssertEqual(host.text, "I do teh ")
    }

    /// One finger tap through the view's path: decode, press, lift.
    private func tap(_ p: CGPoint) {
        let finger = NSObject()
        let id = ObjectIdentifier(finger)
        guard let k = model.key(for: id, at: p, in: keys) else { return XCTFail("no key at \(p)") }
        model.touchBegan(id, k, at: p)
        model.touchEnded(id)
    }

    private func center(_ id: String) -> CGPoint { CGPoint(x: key(id).frame.midX, y: key(id).frame.midY) }

    func testAnEdgeTapTypesTheLikelyLetterAndACoreTapTypesItsKey() async {
        await until("language model") { KeyboardModel.language != nil }
        let y = key("k.0.y").frame, u = key("k.0.u").frame
        let edge = CGPoint(x: (y.maxX + u.minX) / 2 - 3, y: y.midY)
        host.autocapitalization = .none
        tap(center("k.0.q"))
        tap(edge)
        XCTAssertEqual(host.text, "Qu")
        tap(center("k.0.y"))
        XCTAssertEqual(host.text, "Quy")
    }

    func testAdaptationSavesOnlyTapsThatWereKept() async {
        let store = FakeStore()
        let m = KeyboardModel(deps: .fake(api: FakeAPI(), store: store, clock: clock))
        m.host = host
        m.keyboardAppeared()
        model = m
        await until("language model") { KeyboardModel.language != nil }
        host.autocapitalization = .none
        let s = key("k.1.s").frame
        let low = CGPoint(x: s.midX, y: s.maxY - 2)
        // A tap deleted right after teaches nothing.
        tap(low); model.activate(key("delete"))
        model.keyboardDisappeared()
        XCTAssertEqual(store.touchOffsets, [])
        model.keyboardAppeared()
        for _ in 0..<5 { tap(low) }
        model.keyboardDisappeared()
        XCTAssertEqual(store.touchOffsets.count, 6)
        XCTAssertGreaterThan(store.touchOffsets[4], 0, "row 1 learned a low tap")
        XCTAssertEqual(store.touchOffsets[3], 0)
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
