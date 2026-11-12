import XCTest

/// The PayPal actions of docs/PAYPAL-COVERAGE.md in the real keyboard and app, against `npm run fake` (no model, no PayPal).
/// Run with TEST_RUNNER_FAKE_URL=http://127.0.0.1:<port> TEST_RUNNER_SHOT_DIR=<dir>, tests in name order.
final class PayPalShots: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")

    override func setUp() { continueAfterFailure = false }

    private var fake: URL { URL(string: env["FAKE_URL"] ?? "http://127.0.0.1:8799")! }

    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 0.8)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = env["SHOT_DIR"] { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")) }
    }

    private func id(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
    }

    private func label(_ app: XCUIApplication, _ format: String, _ arg: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: format, arg)).firstMatch
    }

    @discardableResult
    private func fakeCall(_ method: String, _ path: String, _ json: String? = nil) -> Data {
        var r = URLRequest(url: fake.appendingPathComponent(path))
        r.httpMethod = method
        if let json { r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = Data(json.utf8) }
        var out = Data()
        let done = expectation(description: path)
        URLSession.shared.dataTask(with: r) { d, _, _ in out = d ?? Data(); done.fulfill() }.resume()
        wait(for: [done], timeout: 5)
        return out
    }

    private func openKeyboard() -> XCUIElement {
        messages.terminate()
        messages.launch()
        let search = messages.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8), messages.debugDescription)
        search.tap()
        let intro = label(messages, "label == %@", "Continue")
        if intro.waitForExistence(timeout: 2) { intro.tap() }
        let ours = id(messages, "muninn.more")
        for _ in 0..<5 where !ours.waitForExistence(timeout: 2) { label(messages, "label == %@", "Next keyboard").tap() }
        XCTAssertTrue(ours.exists, messages.debugDescription)
        return search
    }

    private func clear(_ field: XCUIElement) {
        let x = field.buttons["Clear text"]
        if x.exists { x.tap() }
    }

    /// How many AI calls the fake server has seen. The paste's own suggest call must finish before the next answer is set,
    /// or it takes the answer meant for the last key.
    private func aiCalls() -> Int {
        let data = fakeCall("GET", "_log")
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["ai"].flatMap { $0 as? [Any] }?.count ?? 0
    }

    private func waitForAICalls(above count: Int) {
        let deadline = Date().addingTimeInterval(6)
        while aiCalls() <= count, Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
        Thread.sleep(forTimeInterval: 0.4)
    }

    /// Pastes all but the last character, then types the last one on our keys, so the keyboard reads it as typed.
    private func enter(_ field: XCUIElement, _ text: String, next answer: String? = nil) {
        clear(field)
        UIPasteboard.general.string = String(text.dropLast())
        field.press(forDuration: 1.2)
        let paste = label(messages, "label == %@", "Paste")
        if !paste.waitForExistence(timeout: 2) { field.tap(); field.press(forDuration: 1.2) }
        XCTAssertTrue(paste.waitForExistence(timeout: 3), messages.debugDescription)
        let before = aiCalls()
        paste.tap()
        let allow = messages.alerts.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 1) { allow.tap() }
        UIPasteboard.general.items = []
        waitForAICalls(above: before)
        if let answer { fakeCall("POST", "_next", answer) }
        let last = messages.descendants(matching: .any)
            .matching(NSPredicate(format: "label ==[c] %@ AND identifier BEGINSWITH 'k.'", String(text.last!))).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 3), "no key \(text.last!)")
        last.tap()
    }

    private func chip(_ kind: String) -> XCUIElement {
        let c = id(messages, "chip.\(kind)")
        XCTAssertTrue(c.waitForExistence(timeout: 12), "no chip.\(kind): " + String(messages.debugDescription.suffix(3000)))
        return c
    }

    private func cancel() {
        let c = id(messages, "chip.cancel")
        if c.exists { c.tap() }
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Points the app at the fake server and adds the shot data: an active plan for Ana and an open dispute from Maya.
    func test00Pair() {
        let app = XCUIApplication()
        app.launchArguments = ["-serverURL", fake.absoluteString]
        app.launch()
        if id(app, "onboarding.add").waitForExistence(timeout: 6) { id(app, "onboarding.add").tap() }
        if id(app, "onboarding.later").waitForExistence(timeout: 3) { id(app, "onboarding.later").tap() }
        if id(app, "onboarding.calendar.later").waitForExistence(timeout: 3) { id(app, "onboarding.calendar.later").tap() }
        let start = id(app, "onboarding.start")
        if start.waitForExistence(timeout: 3) {
            start.tap()
            // The PayPal and business steps follow "Get started" (same as WalkthroughTests.test00GetStarted).
            if id(app, "onboarding.paypal.demo").waitForExistence(timeout: 10) { id(app, "onboarding.paypal.demo").tap() }
            if id(app, "onboarding.business.later").waitForExistence(timeout: 5) { id(app, "onboarding.business.later").tap() }
        } else {
            XCUIDevice.shared.system.open(URL(string: "muninn-dev://pair?token=pkd_fake&server=\(fake.absoluteString)")!)
            let open = springboard.buttons["Open"]
            if open.waitForExistence(timeout: 5) { open.tap() }
            Thread.sleep(forTimeInterval: 2)
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(label(app, "label CONTAINS %@", "Jordan Ray").waitForExistence(timeout: 15), "Home did not load from the fake server")
        fakeCall("POST", "_reset")
        fakeCall("POST", "_paypal-extras")
        enableKeyboard()
    }

    private func tapCell(_ app: XCUIApplication, _ labels: [String], timeout: TimeInterval = 8) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for l in labels {
                let cell = app.cells.containing(NSPredicate(format: "label == %@", l)).firstMatch
                let e = cell.exists ? cell : label(app, "label == %@", l)
                if e.exists && e.isHittable { e.tap(); Thread.sleep(forTimeInterval: 1.2); return }
            }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        XCTFail("none of \(labels) found")
    }

    /// A fresh simulator: add the Muninn keyboard and turn on Full Access (same steps as SmartChipShots).
    private func enableKeyboard() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        tapCell(settings, ["General"], timeout: 12)
        tapCell(settings, ["Keyboard"])
        tapCell(settings, ["Keyboards"])
        let ours = label(settings, "label BEGINSWITH %@", "Muninn")
        if !ours.waitForExistence(timeout: 3) {
            tapCell(settings, ["Add New Keyboard", "Add New Keyboard…"])
            let pick = label(settings, "label BEGINSWITH %@", "Muninn")
            XCTAssertTrue(pick.waitForExistence(timeout: 5))
            pick.tap()
        }
        XCTAssertTrue(ours.waitForExistence(timeout: 5))
        ours.tap()
        let toggle = settings.switches.firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if (toggle.value as? String) != "1" {
            toggle.tap()
            if (toggle.value as? String) != "1", toggle.switches.firstMatch.exists { toggle.switches.firstMatch.tap() }
            let allow = settings.alerts.buttons["Allow"]
            if allow.waitForExistence(timeout: 5) { allow.tap() }
        }
        XCTAssertEqual(settings.switches.firstMatch.value as? String, "1")
        settings.terminate()
    }

    func test01KeyboardShots() {
        // A fresh fake each run: an earlier run already paused Ana's plan.
        fakeCall("POST", "_reset")
        fakeCall("POST", "_paypal-extras")
        let field = openKeyboard()

        enter(field, "remind jordan", next: #"{"cls":{"intent":"send_reminder","confidence":0.95},"ext":{"client_name":"Jordan Ray","client_email":null,"amount":null,"currency":null,"item":null}}"#)
        _ = chip("remind")
        shot("01-nudge-chip")

        enter(field, "jordan paid cash")
        chip("invoice_mark_paid").tap()
        XCTAssertTrue(id(messages, "chip.confirm").waitForExistence(timeout: 5))
        shot("02-mark-paid-confirm")
        cancel()
        enter(field, "jordan paid cash")
        _ = chip("invoice_mark_paid")
        shot("02-mark-paid-chip")

        enter(field, "pause ana's plan")
        _ = chip("plan_pause")
        shot("03a-pause-plan-chip")
        chip("plan_pause").tap()
        XCTAssertTrue(id(messages, "chip.confirm").waitForExistence(timeout: 5))
        shot("03b-pause-plan-confirm")
        id(messages, "chip.confirm").tap()
        XCTAssertTrue(id(messages, "chip.undo").waitForExistence(timeout: 10), String(messages.debugDescription.suffix(3000)))
        shot("03c-paused-undo")

        // Under the $50 a day demo cap (demoPayoutDailyCap in server/src/config.ts).
        enter(field, "pay my supplier joe $40 joe@example.com")
        chip("payout").tap()
        XCTAssertTrue(id(messages, "chip.confirm").waitForExistence(timeout: 5))
        shot("04-send-40-confirm")
        cancel()

        enter(field, "how much do I have")
        chip("balance").tap()
        XCTAssertTrue(id(messages, "chip.done").waitForExistence(timeout: 10))
        shot("05-balance")

        enter(field, "tell maya in the dispute: I shipped it Monday")
        chip("dispute_reply").tap()
        XCTAssertTrue(id(messages, "chip.confirm").waitForExistence(timeout: 5))
        shot("06a-dispute-reply-confirm")
        cancel()
    }

    func test02DisputesPage() {
        let app = XCUIApplication()
        app.launchArguments = ["-serverURL", fake.absoluteString]
        app.launch()
        XCTAssertTrue(label(app, "label CONTAINS %@", "Jordan Ray").waitForExistence(timeout: 15))
        let row = id(app, "home.disputes")
        XCTAssertTrue(row.waitForExistence(timeout: 10), String(app.debugDescription.suffix(3000)))
        // The Disputes row sits near the end of Home: scroll until it is clear of the Ask bar.
        for _ in 0..<5 where row.frame.maxY > app.frame.height - 180 { app.swipeUp(velocity: .slow) }
        Thread.sleep(forTimeInterval: 0.8)
        row.tap()
        let reply = id(app, "dispute.reply")
        XCTAssertTrue(reply.waitForExistence(timeout: 10), String(app.debugDescription.suffix(3000)))
        shot("06b-disputes-page")
        reply.tap()
        let field = id(app, "dispute.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Shipped Monday, tracking 1Z999")
        id(app, "dispute.next").tap()
        XCTAssertTrue(id(app, "dispute.confirm").waitForExistence(timeout: 5))
        shot("06c-disputes-page-reply-confirm")
        id(app, "dispute.confirm").tap()
        XCTAssertTrue(id(app, "dispute.done").waitForExistence(timeout: 10))
        shot("06d-disputes-page-reply-sent")
    }
}
