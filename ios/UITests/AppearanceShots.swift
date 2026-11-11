import XCTest

/// Every main app screen against `npm run fake`, for a light and dark check. No model call, no PayPal call.
/// Set the look first (`xcrun simctl ui <sim> appearance light`), reset the keychain, then run with
/// TEST_RUNNER_FAKE_URL=http://127.0.0.1:<port> TEST_RUNNER_SHOT_DIR=<dir> TEST_RUNNER_SHOT_PREFIX=light-
final class AppearanceShots: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() { continueAfterFailure = false }

    private var fake: String { env["FAKE_URL"] ?? "http://127.0.0.1:8799" }

    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 0.8)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let file = (env["SHOT_PREFIX"] ?? "") + name + ".png"
        if let dir = env["SHOT_DIR"] { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(file)) }
    }

    private func id(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
    }

    private func back(_ app: XCUIApplication) {
        let button = app.navigationBars.buttons.firstMatch
        if button.waitForExistence(timeout: 2) {
            button.tap()
        } else {
            // The zoom transition hides the bar on small phones; swipe back from the left edge.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        }
        Thread.sleep(forTimeInterval: 0.8)
    }

    /// The password and calendar prompts from iOS.
    private func dismissPrompts(_ app: XCUIApplication) {
        for a in [app, springboard] where a.buttons["Not Now"].waitForExistence(timeout: 3) { a.buttons["Not Now"].tap() }
    }

    private func setNext(_ json: String) {
        var r = URLRequest(url: URL(string: fake + "/_next")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(json.utf8)
        let done = expectation(description: "next")
        URLSession.shared.dataTask(with: r) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 5)
    }

    func testScreens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-calendarDemo", "-intro_seen", "NO"]
        app.launch()
        try XCTSkipUnless(id(app, "onboarding.skip").waitForExistence(timeout: 8), "already in; reset the simulator keychain first")
        id(app, "onboarding.skip").tap()
        if id(app, "onboarding.step.2").waitForExistence(timeout: 4) {
            shot("03-onboarding-keyboard")
            id(app, "onboarding.later").tap()
        }
        if id(app, "onboarding.calendar.later").waitForExistence(timeout: 3) { id(app, "onboarding.calendar.later").tap() }
        let mark = id(app, "onboarding.mark")
        XCTAssertTrue(id(app, "onboarding.start").waitForExistence(timeout: 8), app.debugDescription)
        shot("01-onboarding-get-started")

        mark.press(forDuration: 1.3)
        let token = app.secureTextFields["token"]
        XCTAssertTrue(token.waitForExistence(timeout: 5))
        let server = app.textFields.firstMatch
        server.tap()
        server.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 60) + fake)
        token.tap()
        token.typeText("pkd_fake")
        shot("02-onboarding-dev-pairing")
        app.buttons["Pair"].tap()
        dismissPrompts(app)

        XCTAssertTrue(app.staticTexts["Earned today"].waitForExistence(timeout: 15), app.debugDescription)
        dismissPrompts(app)
        _ = id(app, "home.brief").waitForExistence(timeout: 10)
        shot("05-home")
        app.swipeUp()
        shot("06-home-lower")
        app.swipeDown()
        app.swipeDown()

        let ask = id(app, "ask.field")
        XCTAssertTrue(ask.waitForExistence(timeout: 5))
        ask.tap()
        setNext(#"{"group":{"group":"info"},"route":{"route":"who_paid"}}"#)
        ask.typeText("who hasn't paid\n")
        _ = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Jordan Ray")).firstMatch.waitForExistence(timeout: 10)
        shot("07-ask-bar")
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }

        id(app, "nav.shortcuts").tap()
        _ = id(app, "shortcuts.new").waitForExistence(timeout: 5)
        shot("08-shortcuts")
        back(app)

        id(app, "nav.notes").tap()
        _ = id(app, "notes.new").waitForExistence(timeout: 5)
        shot("09-notes")
        back(app)

        let folder = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "folder.")).firstMatch
        // Scroll the folders clear of the Ask bar first; on a small phone they start under it.
        app.swipeUp()
        XCTAssertTrue(folder.waitForExistence(timeout: 5), app.debugDescription)
        folder.tap()
        Thread.sleep(forTimeInterval: 1)
        shot("10-client-detail")
        back(app)
        app.swipeDown()

        id(app, "nav.integrations").tap()
        XCTAssertTrue(id(app, "integration.paypal").waitForExistence(timeout: 10))
        shot("11-integrations")
        let lab = app.buttons["Keyboard Lab (debug)"]
        if !lab.isHittable { app.swipeUp() }
        lab.tap()
        shot("12-keyboard-lab")
    }
    /// Apple's keyboard and ours in the same empty Messages search field, for a pixel diff of the keys.
    func testKeyboardMatch() {
        let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        messages.launch()
        let search = messages.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8), messages.debugDescription)
        search.tap()
        let ours = id(messages, "muninn.more")
        // Apple's globe says "Next keyboard"; ours (on phones with a Home button) is the "globe" key.
        let next = messages.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] %@ OR identifier == %@", "Next keyboard", "globe")).firstMatch
        // Apple's English keyboard first: its letter keys have no k. identifiers.
        for title in ["Continue", "OK"] where messages.buttons[title].waitForExistence(timeout: 1) { messages.buttons[title].tap() }
        let appleQ = messages.keys.matching(NSPredicate(format: "label ==[c] %@", "q")).firstMatch
        for _ in 0..<5 where ours.waitForExistence(timeout: 1.5) || !appleQ.exists { next.tap() }
        XCTAssertTrue(appleQ.waitForExistence(timeout: 3), messages.debugDescription)
        Thread.sleep(forTimeInterval: 1)
        shot("kb-apple")
        for _ in 0..<5 where !ours.waitForExistence(timeout: 1.5) {
            // iOS shows a one-time tip ("Quickly Change Keyboards") over the keys after the first switch.
            for title in ["Continue", "OK"] where messages.buttons[title].exists { messages.buttons[title].tap() }
            next.tap()
        }
        XCTAssertTrue(ours.exists, messages.debugDescription)
        Thread.sleep(forTimeInterval: 1)
        shot("kb-muninn")
    }
    /// Release check: a fresh install ends the intro at Get started. Holding the mark opens nothing.
    func testReleaseHasNoDeveloperPairing() {
        let app = XCUIApplication()
        app.launchArguments = ["-intro_seen", "NO"]
        app.launch()
        XCTAssertTrue(id(app, "onboarding.skip").waitForExistence(timeout: 10))
        id(app, "onboarding.skip").tap()
        if id(app, "onboarding.later").waitForExistence(timeout: 4) { id(app, "onboarding.later").tap() }
        if id(app, "onboarding.calendar.later").waitForExistence(timeout: 3) { id(app, "onboarding.calendar.later").tap() }
        let mark = id(app, "onboarding.mark")
        XCTAssertTrue(mark.waitForExistence(timeout: 10))
        shot("01-onboarding-get-started")
        mark.press(forDuration: 2)
        Thread.sleep(forTimeInterval: 1)
        shot("02-after-holding-mark")
        XCTAssertFalse(app.secureTextFields["token"].exists, "developer pairing opened in this build")
        XCTAssertFalse(app.staticTexts["Developer pairing"].exists)
        XCTAssertTrue(id(app, "onboarding.start").exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Apple")).firstMatch.exists)
    }
}
