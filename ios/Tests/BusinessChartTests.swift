import XCTest
@testable import Muninn

/// Charts of the owner's own records, and explain chips that must not take money phrases. Pure, plus the keyboard flow with a fake server.
final class BusinessChartTests: XCTestCase {
    /// 2027-01-15 08:00 UTC, a Friday: the FakeClock's start.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func pay(_ id: String, _ state: String, _ amount: String, item: String = "Haircut", client: String? = "Sam Lee",
                     daysAgo: Int = 0, currency: String = "USD", kind: String = "invoice") -> Payment {
        let at = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Payment(kind: kind, id: id, state: state, amount: amount, currency: currency, item: item, client_name: client, link: nil,
                       created_at: f.string(from: at), days_overdue: 0)
    }

    private func items(_ r: Chart.Request?) -> [String: Double] {
        guard case .data(_, _, let list)? = r else { return [:] }
        return Dictionary(uniqueKeysWithValues: list.map { ($0.label, $0.value) })
    }

    func testDetectsTheOwnersChartPhrases() {
        XCTAssertEqual(BusinessChart.detect("graph my sales this week"), .salesByDay(.bar))
        XCTAssertEqual(BusinessChart.detect("chart sales by day"), .salesByDay(.bar))
        XCTAssertEqual(BusinessChart.detect("line chart of my revenue"), .salesByDay(.line))
        XCTAssertEqual(BusinessChart.detect("bar chart of top items"), .topItems(.bar))
        XCTAssertEqual(BusinessChart.detect("pie chart of my best sellers"), .topItems(.pie))
        XCTAssertEqual(BusinessChart.detect("who owes me chart"), .whoOwes(.bar))
        XCTAssertEqual(BusinessChart.detect("chart unpaid invoices"), .whoOwes(.bar))
    }

    func testPlainChatAndMoneyQuestionsAreNotCharts() {
        for text in ["what does sam owe", "my sales were great this week", "who owes me", "send the chart to ana tomorrow", "graph y = x^2"] {
            XCTAssertNil(BusinessChart.detect(text), text)
        }
    }

    func testSalesByDayMatchTheRecords() {
        let list = [
            pay("A", "paid", "45.00", daysAgo: 0),
            pay("B", "paid", "20.00", daysAgo: 0, kind: "order"),
            pay("C", "paid", "120.00", item: "Color", daysAgo: 2),
            pay("D", "unpaid", "90.00", daysAgo: 1),
            pay("E", "refunded", "35.00", daysAgo: 1),
            pay("F", "paid", "500.00", daysAgo: 9),
        ]
        let chart = BusinessChart.chart(.salesByDay(.bar), payments: list, now: now, calendar: utc)
        guard case .data(.bar, let title, let got)? = chart else { return XCTFail("no chart") }
        XCTAssertEqual(title, "Sales, last 7 days ($)")
        XCTAssertEqual(got.map(\.label), ["Sat", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri"], "7 days, today last")
        XCTAssertEqual(got.map(\.value), [0, 0, 0, 0, 120, 0, 65], "paid only; unpaid, refunded and older sales left out")
        XCTAssertNotNil(ChartScene.build(chart!))
    }

    func testTopItemsMatchTheRecords() {
        let list = [
            pay("A", "paid", "45.00", item: "Haircut"), pay("B", "paid", "45.00", item: "Haircut", daysAgo: 30),
            pay("C", "paid", "120.00", item: "Color"), pay("D", "paid", "20.00", item: "Beard trim"),
            pay("E", "unpaid", "500.00", item: "Wedding"),
        ]
        let chart = BusinessChart.chart(.topItems(.bar), payments: list, now: now, calendar: utc)
        guard case .data(_, _, let got)? = chart else { return XCTFail("no chart") }
        XCTAssertEqual(got.map(\.label), ["Color", "Haircut", "Beard trim"])
        XCTAssertEqual(got.map(\.value), [120, 90, 20])
    }

    func testWhoOwesMatchesTheRecords() {
        let list = [
            pay("A", "unpaid", "120.00", client: "Jordan Ray"), pay("B", "unpaid", "30.00", client: "Jordan Ray"),
            pay("C", "unpaid", "45.00", client: "Maya Lopez"), pay("D", "paid", "999.00", client: "Ava Chen"),
        ]
        XCTAssertEqual(items(BusinessChart.chart(.whoOwes(.bar), payments: list, now: now, calendar: utc)), ["Jordan Ray": 150, "Maya Lopez": 45])
    }

    func testOneChartKeepsOneCurrency() {
        let list = [pay("A", "unpaid", "10.00", client: "Ana"), pay("B", "unpaid", "20.00", client: "Bo"),
                    pay("C", "unpaid", "99.00", client: "Cy", currency: "EUR")]
        let chart = BusinessChart.chart(.whoOwes(.bar), payments: list, now: now, calendar: utc)
        guard case .data(_, let title, _)? = chart else { return XCTFail("no chart") }
        XCTAssertEqual(title, "Who owes you ($)")
        XCTAssertEqual(items(chart), ["Ana": 10, "Bo": 20])
    }

    func testNothingToDrawGivesNoChart() {
        XCTAssertNil(BusinessChart.chart(.salesByDay(.bar), payments: [pay("A", "paid", "45.00", daysAgo: 20)], now: now, calendar: utc))
        XCTAssertNil(BusinessChart.chart(.whoOwes(.bar), payments: [pay("A", "paid", "45.00")], now: now, calendar: utc))
    }

    func testMoneyPhrasesStayOnTheLookupPath() {
        for text in ["what does sam owe", "what is sam's balance", "what's the total for ana", "what is ana's invoice", "what's due today"] {
            XCTAssertTrue(KeyboardModel.yieldsToMoney(text) || Explain.detect(text) == nil, text)
        }
        for text in ["explain how a deposit works", "explain net 30", "what does deposit mean", "how does a refund work", "explain log function"] {
            XCTAssertFalse(KeyboardModel.yieldsToMoney(text), text)
            XCTAssertNotNil(Explain.detect(text), text)
        }
        XCTAssertEqual(Explain.detect("explain how a deposit works")?.subject, "deposit")
        XCTAssertEqual(Explain.detect("explain net 30")?.subject, "net 30")
    }
}

@MainActor
final class BusinessChartModelTests: XCTestCase {
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

    private func set(_ text: String) {
        host.text = text
        model.textChanged()
    }

    private func until(_ what: String, _ cond: () -> Bool) async {
        for _ in 0..<500 where !cond() { await Task.yield() }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    func testWhatDoesSamOweStillGoesToTheLookup() async {
        set("what does sam owe")
        XCTAssertNil(model.explainOffer)
        await until("suggest sleep") { clock.sleeping > 0 }
        clock.advance(SuggestPolicy.debounce.seconds)
        await until("suggest") { api.calls.contains("suggest") }
        XCTAssertFalse(api.calls.contains("explain"))
        XCTAssertEqual(api.suggested.last?.text, "what does sam owe")
    }

    func testABalanceQuestionIsNotAnExplainChip() async {
        set("what is sam's balance")
        XCTAssertNil(model.explainOffer)
        await until("suggest sleep") { clock.sleeping > 0 }
        clock.advance(max(SuggestPolicy.debounce, KeyboardModel.explainDebounce).seconds)
        await until("suggest") { api.calls.contains("suggest") }
        XCTAssertFalse(api.calls.contains("explain"))
    }

    func testABusinessExplainGoesToExplainNotSuggest() async {
        set("explain how a deposit works")
        await until("explain sleep") { clock.sleeping > 0 }
        clock.advance(KeyboardModel.explainDebounce.seconds)
        await until("explain answer") { model.explainOffer != nil }
        XCTAssertEqual(api.calls, ["explain"])
        XCTAssertEqual(api.explained, ["explain how a deposit works"])
    }

    func testSalesChartIsDrawnFromThePaymentsListOnTap() async {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        api.paymentsReply = [
            Payment(kind: "invoice", id: "A", state: "paid", amount: "45.00", currency: "USD", item: "Haircut", client_name: "Sam",
                    link: nil, created_at: f.string(from: clock.now), days_overdue: 0),
        ]
        set("graph my sales this week")
        XCTAssertEqual(model.barItems.first?.title, "Draw it")
        XCTAssertEqual(model.barItems.first?.trigger, "Sales, last 7 days")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(api.calls, [], "detecting the chart reads nothing")
        model.perform(.explain)
        await until("scene") {
            if case .visual(let v)? = model.explainPanel { return v.scene != nil }
            return false
        }
        XCTAssertEqual(api.calls, ["payments"], "only the read-only payments list")
        guard case .visual(let v)? = model.explainPanel else { return XCTFail("no panel") }
        XCTAssertTrue(v.summary.hasPrefix("Sales, last 7 days ($): "), v.summary)
        XCTAssertTrue(v.summary.hasSuffix(" 45"), v.summary)
    }

    func testAnEmptyWeekSaysSo() async {
        set("graph my sales this week")
        model.perform(.explain)
        await until("failed") {
            if case .visual(let v)? = model.explainPanel, case .failed = v.status { return true }
            return false
        }
        guard case .visual(let v)? = model.explainPanel, case .failed(let line) = v.status else { return XCTFail("no panel") }
        XCTAssertEqual(line, "No paid sales in the last 7 days yet.")
    }
}
