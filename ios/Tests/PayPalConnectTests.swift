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

    func testReturnLinkCode() {
        XCTAssertEqual(PayPalConnector.code(of: URL(string: "muninn://paypal-connected?code=ab12")!), "ab12")
        XCTAssertNil(PayPalConnector.code(of: URL(string: "muninn://paypal-connected?result=failed")!))
        XCTAssertNil(PayPalConnector.code(of: URL(string: "muninn://paypal-connected?code=")!))
    }

    func testDisconnectSaysToRevokeInPayPal() {
        XCTAssertTrue(PayPalConnector.disconnectNote.hasSuffix("To fully remove access, also revoke Muninn in your PayPal settings."))
    }

    func testResultLines() {
        XCTAssertNil(PayPalConnector.line(for: "connected"))
        XCTAssertEqual(PayPalConnector.line(for: "taken"), "That PayPal account is already connected to another Muninn account.")
        XCTAssertEqual(PayPalConnector.line(for: "declined"), "PayPal was not connected. Allow the permissions on PayPal to connect.")
        XCTAssertEqual(PayPalConnector.line(for: "anything"), "PayPal did not finish. Try again.")
    }

    func testConnectReadyComesFromTheServerAndAnOlderServerLeavesItOut() throws {
        let off = try status(#"{"connected":false,"demo":true,"connect_ready":false,"pending":false,"email_confirmed":false,"payments_receivable":false,"account":null}"#)
        XCTAssertEqual(off.connect_ready, false)
        let old = try status(#"{"connected":false,"demo":true,"pending":false,"email_confirmed":false,"payments_receivable":false,"account":null}"#)
        XCTAssertNil(old.connect_ready)
        XCTAssertEqual(PayPalConnector.offLine, "Your own PayPal is not open yet. Money runs on the demo PayPal sandbox account.")
        XCTAssertEqual(PayPalConnector.sandboxURL.absoluteString, "https://www.sandbox.paypal.com")
    }

    @MainActor
    func testSplashEndsWhenReadyOrAtTheCap() async {
        var slept: [Duration] = []
        var ready = false
        await Splash.wait(sleep: { slept.append($0); if slept.count == 3 { ready = true } }) { ready }
        XCTAssertEqual(slept.count, 3, "ends as soon as the data is in")
        slept = []
        await Splash.wait(sleep: { slept.append($0) }) { false }
        XCTAssertEqual(slept.reduce(.zero, +), Splash.cap, "never waits past the cap")
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
