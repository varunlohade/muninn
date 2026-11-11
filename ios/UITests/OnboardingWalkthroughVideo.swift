import XCTest

/// A fresh install, start to finish, for the screen recording. It runs against the live server and makes
/// about three model calls (money message, Fix, Ask bar). It never sends money: the confirm is cancelled.
/// Sign in with Apple does not run on the simulator, so it pairs through the developer sheet: a Debug build only, pointed at the live server.
/// Run with TEST_RUNNER_DEVICE_TOKEN=pkd_... on an erased simulator, Debug with DEFAULT_SERVER_URL set to the live server.
final class OnboardingWalkthroughVideo: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")

    override func setUp() { continueAfterFailure = false }

    private func find(_ app: XCUIApplication, _ format: String, _ arg: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: format, arg)).firstMatch
    }

    private func id(_ app: XCUIApplication, _ identifier: String) -> XCUIElement { find(app, "identifier == %@", identifier) }

    private func pause(_ seconds: TimeInterval = 1.2) { Thread.sleep(forTimeInterval: seconds) }

    private func dismissPrompts(_ app: XCUIApplication) {
        for a in [app, springboard] where a.buttons["Not Now"].waitForExistence(timeout: 2) { a.buttons["Not Now"].tap() }
    }

    private func turnOn(_ toggle: XCUIElement) {
        guard (toggle.value as? String) != "1" else { return }
        toggle.tap()
        if (toggle.value as? String) != "1", toggle.switches.firstMatch.exists { toggle.switches.firstMatch.tap() }
        let allow = settings.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 4) { pause(0.8); allow.tap() }
    }

    /// Taps the first Settings row that shows one of `labels`, once it can be hit.
    private func tapRow(_ labels: [String], timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for l in labels {
                let cell = settings.cells.containing(NSPredicate(format: "label == %@", l)).firstMatch
                let e = cell.exists ? cell : find(settings, "label == %@", l)
                if e.exists && e.isHittable { pause(0.8); e.tap(); pause(0.8); return true }
            }
            pause(0.3)
        } while Date() < deadline
        return false
    }

    func testWalkthrough() throws {
        let token = try XCTUnwrap(env["DEVICE_TOKEN"])
        let app = XCUIApplication()
        app.launch()

        // 1. Onboarding.
        let mark = id(app, "onboarding.mark")
        XCTAssertTrue(mark.waitForExistence(timeout: 10), "a fresh install starts at onboarding")
        pause(2.5)
        mark.press(forDuration: 1.3)
        let field = app.secureTextFields["token"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let demo = id(app, "server.demo")
        if demo.exists { demo.tap() }
        field.tap()
        field.typeText(token)
        app.buttons["Pair"].tap()
        // A slow first connection can time out; tap Pair again until the next step shows.
        let deadline = Date().addingTimeInterval(90)
        while !id(app, "onboarding.step.2").exists && Date() < deadline {
            if id(app, "pair.error").exists, app.buttons["Pair"].exists, app.buttons["Pair"].isEnabled { app.buttons["Pair"].tap() }
            pause(0.5)
        }
        dismissPrompts(app)

        // 2. Enable the keyboard in Settings, the way the step says.
        XCTAssertTrue(id(app, "onboarding.step.2").waitForExistence(timeout: 30), app.debugDescription)
        pause(2)
        app.buttons["Open Settings"].tap()
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        let keyboards = find(settings, "label BEGINSWITH %@", "Keyboards")
        if keyboards.waitForExistence(timeout: 4) {
            // The app's own Settings page: Keyboards › Muninn Keyboard, Allow Full Access.
            pause()
            keyboards.tap()
            let ours = settings.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Muninn")).firstMatch
            XCTAssertTrue(ours.waitForExistence(timeout: 5), settings.debugDescription)
            pause()
            turnOn(ours)
        } else {
            // A fresh simulator opens Settings at the top: General › Keyboard › Keyboards › Add New Keyboard.
            settings.launch()
            XCTAssertTrue(tapRow(["General"], timeout: 10), settings.debugDescription)
            XCTAssertTrue(tapRow(["Keyboard"]), settings.debugDescription)
            XCTAssertTrue(tapRow(["Keyboards"]), settings.debugDescription)
            let add = find(settings, "label BEGINSWITH %@", "Add New Keyboard")
            XCTAssertTrue(add.waitForExistence(timeout: 5), settings.debugDescription)
            pause(0.8)
            add.tap()
            let pick = find(settings, "label BEGINSWITH %@", "Muninn")
            if !pick.waitForExistence(timeout: 5) { add.tap() }
            XCTAssertTrue(pick.waitForExistence(timeout: 5), settings.debugDescription)
            pause(0.8)
            pick.tap()
            let row = find(settings, "label BEGINSWITH %@", "Muninn")
            XCTAssertTrue(row.waitForExistence(timeout: 5), settings.debugDescription)
            pause(0.8)
            row.tap()
        }
        let full = settings.switches.firstMatch
        XCTAssertTrue(full.waitForExistence(timeout: 5), settings.debugDescription)
        pause()
        turnOn(full)
        pause(1.5)
        app.activate()

        // 3. The try-it step, then Home.
        if id(app, "onboarding.step.3").waitForExistence(timeout: 10) {
            pause(2)
            id(app, "onboarding.skip").tap()
        }
        XCTAssertTrue(app.staticTexts["Earned today"].waitForExistence(timeout: 20), app.debugDescription)
        dismissPrompts(app)
        _ = id(app, "home.brief").waitForExistence(timeout: 15)
        pause(3)
        app.swipeUp()
        pause(2)
        app.swipeDown()
        pause(1)

        // 4. A money message in another app's text field, typed with the Muninn keyboard.
        messages.launch()
        let search = messages.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), messages.debugDescription)
        search.tap()
        // A fresh phone shows the slide-to-type tip once.
        let tip = messages.buttons["Continue"]
        if tip.waitForExistence(timeout: 3) { tip.tap(); pause(0.8) }
        let more = id(messages, "muninn.more")
        for _ in 0..<5 where !more.waitForExistence(timeout: 2) { find(messages, "label == %@", "Next keyboard").tap() }
        XCTAssertTrue(more.exists, messages.debugDescription)
        pause()
        // One paste, so the money message makes one model call.
        UIPasteboard.general.string = "Thanks! That's $45 for the haircut, sam@example.com"
        search.press(forDuration: 1.2)
        let paste = find(messages, "label == %@", "Paste")
        if !paste.waitForExistence(timeout: 2) { search.tap(); search.press(forDuration: 1.2) }
        XCTAssertTrue(paste.waitForExistence(timeout: 3), messages.debugDescription)
        paste.tap()
        let chip = find(messages, "identifier BEGINSWITH %@", "chip.invoice")
        XCTAssertTrue(chip.waitForExistence(timeout: 20), messages.debugDescription)
        pause(2)
        chip.tap()
        let confirm = id(messages, "chip.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 8), messages.debugDescription)
        pause(2.5)
        // Never send: cancel the confirm.
        id(messages, "chip.cancel").tap()
        pause(1.5)

        // 5. Fix on a typo.
        let delete = id(messages, "delete")
        for _ in 0..<4 where !((search.value as? String ?? "").isEmpty || search.value as? String == search.placeholderValue) {
            delete.press(forDuration: 3)
        }
        for ch in "i can do teh job" {
            let k = ch == " " ? id(messages, "space")
                : find(messages, "identifier BEGINSWITH 'k.' AND label ==[c] %@", String(ch))
            XCTAssertTrue(k.waitForExistence(timeout: 3), "no key \(ch)")
            k.tap()
        }
        let fix = id(messages, "chip.fix")
        XCTAssertTrue(fix.waitForExistence(timeout: 8), messages.debugDescription)
        pause(1.5)
        fix.tap()
        _ = id(messages, "chip.undo").waitForExistence(timeout: 40)
        pause(2.5)

        // 6. The Ask bar.
        app.activate()
        let ask = id(app, "ask.field")
        XCTAssertTrue(ask.waitForExistence(timeout: 10), app.debugDescription)
        ask.tap()
        let other = find(app, "label == %@", "Next keyboard")
        for _ in 0..<5 where !(app.keys["q"].waitForExistence(timeout: 1.5) || app.keys["Q"].exists) { if other.exists { other.tap() } }
        ask.typeText("who hasn't paid\n")
        _ = id(app, "ask.result").waitForExistence(timeout: 20)
        pause(3.5)

        // 7. Notes.
        id(app, "nav.notes").tap()
        _ = id(app, "notes.new").waitForExistence(timeout: 5)
        pause(3)
    }
}
