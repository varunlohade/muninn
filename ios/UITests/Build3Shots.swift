import XCTest

/// Pictures of what build 3 adds, against `npm run fake`. No model call, no PayPal call.
/// Set the look first (`xcrun simctl ui <sim> appearance dark`), then run with
/// TEST_RUNNER_FAKE_URL=http://127.0.0.1:<port> TEST_RUNNER_SHOT_DIR=<dir> TEST_RUNNER_SHOT_PREFIX=dark-
final class Build3Shots: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() { continueAfterFailure = false }

    private var fake: String { env["FAKE_URL"] ?? "http://127.0.0.1:8799" }

    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let file = (env["SHOT_PREFIX"] ?? "") + name + ".png"
        if let dir = env["SHOT_DIR"] { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(file)) }
    }

    private func id(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
    }

    private func dismissPrompts(_ app: XCUIApplication) {
        for a in [app, springboard] where a.buttons["Not Now"].waitForExistence(timeout: 2) { a.buttons["Not Now"].tap() }
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

    /// The hero, then the keyboard step, Get started and Home. Needs a fresh app (reset the simulator keychain).
    func testIntro() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-calendarDemo", "-serverURL", fake, "-intro_seen", "NO"]
        app.launch()
        try XCTSkipUnless(id(app, "onboarding.add").waitForExistence(timeout: 8), "already signed in; reset the simulator keychain first")
        XCTAssertTrue(id(app, "onboarding.hero").exists)
        XCTAssertTrue(id(app, "onboarding.account").exists)
        shot("intro-01-hero")
        id(app, "onboarding.add").tap()
        if id(app, "onboarding.step.2").waitForExistence(timeout: 5) {
            shot("intro-09-turn-on-keyboard")
            id(app, "onboarding.later").tap()
        }
        if id(app, "onboarding.calendar.later").waitForExistence(timeout: 3) {
            shot("intro-09b-allow-calendar")
            id(app, "onboarding.calendar.later").tap()
        }
        let start = id(app, "onboarding.start")
        XCTAssertTrue(start.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Apple")).firstMatch.exists, "there is no sign-in")
        shot("intro-10-get-started")
        // One tap makes the device account on the fake server. Nothing to type.
        start.tap()
        if id(app, "onboarding.paypal.demo").waitForExistence(timeout: 10) { id(app, "onboarding.paypal.demo").tap() }
        XCTAssertTrue(id(app, "home.earned").waitForExistence(timeout: 20), app.debugDescription)
        dismissPrompts(app)
        shot("intro-11-home")
    }

    /// "Add the keyboard" ends the hero. Get started with no server shows one plain line and stays.
    func testIntroPlaysByItselfAndSkipEndsIt() throws {
        let app = XCUIApplication()
        // No server at this address: Get started shows one plain line and stays, ready for another try.
        app.launchArguments = ["-serverURL", "http://127.0.0.1:9", "-intro_seen", "NO"]
        app.launch()
        XCTAssertTrue(id(app, "onboarding.add").waitForExistence(timeout: 8))
        id(app, "onboarding.add").tap()
        if id(app, "onboarding.later").waitForExistence(timeout: 3) { id(app, "onboarding.later").tap() }
        if id(app, "onboarding.calendar.later").waitForExistence(timeout: 3) { id(app, "onboarding.calendar.later").tap() }
        XCTAssertTrue(id(app, "onboarding.start").waitForExistence(timeout: 5), "Add the keyboard did not end the hero")
        id(app, "onboarding.start").tap()
        let error = id(app, "onboarding.error")
        XCTAssertTrue(error.waitForExistence(timeout: 30), app.debugDescription)
        print("START_ERROR", error.label)
        XCTAssertTrue(id(app, "onboarding.start").isHittable, "the button stays for a retry")
        shot("intro-get-started-error")

        // A relaunch in the middle, as iOS does when the keyboard is turned on, goes on after the intro.
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(id(app, "onboarding.start").waitForExistence(timeout: 8) || id(app, "onboarding.later").exists || id(app, "onboarding.calendar.later").exists, "the intro played again after a relaunch")
        XCTAssertFalse(id(app, "onboarding.add").exists)
    }

    /// The new app screens: Home's unpaid cards, the Contacts choice on an invoice with no email, Integrations and its two settings.
    func testScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["-calendarDemo"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["home.earned"].waitForExistence(timeout: 15), "sign in first: \(app.debugDescription)")
        dismissPrompts(app)
        // "Save your details" sits under the day summary. It is Apple's own button; sign-in itself cannot run on the simulator.
        XCTAssertTrue(id(app, "save.card").waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(id(app, "save.apple").exists)
        shot("home-save-details-card")
        let unpaid = id(app, "unpaid.header")
        for _ in 0..<4 where !(unpaid.exists && unpaid.isHittable) { app.swipeUp() }
        XCTAssertTrue(unpaid.exists, app.debugDescription)
        print("UNPAID_HEADER", unpaid.label)
        shot("home-unpaid")
        app.swipeDown(); app.swipeDown(); app.swipeDown()

        let ask = id(app, "ask.field")
        ask.tap()
        setNext(#"{"group":{"group":"money"},"route":{"route":"invoice"},"ext":{"client_name":null,"client_email":null,"amount":45,"currency":"USD","item":"haircut"}}"#)
        ask.typeText("invoice $45 for a haircut\n")
        let chip = id(app, "ask.chip.invoice")
        XCTAssertTrue(chip.waitForExistence(timeout: 10), app.debugDescription)
        chip.tap()
        let contacts = id(app, "ask.contacts")
        XCTAssertTrue(contacts.waitForExistence(timeout: 5), app.debugDescription)
        print("CONFIRM_LABEL", id(app, "ask.confirm").label)
        shot("contacts-1-invoice-confirm-no-email")
        contacts.tap()
        let kate = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Kate Bell")).firstMatch
        XCTAssertTrue(kate.waitForExistence(timeout: 8), app.debugDescription)
        shot("contacts-2-picker")
        kate.tap()
        let confirm = id(app, "ask.confirm")
        let picked = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'ask.confirm' AND label BEGINSWITH %@", "Send $45 invoice to ")).firstMatch
        if !picked.waitForExistence(timeout: 4) {
            // A contact with more than one email opens its card, and the owner picks the address there.
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "@")).firstMatch.tap()
        }
        XCTAssertTrue(picked.waitForExistence(timeout: 8), app.debugDescription)
        print("CONFIRM_AFTER_PICK", confirm.label)
        XCTAssertFalse(id(app, "ask.contacts").exists)
        shot("contacts-3-confirm-with-picked-email")
        // Never send from a picture run: cancel.
        app.buttons["Cancel"].tap()
        if app.keyboards.buttons["Return"].exists { app.keyboards.buttons["Return"].tap() }

        id(app, "nav.integrations").tap()
        XCTAssertTrue(id(app, "integration.paypal").waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Stripe"].exists)
        XCTAssertFalse(app.staticTexts["Square"].exists)
        shot("integrations")
        app.swipeUp()
        XCTAssertTrue(id(app, "integration.apple").waitForExistence(timeout: 3), app.debugDescription)
        shot("integrations-save-details")
        app.swipeDown()

        id(app, "integration.google_reviews").tap()
        let link = id(app, "review.link")
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        shot("review-1-empty")
        link.tap()
        link.typeText("https://example.com/review")
        id(app, "review.save").tap()
        XCTAssertTrue(id(app, "review.note").waitForExistence(timeout: 5))
        print("REVIEW_BAD", id(app, "review.note").label)
        shot("review-2-wrong-link")
        link.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + "https://g.page/r/CdemoShop123/review")
        id(app, "review.save").tap()
        let askReview = id(app, "review.ask")
        XCTAssertTrue(askReview.waitForExistence(timeout: 5), app.debugDescription)
        shot("review-3-saved")
        setNext(#"{"group":{"group":"writing"},"route":{"route":"review_ask"}}"#)
        askReview.tap()
        let message = id(app, "review.message")
        XCTAssertTrue(message.waitForExistence(timeout: 8), app.debugDescription)
        print("REVIEW_MESSAGE", message.label)
        XCTAssertTrue(message.label.contains("https://g.page/r/CdemoShop123/review"))
        shot("review-4-ask-chip-message")
        app.navigationBars.buttons.firstMatch.tap()

        XCTAssertTrue(id(app, "integration.slack").waitForExistence(timeout: 5))
        id(app, "integration.slack").tap()
        let hook = id(app, "slack.link")
        XCTAssertTrue(hook.waitForExistence(timeout: 5))
        shot("slack-1-empty")
        hook.tap()
        hook.typeText("https://hooks.slack.com/services/T00000000/B00000000/fakeSecretForTheFakeServer")
        id(app, "slack.save").tap()
        XCTAssertTrue(id(app, "slack.disconnect").waitForExistence(timeout: 5), app.debugDescription)
        print("SLACK_NOTE", id(app, "slack.note").label)
        shot("slack-2-connected")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(id(app, "integration.slack").waitForExistence(timeout: 5))
        shot("integrations-connected")
        // Leave the fake server as it was for the next run.
        id(app, "integration.slack").tap()
        id(app, "slack.disconnect").tap()
        app.navigationBars.buttons.firstMatch.tap()
        id(app, "integration.google_reviews").tap()
        XCTAssertTrue(id(app, "review.remove").waitForExistence(timeout: 5))
        id(app, "review.remove").tap()
    }
}
