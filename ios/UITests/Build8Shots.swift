import XCTest

/// Build 8 shots against `npm run fake`: the launch splash, the PayPal row when Connect is not open, and "send $20 to Ritika".
/// Run with TEST_RUNNER_FAKE_URL=http://127.0.0.1:<port> TEST_RUNNER_SHOT_DIR=<dir>, tests in name order.
final class Build8Shots: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() { continueAfterFailure = false }

    private var fake: URL { URL(string: env["FAKE_URL"] ?? "http://127.0.0.1:8799")! }

    private func shot(_ name: String, wait: TimeInterval = 0.8) {
        Thread.sleep(forTimeInterval: wait)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = env["SHOT_DIR"] { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")) }
    }

    private func id(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
    }

    private func launchPaired() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-serverURL", fake.absoluteString]
        app.launch()
        if !id(app, "nav.integrations").waitForExistence(timeout: 8) {
            XCUIDevice.shared.system.open(URL(string: "muninn-dev://pair?token=pkd_fake&server=\(fake.absoluteString)")!)
            let open = springboard.buttons["Open"]
            if open.waitForExistence(timeout: 5) { open.tap() }
        }
        XCTAssertTrue(id(app, "nav.integrations").waitForExistence(timeout: 15), "Home did not load")
        return app
    }

    func test01Splash() {
        _ = launchPaired()
        let app = XCUIApplication()
        app.terminate()
        // XCUITest's launch waits for the app to go idle, so the splash is usually gone by then. The still comes from a simctl burst.
        app.launch()
        XCTAssertTrue(id(app, "nav.integrations").waitForExistence(timeout: 6), "Home shows after the splash")
        shot("02-home-after-splash")
    }

    func test02ConnectNotOpen() {
        let app = launchPaired()
        shot("03-home-no-connect-card")
        id(app, "nav.integrations").tap()
        shot("04-settings-paypal-row", wait: 2)
        XCTAssertTrue(app.staticTexts["Your own PayPal is not open yet. Money runs on the demo PayPal sandbox account."].exists, app.debugDescription)
        XCTAssertFalse(id(app, "paypal.connect").exists, "no Connect button the server cannot honor")
    }

    func test03SendMoney() {
        let app = launchPaired()
        let field = id(app, "ask.field")
        field.tap()
        field.typeText("send $20 to Ritika\n")
        let chip = id(app, "ask.chip.payout")
        XCTAssertTrue(chip.waitForExistence(timeout: 8))
        shot("05-send-chip")
        chip.tap()
        let to = id(app, "ask.recipient")
        XCTAssertTrue(to.waitForExistence(timeout: 5))
        to.tap()
        to.typeText("ritika@example.com")
        shot("06-send-type-email")
        id(app, "ask.recipient.use").tap()
        XCTAssertTrue(id(app, "ask.confirm").waitForExistence(timeout: 5))
        shot("07-send-confirm")
        id(app, "ask.confirm").tap()
        XCTAssertTrue(id(app, "ask.undo").waitForExistence(timeout: 8))
        shot("08-send-done")
    }
}
