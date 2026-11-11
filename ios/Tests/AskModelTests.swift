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
        model = AskModel(api: { [api] in api! }, store: store, now: { [unowned self] in self.now }, sleep: { _ in })
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

    func testATimeoutIsOnlyLookedUpThenARetryTapSendsTheSameKey() async {
        let invoice = invoice
        await ask("invoice Sam $45 for a haircut sam@example.com", "invoice", .chips([invoice]))
        XCTAssertEqual(model.state, .chips([invoice]))
        api.failures = [URLError(.timedOut)]
        await tap(invoice, confirmed: "sam@example.com")
        XCTAssertEqual(model.state, .retry(invoice, "sam@example.com"))
        XCTAssertEqual(api.calls, ["ask", "invoice"] + Array(repeating: "lookup:invoice", count: ChipActions.checkTries))
        now += PendingAction.ttl + 1
        await tap(invoice, confirmed: "sam@example.com")
        XCTAssertEqual(api.calls.filter { $0 == "invoice" }.count, 2)
        XCTAssertEqual(Set(api.keys).count, 1, "every call and lookup of this chip uses its one key")
        guard case .result(let r) = model.state else { return XCTFail("\(model.state)") }
        XCTAssertEqual(r.link, "https://fake.pay/INV-1")
    }

    func testALostReplyIsFoundByTheLookupAndNeverSentTwice() async {
        let invoice = invoice
        await ask("invoice Sam $45 for a haircut sam@example.com", "invoice", .chips([invoice]))
        api.lostReplies = 1
        await tap(invoice, confirmed: "sam@example.com")
        XCTAssertEqual(api.calls, ["ask", "invoice", "lookup:invoice"])
        guard case .result(let r) = model.state else { return XCTFail("\(model.state)") }
        XCTAssertEqual(r.link, "https://fake.pay/INV-1")
    }

    func testEachAskReplyGivesItsChipsNewKeys() async {
        let first = invoice, second = invoice // two replies: two decoded chips with the same fields
        await ask("invoice Sam $45", "invoice", .chips([first]))
        await tap(first, confirmed: "sam@example.com")
        await ask("invoice Sam $45", "invoice", .chips([second]))
        await tap(second, confirmed: "sam@example.com")
        XCTAssertEqual(api.keys.count, 2)
        XCTAssertNotEqual(api.keys[0], api.keys[1], "a new reply is a new request")
    }

    func testARemindThatNeedsAConfirmAsksBeforeAnyCall() async {
        let chip = Chip(kind: "remind", label: "Remind Ana · $90", payload: ["invoice_id": .string("INV-A")], needs_confirm: true)
        model.run(chip)
        XCTAssertEqual(model.state, .confirm(chip, ""))
        XCTAssertEqual(api.calls, [])
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
        XCTAssertEqual(model.state, .unpaid([]))
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

    private func payment(_ name: String?, _ amount: String, days: Int, id: String, kind: String = "invoice", currency: String = "USD", state: String = "unpaid") -> Payment {
        Payment(kind: kind, id: id, state: state, amount: amount, currency: currency, item: "Cut", client_name: name, link: "https://fake.pay/\(id)",
                created_at: "2026-11-01T00:00:00Z", days_overdue: days)
    }

    func testWhoHasNotPaidShowsCardsAndRemindGoesThroughTheConfirm() async {
        await ask("who hasn't paid", "who_paid", .payments([payment("Jordan", "120.00", days: 2, id: "INV-J"), payment("Maya", "45.00", days: 0, id: "INV-M")]))
        guard case .unpaid(let clients) = model.state else { return XCTFail("\(model.state)") }
        XCTAssertEqual(WhoPaid.header(clients), "$165 unpaid \u{00B7} 2 clients")
        guard let remind = clients.first?.remind else { return XCTFail("no reminder") }
        await tap(remind)
        XCTAssertEqual(model.state, .confirm(remind, "Jordan"))
        XCTAssertEqual(BarItems.confirmTitle(remind, recipient: "Jordan"), "Remind Jordan about $120?")
        XCTAssertEqual(api.calls, ["ask"])
        await tap(remind, confirmed: "Jordan")
        XCTAssertEqual(model.state, .line("Reminder sent \u{2713}"))
        XCTAssertEqual(api.calls, ["ask", "remind:INV-J"])
        XCTAssertEqual(api.reminded, ["Jordan"])
        XCTAssertEqual(api.keys, [remind.key])
    }

    func testRepeatBillConfirmShowsAmountIntervalAndRecipient() async {
        let sub = Chip(kind: "subscribe", label: "Repeat $40 monthly · Sam",
                       payload: ["amount": .string("40.00"), "currency": .string("USD"), "interval": .string("month"), "item": .string("Repeat payment"),
                                 "client_name": .string("Sam"), "client_email": .null], needs_confirm: true)
        await ask("bill Sam $40 monthly", "subscribe", .chips([sub]))
        await tap(sub)
        XCTAssertEqual(model.state, .confirm(sub, "Sam"))
        XCTAssertEqual(BarItems.confirmTitle(sub, recipient: "Sam"), "Repeat $40 monthly to Sam?")
        XCTAssertEqual(api.calls, ["ask"])
        await tap(sub, confirmed: "Sam")
        guard case .result(let r) = model.state else { return XCTFail("\(model.state)") }
        XCTAssertEqual(r.link, "https://fake.pay/I-SUB1")
        XCTAssertEqual(AskModel.resultTitle(r), "Repeat billing ready \u{00B7} $40 monthly")
        let sent = api.subscribed[0]
        XCTAssertEqual(sent["confirm_amount"], .string("40.00"))
        XCTAssertEqual(sent["confirm_currency"], .string("USD"))
        XCTAssertEqual(sent["confirm_interval"], .string("month"))
        XCTAssertNil(sent["confirm_recipient"], "no email, so PayPal emails nobody")
        XCTAssertEqual(api.keys, [sub.key])
    }

    func testAnEmailPickedFromContactsGoesThroughTheConfirm() async {
        let noEmail = Chip(kind: "invoice", label: "Invoice $45 · Haircut",
                           payload: ["amount": .string("45.00"), "currency": .string("USD"), "item": .string("Haircut"), "client_name": .null, "client_email": .null],
                           needs_confirm: true)
        await ask("invoice $45 for a haircut", "invoice", .chips([noEmail]))
        await tap(noEmail)
        XCTAssertEqual(model.state, .confirm(noEmail, ""))
        XCTAssertTrue(AskModel.canAddContact(noEmail))
        model.useContact(email: " Kate.Bell@Example.com ", name: "Kate Bell", for: noEmail)
        guard case .confirm(let picked, let recipient) = model.state else { return XCTFail("\(model.state)") }
        XCTAssertEqual(recipient, "kate.bell@example.com")
        XCTAssertEqual(BarItems.confirmTitle(picked, recipient: recipient), "Send $45 invoice to kate.bell@example.com?")
        XCTAssertFalse(AskModel.canAddContact(picked))
        XCTAssertNotEqual(picked.key, noEmail.key, "another recipient is another action")
        XCTAssertEqual(api.calls, ["ask"], "picking a contact sends nothing")
        api.requireConfirm = "kate.bell@example.com"
        await tap(picked, confirmed: recipient)
        guard case .result = model.state else { return XCTFail("\(model.state)") }
        XCTAssertEqual(api.invoiced.count, 1)
        XCTAssertEqual(api.invoiced[0]["client_email"], .string("kate.bell@example.com"))
        XCTAssertEqual(api.invoiced[0]["client_name"], .string("Kate Bell"))
        XCTAssertEqual(api.invoiced[0]["confirm_recipient"], .string("kate.bell@example.com"))
        XCTAssertEqual(api.invoiced[0]["confirm_amount"], .string("45.00"))
        XCTAssertEqual(api.keys, [picked.key])
    }

    func testAContactIsOnlyUsedForAnInvoice() {
        let link = Chip(kind: "paylink", label: "Pay link $45", payload: ["amount": .string("45.00")], needs_confirm: false)
        model.useContact(email: "kate.bell@example.com", name: nil, for: link)
        XCTAssertEqual(model.state, .idle)
    }

    func testTheServerAnswerDecodesByRoute() throws {
        func decode(_ json: String) throws -> AskResponse { try JSONDecoder().decode(AskResponse.self, from: Data(json.utf8)) }
        let money = try decode(#"{"route":"invoice","confidence":0.9,"result":{"chips":[{"kind":"invoice","label":"Invoice $45","payload":{"amount":"45.00"},"needs_confirm":true}]}}"#)
        guard case .chips(let chips) = money.result else { return XCTFail() }
        XCTAssertEqual(chips.map(\.kind), ["invoice"])
        XCTAssertTrue(chips[0].needs_confirm)
        guard case .addNote("buy shampoo") = try decode(#"{"route":"add_note","confidence":1,"result":{"action":"add_note","text":"buy shampoo"}}"#).result else { return XCTFail() }
        guard case .showCalendar = try decode(#"{"route":"today_calendar","confidence":1,"result":{"action":"show_calendar"}}"#).result else { return XCTFail() }
        guard case .chips(let repeats) = try decode(#"{"route":"subscribe","confidence":0.9,"result":{"chips":[{"kind":"subscribe","label":"Repeat $40 monthly","payload":{"amount":"40.00","interval":"month"},"needs_confirm":true}]}}"#).result else { return XCTFail() }
        XCTAssertEqual(repeats.map(\.kind), ["subscribe"])
        guard case .review("Thanks! g.page/r/x/review") = try decode(#"{"route":"review_ask","confidence":0.9,"result":{"text":"Thanks! g.page/r/x/review"}}"#).result else { return XCTFail() }
        guard case .text("Hi") = try decode(#"{"route":"reply","confidence":1,"result":{"reply":"Hi"}}"#).result else { return XCTFail() }
        guard case .line("Try again") = try decode(#"{"route":"none","confidence":0.2,"result":{"line":"Try again"}}"#).result else { return XCTFail() }
        guard case .brief(let lines) = try decode(#"{"route":"brief","confidence":1,"result":{"lines":["a","b"],"source":"ai"}}"#).result else { return XCTFail() }
        XCTAssertEqual(lines, ["a", "b"])
    }
}
