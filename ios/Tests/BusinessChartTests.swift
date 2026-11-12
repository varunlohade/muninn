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

    func testDetectsProjectionAsks() {
        XCTAssertEqual(BusinessChart.detect("graph my projections"), .projection(back: 6, ahead: 3))
        XCTAssertEqual(BusinessChart.detect("show revenue next 3 months"), .projection(back: 6, ahead: 3))
        XCTAssertEqual(BusinessChart.detect("chart?"), .projection(back: 6, ahead: 3))
        XCTAssertEqual(BusinessChart.detect("money chart?"), .projection(back: 6, ahead: 3))
        XCTAssertEqual(BusinessChart.detect("bar chart of last 4 months"), .projection(back: 4, ahead: 3))
        XCTAssertEqual(BusinessChart.detect("can you show my sales for the next two months"), .projection(back: 6, ahead: 2))
        XCTAssertEqual(BusinessChart.detect("chart sales last 40 months, next 9 months"), .projection(back: 12, ahead: 6))
        for text in ["sales forecast", "projections?", "how are sales trending", "ok cool. chart of my revenue by month", "plot my earnings forecast"] {
            XCTAssertNotNil(BusinessChart.detect(text).flatMap { if case .projection = $0 { $0 } else { nil } }, text)
        }
    }

    // The owner's own projection phrases, one test each. All read on the phone; no model.
    func testProjectionPhraseMakeMeAProjection() {
        XCTAssertEqual(BusinessChart.detect("make me a projection for next 3 months"), .projection(back: 6, ahead: 3))
    }

    func testProjectionPhraseCanItMakeAGraphInTheKeyboard() {
        XCTAssertEqual(BusinessChart.detect("can it make a graph or anything else in the keyboard, like right in front of me?"), .projection(back: 6, ahead: 3))
    }

    func testProjectionPhraseProjectMySales() {
        XCTAssertEqual(BusinessChart.detect("project my sales for 3 months"), .projection(back: 6, ahead: 3))
    }

    func testProjectionPhraseForecastNextQuarter() {
        XCTAssertEqual(BusinessChart.detect("forecast next quarter"), .projection(back: 6, ahead: 3))
    }

    func testProjectionPhraseHowMuchWillIMake() {
        XCTAssertEqual(BusinessChart.detect("how much will I make in the next 3 months"), .projection(back: 6, ahead: 3))
    }

    func testProjectionPhrasesNegativesStayQuiet() {
        for text in ["the plot of the film", "graph paper", "how much will I make if I sell 3 haircuts", "can it wait till monday",
                     "make me a coffee", "draw a graph of y = x^2"] {
            XCTAssertNil(BusinessChart.detect(text), text)
        }
    }

    func testChartAsksForThePhonesTimeZone() {
        XCTAssertEqual(APIClient.zoneParam(TimeZone(identifier: "Asia/Kolkata")!), "Asia/Kolkata")
        XCTAssertEqual(APIClient.zoneParam(TimeZone(identifier: "America/Argentina/Buenos_Aires")!), "America/Argentina/Buenos_Aires")
        XCTAssertEqual(APIClient.zoneParam(TimeZone(identifier: "Etc/GMT+5")!), "Etc/GMT%2B5")
    }

    /// A chart word alone in chat never becomes a chart and never leaves the phone.
    func testAChartWordInChatStaysOnThePhone() {
        for text in ["the plot of the film", "plot", "trend", "what a trend", "the chart in your deck", "graph paper", "I sent your chart this morning"] {
            XCTAssertNil(BusinessChart.detect(text), text)
            XCTAssertEqual(SuggestPolicy.ask(text, lastAsked: ""), .skip, text)
        }
    }

    func testProjectionSceneMarksTheEstimate() throws {
        let data = ChartData(title: "Money in by month (USD)", currency: "USD", months: [
            .init(month: "2026-09", label: "Sep", value: "2000.00", kind: "actual"),
            .init(month: "2026-10", label: "Oct", value: "3000.00", kind: "actual"),
            .init(month: "2026-11", label: "Nov", value: "640.00", kind: "partial"),
            .init(month: "2026-12", label: "Dec", value: "4000.00", kind: "estimate"),
        ], caption: "Dashed bars are an estimate: a straight-line trend of the last 2 full months. Not a promise.", enough_history: true, source: "paypal")
        let scene = ChartScene.projection(data)
        let bars = scene.steps[1].shapes.map { s -> String in
            switch s {
            case let .rect(_, _, _, _, c, f, _): "\(c)/\(f)"
            case let .dashedRect(_, _, _, _, c): "\(c)/dashed"
            default: "other"
            }
        }
        XCTAssertEqual(bars, ["blue/solid", "blue/solid", "light-blue/solid", "blue/dashed"])
        let texts = scene.steps[2].shapes.compactMap { if case let .text(_, _, t, _, _) = $0 { t } else { nil } }
        XCTAssertTrue(texts.contains("~$4k"), "\(texts)")
        XCTAssertTrue(texts.contains("$3k"))
        XCTAssertFalse(texts.contains("~$3k"))
        XCTAssertEqual(scene.steps[2].say, data.caption)
        let json = try XCTUnwrap(String(data: scene.json(), encoding: .utf8))
        XCTAssertTrue(json.contains(#""stroke":"dashed""#), json)
        XCTAssertEqual(KeyboardModel.summary(data), "Money in by month (USD): Sep $2k, Oct $3k, Nov $640 so far, Dec ~$4k estimate")
    }

    /// low / high from the server: a soft band behind each dashed bar, drawn before the bars, and the "estimate" word stays.
    func testProjectionDrawsTheRangeBandBehindTheEstimate() throws {
        var dec = ChartData.Month(month: "2026-12", label: "Dec", value: "4000.00", kind: "estimate")
        dec.low = "3000.00"
        dec.high = "5000.00"
        let data = ChartData(title: "Money in by month (USD)", currency: "USD", months: [
            .init(month: "2026-10", label: "Oct", value: "3000.00", kind: "actual"),
            .init(month: "2026-11", label: "Nov", value: "640.00", kind: "partial"),
            dec,
        ], caption: "Dashed bars are an estimate.", enough_history: true, source: "paypal")
        let scene = ChartScene.projection(data)
        let shapes = scene.steps[1].shapes
        guard case let .band(bx, by, bw, bh, _)? = shapes.first, case let .dashedRect(x, y, w, h, _)? = shapes.last else {
            return XCTFail("band first, dashed bar last: \(shapes)")
        }
        XCTAssertLessThan(bx, x)
        XCTAssertGreaterThan(bx + bw, x + w)
        XCTAssertLessThan(by, y, "the band's top (high) is above the bar's top (value)")
        XCTAssertGreaterThan(by + bh, y, "the band's bottom (low) is below the bar's top")
        XCTAssertLessThan(by + bh, y + h, "the band's bottom (low) is above zero")
        let texts = scene.steps[2].shapes.compactMap { if case let .text(_, _, t, _, _) = $0 { t } else { nil } }
        XCTAssertTrue(texts.contains("estimate"), "\(texts)")
        XCTAssertTrue(texts.contains("~$4k"))
        let json = try XCTUnwrap(String(data: scene.json(), encoding: .utf8))
        XCTAssertTrue(json.contains(#""opacity":25"#), json)
        XCTAssertTrue(json.contains(#""stroke":"none""#), json)
    }

    /// Thin history: no estimate months, so no band and no "estimate" word; the caption says why in plain text.
    func testThinHistoryHasNoBand() {
        let data = ChartData(title: "Money in by month (USD)", currency: "USD", months: [
            .init(month: "2026-10", label: "Oct", value: "3000.00", kind: "actual"),
            .init(month: "2026-11", label: "Nov", value: "640.00", kind: "partial"),
        ], caption: "Not enough history for an estimate yet. It needs 2 full months of sales.", enough_history: false, source: "paypal")
        let scene = ChartScene.projection(data)
        XCTAssertFalse(scene.steps.flatMap(\.shapes).contains { if case .band = $0 { true } else { false } })
        XCTAssertFalse(scene.steps[2].shapes.contains { if case .text(_, _, "estimate", _, _) = $0 { true } else { false } })
        XCTAssertEqual(scene.steps[2].say, data.caption)
    }

    func testShortMoney() {
        XCTAssertEqual(ChartScene.shortMoney(450, currency: "USD"), "$450")
        XCTAssertEqual(ChartScene.shortMoney(1200, currency: "USD"), "$1.2k")
        XCTAssertEqual(ChartScene.shortMoney(3000, currency: "EUR"), "€3k")
        XCTAssertEqual(ChartScene.shortMoney(12_400, currency: "GBP"), "£12k")
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
        XCTAssertTrue(v.chart, "a chart has no voice button")
    }

    func testProjectionIsDrawnFromPayPalMonthsOnTap() async {
        api.chartReply = ChartData(title: "Money in by month (USD)", currency: "USD", months: [
            .init(month: "2026-10", label: "Oct", value: "3000.00", kind: "actual"),
            .init(month: "2026-11", label: "Nov", value: "500.00", kind: "partial"),
            .init(month: "2026-12", label: "Dec", value: "3500.00", kind: "estimate"),
        ], caption: "Dashed bars are an estimate. Not a promise.", enough_history: true, source: "paypal")
        set("show revenue next 3 months")
        XCTAssertEqual(model.barItems.first?.title, "Draw it")
        XCTAssertEqual(model.barItems.first?.trigger, "Money in by month")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(api.calls, [], "detecting the projection reads nothing and never asks /v1/suggest")
        model.perform(.explain)
        await until("scene") {
            if case .visual(let v)? = model.explainPanel { return v.scene != nil }
            return false
        }
        XCTAssertEqual(api.calls, ["chart:6:3"], "only the read-only month chart")
        guard case .visual(let v)? = model.explainPanel else { return XCTFail("no panel") }
        XCTAssertEqual(v.summary, "Money in by month (USD): Oct $3k, Nov $500 so far, Dec ~$3.5k estimate")
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
