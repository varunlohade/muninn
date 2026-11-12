import XCTest

/// The catalog in the app and in the real Muninn keyboard in Messages, against `npm run fake` (no model call, no PayPal).
/// Run test1Setup once per simulator, then test2Shots, with TEST_RUNNER_FAKE_URL and TEST_RUNNER_SHOT_DIR.
final class CatalogShots: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    private let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")

    override func setUp() { continueAfterFailure = false }

    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 0.8)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = env["SHOT_DIR"] { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")) }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", id)).firstMatch
    }

    private func label(_ app: XCUIApplication, _ format: String, _ arg: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: format, arg)).firstMatch
    }

    private func tap(_ app: XCUIApplication, _ labels: [String], timeout: TimeInterval = 8) {
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

    /// Pairs with the fake server, then turns on the keyboard with Full Access.
    func test1Setup() throws {
        // A dev pairing link (muninn-dev://pair?...) opened before this test leaves an "Open in Muninn?" alert.
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 2) { open.tap(); Thread.sleep(forTimeInterval: 3) }
        let app = XCUIApplication()
        app.activate()
        let mark = element(app, "onboarding.mark")
        if mark.waitForExistence(timeout: 6) {
            mark.press(forDuration: 1.3)
            let token = app.secureTextFields["token"]
        if token.waitForExistence(timeout: 5) {
            let server = app.textFields.firstMatch
            server.tap()
            server.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 60) + (env["FAKE_URL"] ?? "http://127.0.0.1:8811"))
            token.tap()
            token.typeText("pkd_fake")
            app.buttons["Pair"].tap()
            for id in ["onboarding.later", "onboarding.add"] {
                let b = element(app, id)
                if b.waitForExistence(timeout: 8) { b.tap() }
            }
        }
        }
        // The intro tour, if it shows.
        let later = NSPredicate(format: "identifier ENDSWITH 'later' OR identifier ENDSWITH 'skip' OR identifier == 'onboarding.start' OR label == 'Skip' OR label == 'Not now'")
        for _ in 0..<10 where !app.descendants(matching: .any)["home.earned"].waitForExistence(timeout: 2) {
            let b = app.buttons.matching(later).firstMatch
            if b.exists && b.isHittable { b.tap() }
        }
        XCTAssertTrue(app.descendants(matching: .any)["home.earned"].waitForExistence(timeout: 15), String(app.debugDescription.prefix(4000)))

        settings.launch()
        tap(settings, ["General"], timeout: 12)
        tap(settings, ["Keyboard"])
        tap(settings, ["Keyboards"])
        let ours = label(settings, "label BEGINSWITH %@", "Muninn")
        if !ours.waitForExistence(timeout: 3) {
            tap(settings, ["Add New Keyboard", "Add New Keyboard…"])
            let pick = label(settings, "label BEGINSWITH %@", "Muninn")
            if !pick.waitForExistence(timeout: 5) { tap(settings, ["Add New Keyboard", "Add New Keyboard…"]) }
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
    }

    /// Pastes text into the focused field, the fast way to type.
    private func paste(_ text: String, into field: XCUIElement) {
        UIPasteboard.general.string = text
        field.press(forDuration: 1.0)
        let p = label(messages, "label == %@", "Paste")
        XCTAssertTrue(p.waitForExistence(timeout: 4), "no Paste menu")
        p.tap()
        let allow = messages.alerts.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 1) { allow.tap() }
        UIPasteboard.general.items = []
        Thread.sleep(forTimeInterval: 0.5)
    }

    func test2Shots() {
        let app = XCUIApplication()
        app.launch()
        let nav = element(app, "nav.catalog")
        XCTAssertTrue(nav.waitForExistence(timeout: 15))
        nav.tap()
        XCTAssertTrue(element(app, "catalog.row.Haircut").waitForExistence(timeout: 10), String(app.debugDescription.suffix(3000)))
        Thread.sleep(forTimeInterval: 2)
        shot("01-app-catalog-list")

        element(app, "catalog.new").tap()
        let name = element(app, "catalog.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Beard trim")
        let price = element(app, "catalog.price")
        price.tap()
        price.typeText("20")
        let desc = element(app, "catalog.description")
        desc.tap()
        desc.typeText("Shape and line-up")
        let cat = element(app, "catalog.category")
        cat.tap()
        cat.typeText("Hair")
        shot("02-app-add-sheet")
        element(app, "catalog.save").tap()
        XCTAssertTrue(element(app, "catalog.row.Beard trim").waitForExistence(timeout: 10))

        // A new message in Messages, with our keyboard up.
        messages.terminate()
        messages.launch()
        // The first conversation in the list.
        let chat = messages.cells.firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 8), String(messages.debugDescription.suffix(3000)))
        chat.tap()
        let field = messages.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND (identifier == 'messageBodyField' OR placeholderValue == 'iMessage' OR label == 'Message')",
            XCUIElement.ElementType.textView.rawValue, XCUIElement.ElementType.textField.rawValue)).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), String(messages.debugDescription.suffix(3000)))
        field.tap()
        let intro = label(messages, "label == %@", "Continue")
        if intro.waitForExistence(timeout: 2) { intro.tap() }
        let ours = element(messages, "muninn.more")
        for _ in 0..<5 where !ours.waitForExistence(timeout: 1.5) {
            label(messages, "label == %@", "Next keyboard").tap()
        }
        XCTAssertTrue(ours.exists, "Muninn keyboard not shown")
        paste("Hi Ana! Here are our prices:", into: field)

        let toggle = element(messages, "catalog.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no catalog button in the bar")
        toggle.tap()
        let cut = element(messages, "catalog.item.Haircut")
        XCTAssertTrue(cut.waitForExistence(timeout: 5), String(messages.debugDescription.suffix(3000)))
        cut.tap()
        element(messages, "catalog.item.Blowout").tap()
        XCTAssertTrue(element(messages, "catalog.count").waitForExistence(timeout: 3))
        shot("03-keyboard-panel-2-selected")

        element(messages, "catalog.insert").tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(((field.value as? String) ?? "").contains("Haircut \u{2014} $45"), "\(field.value ?? "")")
        shot("04-inserted-in-chat")

        // The typed trigger: "do you have a blowout" offers the item chip.
        paste(" Do you have a blowout", into: field)
        element(messages, "space").tap()
        let chip = element(messages, "chip.catalog")
        if chip.waitForExistence(timeout: 5) { shot("05-typed-trigger-chip") }
    }
}
