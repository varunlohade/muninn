import XCTest

/// Drives the real flow on the simulator. Run with:
/// TEST_RUNNER_DEVICE_TOKEN=pkd_... TEST_RUNNER_SHOT_DIR=/path xcodebuild test ... -only-testing:MuninnUITests/FlowTests/<name>
final class FlowTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() { continueAfterFailure = false }

    /// Rewrite, Notes and Catalog sit behind the bar's "…" slot; this opens it first when the button is hidden.
    private func tapTool(_ app: XCUIApplication, _ identifier: String) {
        let tool = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
        let more = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", "bar.more")).firstMatch
        if !tool.exists, more.waitForExistence(timeout: 3) { more.tap() }
        XCTAssertTrue(tool.waitForExistence(timeout: 5), "no \(identifier) behind the bar's …")
        tool.tap()
    }

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

    /// The hidden developer path: hold the mark on the first screen, then pair with a device token.
    private func devPair(_ app: XCUIApplication, token: String) {
        element(app, "identifier == %@", "onboarding.mark").press(forDuration: 1.3)
        let field = app.secureTextFields["token"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "developer pairing sheet did not open")
        if env["USE_DEMO_SERVER"] == "1" { element(app, "identifier == %@", "server.demo").tap() }
        // TEST_RUNNER_SERVER_URL: another local server, for example one with a stubbed model.
        if let url = env["SERVER_URL"] {
            let server = app.textFields.firstMatch
            server.tap()
            server.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 60) + url)
        }
        field.tap()
        field.typeText(token)
        app.buttons["Pair"].tap()
    }

    /// Leaves the steps after sign-in without doing them.
    private func skipIntro(_ app: XCUIApplication) {
        for id in ["onboarding.later", "onboarding.add"] {
            let b = element(app, "identifier == %@", id)
            if b.waitForExistence(timeout: 5) { b.tap() }
        }
    }

    /// Fresh keychain: the whole first run. Apple button, no token field, keyboard step, try-it scene, Home, relaunch.
    /// With TEST_RUNNER_LIVE=1 the try-it scene runs for real: example, chip, sandbox pay link.
    func test0Onboarding() throws {
        let token = try XCTUnwrap(env["DEVICE_TOKEN"])
        let app = XCUIApplication()
        app.launch()
        let mark = element(app, "identifier == %@", "onboarding.mark")
        try XCTSkipUnless(mark.waitForExistence(timeout: 5), "already signed in; reset the simulator keychain to run onboarding")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Continue with Apple")).firstMatch.exists)
        XCTAssertFalse(app.secureTextFields["token"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "npm run")).firstMatch.exists)
        shot("20-onboarding-apple")

        devPair(app, token: token)
        // The keyboard step shows only while the keyboard is off in Settings.
        if element(app, "identifier == %@", "onboarding.step.2").waitForExistence(timeout: 6) {
            Thread.sleep(forTimeInterval: 0.6)
            shot("21-onboarding-keyboard")
            element(app, "identifier == %@", "onboarding.later").tap()
        }

        XCTAssertTrue(element(app, "identifier == %@", "onboarding.step.3").waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 0.6)
        shot("22-onboarding-try")
        if env["LIVE"] == "1" {
            element(app, "identifier == %@", "onboarding.example").tap()
            let anyChip = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "chip.")).firstMatch
            XCTAssertTrue(anyChip.waitForExistence(timeout: 15), "no chip for the example")
            shot("23-onboarding-chip")
            let payLink = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "chip.", "Pay link")).firstMatch
            (payLink.exists ? payLink : anyChip).tap()
            let link = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "onboarding.message", "paypal.com")).firstMatch
            XCTAssertTrue(link.waitForExistence(timeout: 20), "no pay link in the message")
            Thread.sleep(forTimeInterval: 0.5)
            shot("24-onboarding-link")
        } else {
            element(app, "identifier == %@", "onboarding.add").tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["home.earned"].waitForExistence(timeout: 15))
        _ = element(app, "identifier == %@", "home.brief").waitForExistence(timeout: 15)
        Thread.sleep(forTimeInterval: 1)
        shot("25-home")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["home.earned"].waitForExistence(timeout: 10))
        XCTAssertFalse(mark.exists, "onboarding showed again after sign-in")
    }

    func test1Pair() throws {
        let token = try XCTUnwrap(env["DEVICE_TOKEN"])
        let app = XCUIApplication()
        app.launch()
        if element(app, "identifier == %@", "onboarding.mark").waitForExistence(timeout: 5) {
            devPair(app, token: token)
            skipIntro(app)
        }
        XCTAssertTrue(app.descendants(matching: .any)["home.earned"].waitForExistence(timeout: 10))
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

    /// Fresh keychain: onboarding, pair with the demo token (developer path), Home, Integrations.
    func test7Screens() throws {
        let token = try XCTUnwrap(env["DEVICE_TOKEN"])
        let app = XCUIApplication()
        app.launch()
        try XCTSkipUnless(element(app, "identifier == %@", "onboarding.mark").waitForExistence(timeout: 5), "already paired; reset the simulator keychain to run onboarding")
        shot("13-onboarding")
        devPair(app, token: token)
        if element(app, "identifier == %@", "onboarding.step.2").waitForExistence(timeout: 6) {
            Thread.sleep(forTimeInterval: 0.6)
            shot("14-onboarding-steps")
        }
        skipIntro(app)
        XCTAssertTrue(app.descendants(matching: .any)["home.earned"].waitForExistence(timeout: 15))
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

    /// Calendar: Connect on Integrations, the system prompt, then Home "Today" and "Invoice Ava".
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

    /// Notes panel in our keyboard on the Messages search field: insert two notes, then "+" saves the field text.
    /// No model call: inserted notes are not sent for suggestions.
    func test17KeyboardNotes() {
        UIPasteboard.general.items = []
        let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        messages.launch()
        let search = messages.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        let ours = element(messages, "identifier == %@", "muninn.more")
        for _ in 0..<4 where !ours.waitForExistence(timeout: 2) { element(messages, "label == %@", "Next keyboard").tap() }
        XCTAssertTrue(ours.exists, messages.debugDescription)
        let toggle = element(messages, "identifier == %@", "notes.toggle")
        let prices = element(messages, "label BEGINSWITH %@", "Prices: cut $45")
        let policy = element(messages, "label BEGINSWITH %@", "Cancellation: 24h")
        tapTool(messages, "notes.toggle")
        XCTAssertTrue(prices.waitForExistence(timeout: 3), messages.debugDescription)
        Thread.sleep(forTimeInterval: 0.5)
        shot("35-keyboard-notes-panel")
        prices.tap()
        XCTAssertTrue(ours.waitForExistence(timeout: 3), "keys come back after a note is inserted")
        XCTAssertEqual(search.value as? String, "Prices: cut $45, color $120, blowout $35")
        Thread.sleep(forTimeInterval: 0.5)
        shot("36-keyboard-note-inserted")
        tapTool(messages, "notes.toggle")
        policy.tap()
        let both = "Prices: cut $45, color $120, blowout $35 Cancellation: 24h notice or 50% fee"
        XCTAssertEqual(search.value as? String, both)
        tapTool(messages, "notes.toggle")
        let add = element(messages, "identifier == %@", "notes.add")
        if add.isEnabled { add.tap() }
        XCTAssertEqual(element(messages, "identifier == %@", "note.0").label, both, "+ saves the text before the cursor")
        Thread.sleep(forTimeInterval: 0.5)
        shot("37-keyboard-note-saved")
        toggle.tap()
    }

    /// The app's Notes screen: the two demo notes, then delete the note test17 saved from the keyboard.
    func test18NotesScreen() {
        let app = XCUIApplication()
        app.launch()
        element(app, "identifier == %@", "nav.notes").tap()
        XCTAssertTrue(element(app, "label == %@", "Prices: cut $45, color $120, blowout $35").waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(element(app, "label == %@", "Cancellation: 24h notice or 50% fee").exists)
        Thread.sleep(forTimeInterval: 0.5)
        shot("38-notes-screen")
        let saved = element(app, "label BEGINSWITH %@", "Prices: cut $45, color $120, blowout $35 Cancellation")
        if saved.exists {
            saved.tap()
            XCTAssertTrue(element(app, "identifier == %@", "note.delete").waitForExistence(timeout: 5))
            Thread.sleep(forTimeInterval: 0.5)
            shot("39-note-editor")
            element(app, "identifier == %@", "note.delete").tap()
            XCTAssertFalse(saved.waitForExistence(timeout: 2), "deleted note is gone")
        }
    }

    // MARK: writing tools and shortcuts

    /// These tests send text to the writing routes. They run only against a server with a stubbed model
    /// (TEST_RUNNER_STUB=1 with TEST_RUNNER_SERVER_URL), or with TEST_RUNNER_LIVE=1.
    private func requireWriting() throws {
        try XCTSkipUnless(env["STUB"] == "1" || env["LIVE"] == "1", "writing calls a model; set TEST_RUNNER_STUB=1 or TEST_RUNNER_LIVE=1")
    }

    private func id(_ app: XCUIApplication, _ identifier: String) -> XCUIElement { element(app, "identifier == %@", identifier) }

    /// Types on our own keys in the app. Letters, space, and the 123 layer for everything else.
    private func typeOnKeys(_ app: XCUIApplication, _ text: String) {
        var symbols = false
        func layer(_ wantSymbols: Bool) {
            if symbols != wantSymbols { id(app, "muninn.more").tap(); symbols = wantSymbols }
        }
        for ch in text {
            if ch == " " {
                id(app, "space").tap()
                symbols = false
            } else if ch.isLetter {
                layer(false)
                app.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] %@ AND identifier BEGINSWITH 'k.'", String(ch))).firstMatch.tap()
            } else {
                layer(true)
                app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND identifier BEGINSWITH 'k.'", String(ch))).firstMatch.tap()
            }
        }
        layer(false)
    }

    private func openLab(_ app: XCUIApplication) -> XCUIElement {
        app.launch()
        id(app, "nav.integrations").tap()
        app.swipeUp()
        tap(app, ["Keyboard Lab (debug)"])
        let text = id(app, "lab.text")
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        return text
    }

    private func clearLab(_ app: XCUIApplication, _ text: XCUIElement) {
        for _ in 0..<6 where text.label != "Type with the keyboard below" { id(app, "delete").press(forDuration: 3.5) }
    }

    /// The hero: the street plays, the two-tone headline, "Add the keyboard" goes on to the next step.
    func test19IntroScenes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-intro_seen", "NO"]
        app.launch()
        try XCTSkipUnless(id(app, "onboarding.add").waitForExistence(timeout: 8), "already signed in; reset the simulator keychain first")
        XCTAssertTrue(id(app, "onboarding.hero").exists)
        XCTAssertEqual(id(app, "onboarding.headline").label, "Your business, in your keyboard. Works in every app you already type in.")
        shot("50-intro-hero")
        id(app, "onboarding.add").tap()
        XCTAssertTrue(id(app, "onboarding.step.2").waitForExistence(timeout: 8) || id(app, "onboarding.start").exists, "the hero ends on the next onboarding step")
    }

    /// Keyboard Lab: Fix with Undo, the Rewrite panel with Fix grammar, and the three kinds of shortcut.
    func test20WritingAndShortcuts() throws {
        try requireWriting()
        let app = XCUIApplication()
        let text = openLab(app)

        typeOnKeys(app, "i can do teh job")
        let fix = id(app, "chip.fix")
        XCTAssertTrue(fix.waitForExistence(timeout: 5), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.5)
        shot("40-fix-before")
        fix.tap()
        XCTAssertTrue(id(app, "chip.undo").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(text.label, "I can do the job.")
        shot("41-fix-after")
        id(app, "chip.undo").tap()
        XCTAssertEqual(text.label, "I can do teh job", "Undo puts the old text back")
        XCTAssertFalse(id(app, "chip.undo").exists)
        XCTAssertFalse(fix.exists, "Fix is not offered again for text the owner chose to keep")
        typeOnKeys(app, " ok")
        fix.tap()
        XCTAssertTrue(id(app, "chip.undo").waitForExistence(timeout: 10))
        XCTAssertEqual(text.label, "I can do the job ok.")
        Thread.sleep(forTimeInterval: 6.5)
        XCTAssertFalse(id(app, "chip.undo").exists, "Undo goes away after about 5 s")

        tapTool(app, "write.toggle")
        XCTAssertTrue(id(app, "write.professional").waitForExistence(timeout: 5))
        for tone in ["polite", "friendly", "shorter", "firmer", "grammar"] { XCTAssertTrue(id(app, "write.\(tone)").exists, tone) }
        Thread.sleep(forTimeInterval: 0.5)
        shot("42-refine-panel")
        id(app, "write.shorter").tap()
        XCTAssertTrue(id(app, "write.use").waitForExistence(timeout: 10))
        XCTAssertEqual(text.label, "I can do the job ok.", "a preview does not change the message")
        Thread.sleep(forTimeInterval: 0.5)
        shot("43-refine-preview")
        id(app, "write.preview").tap()
        XCTAssertEqual(text.label, "Please pay today.")
        XCTAssertTrue(id(app, "muninn.more").waitForExistence(timeout: 3), "keys come back")

        clearLab(app, text)
        typeOnKeys(app, "me and him is coming at noon")
        tapTool(app, "write.toggle")
        id(app, "write.grammar").tap()
        let grammarUse = id(app, "write.use")
        let grammarFine = element(app, "label BEGINSWITH %@", "The grammar looks good")
        XCTAssertTrue(grammarUse.waitForExistence(timeout: 10) || grammarFine.exists, app.debugDescription)
        Thread.sleep(forTimeInterval: 0.5)
        shot("44-fix-grammar")
        id(app, "write.toggle").tap()

        clearLab(app, text)
        typeOnKeys(app, ";prices")
        Thread.sleep(forTimeInterval: 0.5)
        shot("45-shortcut-typed")
        id(app, "space").tap()
        XCTAssertEqual(text.label, "Prices: cut $45, color $120, blowout $35")
        shot("46-shortcut-expanded")

        clearLab(app, text)
        typeOnKeys(app, ";pay 45")
        id(app, "space").tap()
        let pay = id(app, "chip.paylink")
        XCTAssertTrue(pay.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(text.label, "Type with the keyboard below", "the trigger is gone and no link is made before the tap")
        Thread.sleep(forTimeInterval: 0.5)
        shot("47-shortcut-pay-chip")
        pay.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "lab.text", "paypal.com")).firstMatch.waitForExistence(timeout: 15))

        clearLab(app, text)
        typeOnKeys(app, ";late")
        id(app, "space").tap()
        XCTAssertTrue(element(app, "label BEGINSWITH %@", "Ana $90").waitForExistence(timeout: 10), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.5)
        shot("48-shortcut-late")
    }

    /// The Shortcuts screen: the three actions and the price note. Change a trigger, turn it back. No model call.
    func test21ShortcutsScreen() {
        let app = XCUIApplication()
        app.launch()
        id(app, "nav.shortcuts").tap()
        XCTAssertTrue(id(app, "shortcut.pay").waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(id(app, "shortcut.late").exists && id(app, "shortcut.fix").exists)
        XCTAssertTrue(app.staticTexts[";prices"].exists, app.debugDescription)
        Thread.sleep(forTimeInterval: 0.5)
        shot("49-shortcuts-screen")
        func setTrigger(_ value: String) {
            id(app, "shortcut.late").tap()
            let field = id(app, "shortcut.trigger")
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + value)
        }
        setTrigger(";pay")
        XCTAssertTrue(app.staticTexts["Another shortcut uses ;pay."].waitForExistence(timeout: 3), "a trigger in use is refused")
        let field = id(app, "shortcut.trigger")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + ";owed")
        Thread.sleep(forTimeInterval: 0.5)
        shot("49b-shortcut-editor")
        id(app, "shortcut.save").tap()
        XCTAssertTrue(app.staticTexts[";owed"].waitForExistence(timeout: 5), app.debugDescription)
        setTrigger(";late")
        id(app, "shortcut.save").tap()
        XCTAssertTrue(app.staticTexts[";late"].waitForExistence(timeout: 5))

        id(app, "shortcuts.new").tap()
        let trigger = id(app, "note.trigger")
        XCTAssertTrue(trigger.waitForExistence(timeout: 5))
        trigger.tap()
        trigger.typeText("hours")
        id(app, "note.text").tap()
        id(app, "note.text").typeText("Open Tue to Sat, 9 to 6.")
        id(app, "note.save").tap()
        XCTAssertTrue(app.staticTexts[";hours"].waitForExistence(timeout: 5), app.debugDescription)
        element(app, "label CONTAINS %@", "Open Tue to Sat").tap()
        id(app, "note.delete").tap()
        XCTAssertFalse(app.staticTexts[";hours"].waitForExistence(timeout: 2), "a deleted shortcut is gone")
    }

    /// The Ask bar against `npm run fake`: one request to /v1/ask shown as a line, one shown as the keyboard's chips.
    /// Run with TEST_RUNNER_FAKE_URL=http://127.0.0.1:<port>. It pairs the app with that server. No model call.
    func test17AskRouter() throws {
        let fake = try XCTUnwrap(env["FAKE_URL"].flatMap(URL.init), "set TEST_RUNNER_FAKE_URL to the fake server")
        func next(_ json: String) {
            var r = URLRequest(url: fake.appendingPathComponent("_next"))
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data(json.utf8)
            let sent = expectation(description: "fake answer set")
            URLSession.shared.dataTask(with: r) { _, _, _ in sent.fulfill() }.resume()
            wait(for: [sent], timeout: 5)
        }
        let app = XCUIApplication()
        app.launch()
        // Pair with the fake through the dev link. iOS asks before it opens the app.
        XCUIDevice.shared.system.open(URL(string: "muninn-dev://pair?token=pkd_fake&server=\(fake.absoluteString)")!)
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 5) { open.tap() }
        Thread.sleep(forTimeInterval: 2)
        // Home loads once at launch, so start again on the new server.
        app.terminate()
        app.launch()
        XCTAssertTrue(element(app, "label CONTAINS %@", "Jordan Ray").waitForExistence(timeout: 15), "Home did not load from the fake server")
        let field = element(app, "identifier == %@", "ask.field")
        XCTAssertTrue(field.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(field.placeholderValue, "Ask Muninn anything")
        field.tap()
        let other = element(app, "label == %@", "Next keyboard")
        for _ in 0..<4 where other.exists && !(app.keys["q"].waitForExistence(timeout: 1.5) || app.keys["Q"].exists) { other.tap() }

        next(#"{"group":{"group":"info"},"route":{"route":"who_paid"}}"#)
        field.typeText("who hasn't paid\n")
        XCTAssertTrue(element(app, "label BEGINSWITH %@", "Jordan Ray $120").waitForExistence(timeout: 10), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.6)
        shot("40-ask-who-paid")

        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20))
        next(#"{"ext":{"client_name":"Jordan Ray","client_email":null,"amount":120,"item":"logo"}}"#)
        field.typeText("invoice Jordan Ray $120 for the logo\n")
        XCTAssertTrue(element(app, "identifier == %@", "ask.chip.invoice").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(element(app, "identifier == %@", "ask.chip.paylink").exists)
        Thread.sleep(forTimeInterval: 0.6)
        shot("41-ask-money-chips")
    }
}
