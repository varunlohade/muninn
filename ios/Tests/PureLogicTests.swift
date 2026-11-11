import XCTest
@testable import Muninn

final class ShortcutsAmountTests: XCTestCase {
    private func check(_ word: String, _ value: String, _ currency: String?, line: UInt = #line) {
        let r = Shortcuts.amount(word)
        XCTAssertEqual(r?.value, value, word, line: line)
        XCTAssertEqual(r?.currency, currency, word, line: line)
    }

    func testPlainWholeNumber() { check("45", "45.00", nil) }
    func testDollarSign() { check("$45", "45.00", "USD") }
    func testEuroWithCents() { check("€12.05", "12.05", "EUR") }
    func testPoundUnderOne() { check("£0.50", "0.50", "GBP") }
    func testOneCentDigitPads() { check("45.5", "45.50", nil) }
    func testLeadingZerosDrop() { check("007", "7.00", nil) }
    func testFiveDigitsIsMax() { check("99999", "99999.00", nil) }

    func testNotAmounts() {
        for word in ["", "$", "0", "0.00", "$0", "45.", ".5", "45.505", "123456", "1.2.3",
                     "abc", "4a", "¥45", "45$", "-5", "١٢", "4 5"] {
            XCTAssertNil(Shortcuts.amount(word), word)
        }
    }
}

final class ShortcutsProblemTests: XCTestCase {
    func testTooShort() {
        XCTAssertEqual(Shortcuts.problem(";", taken: []), "Use 2 characters or more.")
    }

    func testTooLong() {
        XCTAssertEqual(Shortcuts.problem(String(repeating: "a", count: 21), taken: []), "Use 20 characters or fewer.")
    }

    func testLimitsAreInclusive() {
        XCTAssertNil(Shortcuts.problem(";p", taken: []))
        XCTAssertNil(Shortcuts.problem(String(repeating: "a", count: 20), taken: []))
    }

    func testTaken() {
        XCTAssertEqual(Shortcuts.problem(";pay", taken: [";pay", ";late"]), "Another shortcut uses ;pay.")
    }

    func testFree() {
        XCTAssertNil(Shortcuts.problem(";tip", taken: [";pay", ";late"]))
    }
}

@MainActor
final class LateLineTests: XCTestCase {
    private func payment(_ name: String?, _ amount: String, _ currency: String = "USD", days: Int,
                         kind: String = "invoice", state: String = "unpaid") -> Payment {
        Payment(kind: kind, id: UUID().uuidString, state: state, amount: amount, currency: currency, item: "work",
                client_name: name, link: nil, created_at: "2026-11-01T00:00:00Z", days_overdue: days)
    }

    func testNobody() {
        XCTAssertEqual(KeyboardModel.lateLine([]), "Nobody owes you \u{2713}")
    }

    func testPaidAndPayLinksDoNotCount() {
        let list = [payment("Ana", "90.00", days: 3, state: "paid"),
                    payment("Sam", "45.00", days: 3, kind: "paylink")]
        XCTAssertEqual(KeyboardModel.lateLine(list), "Nobody owes you \u{2713}")
    }

    func testOneLate() {
        XCTAssertEqual(KeyboardModel.lateLine([payment("Ana", "90.00", days: 2)]), "Ana $90 \u{00B7} 2d late")
    }

    func testNotYetLateHasNoDays() {
        XCTAssertEqual(KeyboardModel.lateLine([payment("Sam", "45.50", days: 0)]), "Sam $45.50")
    }

    func testMissingNameSaysClient() {
        XCTAssertEqual(KeyboardModel.lateLine([payment(nil, "12.00", "EUR", days: 0)]), "Client €12")
    }

    func testMostLateFirstThenMore() {
        let list = [payment("Sam", "45.00", days: 0), payment("Ana", "90.00", days: 2),
                    payment("Bo", "10.00", days: 5), payment("Cy", "20.00", days: 1)]
        XCTAssertEqual(KeyboardModel.lateLine(list), "Bo $10 \u{00B7} 5d late, Ana $90 \u{00B7} 2d late +2 more")
    }

    func testTwoHaveNoMore() {
        let list = [payment("Ana", "90.00", days: 2), payment("Sam", "45.00", days: 0)]
        XCTAssertEqual(KeyboardModel.lateLine(list), "Ana $90 \u{00B7} 2d late, Sam $45")
    }
}

final class SuggestionBarTextTests: XCTestCase {
    private func chip(_ kind: String, _ payload: [String: String], label: String = "label") -> Chip {
        Chip(kind: kind, label: label, payload: payload.mapValues { .string($0) }, needs_confirm: false)
    }

    func testOtherKindsUseLabel() {
        XCTAssertEqual(BarItems.title(chip("tone", ["amount": "45.00"], label: "Calm reply")), "Calm reply")
    }

    func testInvoiceTitle() {
        let c = chip("invoice", ["amount": "90.00", "currency": "USD", "item": "logo design"])
        XCTAssertEqual(BarItems.title(c), "Invoice $90 logo design")
    }

    func testPayLinkWithoutCurrencyShowsBareAmount() {
        XCTAssertEqual(BarItems.title(chip("paylink", ["amount": "45.00"])), "Pay link 45")
    }

    func testPayLinkWithNothing() {
        XCTAssertEqual(BarItems.title(chip("paylink", [:])), "Pay link")
        XCTAssertEqual(BarItems.title(chip("paylink", ["amount": "", "item": ""])), "Pay link")
    }

    func testInvoiceDetailPrefersEmail() {
        let c = chip("invoice", ["client_email": "ana@example.com", "client_name": "Ana"])
        XCTAssertEqual(BarItems.detail(c, fromCopied: false), "→ ana@example.com")
    }

    func testInvoiceDetailFallsBackToName() {
        XCTAssertEqual(BarItems.detail(chip("invoice", ["client_name": "Ana"]), fromCopied: false), "→ Ana")
    }

    func testInvoiceDetailFromCopied() {
        let c = chip("invoice", ["client_email": "ana@example.com"])
        XCTAssertEqual(BarItems.detail(c, fromCopied: true), "→ ana@example.com · from copied message")
    }

    func testInvoiceWithNoRecipientAndNotCopied() {
        XCTAssertNil(BarItems.detail(chip("invoice", [:]), fromCopied: false))
    }

    func testPayLinkDetailIgnoresRecipient() {
        let c = chip("paylink", ["client_email": "ana@example.com"])
        XCTAssertNil(BarItems.detail(c, fromCopied: false))
        XCTAssertEqual(BarItems.detail(c, fromCopied: true), "from copied message")
    }
}

final class FormatMoneyTests: XCTestCase {
    func testKnownSymbols() {
        XCTAssertEqual(formatMoney("45.00", "USD"), "$45")
        XCTAssertEqual(formatMoney("45.50", "USD"), "$45.50")
        XCTAssertEqual(formatMoney("12.00", "EUR"), "€12")
        XCTAssertEqual(formatMoney("7.25", "GBP"), "£7.25")
        XCTAssertEqual(formatMoney("10.00", "CAD"), "CA$10")
        XCTAssertEqual(formatMoney("5.00", "AUD"), "A$5")
    }

    func testUnknownCurrencyUsesCode() {
        XCTAssertEqual(formatMoney("100.00", "JPY"), "JPY 100")
    }

    func testOnlyWholeZeroCentsDrop() {
        XCTAssertEqual(formatMoney("45.10", "USD"), "$45.10")
        XCTAssertEqual(formatMoney("45", "USD"), "$45")
    }

    func testAppleLinkAnswerDecodesAndSaysWelcomeBackOnlyForAnEarlierAccount() throws {
        let fresh = try JSONDecoder().decode(AppleLinkResponse.self, from: Data(#"{"linked":true,"recovered":false}"#.utf8))
        XCTAssertEqual(fresh, AppleLinkResponse(linked: true, recovered: false, device_token: nil))
        XCTAssertTrue(Session.linkNotice(fresh).hasPrefix("Saved"))
        let back = try JSONDecoder().decode(AppleLinkResponse.self, from: Data(#"{"linked":true,"recovered":true,"device_token":"pkd_earlier_account_token_0001"}"#.utf8))
        XCTAssertEqual(back.device_token, "pkd_earlier_account_token_0001")
        XCTAssertTrue(Session.linkNotice(back).hasPrefix("Welcome back"))
    }
}
