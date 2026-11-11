import XCTest
@testable import Muninn

/// The Disputes page: Reply, Offer and Accept each ask first and send the values the server checks.
@MainActor
final class DisputeTests: XCTestCase {
    private let sam = OpenDispute(id: "PP-D-12345", name: "Sam Lee", amount: "45.00", currency: "USD", line: "Sam Lee $45 \u{00B7} reply by Thu")
    private var api: FakeAPI!
    private var model: DisputesModel!

    override func setUp() async throws {
        api = FakeAPI()
        let list = [sam]
        model = DisputesModel(load: { list }, api: { [api] in api! })
        await model.reload()
    }

    private func until(_ what: String, _ cond: () -> Bool) async {
        for _ in 0..<500 where !cond() { await Task.yield() }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    func testChipsUseTheServersShapeAndQuestions() throws {
        let accept = try XCTUnwrap(DisputeChips.accept(sam))
        XCTAssertEqual(accept.label, "Accept claim $45 \u{00B7} Sam Lee")
        XCTAssertEqual(BarItems.confirmTitle(accept, recipient: "Sam Lee"), "Accept Sam Lee's claim and refund $45? Can't undo.")
        XCTAssertTrue(BarItems.asksFirst(accept))
        let reply = try XCTUnwrap(DisputeChips.reply(sam, message: " I shipped it Monday "))
        XCTAssertEqual(BarItems.confirmTitle(reply, recipient: "Sam Lee"), "Send this to Sam Lee in PayPal's dispute? \"I shipped it Monday\"")
        XCTAssertNil(DisputeChips.reply(sam, message: "  "))
        guard case .success(let offer) = DisputeChips.offer(sam, typed: "$20") else { return XCTFail("no offer") }
        XCTAssertEqual(offer.label, "Offer $20 \u{00B7} Sam Lee")
        XCTAssertEqual(BarItems.confirmTitle(offer, recipient: "Sam Lee"), "Offer Sam Lee a $20 refund to close the dispute?")
        XCTAssertEqual(DisputeChips.offer(sam, typed: "60").failureValue, .moreThanDispute("$45"))
        XCTAssertEqual(DisputeChips.offer(sam, typed: "twenty").failureValue, .notAnAmount)
        XCTAssertNil(DisputeChips.accept(OpenDispute(id: "PP-X", name: "Ana", amount: nil, currency: nil, line: "Ana")))
    }

    func testOfferAsksThenSendsTheAmountItShowed() async {
        model.start(sam, .offer)
        model.draft = "20"
        model.next(sam, .offer)
        guard case .confirm(let chip) = model.step else { return XCTFail("\(model.step)") }
        XCTAssertEqual(api.calls, [], "nothing is sent before the confirm tap")
        api.moreReply = MoreResponse(line: "Offer sent \u{2713}", undo: nil)
        model.send(chip, to: sam)
        await until("sent") { model.step == .done("Offer sent \u{2713}") }
        XCTAssertEqual(api.moreSent.first?.path, "dispute/offer")
        XCTAssertEqual(api.moreSent.first?.body, ["dispute_id": .string("PP-D-12345"), "amount": .string("20.00"), "currency": .string("USD"),
                                                  "confirm_client": .string("Sam Lee"), "confirm_amount": .string("20.00"), "confirm_currency": .string("USD")])
    }

    func testAcceptAndReplyGoToTheirRoutes() async {
        model.accept(sam)
        guard case .confirm(let accept) = model.step else { return XCTFail("\(model.step)") }
        model.send(accept, to: sam)
        await until("accepted") { if case .done = model.step { true } else { false } }
        model.close()
        model.start(sam, .reply)
        model.draft = "Shipped Monday"
        model.next(sam, .reply)
        guard case .confirm(let reply) = model.step else { return XCTFail("\(model.step)") }
        model.send(reply, to: sam)
        await until("replied") { if case .done = model.step { true } else { false } }
        XCTAssertEqual(api.calls, ["more:dispute/accept", "more:dispute/reply"])
        XCTAssertEqual(api.moreSent.last?.body["message"], .string("Shipped Monday"))
    }

    func testAMoreThanDisputeOfferShowsAPlainLine() {
        model.start(sam, .offer)
        model.draft = "60"
        model.next(sam, .offer)
        XCTAssertEqual(model.step, .error("Offer $45 or less, or accept the claim"))
        XCTAssertEqual(api.calls, [])
    }
}

private extension Result {
    var failureValue: Failure? { if case .failure(let e) = self { e } else { nil } }
}
