import XCTest
@testable import Muninn

final class PayPalConnectTests: XCTestCase {
    private func status(_ json: String) throws -> PayPalStatus {
        try JSONDecoder().decode(PayPalStatus.self, from: Data(json.utf8))
    }

    func testReturnLinkResult() {
        XCTAssertEqual(PayPalConnector.result(of: URL(string: "muninn://paypal-connected?result=connected")!), "connected")
        XCTAssertEqual(PayPalConnector.result(of: URL(string: "muninn://paypal-connected?result=taken")!), "taken")
        XCTAssertEqual(PayPalConnector.result(of: URL(string: "muninn://paypal-connected")!), "failed")
    }

    func testResultLines() {
        XCTAssertNil(PayPalConnector.line(for: "connected"))
        XCTAssertEqual(PayPalConnector.line(for: "taken"), "That PayPal account is already connected to another Muninn account.")
        XCTAssertEqual(PayPalConnector.line(for: "declined"), "PayPal was not connected. Allow the permissions on PayPal to connect.")
        XCTAssertEqual(PayPalConnector.line(for: "anything"), "PayPal did not finish. Try again.")
    }

    func testSummaryDemoAndConnected() throws {
        XCTAssertEqual(PayPalConnector.summary(nil), "Demo PayPal (sandbox)")
        let demo = try status(#"{"connected":false,"demo":true,"pending":false,"email_confirmed":false,"payments_receivable":false,"account":null}"#)
        XCTAssertEqual(PayPalConnector.summary(demo), "Demo PayPal (sandbox)")
        let on = try status(#"{"connected":true,"demo":false,"pending":false,"email_confirmed":true,"payments_receivable":true,"account":"s•••@shop.test"}"#)
        XCTAssertEqual(PayPalConnector.summary(on), "PayPal connected \u{00B7} s•••@shop.test")
        let unconfirmed = try status(#"{"connected":true,"demo":false,"pending":false,"email_confirmed":false,"payments_receivable":false,"account":"•••2345"}"#)
        XCTAssertEqual(PayPalConnector.summary(unconfirmed), "PayPal connected \u{00B7} •••2345. Confirm your PayPal email to get paid.")
    }
}
