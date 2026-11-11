import XCTest
@testable import Muninn

@MainActor
final class KeyboardModelTests: XCTestCase {
    private var host: FakeHost!
    private var api: FakeAPI!
    private var clock: FakeClock!
    private var model: KeyboardModel!

    override func setUp() async throws {
        host = FakeHost()
        api = FakeAPI()
        clock = FakeClock()
        model = KeyboardModel(deps: .fake(api: api, clock: clock))
        model.host = host
        model.keyboardAppeared()
    }

    override func tearDown() async throws {
        model.keyboardDisappeared()
        model = nil
    }

    /// Taps the real keys, switching layouts and shift the way a person would. One second between taps.
    private func type(_ s: String) {
        func keys() -> [KeyCap] { KeyboardGeometry.keys(layout: model.layout, width: 390, globe: false, currency: "$") }
        func tap(_ id: String) {
            guard let key = keys().first(where: { $0.id == id }) else { return XCTFail("no key \(id) in \(model.layout)") }
            clock.advance(1)
            model.activate(key)
        }
        func charKey(_ c: String) -> KeyCap? { keys().first { $0.kind == .char(c) } }

        for ch in s {
            if ch == " " { tap("space"); continue }
            let c = String(ch).lowercased()
            if charKey(c) == nil {
                if model.layout != .letters { tap("mode") }
                if charKey(c) == nil { tap("mode") }
                if charKey(c) == nil { tap("mode.alt") }
            }
            guard let key = charKey(c) else { return XCTFail("cannot type \(ch)") }
            if model.layout == .letters, ch.isUppercase != (model.shift != .off) { tap("shift") }
            clock.advance(1)
            model.activate(key)
        }
    }

    private func until(_ what: String, _ cond: () -> Bool) async {
        for _ in 0..<500 where !cond() { await Task.yield() }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    func testTypedSentenceGivesInvoiceChipAndTapInsertsLink() async {
        let chip = Chip(kind: "invoice", label: "Invoice Sam $45",
                        payload: ["client_name": .string("Sam"), "client_email": .string("sam@example.com"),
                                  "item": .string("haircut"), "amount": .string("45.00"), "currency": .string("USD")],
                        needs_confirm: true)
        api.suggestReply = SuggestResponse(chips: [chip], intent: "invoice", timings: nil)
        api.requireConfirm = "sam@example.com"

        type("That is $45 for the haircut, sam@example.com")
        XCTAssertEqual(host.text, "That is $45 for the haircut, sam@example.com")

        await until("chip") { model.bar == .chips([chip], fromCopied: false) }
        XCTAssertEqual(api.suggested.last?.text, "That is $45 for the haircut, sam@example.com")
        XCTAssertTrue(clock.sleeps.contains(AppConfig.suggestDebounce))

        model.tapChip(chip)
        if case .confirm(let c, let recipient) = model.bar {
            XCTAssertEqual(recipient, "sam@example.com")
            model.confirm(c, recipient: recipient)
        }

        await until("link inserted") { host.text.hasSuffix("https://fake.pay/INV-1") }
        XCTAssertEqual(host.text, "That is $45 for the haircut, sam@example.com\nHere's your invoice for haircut ($45): https://fake.pay/INV-1")
        XCTAssertEqual(api.invoiced.last?["confirm_recipient"], .string("sam@example.com"))
        XCTAssertEqual(model.watch, Watch(id: "INV-1", who: "Sam", money: "$45"))
        XCTAssertEqual(model.bar, .idle)
    }
}
