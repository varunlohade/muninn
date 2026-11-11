import XCTest
@testable import Muninn

/// The app's Ask bar: one request to the router, then the keyboard's chips. FakeAPI stands in for the server.
@MainActor
final class AskModelTests: XCTestCase {
    private var api: FakeAPI!
    private var store: FakeStore!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var model: AskModel!

    override func setUp() async throws {
        api = FakeAPI()
        store = FakeStore()
        model = AskModel(api: { [api] in api! }, store: store, now: { [unowned self] in self.now })
    }

    private var invoice: Chip {
        Chip(kind: "invoice", label: "Invoice $45 · Haircut → sam@example.com",
             payload: ["amount": .string("45.00"), "currency": .string("USD"), "item": .string("Haircut"),
                       "client_name": .string("Sam"), "client_email": .string("sam@example.com"), "confirm_recipient": .string("sam@example.com")],
             needs_confirm: false)
    }

    private func ask(_ text: String, _ route: String, _ result: AskResponse.Result) async {
        api.askReply = AskResponse(route: route, confidence: 0.9, result: result)
        model.text = text
        model.submit()
        await model.task?.value
    }

    private func tap(_ chip: Chip, confirmed: String? = nil) async {
        model.run(chip, confirmed: confirmed)
        await model.task?.value
    }

    func testAReTapOnTheSameChipSendsTheSameKey() async {
        await ask("invoice Sam $45 for a haircut sam@example.com", "invoice", .chips([invoice]))
        XCTAssertEqual(model.state, .chips([invoice]))
        api.failures = [URLError(.timedOut)]
        await tap(invoice, confirmed: "sam@example.com")
        XCTAssertEqual(model.state, .error("Took too long. Try again."))
        await tap(invoice, confirmed: "sam@example.com")
        XCTAssertEqual(api.calls, ["ask", "invoice", "invoice"])
        XCTAssertEqual(api.keys.count, 2)
        XCTAssertEqual(api.keys[0], api.keys[1], "the second tap replays the first call")
        guard case .result(let r) = model.state else { return XCTFail("\(model.state)") }
        XCTAssertEqual(r.link, "https://fake.pay/INV-1")
    }

    func testTheSameRequestAskedAgainKeepsItsKeyAndAnotherChipGetsItsOwn() async {
        await ask("invoice Sam $45", "invoice", .chips([invoice]))
        await tap(invoice, confirmed: "sam@example.com")
        await ask("invoice Sam $45", "invoice", .chips([invoice]))
        await tap(invoice, confirmed: "sam@example.com")
        let other = Chip(kind: "paylink", label: "Pay link $45 · Haircut", payload: ["amount": .string("45.00"), "item": .string("Haircut")], needs_confirm: false)
        await tap(other)
        XCTAssertEqual(api.keys[0], api.keys[1])
        XCTAssertNotEqual(api.keys[1], api.keys[2])
        now += ChipKeys.ttl + 1
        await tap(invoice, confirmed: "sam@example.com")
        XCTAssertNotEqual(api.keys[3], api.keys[0], "after the key expires the chip is a new request")
    }

    func testAnUnconfirmedInvoiceAsksBeforeAnyCall() async {
        let chip = Chip(kind: "invoice", label: "Invoice $45", payload: ["client_email": .string("eve@evil.test")], needs_confirm: true)
        model.run(chip)
        XCTAssertEqual(model.state, .confirm(chip, "eve@evil.test"))
        XCTAssertEqual(api.calls, [])
    }

    func testANoteIsSavedOnThePhone() async {
        await ask("add a note: buy shampoo", "add_note", .addNote("buy shampoo"))
        XCTAssertEqual(store.notes.map(\.text), ["buy shampoo"])
        XCTAssertEqual(model.state, .line("Note saved \u{2713}"))
        XCTAssertEqual(model.text, "")
        XCTAssertEqual(api.calls, ["ask"])
    }

    func testTheCalendarLineComesFromThePhone() async {
        await ask("what's on today", "today_calendar", .showCalendar)
        XCTAssertEqual(model.state, .line("Nothing on your calendar today"))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        store.appointments = [Appointment(start: start, end: start + 1800, title: "Cut", clientName: "Sam Okafor")]
        await ask("what's on today", "today_calendar", .showCalendar)
        XCTAssertEqual(model.state, .line("\(store.appointments[0].time) Sam"))
    }

    func testInfoWritingAndNoneShowOneLine() async {
        await ask("who hasn't paid", "who_paid", .payments([]))
        XCTAssertEqual(model.state, .line("Nobody owes you \u{2713}"))
        await ask("make this nicer: ya ok will send", "refine", .text("Sure, I will send it."))
        XCTAssertEqual(model.state, .line("Sure, I will send it."))
        await ask("how is today", "brief", .brief(["Brought back $90 today.", "Ana's $90 is 2 days late."]))
        XCTAssertEqual(model.state, .line("Brought back $90 today.\nAna's $90 is 2 days late."))
        await ask("blah", "none", .line("Not sure what you need."))
        XCTAssertEqual(model.state, .line("Not sure what you need."))
        await ask("refund Maya", "refund", .chips([]))
        XCTAssertEqual(model.state, .error("No action for that yet. Try \"invoice Sam $45 for a haircut\"."))
        XCTAssertEqual(api.asked.count, 5)
    }

    func testTheServerAnswerDecodesByRoute() throws {
        func decode(_ json: String) throws -> AskResponse { try JSONDecoder().decode(AskResponse.self, from: Data(json.utf8)) }
        let money = try decode(#"{"route":"invoice","confidence":0.9,"result":{"chips":[{"kind":"invoice","label":"Invoice $45","payload":{"amount":"45.00"},"needs_confirm":true}]}}"#)
        guard case .chips(let chips) = money.result else { return XCTFail() }
        XCTAssertEqual(chips.map(\.kind), ["invoice"])
        XCTAssertTrue(chips[0].needs_confirm)
        guard case .addNote("buy shampoo") = try decode(#"{"route":"add_note","confidence":1,"result":{"action":"add_note","text":"buy shampoo"}}"#).result else { return XCTFail() }
        guard case .showCalendar = try decode(#"{"route":"today_calendar","confidence":1,"result":{"action":"show_calendar"}}"#).result else { return XCTFail() }
        guard case .text("Hi") = try decode(#"{"route":"reply","confidence":1,"result":{"reply":"Hi"}}"#).result else { return XCTFail() }
        guard case .line("Try again") = try decode(#"{"route":"none","confidence":0.2,"result":{"line":"Try again"}}"#).result else { return XCTFail() }
        guard case .brief(let lines) = try decode(#"{"route":"brief","confidence":1,"result":{"lines":["a","b"],"source":"ai"}}"#).result else { return XCTFail() }
        XCTAssertEqual(lines, ["a", "b"])
    }
}
