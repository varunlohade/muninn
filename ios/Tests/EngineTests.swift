import XCTest
@testable import Muninn

final class SuggestPolicyTests: XCTestCase {
    private let chip = Chip(kind: "invoice", label: "Invoice Sam $45", payload: [:], needs_confirm: true)
    private let link = Chip(kind: "paylink", label: "Pay link", payload: [:], needs_confirm: false)

    func testOneCharacterAsksNothing() {
        XCTAssertEqual(SuggestPolicy.ask("h", lastAsked: ""), .skip)
    }

    func testTwoWordsAskNothing() {
        XCTAssertEqual(SuggestPolicy.ask("see you", lastAsked: ""), .skip)
        XCTAssertEqual(SuggestPolicy.ask("ok", lastAsked: ""), .skip)
    }

    func testTwoWordsWithMoneyAsk() {
        for text in ["$45 haircut", "45 usd", "€45.50 color", "invoice Sam", "Sam paid", "refund Ana", "you owe"] {
            XCTAssertEqual(SuggestPolicy.ask(text, lastAsked: ""), .ask(text, after: AppConfig.suggestDebounce), text)
        }
    }

    func testOneWordWithMoneyAsksNothing() {
        for text in ["$", "$45", "invoice"] {
            XCTAssertEqual(SuggestPolicy.ask(text, lastAsked: ""), .skip, text)
        }
    }

    func testMoneyNeverOverridesTheSecretScan() {
        XCTAssertEqual(SuggestPolicy.ask("pay 482913", lastAsked: ""), .skip)
        XCTAssertEqual(SuggestPolicy.ask("pay 4242424242424242", lastAsked: ""), .skip)
    }

    func testEmptyAsksNothing() {
        XCTAssertEqual(SuggestPolicy.ask("", lastAsked: "a b c"), .skip)
    }

    func testCardNumberAsksNothing() {
        XCTAssertEqual(SuggestPolicy.ask("my card is 4242 4242 4242 4242 thanks", lastAsked: ""), .skip)
        XCTAssertEqual(SuggestPolicy.ask("card 4242-4242-4242-4242 for the $45", lastAsked: ""), .skip)
        XCTAssertEqual(SuggestPolicy.ask("card 4242424242424242 for the $45", lastAsked: ""), .skip)
    }

    func testSecretsAskNothing() {
        XCTAssertEqual(SuggestPolicy.ask("the code is 482913", lastAsked: ""), .skip)
        XCTAssertEqual(SuggestPolicy.ask("use key sk_live_abcdefghijklmnop1234 please", lastAsked: ""), .skip)
        XCTAssertEqual(SuggestPolicy.ask("token is aB3dE5gH7jK9mN1pQ3sT5vW7yZ9bC1dE3f ok", lastAsked: ""), .skip)
    }

    func testThreeWordsAskAfterTheDebounce() {
        XCTAssertEqual(SuggestPolicy.ask("$45 for haircut", lastAsked: ""), .ask("$45 for haircut", after: AppConfig.suggestDebounce))
    }

    func testEverydayNumbersStillAsk() {
        for text in ["call me at 555 123 4567 about the $45", "That is $45 for the haircut, sam@example.com",
                     "see https://example.com/invoice/123 for the details"] {
            XCTAssertEqual(SuggestPolicy.ask(text, lastAsked: ""), .ask(text, after: AppConfig.suggestDebounce), text)
        }
    }

    func testSameTextKeepsTheBar() {
        XCTAssertEqual(SuggestPolicy.ask("$45 for haircut", lastAsked: "$45 for haircut"), .keep)
    }

    func testBillingPrefixCountsTowardTheWords() {
        XCTAssertEqual(SuggestPolicy.ask("45", lastAsked: "", prefix: "Invoice Sam sam@example.com"),
                       .ask("Invoice Sam sam@example.com 45", after: AppConfig.suggestDebounce))
    }

    func testStaleReplyIsDropped() {
        let p = SuggestPolicy()
        XCTAssertNil(p.show([chip], askedFor: "$45 for haircut", current: "$45 for haircut today"))
        XCTAssertEqual(p.show([chip], askedFor: "$45 for haircut", current: "$45 for haircut"), [chip])
    }

    func testDismissedChipStaysAwayUntilTheTextChanges() {
        var p = SuggestPolicy()
        p.dismiss(chip, on: "$45 for haircut")
        p.observe("$45 for haircut")
        XCTAssertEqual(p.show([chip, link], askedFor: "$45 for haircut", current: "$45 for haircut"), [link])
        p.observe("$45 for haircut!")
        XCTAssertEqual(p.show([chip, link], askedFor: "$45 for haircut!", current: "$45 for haircut!"), [chip, link])
        p.observe("$45 for haircut")
        XCTAssertEqual(p.show([chip], askedFor: "$45 for haircut", current: "$45 for haircut"), [chip])
    }
}

final class ShortcutEngineTests: XCTestCase {
    private let notes = [Note(text: "Prices: cut $45", trigger: ";prices")]
    private func match(_ before: String, actions: [ActionShortcut] = ActionShortcut.defaults) -> ShortcutEngine.Match? {
        ShortcutEngine.match(before: before, notes: notes, actions: actions)
    }

    func testNoteTrigger() {
        XCTAssertEqual(match("hi ;Prices"), .init(delete: 7, action: .insert("Prices: cut $45"), trigger: ";prices"))
    }

    func testLate() {
        XCTAssertEqual(match(";late"), .init(delete: 5, action: .late, trigger: ";late"))
    }

    func testFixTakesTheSpaceBefore() {
        XCTAssertEqual(match("teh cat ;fix"), .init(delete: 5, action: .fix, trigger: ";fix"))
        XCTAssertEqual(match(";fix"), .init(delete: 4, action: .fix, trigger: ";fix"))
    }

    func testPayAmount() {
        XCTAssertEqual(match("ok ;pay $45"), .init(delete: 8, action: .payLink(amount: "45.00", currency: "USD"), trigger: "$45"))
    }

    func testNoMatch() {
        XCTAssertNil(match(";pay"))
        XCTAssertNil(match(";pay abc"))
        XCTAssertNil(match("x"))
        XCTAssertNil(match("hello world"))
        XCTAssertNil(match("abc;late"))
        XCTAssertNil(match(";late ")) // the trigger must be the last word
    }

    func testDisabledActionDoesNothing() {
        var off = ActionShortcut.defaults
        off[1].enabled = false
        XCTAssertNil(match(";late", actions: off))
    }
}

final class AppointmentRulesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func appt(_ startH: Double, _ title: String, client: String? = "Sam Lee", billed: Bool = false) -> Appointment {
        Appointment(start: t0 + startH * 3600, end: t0 + (startH + 1) * 3600, title: title, clientName: client, billed: billed)
    }

    func testToBillPicksTheLatestEndedUnbilledWithAClient() {
        let list = [appt(0, "a"), appt(1, "b"), appt(2, "c", client: nil), appt(5, "later")]
        XCTAssertEqual(AppointmentRules.toBill(list, now: t0 + 4 * 3600, billed: [])?.title, "b")
        XCTAssertEqual(AppointmentRules.toBill(list, now: t0 + 4 * 3600, billed: [list[1].id])?.title, "a")
        XCTAssertNil(AppointmentRules.toBill(list, now: t0 + 0.5 * 3600, billed: []))
        XCTAssertNil(AppointmentRules.toBill([appt(0, "a", billed: true)], now: t0 + 4 * 3600, billed: []))
    }

    func testNextUp() {
        let list = [appt(0, "a"), appt(2, "b"), appt(3, "c")]
        XCTAssertEqual(AppointmentRules.nextUp(list, now: t0 + 1 * 3600)?.title, "b")
        XCTAssertNil(AppointmentRules.nextUp(list, now: t0 + 3 * 3600))
    }
}

final class BarItemsTests: XCTestCase {
    private func state(_ bar: BarState = .idle) -> BarItems.State {
        .init(hasFullAccess: true, paired: true, undo: nil, hasCalmOffer: false, watch: nil, bar: bar,
              copiedAvailable: false, toBill: nil, nextUp: nil)
    }

    func testNoFullAccessIsOneInfoLine() {
        var s = state()
        s.hasFullAccess = false
        XCTAssertEqual(BarItems.build(s).map(\.id), ["info"])
    }

    func testIdleOffersAtMostThree() {
        var s = state()
        s.copiedAvailable = true
        s.hasCalmOffer = true
        s.watch = Watch(id: "INV-1", who: "Sam", money: "$45")
        let a = Appointment(start: .now, end: .now, title: "Cut", clientName: "Sam")
        s.toBill = a
        XCTAssertEqual(BarItems.build(s).map(\.id), ["calm", "waiting", "copied"])
    }

    func testConfirmHasSendAndCancel() {
        let chip = Chip(kind: "invoice", label: "x", payload: ["amount": .string("45.00"), "currency": .string("USD")], needs_confirm: true)
        let items = BarItems.build(state(.confirm(chip, recipient: "sam@example.com")))
        XCTAssertEqual(items.map(\.title), ["Send $45 invoice to sam@example.com?", "Cancel"])
        XCTAssertEqual(items.map(\.action), [.confirm(chip, recipient: "sam@example.com"), .cancelConfirm])
        XCTAssertEqual(items.first?.tone, .accent)
    }

    func testErrorIsDueTone() {
        XCTAssertEqual(BarItems.build(state(.error("No connection"))).first?.tone, .due)
    }
}
