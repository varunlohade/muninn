import XCTest
@testable import Muninn

/// The PayPal actions that share one shape (server/src/actions-more.ts), tapped in the keyboard.
/// FakeAPI stands in for the server; nothing leaves the test.
@MainActor
final class MoreActionTests: XCTestCase {
    private var host: FakeHost!
    private var api: FakeAPI!
    private var clock: FakeClock!
    private var store: FakeStore!
    private var model: KeyboardModel!

    override func setUp() async throws {
        host = FakeHost()
        api = FakeAPI()
        clock = FakeClock()
        store = FakeStore()
        model = KeyboardModel(deps: .fake(api: api, store: store, clock: clock))
        model.host = host
        model.keyboardAppeared()
    }

    override func tearDown() async throws {
        model.keyboardDisappeared()
        model = nil
    }

    private func until(_ what: String, _ cond: () -> Bool) async {
        for _ in 0..<500 where !cond() { await Task.yield() }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    private func settled() async {
        await until("action done") { if case .working = model.bar { false } else { true } }
    }

    private func titles() -> [String] {
        BarItems.build(.init(hasFullAccess: true, paired: true, undo: nil, hasCalmOffer: false, watch: nil, bar: model.bar,
                             copiedAvailable: false, toBill: nil, nextUp: nil)).map(\.title)
    }

    /// A chip as the server builds it: the body, the values the confirm shows, and the question.
    private func action(_ kind: String, _ label: String, body: [String: JSONValue], confirm: [String: JSONValue], question: String) -> Chip {
        Chip(kind: kind, label: label, payload: ["body": .object(body), "confirm": .object(confirm), "question": .string(question)], needs_confirm: true)
    }

    private var pause: Chip {
        action("plan_pause", "Pause $40/mo \u{00B7} Ana", body: ["subscription_id": .string("I-ANA1")],
               confirm: ["confirm_client": .string("Ana"), "confirm_amount": .string("40.00"), "confirm_currency": .string("USD")],
               question: "Pause Ana's $40 monthly bill? PayPal tells Ana.")
    }

    func testPauseAsksWithTheServersQuestionThenSendsTheConfirmValues() async {
        let pause = self.pause
        model.tapChip(pause)
        XCTAssertEqual(api.calls, [], "nothing goes out before the confirm tap")
        XCTAssertEqual(titles(), ["Pause Ana's $40 monthly bill? PayPal tells Ana.", "Cancel"])
        guard case .confirm(let next, let recipient) = model.bar else { return XCTFail("\(model.bar)") }
        XCTAssertEqual(recipient, "Ana")
        model.confirm(next, recipient: recipient)
        XCTAssertEqual(titles(), ["Pausing\u{2026}"])
        await settled()
        XCTAssertEqual(api.calls, ["more:plan/pause"])
        XCTAssertEqual(api.moreSent.first?.body, ["subscription_id": .string("I-ANA1"), "confirm_client": .string("Ana"),
                                                  "confirm_amount": .string("40.00"), "confirm_currency": .string("USD")])
        XCTAssertEqual(api.keys, [pause.key], "the chip's own key, so a second tap replays")
    }

    func testDoneWithUndoShowsBothAndUndoRunsTheReverse() async {
        let undo = Chip(kind: "plan_resume", label: "Undo", payload: ["body": .object(["subscription_id": .string("I-ANA1"), "confirm_client": .string("Ana")]),
                                                                     "confirm": .object([:]), "question": .string("")], needs_confirm: false)
        api.moreReply = MoreResponse(line: "Paused \u{2713}", undo: undo)
        model.tapChip(pause)
        guard case .confirm(let next, let recipient) = model.bar else { return XCTFail("\(model.bar)") }
        model.confirm(next, recipient: recipient)
        await settled()
        XCTAssertEqual(model.bar, .undoable("Paused \u{2713}", undo: undo))
        let items = BarItems.build(.init(hasFullAccess: true, paired: true, undo: nil, hasCalmOffer: false, watch: nil, bar: model.bar,
                                         copiedAvailable: false, toBill: nil, nextUp: nil))
        XCTAssertEqual(items.map(\.title), ["Paused \u{2713}", "Undo"])
        XCTAssertEqual(items.first?.tone, .paid)
        api.moreReply = MoreResponse(line: "Restarted \u{2713}", undo: nil)
        model.perform(items[1].action!)
        await settled()
        XCTAssertEqual(api.calls, ["more:plan/pause", "more:plan/resume"], "Undo runs at once: the owner just confirmed this plan")
        XCTAssertEqual(api.moreSent.last?.body["confirm_client"], .string("Ana"))
        XCTAssertEqual(model.bar, .done("Restarted \u{2713}"))
    }

    func testServerAskingToConfirmPutsTheQuestionInTheBar() async {
        api.moreNeedsConfirm = true
        var c = pause
        c = Chip(kind: c.kind, label: c.label, payload: c.payload, needs_confirm: false)
        model.tapChip(c)
        await settled()
        XCTAssertEqual(api.calls, ["more:plan/pause"])
        XCTAssertEqual(titles(), ["Pause Ana's $40 monthly bill? PayPal tells Ana.", "Cancel"])
    }

    func testMarkPaidRunsTheInvoiceRouteAndUndoTakesItBack() async {
        let mark = action("invoice_mark_paid", "Mark paid $45 \u{00B7} Sam", body: ["invoice_id": .string("INV2-SAM"), "method": .string("CASH")],
                          confirm: ["confirm_client": .string("Sam"), "confirm_amount": .string("45.00"), "confirm_currency": .string("USD")],
                          question: "Mark Sam's $45 invoice paid (cash)? No money moves.")
        let undo = Chip(kind: "invoice_unmark", label: "Undo", payload: ["body": .object(["invoice_id": .string("INV2-SAM")])], needs_confirm: false)
        api.moreReply = MoreResponse(line: "Marked paid \u{2713}", undo: undo)
        XCTAssertEqual(BarItems.title(mark), "Mark paid $45 \u{00B7} Sam")
        model.tapChip(mark)
        XCTAssertEqual(titles(), ["Mark Sam's $45 invoice paid (cash)? No money moves.", "Cancel"])
        guard case .confirm(let next, let recipient) = model.bar else { return XCTFail("\(model.bar)") }
        model.confirm(next, recipient: recipient)
        XCTAssertEqual(titles(), ["Marking paid\u{2026}"])
        await settled()
        XCTAssertEqual(titles(), ["Marked paid \u{2713}", "Undo"])
        XCTAssertEqual(store.pendingAction, nil, "the answer came, so nothing waits")
        api.moreReply = MoreResponse(line: "Back to unpaid \u{2713}", undo: nil)
        model.tapChip(undo)
        await settled()
        XCTAssertEqual(api.calls, ["more:invoice/mark-paid", "more:invoice/unmark-paid"])
        XCTAssertEqual(model.bar, .done("Back to unpaid \u{2713}"))
    }

    func testLineChipsShowTheirLineWithNoCall() async {
        model.tapChip(Chip(kind: "show", label: "Repeat bills \u{00B7} 2 active", payload: ["line": .string("Ana $40/mo, Ben $20/wk")], needs_confirm: false))
        await settled()
        XCTAssertEqual(api.calls, [])
        XCTAssertEqual(model.bar, .done("Ana $40/mo, Ben $20/wk"))
    }

    func testPlanStatusReadsPayPalOnTap() async {
        model.tapChip(Chip(kind: "plan_status", label: "Ana's plan \u{00B7} active", payload: ["id": .string("I-ANA1")], needs_confirm: false))
        await settled()
        XCTAssertEqual(api.calls, ["read:plans/I-ANA1"])
        XCTAssertEqual(model.bar, .done("Ana $40/mo \u{00B7} active"))
    }

    func testPayoutAsksWithRecipientAmountAndCurrencyAndKeepsItsKeyUntilTheAnswer() async {
        let send = action("payout", "Send $200 \u{00B7} Joe",
                          body: ["recipient_name": .string("Joe"), "recipient_email": .string("joe@x.com"), "amount": .string("200.00"), "currency": .string("USD")],
                          confirm: ["confirm_recipient": .string("joe@x.com"), "confirm_amount": .string("200.00"), "confirm_currency": .string("USD")],
                          question: "Send Joe (joe@x.com) $200 from your PayPal?")
        XCTAssertTrue(ChipActions.sendsMoney.contains("payout"))
        model.tapChip(send)
        XCTAssertEqual(api.calls, [])
        XCTAssertEqual(titles(), ["Send Joe (joe@x.com) $200 from your PayPal?", "Cancel"])
        guard case .confirm(let next, let recipient) = model.bar else { return XCTFail("\(model.bar)") }
        XCTAssertEqual(recipient, "joe@x.com")
        model.confirm(next, recipient: recipient)
        XCTAssertEqual(store.pendingAction?.key, send.key, "kept while the call runs, so a closed keyboard can look it up")
        XCTAssertEqual(titles(), ["Sending\u{2026}"])
        await settled()
        XCTAssertEqual(api.moreSent.first?.path, "payout")
        XCTAssertEqual(api.moreSent.first?.body["confirm_recipient"], .string("joe@x.com"))
        XCTAssertEqual(api.moreSent.first?.body["confirm_amount"], .string("200.00"))
        XCTAssertEqual(api.moreSent.first?.body["confirm_currency"], .string("USD"))
        XCTAssertNil(store.pendingAction)
    }

    /// "send $20 to Ritika" with no email on file, as the server builds it.
    private var ritika: Chip {
        Chip(kind: "payout", label: "Send $20 \u{00B7} Ritika", payload: [
            "body": .object(["recipient_name": .string("Ritika"), "amount": .string("20.00"), "currency": .string("USD")]),
            "confirm": .object(["confirm_amount": .string("20.00"), "confirm_currency": .string("USD")]),
            "question": .string("Send Ritika ({to}) $20 from your PayPal?"),
            "needs_recipient": .bool(true), "ask": .string("Type Ritika's email or phone"),
        ], needs_confirm: true)
    }

    /// Taps real keys, switching to the number layout for @ and digits.
    private func typeKeys(_ s: String) {
        func keys() -> [KeyCap] { KeyboardGeometry.keys(layout: model.layout, width: 390, globe: false, currency: "$") }
        for ch in s {
            let c = String(ch)
            if !keys().contains(where: { $0.kind == .char(c) }), let mode = keys().first(where: { $0.id == "mode" }) { model.activate(mode) }
            guard let key = keys().first(where: { $0.kind == .char(c) }) else { return XCTFail("cannot type \(c)") }
            model.activate(key)
        }
    }

    func testSendMoneyWithNoEmailAsksForItInTheBarThenConfirmsAndSends() async {
        host.text = "send $20 to Ritika"
        model.tapChip(ritika)
        XCTAssertEqual(titles(), ["Type Ritika's email or phone", "Cancel"], "no Use until it reads as an email or phone")
        typeKeys("ritika@x.co")
        XCTAssertEqual(host.text, "send $20 to Ritika", "the email never goes into the chat")
        XCTAssertEqual(titles(), ["ritika@x.co", "Use", "Cancel"])
        model.perform(.useRecipient)
        XCTAssertEqual(api.calls, [], "nothing goes out before the confirm tap")
        XCTAssertEqual(titles(), ["Send Ritika (ritika@x.co) $20 from your PayPal?", "Cancel"])
        guard case .confirm(let next, let recipient) = model.bar else { return XCTFail("\(model.bar)") }
        api.moreReply = MoreResponse(line: "Sent $20 to Ritika \u{2713}", undo: nil)
        model.confirm(next, recipient: recipient)
        await settled()
        XCTAssertEqual(api.moreSent.first?.path, "payout")
        XCTAssertEqual(api.moreSent.first?.body["recipient_email"], .string("ritika@x.co"))
        XCTAssertEqual(api.moreSent.first?.body["confirm_recipient"], .string("ritika@x.co"))
        XCTAssertEqual(api.moreSent.first?.body["confirm_amount"], .string("20.00"))
        XCTAssertEqual(titles(), ["Sent $20 to Ritika \u{2713}"])
    }

    func testSendMoneyTakesATypedPhoneAndCancelSendsNothing() {
        model.tapChip(ritika)
        model.perform(.cancelConfirm)
        XCTAssertEqual(model.bar, .idle)
        XCTAssertEqual(PayoutRecipient.parse("+1 (408) 555-0134"), "+14085550134")
        XCTAssertEqual(PayoutRecipient.parse("Ritika@X.com "), "ritika@x.com")
        for bad in ["ritika", "ritika@", "12", "@x.com"] { XCTAssertNil(PayoutRecipient.parse(bad), bad) }
        let filled = PayoutRecipient.filled(ritika, with: "+14085550134")
        XCTAssertFalse(PayoutRecipient.needed(filled))
        XCTAssertEqual(BarItems.confirmTitle(filled, recipient: "+14085550134"), "Send Ritika (+14085550134) $20 from your PayPal?")
        guard case .object(let body)? = filled.payload["body"] else { return XCTFail("no body") }
        XCTAssertEqual(body["recipient_phone"], .string("+14085550134"))
        XCTAssertNil(body["recipient_email"])
        XCTAssertEqual(api.calls, [])
    }

    func testBalanceReadsOnTapAndStaysInTheBar() async {
        host.text = "how much do I have"
        api.readReply = MoreResponse(line: "PayPal balance $1,240.50", undo: nil)
        model.tapChip(Chip(kind: "balance", label: "Balance", payload: [:], needs_confirm: false))
        XCTAssertEqual(titles(), ["Checking balance\u{2026}"])
        await settled()
        XCTAssertEqual(api.calls, ["read:balance"])
        XCTAssertEqual(model.bar, .done("PayPal balance $1,240.50"))
        XCTAssertEqual(host.text, "how much do I have", "a balance never goes into the chat")
        XCTAssertNil(store.pendingAction, "a read keeps no pending call")
    }

    func testPlanWordsReachTheServer() {
        for text in ["pause ana's plan", "what plans do I have", "restart ana"] {
            XCTAssertTrue(SuggestPolicy.hasMoneySignal(text), text)
        }
    }

    func testOfferAndClaimAloneStayOnThePhone() {
        for text in ["I can offer 2 slots", "that's my claim to fame"] {
            XCTAssertFalse(SuggestPolicy.hasMoneySignal(text), text)
        }
        for text in ["offer sam $20 back", "accept sam's claim in the dispute", "accept sam's claim", "accept the claim from sam"] {
            XCTAssertTrue(SuggestPolicy.hasMoneySignal(text), text)
        }
    }

    func testAskRouteActionDecodesChips() throws {
        let json = #"{"route":"action","confidence":1,"result":{"chips":[{"kind":"plan_pause","label":"Pause $40/mo · Ana","payload":{"body":{"subscription_id":"I-ANA1"}},"needs_confirm":true}]}}"#
        let r = try JSONDecoder().decode(AskResponse.self, from: Data(json.utf8))
        guard case .chips(let chips) = r.result else { return XCTFail("\(r.result)") }
        XCTAssertEqual(chips.map(\.kind), ["plan_pause"])
    }
}
