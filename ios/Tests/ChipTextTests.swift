import XCTest
@testable import Muninn

final class ChipTextTests: XCTestCase {
    private let link = "https://fake.pay/INV-1"

    func testCommandsToMuninn() {
        for s in ["invoice sam $45", "invoice sam $45 for the haircut", "Invoice Sam 45", "send invoice to sam for $45",
                  "pay link $45 haircut", "make a pay link for 50", "bill ana $40", "create invoice for sam",
                  "Send a payment link for $30", "paylink 50", "charge sam $45", "please invoice ana $90",
                  "request $45 from sam", "invoice for sam", "Make me an invoice for 80"] {
            XCTAssertTrue(ChipText.isCommand(s), s)
        }
    }

    func testChatToTheClient() {
        for s in ["done with the 2 screens, that's $50", "$45 for the haircut", "can you pay $45 for the haircut",
                  "That is $45 for the haircut, sam@example.com", "Thanks Sam", "the invoice is attached",
                  "bill was $40 last time", "invoice sent, thanks!", "Here you go", "I'll send the invoice tonight",
                  "the pay link is below", "bill for the haircut is $45", "Total comes to 120 dollars"] {
            XCTAssertFalse(ChipText.isCommand(s), s)
        }
    }

    func testClientMessage() {
        XCTAssertEqual(ChipText.clientMessage(kind: "invoice", who: "Sam", item: "haircut", money: "$45", link: link),
                       "Hi Sam, here's the invoice for the haircut ($45): \(link)")
        XCTAssertEqual(ChipText.clientMessage(kind: "paylink", who: "Client", item: "Payment", money: "$50", link: link),
                       "Hi, here's the payment link ($50): \(link)")
        XCTAssertEqual(ChipText.clientMessage(kind: "paylink", who: "Client", item: "SEO audit", money: "", link: link),
                       "Hi, here's the payment link for the SEO audit: \(link)")
    }

    private func edit(_ before: String, kind: String = "invoice") -> ChipText.Edit {
        ChipText.edit(before: before, kind: kind, who: "Sam", item: "Haircut", money: "$45", link: link, gap: kind == "invoice" ? "\n" : " ")
    }

    func testCommandSentenceIsReplacedByExactCount() {
        let message = "Hi Sam, here's the invoice for the haircut ($45): \(link)"
        XCTAssertEqual(edit("invoice sam $45 for the haircut"), .init(delete: 31, insert: message, fallback: message))
        // The trailing space goes too; the earlier sentence stays.
        XCTAssertEqual(edit("See you Friday. invoice sam $45 "), .init(delete: 16, insert: message, fallback: message))
        XCTAssertEqual(edit("Great work today\ninvoice sam $45"), .init(delete: 15, insert: message, fallback: message))
    }

    func testChatKeepsTheTextAndAddsTheLink() {
        XCTAssertEqual(edit("$45 for the haircut"), .init(delete: 0, insert: "\n" + link, fallback: link))
        XCTAssertEqual(edit("done with the 2 screens, that's $50", kind: "paylink"), .init(delete: 0, insert: " " + link, fallback: link))
        XCTAssertEqual(edit("Here you go ", kind: "paylink"), .init(delete: 0, insert: link, fallback: link))
        XCTAssertEqual(edit("Pay here \(link)", kind: "paylink"), .init(delete: 0, insert: "", fallback: link), "no second link")
    }
}
