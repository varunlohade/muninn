import SwiftUI
import XCTest
@testable import Muninn

/// "invoice for sam": the lookup chip, its card, and the same search in the Ask bar. JSON below is the server's real reply
/// for the salon seed in server/test/search-fixtures.ts.
@MainActor
final class LookupTests: XCTestCase {
    static let samJSON = #"""
    {"chips":[{"kind":"lookup","label":"Sam Lee's invoice · $120 · unpaid · Nov 9","payload":{"kind":"money","noun":"invoice","query":"sam","match":"exact","candidates":[{"name":"Sam Lee","records":[{"kind":"invoice","id":"INV2-cba387ce","title":"Color","amount":"120.00","currency":"USD","date":"2026-11-09","date_label":"Nov 9","state":"unpaid","link":"https://paypal.test/inv/INV2-cba387ce","line":"Your invoice for $120 (Nov 9) is here: https://paypal.test/inv/INV2-cba387ce","remind":{"kind":"remind","label":"Nudge Sam Lee · $120 owed","payload":{"invoice_id":"INV2-cba387ce","client_name":"Sam Lee","amount":"120.00","currency":"USD"},"needs_confirm":true}},{"kind":"invoice","id":"INV2-b47df4c0","title":"Haircut","amount":"45.00","currency":"USD","date":"2026-10-20","date_label":"Oct 20","state":"paid","link":"https://paypal.test/inv/INV2-b47df4c0","line":"Your invoice for $45 (Oct 20) is paid. Thank you!"},{"kind":"invoice","id":"INV2-dcdd25a5","title":"Blowout","amount":"60.00","currency":"USD","date":"2026-09-22","date_label":"Sep 22","state":"paid","link":"https://paypal.test/inv/INV2-dcdd25a5","line":"Your invoice for $60 (Sep 22) is paid. Thank you!"}],"empty_line":null}],"note":null,"new_invoice":false},"needs_confirm":false,"trigger":"invoice for sam"}],"intent":"lookup","confidence":1,"timings":{"total_ms":12}}
    """#
    static let anaJSON = #"""
    {"chips":[{"kind":"lookup","label":"No invoices for Ana Lopez yet","payload":{"kind":"money","noun":"invoice","query":"ana","match":"exact","candidates":[{"name":"Ana Lopez","records":[],"empty_line":"No invoices yet"}],"note":null,"new_invoice":false},"needs_confirm":false,"trigger":"ana's invoice"}],"intent":"lookup","confidence":1,"timings":{"total_ms":3}}
    """#
    static func reply(_ json: String) -> SuggestResponse { try! JSONDecoder().decode(SuggestResponse.self, from: Data(json.utf8)) }
    /// "invoice sam" with one Sam: the server's same records, plus new_invoice, and the typed words as the trigger.
    static let invoiceSamJSON = samJSON.replacingOccurrences(of: #""new_invoice":false"#, with: #""new_invoice":true"#)
        .replacingOccurrences(of: #""trigger":"invoice for sam""#, with: #""trigger":"invoice sam""#)

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

    private func until(_ what: String, _ cond: () -> Bool) async {
        for _ in 0..<500 where !cond() { await Task.yield() }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    /// Types `text` into the field and lets the suggest pause run out, then waits for the chip.
    private func typeAndWait(_ text: String, _ reply: SuggestResponse) async -> Chip? {
        api.suggestReply = reply
        host.text = text
        model.textChanged()
        await until("debounce sleep") { clock.sleeping > 0 }
        clock.advance(SuggestPolicy.debounce.seconds)
        await until("chip") { if case .chips = model.bar { true } else { false } }
        guard case .chips(let chips, _) = model.bar else { return nil }
        return chips.first
    }

    func testChipSaysWhatItFoundAndQuotesTheTypedWords() async throws {
        let typedChip = await typeAndWait("invoice for sam", Self.reply(Self.samJSON))
        let chip = try XCTUnwrap(typedChip)
        XCTAssertEqual(api.suggested.first?.text, "invoice for sam")
        let item = try XCTUnwrap(model.barItems.first { $0.id == "lookup" })
        XCTAssertEqual(item.title, "Sam Lee's invoice · $120 · unpaid · Nov 9")
        XCTAssertEqual(item.trigger, "invoice for sam")
        XCTAssertEqual(chip.kind, "lookup")
    }

    func testTapOpensTheCardAndCallsNothing() async throws {
        let typedChip = await typeAndWait("invoice for sam", Self.reply(Self.samJSON))
        let chip = try XCTUnwrap(typedChip)
        let before = api.calls
        model.tapChip(chip)
        let found = try XCTUnwrap(model.lookup)
        XCTAssertEqual(found.candidates.first?.records.count, 3, "the latest and 2 older ones")
        XCTAssertEqual(api.calls, before, "opening the card sends nothing")
        XCTAssertEqual(KeyboardView.height(whoPaid: nil, lookup: true), KeyboardView.height(whoPaid: nil) + LookupCard.height)
    }

    func testInsertPutsTheLineWhereTheLookupWordsWere() async throws {
        host.text = "Hi Sam! "
        let typedChip = await typeAndWait("Hi Sam! invoice for sam", Self.reply(Self.samJSON))
        let chip = try XCTUnwrap(typedChip)
        model.tapChip(chip)
        model.insertLookup(try XCTUnwrap(model.lookup?.candidates.first?.records.first))
        XCTAssertEqual(host.text, "Hi Sam! Your invoice for $120 (Nov 9) is here: https://paypal.test/inv/INV2-cba387ce")
        XCTAssertNil(model.lookup)
        XCTAssertFalse(api.calls.contains { $0 != "suggest" }, "Insert moves no money and sends nothing")
    }

    func testRemindGoesThroughTheUsualConfirm() async throws {
        let typedChip = await typeAndWait("invoice for sam", Self.reply(Self.samJSON))
        let chip = try XCTUnwrap(typedChip)
        model.tapChip(chip)
        let remind = try XCTUnwrap(model.lookup?.candidates.first?.records.first?.remind)
        model.remindFromLookup(remind)
        guard case .confirm(let c, let who) = model.bar else { return XCTFail("expected the confirm, got \(model.bar)") }
        XCTAssertEqual(who, "Sam Lee")
        XCTAssertEqual(BarItems.confirmTitle(c, recipient: who), "Email Sam Lee a reminder for $120?")
        XCTAssertFalse(api.calls.contains("remind"), "nothing is sent before the confirm tap")
        model.confirm(c, recipient: who)
        await until("reminded") { api.reminded == ["Sam Lee"] }
    }

    func testEmptyResultOffersNewInvoiceThroughTheAmountAndConfirm() async throws {
        let typedChip = await typeAndWait("ana's invoice", Self.reply(Self.anaJSON))
        let chip = try XCTUnwrap(typedChip)
        XCTAssertEqual(chip.label, "No invoices for Ana Lopez yet")
        model.tapChip(chip)
        let found = try XCTUnwrap(model.lookup)
        let ana = try XCTUnwrap(found.candidates.first)
        XCTAssertEqual(LookupCopy.newInvoiceName(found, ana), "Ana Lopez")
        model.newInvoiceFromLookup("Ana Lopez")
        XCTAssertEqual(host.text, "", "the lookup words go; the client gets no stray text")
        XCTAssertEqual(model.bar, .done("Type the amount for Ana"))
        XCTAssertFalse(api.calls.contains("invoice"))
    }

    func testInvoiceSamShowsTheLatestAndOffersNewInvoice() async throws {
        let typedChip = await typeAndWait("invoice sam", Self.reply(Self.invoiceSamJSON))
        let chip = try XCTUnwrap(typedChip)
        XCTAssertEqual(chip.trigger, "invoice sam")
        model.tapChip(chip)
        let found = try XCTUnwrap(model.lookup)
        let sam = try XCTUnwrap(found.candidates.first)
        XCTAssertEqual(LookupCopy.newInvoiceName(found, sam), "Sam Lee", "records shown, and New invoice offered")
        XCTAssertEqual(LookupCopy.hint(sam.records[0], insertWord: "Insert", offersNew: true),
                       "Insert gives you a line with this invoice. Nudge and New invoice ask you to confirm first.")
        model.newInvoiceFromLookup("Sam Lee")
        XCTAssertEqual(model.bar, .done("Type the amount for Sam"))
        XCTAssertFalse(api.calls.contains("invoice"), "no invoice before the amount and the confirm")
    }

    func testCardWordsSayWhatEachButtonDoes() throws {
        let chip = try XCTUnwrap(Self.reply(Self.samJSON).chips.first)
        let r = try XCTUnwrap(LookupResult(chip: chip))
        let sam = try XCTUnwrap(r.candidates.first)
        XCTAssertEqual(LookupCopy.header(r, sam), "Sam Lee \u{00B7} latest invoice")
        XCTAssertEqual(LookupCopy.row(sam.records[0]), "$120 \u{00B7} unpaid \u{00B7} Nov 9")
        XCTAssertEqual(LookupCopy.hint(sam.records[0], insertWord: "Insert"),
                       "Insert gives you a line with this invoice and its link. Nudge asks before it sends.")
        XCTAssertEqual(LookupCopy.hint(sam.records[1], insertWord: "Copy"), "Copy gives you a line with this invoice.")
        XCTAssertNil(LookupCopy.newInvoiceName(r, sam), "a client with records gets no New invoice")
        XCTAssertNil(LookupResult(chip: Chip(kind: "invoice", label: "x", payload: [:], needs_confirm: true)))
    }

    func testOnlyLookupShapedTextLeavesThePhone() {
        for t in ["last order from ana", "ana's booking", "invocie for sam", "sams invoce", "did sam pay", "invoice for sam"] {
            XCTAssertNotEqual(SuggestPolicy.ask(t, lastAsked: ""), .skip, t)
        }
        for t in ["class is cancelled tomorrow", "see you soon", "the table looks great today"] {
            XCTAssertEqual(SuggestPolicy.ask(t, lastAsked: ""), .skip, t)
        }
    }

    func testAskBarShowsTheSameResult() async throws {
        let store = FakeStore()
        let ask = AskModel(api: { [api] in api! }, store: store, sleep: { _ in })
        let r = try XCTUnwrap(LookupResult(chip: try XCTUnwrap(Self.reply(Self.samJSON).chips.first)))
        api.askReply = AskResponse(route: "lookup", confidence: 1, result: .lookup(r))
        ask.text = "invoice for sam"
        ask.submit()
        await ask.task?.value
        XCTAssertEqual(ask.state, .lookup(r))
        let wire = #"{"route":"lookup","confidence":1,"result":{"kind":"money","noun":"invoice","query":"ana","match":"exact","candidates":[{"name":"Ana Lopez","records":[],"empty_line":"No invoices yet"}],"note":null,"new_invoice":false}}"#
        guard case .lookup(let decoded) = try JSONDecoder().decode(AskResponse.self, from: Data(wire.utf8)).result else { return XCTFail("route") }
        XCTAssertEqual(decoded.candidates.first?.empty_line, "No invoices yet")
        XCTAssertEqual(LookupCopy.newInvoiceRequest("Ana Lopez"), "Invoice Ana Lopez $")
    }

    /// Pictures of the real views in each state. Runs only with TEST_RUNNER_SHOT_DIR set.
    func testShots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] else { throw XCTSkip("set TEST_RUNNER_SHOT_DIR to save shots") }
        // ImageRenderer cannot draw the UIKit key grid, so keyboard shots keep only the card and the suggestion bar above it.
        let keys = Theme.SystemKeyboard.height - Theme.SystemKeyboard.barHeight
        func save(_ name: String, _ view: some View, dark: Bool = false, cutKeys: Bool = true) {
            let r = ImageRenderer(content: view.frame(width: 402).environment(\.colorScheme, dark ? .dark : .light))
            r.scale = 3
            guard var image = r.cgImage else { return }
            if cutKeys, let top = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: image.height - Int((keys + 6) * 3))) { image = top }
            if let png = UIImage(cgImage: image).pngData() { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")) }
        }
        let samChip = await typeAndWait("invoice sam", Self.reply(Self.invoiceSamJSON))
        save("1-chip", KeyboardView(model: model))
        model.tapChip(try XCTUnwrap(samChip))
        save("6-card-invoice-sam", KeyboardView(model: model))
        model.closeLookup()
        let typedChip = await typeAndWait("invoice for sam", Self.reply(Self.samJSON))
        let chip = try XCTUnwrap(typedChip)
        model.tapChip(chip)
        save("2-card", KeyboardView(model: model))
        model.isDark = true
        save("3-card-dark", KeyboardView(model: model), dark: true)
        model.isDark = false
        model.closeLookup()
        let anaChip = await typeAndWait("ana's invoice", Self.reply(Self.anaJSON))
        model.tapChip(try XCTUnwrap(anaChip))
        save("4-empty-card", KeyboardView(model: model))
        let ask = AskModel(api: { [api] in api! }, store: FakeStore(), sleep: { _ in })
        let r = try XCTUnwrap(LookupResult(chip: chip))
        api.askReply = AskResponse(route: "lookup", confidence: 1, result: .lookup(r))
        ask.text = "invoice for sam"
        ask.submit()
        await ask.task?.value
        save("5-ask-bar", AskBar(model: ask).background(Theme.Color.bg), cutKeys: false)
    }
}
