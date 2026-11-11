import XCTest
@testable import Muninn

/// Each server chip kind, tapped in the keyboard. FakeAPI stands in for the server; nothing leaves the test.
@MainActor
final class ChipActionTests: XCTestCase {
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

    private func chip(_ kind: String, _ label: String, _ payload: [String: JSONValue] = [:], confirm: Bool = false) -> Chip {
        Chip(kind: kind, label: label, payload: payload, needs_confirm: confirm)
    }

    /// Taps a chip and, when it asks first, taps the confirm too.
    private func send(_ c: Chip) {
        model.tapChip(c)
        if case .confirm(let next, let recipient) = model.bar { model.confirm(next, recipient: recipient) }
    }

    private var invoice: Chip {
        chip("invoice", "Invoice $45 · Haircut → sam@example.com",
             ["amount": .string("45.00"), "currency": .string("USD"), "item": .string("Haircut"),
              "client_name": .string("Sam"), "client_email": .string("sam@example.com"), "confirm_recipient": .string("sam@example.com")])
    }

    func testInvoiceInsertsTheMessageAndWatches() async {
        host.text = "Thanks Sam"
        send(invoice)
        await settled()
        XCTAssertEqual(host.text, "Thanks Sam\nHere's your invoice for Haircut ($45): https://fake.pay/INV-1")
        XCTAssertEqual(model.watch, Watch(id: "INV-1", who: "Sam", money: "$45"))
        XCTAssertEqual(model.bar, .idle)
    }

    func testPayLinkInsertsTheBareLink() async {
        host.text = "Here you go"
        model.tapChip(chip("paylink", "Pay link $45 · Haircut", ["amount": .string("45.00"), "currency": .string("USD"), "item": .string("Haircut")]))
        await settled()
        XCTAssertEqual(host.text, "Here you go https://fake.pay/PL-1")
        XCTAssertEqual(model.watch?.id, "PL-1")
    }

    func testRemindSendsTheInvoiceIdAndShowsALine() async {
        host.text = "remind Sam"
        model.tapChip(chip("remind", "Remind Sam · $45", ["invoice_id": .string("INV-9")]))
        await settled()
        XCTAssertEqual(api.calls, ["remind:INV-9"])
        XCTAssertEqual(model.bar, .done("Reminder sent \u{2713}"))
        XCTAssertEqual(host.text, "remind Sam")
    }

    func testRefundAsksFirstThenRunsWithTheToken() async {
        host.text = "refund Sam"
        model.tapChip(chip("refund", "Refund $45 · Sam", ["id": .string("INV-2"), "amount": .string("45.00")]))
        await settled()
        XCTAssertEqual(api.refunded, [["id": .string("INV-2"), "amount": .string("45.00")]])
        guard case .ask(let next, let question) = model.bar else { return XCTFail("expected the ask slot, got \(model.bar)") }
        XCTAssertEqual(question, "Refund $45 to Sam?")
        XCTAssertEqual(BarItems.build(.init(hasFullAccess: true, paired: true, undo: nil, hasCalmOffer: false, watch: nil, bar: model.bar,
                                            copiedAvailable: false, toBill: nil, nextUp: nil)).map(\.title),
                       ["Refund $45 to Sam?", "Cancel"])

        model.tapChip(next)
        await settled()
        XCTAssertEqual(api.refunded.last, ["confirm_token": .string("rf_token_123")])
        XCTAssertEqual(model.bar, .done("Refunded $45 \u{2713}"))
        XCTAssertEqual(host.text, "refund Sam")
    }

    func testRefundCancelSendsNothingMore() async {
        model.tapChip(chip("refund", "Refund $45 · Sam", ["id": .string("INV-2")]))
        await settled()
        model.cancelConfirm()
        XCTAssertEqual(model.bar, .idle)
        XCTAssertEqual(api.calls, ["refund"])
    }

    func testPaymentsShowsTheLateLine() async {
        api.paymentsReply = [Payment(kind: "invoice", id: "INV-1", state: "unpaid", amount: "90.00", currency: "USD", item: "color",
                                     client_name: "Ana", link: nil, created_at: "2026-11-01T00:00:00Z", days_overdue: 2)]
        model.tapChip(chip("payments", "Who paid? · 1 unpaid"))
        await settled()
        XCTAssertEqual(model.bar, .done("Ana $90 \u{00B7} 2d late"))
    }

    func testReplyAnswersTheTypedMessageAndInsertsIt() async {
        let reply = chip("reply", "Reply with prices")
        api.suggestReply = SuggestResponse(chips: [reply], intent: "catalog_reply", timings: nil)
        host.text = "how much is a haircut"
        model.textChanged()
        await until("debounce sleep") { clock.sleeping > 0 }
        clock.advance(SuggestPolicy.debounce.seconds)
        await until("chip") { model.bar == .chips([reply], fromCopied: false) }

        model.tapChip(reply)
        await settled()
        XCTAssertEqual(api.replied, ["how much is a haircut"])
        XCTAssertEqual(host.text, "how much is a haircut A haircut is $45. Want a slot tomorrow?")
    }

    func testNeedsConfirmShowsTheConfirmSlot() async {
        api.requireConfirm = "new@example.com"
        let c = chip("invoice", "Invoice $45", ["amount": .string("45.00"), "item": .string("Haircut"), "client_email": .string("new@example.com")])
        model.tapChip(c)
        await settled()
        XCTAssertEqual(model.bar, .confirm(c, recipient: "new@example.com"))
        model.confirm(c, recipient: "new@example.com")
        await settled()
        XCTAssertEqual(api.invoiced.last?["confirm_recipient"], .string("new@example.com"))
        XCTAssertTrue(host.text.hasSuffix("https://fake.pay/INV-1"))
    }

    func testHTTP500ShowsNoStatusCodeInTheBar() async {
        api.failures = [APIError.http(500, #"{"error":"internal error"}"#)]
        send(invoice)
        await settled()
        guard case .error(let line) = model.bar else { return XCTFail("expected an error line, got \(model.bar)") }
        XCTAssertEqual(line, "Something went wrong. Try again.")
        XCTAssertFalse(line.contains("500"))
        XCTAssertFalse(line.contains("HTTP"))
        XCTAssertEqual(api.calls, ["invoice"], "a server error is not retried")
    }

    func testServerRefusalUsesItsOwnWords() {
        XCTAssertEqual(plainLine(APIError.http(409, #"{"error":"invoice is already paid"}"#)), "Invoice is already paid")
        XCTAssertEqual(plainLine(APIError.http(409, #"{"error":"request with this Idempotency-Key is in progress"}"#)),
                       "Still sending. Check again in a minute.")
        XCTAssertEqual(plainLine(APIError.http(0, "")), "Something went wrong. Try again.")
        XCTAssertEqual(plainLine(URLError(.notConnectedToInternet)), "No connection. Try again.")
        XCTAssertEqual(plainLine(URLError(.timedOut)), "Took too long. Try again.")
    }

    func testRetryReusesTheIdempotencyKey() async {
        api.failures = [URLError(.networkConnectionLost)]
        host.text = "Thanks Sam"
        send(invoice)
        await until("retry wait") { clock.sleeping > 0 }
        XCTAssertEqual(clock.sleeps.last, ChipActions.retryDelay)
        clock.advance(ChipActions.retryDelay.seconds)
        await settled()
        XCTAssertEqual(api.calls, ["invoice", "invoice"])
        XCTAssertEqual(api.keys.count, 2)
        XCTAssertEqual(api.keys[0], api.keys[1])
        XCTAssertTrue(host.text.hasSuffix("https://fake.pay/INV-1"))
    }

    func testOnlyOneQuietRetry() async throws {
        api.failures = [URLError(.notConnectedToInternet), URLError(.notConnectedToInternet)]
        do {
            _ = try await ChipActions.run(invoice, confirmed: nil, api: api, sleep: { _ in })
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(plainLine(error), "No connection. Try again.")
        }
        XCTAssertEqual(api.calls, ["invoice", "invoice"])
    }

    // MARK: one key per chip, so a second tap never sends a second invoice

    private let inProgress = APIError.http(409, #"{"error":"request with this Idempotency-Key is in progress"}"#)

    func testTwoTapsOfTheSameChipShareOneKey() async {
        send(invoice)
        await settled()
        host.text = "" // the same chip over the same field text
        send(invoice)
        await settled()
        XCTAssertEqual(api.keys.count, 2)
        XCTAssertEqual(api.keys[0], api.keys[1])
    }

    func testADifferentChipGetsADifferentKey() async {
        send(invoice)
        await settled()
        send(chip("invoice", "Invoice $60 · Color", ["amount": .string("60.00"), "currency": .string("USD"), "item": .string("Color"),
                                                             "client_email": .string("sam@example.com")]))
        await settled()
        XCTAssertEqual(api.keys.count, 2)
        XCTAssertNotEqual(api.keys[0], api.keys[1])
    }

    func testTheKeyExpiresAfterTheTTL() async {
        send(invoice)
        await settled()
        clock.advance(ChipKeys.ttl + 1)
        send(invoice)
        await settled()
        XCTAssertEqual(api.keys.count, 2)
        XCTAssertNotEqual(api.keys[0], api.keys[1])
    }

    func testDisappearMidCallThenReTapUsesTheSameKey() async {
        host.text = "Thanks Sam"
        api.failures = [URLError(.networkConnectionLost)]
        send(invoice)
        await until("retry wait") { clock.sleeping > 0 }
        model.keyboardDisappeared()
        for _ in 0..<50 { await Task.yield() }
        send(invoice)
        await settled()
        XCTAssertEqual(api.keys.count, 2)
        XCTAssertEqual(Set(api.keys).count, 1, "the re-tap replays the first call, it does not send a new invoice")
        XCTAssertTrue(host.text.hasSuffix("https://fake.pay/INV-1"))
    }

    func testAppearAfterDisappearLooksUpWithTheSameKeyAndInsertsTheLink() async {
        host.text = "Thanks Sam"
        api.failures = [URLError(.networkConnectionLost)]
        send(invoice)
        await until("retry wait") { clock.sleeping > 0 }
        model.keyboardDisappeared()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertNotNil(store.pendingAction, "a money call cut off by the keyboard closing is kept")
        api.stored = Set(api.keys)
        model.keyboardAppeared()
        await until("lookup") { store.pendingAction == nil }
        XCTAssertEqual(api.calls, ["invoice", "lookup:invoice"])
        XCTAssertEqual(Set(api.keys).count, 1)
        XCTAssertEqual(host.text, "Thanks Sam\nHere's your invoice for Haircut ($45): https://fake.pay/INV-1")
        XCTAssertEqual(model.watch?.id, "INV-1")
        XCTAssertNil(store.pendingAction)
    }

    func testAppearInAnotherFieldShowsSentInsteadOfTyping() async {
        host.text = "Thanks Sam"
        api.failures = [URLError(.networkConnectionLost)]
        send(invoice)
        await until("retry wait") { clock.sleeping > 0 }
        model.keyboardDisappeared()
        for _ in 0..<50 { await Task.yield() }
        host.text = "Other chat"
        api.stored = Set(api.keys)
        model.keyboardAppeared()
        await until("lookup") { store.pendingAction == nil }
        XCTAssertEqual(api.calls, ["invoice", "lookup:invoice"])
        XCTAssertEqual(host.text, "Other chat")
        XCTAssertEqual(model.bar, .done("Invoice sent to Sam \u{2713}"))
        XCTAssertEqual(Set(api.keys).count, 1)
    }

    func testInProgressSaysStillSendingThenShowsTheResult() async {
        host.text = "Thanks Sam"
        api.failures = [inProgress]
        send(invoice)
        await until("in-progress wait") { clock.sleeping > 0 }
        XCTAssertEqual(model.bar, .working("Still sending\u{2026}"))
        clock.advance(ChipActions.inProgressDelay.seconds)
        await settled()
        XCTAssertEqual(api.keys.count, 2)
        XCTAssertEqual(Set(api.keys).count, 1, "the re-check sends no new key")
        XCTAssertTrue(host.text.hasSuffix("https://fake.pay/INV-1"))
    }

    func testInProgressGivesUpAfterThreeChecksAndKeepsThePendingCall() async {
        api.failures = Array(repeating: inProgress, count: ChipActions.inProgressTries + 1)
        send(invoice)
        for _ in 0..<ChipActions.inProgressTries {
            await until("in-progress wait") { clock.sleeping > 0 }
            clock.advance(ChipActions.inProgressDelay.seconds)
        }
        await settled()
        XCTAssertEqual(api.keys.count, ChipActions.inProgressTries + 1)
        XCTAssertEqual(Set(api.keys).count, 1)
        XCTAssertEqual(model.bar, .error("Still sending. Check again in a minute."))
        XCTAssertNotNil(store.pendingAction, "the next appear checks it again")
    }

    func testTextChangedDuringTheCallWaitsAsAChip() async {
        host.text = "Thanks Sam"
        api.failures = [URLError(.networkConnectionLost)]
        send(invoice)
        await until("retry wait") { clock.sleeping > 0 }
        host.text = "Other chat"
        clock.advance(ChipActions.retryDelay.seconds)
        await settled()
        XCTAssertEqual(host.text, "Other chat")
        guard case .chips(let chips, _) = model.bar, let add = chips.first else { return XCTFail("expected a chip, got \(model.bar)") }
        model.tapChip(add)
        XCTAssertEqual(host.text, "Other chat Here's your invoice for Haircut ($45): https://fake.pay/INV-1")
    }

    func testDisappearCancelsTheAction() async {
        host.text = "Thanks Sam"
        api.failures = [URLError(.networkConnectionLost)]
        send(invoice)
        await until("retry wait") { clock.sleeping > 0 }
        model.keyboardDisappeared()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(api.calls, ["invoice"])
        XCTAssertEqual(host.text, "Thanks Sam")
        XCTAssertEqual(model.bar, .idle)
    }

    func testUnknownKindSaysOpenTheApp() async {
        model.tapChip(chip("mystery", "Something"))
        await settled()
        XCTAssertEqual(model.bar, .error("Open \(AppConfig.displayName) for this one"))
    }
    // MARK: money round 2: one confirm per invoice, per-client keys, lookup-only replay

    private func titles() -> [String] {
        BarItems.build(.init(hasFullAccess: true, paired: true, undo: nil, hasCalmOffer: false, watch: nil, bar: model.bar,
                             copiedAvailable: false, toBill: nil, nextUp: nil)).map(\.title)
    }

    func testEveryInvoiceAsksOnceWithAmountAndRecipient() async {
        let c = chip("invoice", "Invoice $45", ["amount": .string("45.00"), "currency": .string("USD"), "item": .string("Haircut"),
                                                "client_email": .string("bob@x.com")])
        model.tapChip(c)
        XCTAssertEqual(api.calls, [], "one tap never sends an invoice")
        XCTAssertEqual(titles(), ["Send $45 invoice to bob@x.com?", "Cancel"])
        guard case .confirm(let next, let recipient) = model.bar else { return XCTFail("expected the confirm slot, got \(model.bar)") }
        model.confirm(next, recipient: recipient)
        await settled()
        XCTAssertEqual(api.invoiced.last?["confirm_recipient"], .string("bob@x.com"))
        XCTAssertEqual(api.invoiced.last?["confirm_amount"], .string("45.00"))
    }

    func testANameOnlyInvoiceAsksWithTheName() async {
        let c = chip("invoice", "Invoice $45", ["amount": .string("45.00"), "currency": .string("USD"), "item": .string("Haircut"),
                                                "client_name": .string("Sam")])
        model.tapChip(c)
        XCTAssertEqual(api.calls, [])
        XCTAssertEqual(titles(), ["Send $45 invoice to Sam?", "Cancel"])
        guard case .confirm(let next, let recipient) = model.bar else { return XCTFail("expected the confirm slot, got \(model.bar)") }
        model.confirm(next, recipient: recipient)
        await settled()
        XCTAssertNil(api.invoiced.last?["confirm_recipient"])
        XCTAssertEqual(api.invoiced.last?["confirm_amount"], .string("45.00"))
    }

    func testAPayLinkThatNeedsAConfirmAsksFirst() async {
        model.tapChip(chip("paylink", "Pay link $135", ["amount": .string("135.00"), "currency": .string("USD"), "item": .string("Haircut")], confirm: true))
        XCTAssertEqual(api.calls, [])
        XCTAssertEqual(titles(), ["Create $135 pay link?", "Cancel"])
    }

    func testTwoClientsNeverShareAKey() async {
        let link = chip("paylink", "Pay link $45 · Haircut", ["amount": .string("45.00"), "currency": .string("USD"), "item": .string("Haircut")])
        host.text = "Hi Ana,"
        model.tapChip(link)
        await settled()
        host.text = "Hi Bo,"
        model.tapChip(link)
        await settled()
        var named = link.payload
        named["client_name"] = .string("Cy")
        host.text = "Hi,"
        model.tapChip(chip("paylink", "Pay link $45 · Haircut", named))
        await settled()
        named["client_name"] = .string("Di")
        host.text = "Hi,"
        model.tapChip(chip("paylink", "Pay link $45 · Haircut", named))
        await settled()
        XCTAssertEqual(api.keys.count, 4)
        XCTAssertEqual(Set(api.keys).count, 4, "a pay link for another client is a new request")
    }

    private func pending(before: String) -> PendingAction {
        PendingAction(chip: invoice, confirmed: "sam@example.com", before: before, key: "stale-key-1", expires: clock.now + 60)
    }

    func testStalePendingWithAnEmptyFieldInsertsAndSendsNothing() async {
        store.pendingAction = pending(before: "")
        host.text = ""
        model.keyboardAppeared()
        await until("lookup") { store.pendingAction == nil }
        await settled()
        XCTAssertEqual(api.calls, ["lookup:invoice"], "the replay only looks up, it never sends")
        XCTAssertEqual(host.text, "")
        XCTAssertEqual(model.bar, .idle, "not found: dropped with no line")
    }

    func testFoundPendingWithAnEmptyFieldSaysSentAndTypesNothing() async {
        api.stored = ["stale-key-1"]
        store.pendingAction = pending(before: "")
        host.text = ""
        model.keyboardAppeared()
        await until("lookup") { store.pendingAction == nil }
        await settled()
        XCTAssertEqual(api.calls, ["lookup:invoice"])
        XCTAssertEqual(host.text, "")
        XCTAssertEqual(model.bar, .done("Invoice sent to Sam \u{2713}"))
    }

    func testFoundPendingInTheSameFieldInsertsTheLink() async {
        api.stored = ["stale-key-1"]
        store.pendingAction = pending(before: "Thanks Sam")
        host.text = "Thanks Sam"
        model.keyboardAppeared()
        await until("lookup") { store.pendingAction == nil }
        await settled()
        XCTAssertEqual(api.calls, ["lookup:invoice"])
        XCTAssertEqual(host.text, "Thanks Sam\nHere's your invoice for Haircut ($45): https://fake.pay/INV-1")
    }

    func testTappingAnotherChipClearsThePendingCall() async {
        store.pendingAction = pending(before: "Thanks Sam")
        model.tapChip(chip("payments", "Who paid?"))
        XCTAssertNil(store.pendingAction)
    }
}
