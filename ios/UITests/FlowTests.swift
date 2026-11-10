import XCTest

/// Drives the real flow on the simulator. Run with:
/// TEST_RUNNER_DEVICE_TOKEN=pkd_... TEST_RUNNER_SHOT_DIR=/path xcodebuild test ... -only-testing:MuninnUITests/FlowTests/<name>
final class FlowTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() { continueAfterFailure = false }

    /// Tests that send text to /v1/suggest (paid model calls) run only with TEST_RUNNER_LIVE=1.
    private func requireLive() throws {
        try XCTSkipUnless(env["LIVE"] == "1", "live model call; set TEST_RUNNER_LIVE=1")
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = env["SHOT_DIR"] { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")) }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png"); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func element(_ app: XCUIApplication, _ format: String, _ arg: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: format, arg)).firstMatch
    }

    private func tap(_ app: XCUIApplication, _ labels: [String], timeout: TimeInterval = 6) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for l in labels {
                let cell = app.cells.containing(NSPredicate(format: "label == %@", l)).firstMatch
                let e = cell.exists ? cell : element(app, "label == %@", l)
                if e.exists && e.isHittable { e.tap(); Thread.sleep(forTimeInterval: 1.2); return }
            }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        XCTFail("none of \(labels) found\n\(app.debugDescription.suffix(6000))")
    }

    func test1Pair() throws {
        let token = try XCTUnwrap(env["DEVICE_TOKEN"])
        let app = XCUIApplication()
        app.launch()
        let field = app.secureTextFields["token"]
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText(token)
            app.buttons["Pair"].tap()
        }
        XCTAssertTrue(app.staticTexts["Earned today"].waitForExistence(timeout: 10))
        shot("02-home-paired")
    }

    func test2EnableKeyboard() {
        settings.launch()
        tap(settings, ["General"], timeout: 10)
        tap(settings, ["Keyboard"])
        let sound = settings.switches["Sound"]
        if sound.waitForExistence(timeout: 3), (sound.value as? String) == "1" { sound.tap() }
        tap(settings, ["Keyboards"])
        let ours = element(settings, "label BEGINSWITH %@", "Muninn")
        if !ours.waitForExistence(timeout: 3) {
            tap(settings, ["Add New Keyboard", "Add New Keyboard…"])
            let pick = element(settings, "label BEGINSWITH %@", "Muninn")
            if !pick.waitForExistence(timeout: 5) {
                // Flaky on a cold Settings launch: the first tap can land before the list is ready.
                tap(settings, ["Add New Keyboard", "Add New Keyboard…"])
            }
            XCTAssertTrue(pick.waitForExistence(timeout: 5), settings.debugDescription)
            pick.tap()
        }
        XCTAssertTrue(ours.waitForExistence(timeout: 5), settings.debugDescription)
        ours.tap()
        let toggle = settings.switches.firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), settings.debugDescription)
        if (toggle.value as? String) != "1" {
            toggle.tap()
            if (toggle.value as? String) != "1", toggle.switches.firstMatch.exists { toggle.switches.firstMatch.tap() }
            let allow = settings.alerts.buttons["Allow"]
            if allow.waitForExistence(timeout: 5) { allow.tap() }
        }
        shot("03-settings-full-access")
        XCTAssertEqual(settings.switches.firstMatch.value as? String, "1", settings.debugDescription)
    }

    func test3MessagesFlow() throws {
        try requireLive()
        let sentence = "thanks! that'll be $45 for the haircut, sam@example.com"
        let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        messages.launch()
        let convo = messages.cells.element(boundBy: Int(env["CONVO_INDEX"] ?? "0") ?? 0)
        XCTAssertTrue(convo.waitForExistence(timeout: 5))
        convo.tap()
        let field = messages.textFields["messageBodyField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), messages.debugDescription)
        field.tap()
        let intro = element(messages, "label == %@", "Continue")
        if intro.waitForExistence(timeout: 2) { intro.tap() }

        // Cycle with the system globe key until our keyboard shows.
        let ours = element(messages, "identifier == %@", "muninn.more")
        for _ in 0..<4 where !ours.waitForExistence(timeout: 2) {
            let globe = element(messages, "label == %@", "Next keyboard")
            XCTAssertTrue(globe.waitForExistence(timeout: 3), messages.debugDescription)
            globe.tap()
        }
        XCTAssertTrue(ours.exists, messages.debugDescription)
        shot("04-messages-muninn-keyboard")

        // Paste all but the last letter (one model call, not 55), then type the last key on our keyboard.
        UIPasteboard.general.string = String(sentence.dropLast())
        field.tap()
        let paste = element(messages, "label == %@", "Paste")
        if !paste.waitForExistence(timeout: 2) { field.press(forDuration: 1.0) }
        XCTAssertTrue(paste.waitForExistence(timeout: 3), messages.debugDescription)
        paste.tap()
        Thread.sleep(forTimeInterval: 0.2)
        let key = element(messages, "label == %@", "m")
        XCTAssertTrue(key.waitForExistence(timeout: 3), messages.debugDescription)
        key.tap()

        let chip = element(messages, "identifier == %@", "chip.invoice")
        XCTAssertTrue(chip.waitForExistence(timeout: 15), messages.debugDescription)
        shot("05-messages-chips")
        chip.tap()
        let waiting = element(messages, "identifier == %@", "chip.waiting")
        XCTAssertTrue(waiting.waitForExistence(timeout: 30), messages.debugDescription)
        Thread.sleep(forTimeInterval: 0.5)
        shot("06-messages-link-inserted")
        let value = field.value as? String ?? ""
        print("FIELD_VALUE", value)
        XCTAssertTrue(value.contains("paypal.com"), value)
        XCTAssertTrue(value.hasPrefix(sentence + "\nHere's your invoice for "), value)
    }

    /// No model call: clears the draft, shows our keyboard idle, holds 10 s for a memory reading.
    func test4KeyboardIdle() {
        let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        messages.launch()
        let convo = messages.cells.firstMatch
        XCTAssertTrue(convo.waitForExistence(timeout: 5))
        convo.tap()
        let field = messages.textFields["messageBodyField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let ours = element(messages, "identifier == %@", "muninn.more")
        let delete = element(messages, "label == %@", "delete")
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.press(forDuration: 6)
        XCTAssertEqual((field.value as? String).map { $0 == "iMessage" || $0.isEmpty }, true, String(describing: field.value))
        if !ours.exists { element(messages, "label == %@", "Next keyboard").tap() }
        XCTAssertTrue(ours.waitForExistence(timeout: 5))
        shot("07-keyboard-v2-theme")
        Thread.sleep(forTimeInterval: 10)
    }

    /// Copy a client's message, open the keyboard: one suggest call with the copy as context, then tap the invoice chip.
    func test5CopiedMessage() throws {
        try requireLive()
        UIPasteboard.general.string = "how much do I owe you?"
        let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        messages.launch()
        let convo = messages.cells.firstMatch
        XCTAssertTrue(convo.waitForExistence(timeout: 5))
        convo.tap()
        let field = messages.textFields["messageBodyField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        // iOS asks before a keyboard reads text another app copied. Answer it before touching Messages again,
        // because Messages' accessibility tree waits on the keyboard while the prompt is up.
        let allow = springboard.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 6) { allow.tap() }
        let ours = element(messages, "identifier == %@", "muninn.more")
        XCTAssertTrue(ours.waitForExistence(timeout: 5))

        let chip = element(messages, "identifier == %@", "chip.invoice")
        XCTAssertTrue(chip.waitForExistence(timeout: 15), messages.debugDescription)
        XCTAssertTrue(element(messages, "label CONTAINS %@", "from copied message").exists, messages.debugDescription)
        shot("09-copied-message-chip")
        chip.tap()
        XCTAssertTrue(element(messages, "identifier == %@", "chip.waiting").waitForExistence(timeout: 30), messages.debugDescription)
        Thread.sleep(forTimeInterval: 0.5)
        shot("10-invoice-line-inserted")
        let value = field.value as? String ?? ""
        print("FIELD_VALUE", value)
        XCTAssertTrue(value.hasPrefix("Here's your invoice for "), value)
        XCTAssertTrue(value.contains("paypal.com"), value)
    }

    /// No model call: empties the pasteboard, shows our keyboard on the empty search field, holds 10 s for a memory reading.
    func test6MemoryIdle() {
        UIPasteboard.general.items = []
        let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        messages.launch()
        let search = messages.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        let ours = element(messages, "identifier == %@", "muninn.more")
        if !ours.waitForExistence(timeout: 3) { element(messages, "label == %@", "Next keyboard").tap() }
        XCTAssertTrue(ours.waitForExistence(timeout: 5))
        shot("12-memory-idle")
        Thread.sleep(forTimeInterval: 10)
    }

    // MARK: v3 proof

    /// Fresh keychain: onboarding, pair with the demo token, Home, Integrations.
    func test7Screens() throws {
        let token = try XCTUnwrap(env["DEVICE_TOKEN"])
        let app = XCUIApplication()
        app.launch()
        let field = app.secureTextFields["token"]
        try XCTSkipUnless(field.waitForExistence(timeout: 5), "already paired; reset the simulator keychain to run onboarding")
        if env["USE_DEMO_SERVER"] == "1" { element(app, "identifier == %@", "server.demo").tap() }
        shot("13-onboarding")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 0.5)
        shot("14-onboarding-steps")
        app.swipeDown()
        field.tap()
        field.typeText(token)
        app.buttons["Pair"].tap()
        XCTAssertTrue(app.staticTexts["Earned today"].waitForExistence(timeout: 15))
        for a in [app, springboard] where a.buttons["Not Now"].waitForExistence(timeout: 2) { a.buttons["Not Now"].tap() }
        _ = element(app, "identifier == %@", "home.brief").waitForExistence(timeout: 15)
        Thread.sleep(forTimeInterval: 1)
        shot("15-home")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 0.8)
        shot("16-home-lower")
        app.swipeDown()
        Thread.sleep(forTimeInterval: 0.5)
        element(app, "identifier == %@", "nav.integrations").tap()
        XCTAssertTrue(element(app, "identifier == %@", "integration.paypal").waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 0.5)
        shot("17-integrations")
    }

    /// Recorded from the host: tap the first folder, the glass squashes and papers fan, rows slide in.
    func test8FolderOpen() {
        let app = XCUIApplication()
        app.launch()
        let folder = element(app, "identifier BEGINSWITH %@", "folder.")
        XCTAssertTrue(folder.waitForExistence(timeout: 15), app.debugDescription)
        Thread.sleep(forTimeInterval: 1.5)
        folder.tap()
        Thread.sleep(forTimeInterval: 2.5)
        shot("18-client-detail")
    }

    /// Clears the chat draft with the system keyboard, so our keyboard never sends the old draft.
    func test9aPrepareChat() {
        let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        messages.launch()
        let search = messages.searchFields.firstMatch
        if search.waitForExistence(timeout: 5) {
            search.tap()
            // Move to the system English keyboard while the field is empty.
            for _ in 0..<4 where !(messages.keys["q"].waitForExistence(timeout: 1.5) || messages.keys["Q"].exists) {
                element(messages, "label == %@", "Next keyboard").tap()
            }
            XCTAssertTrue(messages.keys["q"].exists || messages.keys["Q"].exists, "system keyboard not reached")
            let close = messages.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Close", "close"])).firstMatch
            if close.exists { close.tap() } else { print("BUTTONS", messages.buttons.allElementsBoundByIndex.map(\.label)) }
        }
        let convo = messages.cells.firstMatch
        XCTAssertTrue(convo.waitForExistence(timeout: 5))
        convo.tap()
        let field = messages.textFields["messageBodyField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertFalse(element(messages, "identifier == %@", "muninn.more").waitForExistence(timeout: 2), "our keyboard is up with the draft")
        let delete = element(messages, "label == %@", "delete")
        if delete.waitForExistence(timeout: 3) { delete.press(forDuration: 8) }
        let value = field.value as? String ?? ""
        XCTAssertTrue(value.isEmpty || value == "iMessage", value)
    }

    /// Recorded from the host: copied client message, tap "Use copied message", invoice chip, link inserted.
    func test9bChipToLink() throws {
        try requireLive()
        UIPasteboard.general.string = "What do I owe you for the haircut?"
        let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        messages.activate()
        let field = messages.textFields["messageBodyField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let ours = element(messages, "identifier == %@", "muninn.more")
        for _ in 0..<4 where !ours.waitForExistence(timeout: 1.5) {
            element(messages, "label == %@", "Next keyboard").tap()
        }
        XCTAssertTrue(ours.exists)
        let copied = element(messages, "identifier == %@", "chip.copied")
        XCTAssertTrue(copied.waitForExistence(timeout: 5), messages.debugDescription)
        shot("19-keyboard-copied-chip")
        copied.tap()
        let allow = springboard.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 6) { allow.tap() }
        let chip = element(messages, "identifier == %@", "chip.invoice")
        XCTAssertTrue(chip.waitForExistence(timeout: 15), messages.debugDescription)
        Thread.sleep(forTimeInterval: 0.6)
        shot("20-keyboard-chips")
        chip.tap()
        XCTAssertTrue(element(messages, "identifier == %@", "chip.waiting").waitForExistence(timeout: 30), messages.debugDescription)
        Thread.sleep(forTimeInterval: 0.8)
        shot("21-keyboard-link-inserted")
        let value = field.value as? String ?? ""
        print("FIELD_VALUE", value)
        XCTAssertTrue(value.hasPrefix("Here's your invoice for "), value)
    }

    func test10Raven() {
        let app = XCUIApplication()
        app.launchArguments = ["-ravenDemo"]
        app.launch()
        XCTAssertTrue(element(app, "identifier == %@", "raven.stamp").waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 0.9)
        shot("22-raven-returns")
    }

    /// Screens of a keyboard in an empty Messages field: letters, then 123. KB=system or ours; NAME is the file prefix.
    func test11KeyboardScreens() {
        let which = env["KB"] ?? "system"
        let name = env["NAME"] ?? "kb"
        let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        messages.activate()
        let convo = messages.cells.firstMatch
        if convo.waitForExistence(timeout: 2) && convo.isHittable { convo.tap() }
        let field = messages.textFields["messageBodyField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let ours = element(messages, "identifier == %@", "muninn.more")
        func isWanted() -> Bool { which == "ours" ? ours.exists : (messages.keys["q"].exists || messages.keys["Q"].exists) }
        for _ in 0..<5 where !({ Thread.sleep(forTimeInterval: 1.2); return isWanted() }()) {
            element(messages, "label == %@", "Next keyboard").tap()
        }
        XCTAssertTrue(isWanted(), "keyboard \(which) not shown")
        XCTAssertTrue((field.value as? String ?? "").isEmpty || field.value as? String == "iMessage", "field not empty")
        Thread.sleep(forTimeInterval: 0.8)
        shot("\(name)-letters")
        let more = which == "ours" ? ours : messages.keys["more"]
        if more.exists { more.tap() } else { print("KEYS", messages.keys.allElementsBoundByIndex.map(\.label)) }
        Thread.sleep(forTimeInterval: 0.8)
        shot("\(name)-123")
        if more.exists { more.tap() }
    }

    /// Home after the fixes, then the Ask bar: one /v1/suggest call, tap the invoice chip, result card with Copy.
    func test12HomeAndAsk() throws {
        try requireLive()
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Keyboard is on"].waitForExistence(timeout: 15), app.debugDescription)
        _ = element(app, "identifier == %@", "home.brief").waitForExistence(timeout: 15)
        Thread.sleep(forTimeInterval: 1)
        shot("24-home-fixed")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 0.8)
        shot("25-home-scrolled")
        let field = element(app, "identifier == %@", "ask.field")
        field.tap()
        // Leave our own keyboard (it would send each keystroke) for the system one on the empty field.
        for _ in 0..<4 where !(app.keys["q"].waitForExistence(timeout: 1.5) || app.keys["Q"].exists) {
            element(app, "label == %@", "Next keyboard").tap()
        }
        field.typeText("invoice Sam Okafor $45 for a haircut sam.okafor@example.com\n")
        let chip = element(app, "identifier == %@", "ask.chip.invoice")
        XCTAssertTrue(chip.waitForExistence(timeout: 20), app.debugDescription)
        shot("26-ask-chips")
        chip.tap()
        XCTAssertTrue(element(app, "identifier == %@", "ask.copy").waitForExistence(timeout: 30), app.debugDescription)
        element(app, "identifier == %@", "ask.copy").tap()
        Thread.sleep(forTimeInterval: 0.6)
        shot("27-ask-result")
    }

    func test13HomeOnly() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Keyboard is on"].waitForExistence(timeout: 15))
        _ = element(app, "identifier == %@", "home.brief").waitForExistence(timeout: 10)
        Thread.sleep(forTimeInterval: 1)
        shot("24-home-fixed")
    }

    /// Keyboard Lab with no Full Access (no network): auto-caps, double space, caps lock, delete repeat, callout.
    func test14KeysOffline() {
        let app = XCUIApplication()
        app.launchArguments = ["-labOffline"]
        app.launch()
        element(app, "identifier == %@", "nav.integrations").tap()
        app.swipeUp()
        tap(app, ["Keyboard Lab (debug)"])
        let text = element(app, "identifier == %@", "lab.text")
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        func key(_ c: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND identifier BEGINSWITH 'k.'", c)).firstMatch
        }
        for c in ["h", "e", "l", "l", "o"] { key(c).tap() }
        element(app, "identifier == %@", "space").doubleTap()
        XCTAssertEqual(text.label, "Hello. ", "auto-caps + double space")
        element(app, "identifier == %@", "shift").doubleTap()
        key("o").tap(); key("k").tap()
        XCTAssertEqual(text.label, "Hello. OK", "caps lock")
        element(app, "identifier == %@", "shift").tap()
        key("a").tap()
        XCTAssertEqual(text.label, "Hello. OKa", "caps lock off")
        element(app, "identifier == %@", "muninn.more").tap()
        element(app, "label == %@", "4").tap()
        element(app, "identifier == %@", "space").tap()
        XCTAssertTrue(key("q").waitForExistence(timeout: 2), "space in 123 returns to letters")
        shot("28-lab-keys")
        print("PRESS_START", Date().timeIntervalSince1970)
        key("g").press(forDuration: 3)
        print("PRESS_END", Date().timeIntervalSince1970)
        let before = text.label.count
        element(app, "identifier == %@", "delete").press(forDuration: 2.5)
        print("LAB_TEXT_AFTER_DELETE", text.label)
        // An empty field shows the placeholder, so empty counts as zero characters left.
        let left = text.label == "Type with the keyboard below" ? 0 : text.label.count
        XCTAssertLessThan(left, before - 5, "delete repeats on hold")
    }

    /// Calendar: Connect on Integrations, the system prompt, then Home "Today" and "Bill Ava?".
    /// "-calendarDemo" seeds four events for today. No model call: the prefilled request is not submitted.
    func test15Calendar() {
        let app = XCUIApplication()
        app.launchArguments = ["-calendarDemo"]
        app.launch()
        element(app, "identifier == %@", "nav.integrations").tap()
        let connect = element(app, "identifier == %@", "calendar.connect")
        if connect.waitForExistence(timeout: 5) {
            shot("30-integrations-calendar-connect")
            connect.tap()
            let allow = springboard.buttons["Allow Full Access"]
            XCTAssertTrue(allow.waitForExistence(timeout: 6), springboard.debugDescription)
            allow.tap()
        }
        XCTAssertTrue(element(app, "label BEGINSWITH %@", "Connected ·").waitForExistence(timeout: 5), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.5)
        shot("31-integrations-calendar-connected")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Today"].waitForExistence(timeout: 10), app.debugDescription)
        let bill = element(app, "identifier == %@", "today.bill.Ava")
        XCTAssertTrue(bill.waitForExistence(timeout: 10), app.debugDescription)
        if !bill.isHittable { app.swipeUp(velocity: .slow) }
        Thread.sleep(forTimeInterval: 0.8)
        shot("32-home-today")
        bill.tap()
        let field = element(app, "identifier == %@", "ask.field")
        XCTAssertEqual(field.value as? String, "Invoice Ava Chen ava.chen@example.com $")
        Thread.sleep(forTimeInterval: 0.8)
        shot("33-bill-prefilled")
    }

    /// Our keyboard on the empty Messages search field shows the appointment snapshot. No model call.
    func test16KeyboardAppointments() {
        UIPasteboard.general.items = []
        let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        messages.launch()
        let search = messages.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        let ours = element(messages, "identifier == %@", "muninn.more")
        for _ in 0..<4 where !ours.waitForExistence(timeout: 2) { element(messages, "label == %@", "Next keyboard").tap() }
        XCTAssertTrue(ours.exists, messages.debugDescription)
        XCTAssertTrue(element(messages, "identifier == %@", "chip.bill").waitForExistence(timeout: 5), messages.debugDescription)
        XCTAssertTrue(element(messages, "label BEGINSWITH %@", "Next: ").exists, messages.debugDescription)
        shot("34-keyboard-appointments")
    }
}
