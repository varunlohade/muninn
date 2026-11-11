import XCTest
@testable import Muninn

/// The "Who hasn't paid" list: one card per client, most days late first, and the total in the header.
final class WhoPaidTests: XCTestCase {
    private func payment(_ name: String?, _ amount: String, days: Int, id: String, kind: String = "invoice", currency: String = "USD",
                         state: String = "unpaid", item: String = "Cut", created: String = "2026-11-01T00:00:00Z") -> Payment {
        Payment(kind: kind, id: id, state: state, amount: amount, currency: currency, item: item, client_name: name, link: "https://fake.pay/\(id)",
                created_at: created, days_overdue: days)
    }

    func testTheHeaderAddsUpWhatIsUnpaid() {
        let clients = WhoPaid.clients([payment("Jordan", "120.00", days: 2, id: "A"), payment("Maya", "45.00", days: 0, id: "B"),
                                       payment("Sam", "500.00", days: 0, id: "C", state: "paid")])
        XCTAssertEqual(WhoPaid.header(clients), "$165 unpaid \u{00B7} 2 clients")
        XCTAssertEqual(WhoPaid.header(WhoPaid.clients([payment("Ana", "90.50", days: 1, id: "A")])), "$90.50 unpaid \u{00B7} 1 client")
    }

    func testTheReadyChipAndTheHeaderCountTheSameClients() {
        let clients = WhoPaid.clients([payment("Jordan", "120.00", days: 2, id: "A"), payment("Jordan", "45.00", days: 5, id: "B"),
                                       payment("Maya", "30.00", days: 0, id: "C", kind: "link"), payment("Ana", "10.00", days: 0, id: "D", currency: "EUR"),
                                       payment("Ana", "15.00", days: 1, id: "E"), payment("Sam", "500.00", days: 0, id: "F", state: "paid")])
        let n = WhoPaid.count(clients)
        XCTAssertEqual(n, 3)
        XCTAssertTrue(WhoPaid.header(clients).hasSuffix("\u{00B7} 3 clients"))
        XCTAssertEqual(ReadyChips.build(.init(unpaidCount: n)).first { $0.id == "whopaid" }?.detail, "3 unpaid")
    }

    func testNothingUnpaidSaysEveryoneHasPaid() {
        XCTAssertEqual(WhoPaid.clients([payment("Sam", "45.00", days: 0, id: "A", state: "paid")]), [])
        XCTAssertEqual(WhoPaid.header([]), "Everyone's paid \u{2713}")
    }

    func testTheMostDaysLateComesFirstThenTheLargerAmount() {
        let clients = WhoPaid.clients([payment("Open small", "10.00", days: 0, id: "A"), payment("Late", "20.00", days: 3, id: "B"),
                                       payment("Very late", "5.00", days: 20, id: "C"), payment("Open big", "300.00", days: 0, id: "D")])
        XCTAssertEqual(clients.map(\.name), ["Very late", "Late", "Open big", "Open small"])
        XCTAssertEqual(clients.map(\.veryLate), [true, false, false, false])
        XCTAssertEqual(clients.map(\.late), ["20 days late", "3 days late", "Open", "Open"])
        XCTAssertFalse(WhoPaid.clients([payment("Edge", "5.00", days: WhoPaid.veryLateDays - 1, id: "E")])[0].veryLate)
        XCTAssertEqual(WhoPaid.clients([payment("One", "5.00", days: 1, id: "E")])[0].late, "1 day late")
    }

    func testOneCardPerClientAddsTheirInvoicesAndRemindsTheMostOverdue() {
        let clients = WhoPaid.clients([payment("Jordan", "120.00", days: 2, id: "NEW", item: "Color"), payment("Jordan", "45.00", days: 9, id: "OLD", item: "Cut"),
                                       payment("Maya", "30.00", days: 0, id: "M")])
        XCTAssertEqual(clients.count, 2)
        let jordan = clients[0]
        XCTAssertEqual(jordan.money, "$165")
        XCTAssertEqual(jordan.item, "Cut +1 more")
        XCTAssertEqual(jordan.daysLate, 9)
        XCTAssertEqual(jordan.link, "https://fake.pay/OLD")
        XCTAssertEqual(jordan.remind?.kind, "remind")
        XCTAssertEqual(jordan.remind?.payload["invoice_id"], .string("OLD"))
        XCTAssertEqual(jordan.remind?.payload["client_name"], .string("Jordan"))
        XCTAssertTrue(jordan.remind?.needs_confirm ?? false)
        XCTAssertEqual(BarItems.confirmTitle(jordan.remind!, recipient: BarItems.recipient(jordan.remind!)), "Remind Jordan about $45?")
        XCTAssertEqual(WhoPaid.header(clients), "$195 unpaid \u{00B7} 2 clients")
    }

    func testAPayLinkHasNoReminderAndCurrenciesStayApart() {
        let clients = WhoPaid.clients([payment("Ava", "35.00", days: 0, id: "ORDER-1", kind: "order"), payment(nil, "12.00", days: 0, id: "ORDER-2", kind: "order", item: "Blowout"),
                                       payment("Ava", "20.00", days: 4, id: "INV-E", currency: "EUR")])
        XCTAssertEqual(clients.map(\.name), ["Ava", "Ava", "Blowout"])
        XCTAssertEqual(clients.map(\.money), ["€20", "$35", "$12"])
        XCTAssertNotNil(clients[0].remind)
        XCTAssertNil(clients[1].remind, "only an invoice can be reminded")
        XCTAssertNil(clients[2].remind)
        XCTAssertEqual(WhoPaid.header(clients), "€20 + $47 unpaid \u{00B7} 2 clients")
    }

    func testAReloadKeepsTheKeyOfAReminderForTheSameInvoice() {
        let first = WhoPaid.clients([payment("Jordan", "120.00", days: 2, id: "INV-J")])
        let again = WhoPaid.clients([payment("Jordan", "120.00", days: 3, id: "INV-J"), payment("Maya", "45.00", days: 0, id: "INV-M")], keeping: first)
        XCTAssertEqual(again[0].remind?.key, first[0].remind?.key)
        XCTAssertNotEqual(again[1].remind?.key, first[0].remind?.key)
        XCTAssertNotEqual(WhoPaid.clients([payment("Jordan", "120.00", days: 2, id: "INV-J")])[0].remind?.key, first[0].remind?.key, "a new list is a new chip")
    }
}
