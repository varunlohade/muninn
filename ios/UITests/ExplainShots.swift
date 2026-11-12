import XCTest

/// Explain in the real Muninn keyboard, in a Messages chat, against `npm run fake` (no model call; the fake answers with
/// the log-function fixtures). Run SmartChipShots/test1Setup first to pair and turn the keyboard on, then this, with
/// TEST_RUNNER_SHOT_DIR set. It never taps "Play with voice".
final class ExplainShots: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")

    override func setUp() { continueAfterFailure = false }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = env["SHOT_DIR"] { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")) }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", id)).firstMatch
    }

    private func label(_ app: XCUIApplication, _ l: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", l)).firstMatch
    }

    /// A Messages chat to a test number, with the Muninn keyboard up in the message box.
    private func openField() -> XCUIElement {
        messages.terminate()
        XCUIDevice.shared.system.open(URL(string: "sms:+15555550123")!)
        XCTAssertTrue(messages.wait(for: .runningForeground, timeout: 10), "Messages did not open")
        let body = messages.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'messageBodyField' OR placeholderValue IN {'iMessage', 'Text Message', 'Message', 'Text Message • SMS'}")).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 8), "no message box: \(messages.debugDescription.suffix(3000))")
        body.tap()
        let intro = label(messages, "Continue")
        if intro.waitForExistence(timeout: 2) { intro.tap() }
        let ours = element(messages, "muninn.more")
        for _ in 0..<5 where !ours.waitForExistence(timeout: 1.5) { label(messages, "Next keyboard").tap() }
        XCTAssertTrue(ours.exists, "Muninn keyboard not shown")
        return body
    }

    /// Empties the message box, pastes the text, then taps Muninn's space key so the keyboard reads it as typed.
    private func enter(_ text: String, in field: XCUIElement) {
        let delete = element(messages, "delete")
        for _ in 0..<6 where !((field.value as? String) ?? "").isEmpty && (field.value as? String) != field.placeholderValue {
            delete.press(forDuration: 2.5)
        }
        UIPasteboard.general.string = text
        field.press(forDuration: 1.0)
        let paste = label(messages, "Paste")
        XCTAssertTrue(paste.waitForExistence(timeout: 4), "no Paste menu")
        paste.tap()
        let allow = messages.alerts.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 1) { allow.tap() }
        Thread.sleep(forTimeInterval: 0.6)
        UIPasteboard.general.items = []
        Thread.sleep(forTimeInterval: 0.3)
        element(messages, "space").tap()
    }

    private func waitDrawn(_ what: String) {
        let title = element(messages, "explain.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let started = Date().addingTimeInterval(8)
        while !title.label.contains("step"), Date() < started { Thread.sleep(forTimeInterval: 0.1) }
        let done = Date().addingTimeInterval(25)
        while title.label.contains("step"), Date() < done { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertFalse(title.label.contains("step"), "\(what) did not finish: \(title.label)")
        Thread.sleep(forTimeInterval: 0.6)
    }

    /// Pairs with the fake server through the Debug pairing link, then turns on the keyboard with Full Access.
    func test1Setup() throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let server = env["FAKE_URL"] ?? "http://127.0.0.1:8799"
        XCUIDevice.shared.system.open(URL(string: "muninn-dev://pair?token=pkd_fake&server=\(server)")!)
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 4) { open.tap() }
        Thread.sleep(forTimeInterval: 4)

        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        func tap(_ labels: [String], timeout: TimeInterval = 8) {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                for l in labels {
                    let cell = settings.cells.containing(NSPredicate(format: "label == %@", l)).firstMatch
                    let e = cell.exists ? cell : label(settings, l)
                    if e.exists && e.isHittable { e.tap(); Thread.sleep(forTimeInterval: 1.2); return }
                }
                Thread.sleep(forTimeInterval: 0.3)
            } while Date() < deadline
            XCTFail("none of \(labels) found")
        }
        settings.launch()
        tap(["General"], timeout: 12)
        tap(["Keyboard"])
        tap(["Keyboards"])
        let ours = settings.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Muninn")).firstMatch
        if !ours.waitForExistence(timeout: 3) {
            tap(["Add New Keyboard", "Add New Keyboard…"])
            let pick = settings.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Muninn")).firstMatch
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

    func test2Explain() {
        let field = openField()
        let chip = element(messages, "chip.explain")

        enter("what does btw mean", in: field)
        XCTAssertTrue(chip.waitForExistence(timeout: 4), "no btw chip")
        Thread.sleep(forTimeInterval: 0.6)
        shot("01-btw-chip")

        enter("explain log function", in: field)
        let more = element(messages, "chip.explain.more")
        XCTAssertTrue(more.waitForExistence(timeout: 8), "no explain chip from the server")
        more.tap()
        let visual = element(messages, "explain.visual")
        XCTAssertTrue(visual.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.4)
        shot("02-explain-log-card")
        visual.tap()
        waitDrawn("log")
        shot("03-explain-log-drawing")

        // One tap on Send: the upload runs now, then the caption and the short link replace the typed request.
        element(messages, "visual.send").tap()
        let note = element(messages, "visual.note")
        let linked = NSPredicate(format: "label BEGINSWITH %@", "Link added")
        let linkBy = Date().addingTimeInterval(8)
        while !(note.exists && linked.evaluate(with: note)), Date() < linkBy { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertTrue(note.exists && linked.evaluate(with: note), "no Link added note: \(note.exists ? note.label : "none")")
        let typed = field.value as? String ?? ""
        XCTAssertTrue(typed.contains("log function, explained: http") && typed.contains("/d/"), "no caption and link in the field: \(typed)")
        shot("04-send-link-inserted")
        // Send as image waits in the small menu.
        element(messages, "visual.more").tap()
        XCTAssertTrue(element(messages, "visual.send.image").waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.3)
        shot("04b-send-menu")
        element(messages, "visual.export.back").tap()
        element(messages, "explain.close").tap()

        enter("graph my sales this week", in: field)
        XCTAssertTrue(chip.waitForExistence(timeout: 4), "no sales chart chip")
        Thread.sleep(forTimeInterval: 0.4)
        shot("05-sales-chart-chip")
        chip.tap()
        waitDrawn("sales chart")
        shot("06-sales-chart")
        element(messages, "explain.close").tap()
    }

    /// The projection from PayPal months. Load the history first: `curl -X POST $FAKE_URL/_chart-history`.
    func test3Projection() {
        let field = openField()
        let chip = element(messages, "chip.explain")
        enter("show revenue next 3 months", in: field)
        XCTAssertTrue(chip.waitForExistence(timeout: 4), "no projection chip")
        chip.tap()
        waitDrawn("projection")
        XCTAssertFalse(element(messages, "visual.voice").exists, "a chart has no read-aloud button")
        XCTAssertTrue(element(messages, "visual.replay").exists)
        shot("07-projection")
        element(messages, "explain.close").tap()
    }

    /// Opens and closes the projection chart 20 times, typing between opens. Each open must draw (no blank panel, no error line).
    /// Writes "open epoch" lines to SHOT_DIR/stress.txt so a memory log can be read at opens 1, 10 and 20.
    func test4Stress() {
        let field = openField()
        let chip = element(messages, "chip.explain")
        var marks = ""
        for i in 1...20 {
            if i == 1 { enter("show revenue next 3 months", in: field) }
            XCTAssertTrue(chip.waitForExistence(timeout: 4), "no projection chip at open \(i)")
            chip.tap()
            waitDrawn("projection \(i)")
            XCTAssertTrue(element(messages, "visual.canvas").exists, "no canvas at open \(i)")
            XCTAssertFalse(element(messages, "visual.status").exists, "panel shows a status line at open \(i)")
            marks += "\(i) \(Date().timeIntervalSince1970)\n"
            if [1, 10, 20].contains(i) { shot("stress-\(i)") }
            element(messages, "explain.close").tap()
            element(messages, "space").tap()
            for c in "hello" {
                let key = messages.descendants(matching: .any).matching(NSPredicate(format: "identifier LIKE[c] %@", "k.*.\(c)")).firstMatch
                XCTAssertTrue(key.waitForExistence(timeout: 3), "no key \(c) at open \(i): \(messages.debugDescription.suffix(2500))")
                key.tap()
            }
            // Delete " hello" so the sentence is the chart question again and its chip comes back.
            for _ in 0..<6 { element(messages, "delete").tap() }
        }
        if let dir = env["SHOT_DIR"] { try? marks.write(toFile: dir + "/stress.txt", atomically: true, encoding: .utf8) }
    }
}
