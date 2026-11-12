import XCTest

/// The real flows against `npm run fake`, with screenshots. No model call, no PayPal call.
/// Run with TEST_RUNNER_FAKE_URL=http://127.0.0.1:<port> TEST_RUNNER_SHOT_DIR=<dir>, tests in name order.
/// The keyboard tests use the Messages search field, so the keyboard is the real extension.
final class WalkthroughTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")

    override func setUp() { continueAfterFailure = false }

    private var fake: URL { URL(string: env["FAKE_URL"] ?? "http://127.0.0.1:8799")! }

    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = env["SHOT_DIR"] { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent((env["SHOT_PREFIX"] ?? "") + name + ".png")) }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png"); a.name = name; a.lifetime = .keepAlways; add(a)
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

    private func next(_ json: String) { fakeCall("POST", "_next", json) }

    /// Rewrite and Notes sit behind the bar's "…" slot; this opens it first when the button is hidden.
    private func tapTool(_ app: XCUIApplication, _ identifier: String) {
        let tool = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
        let more = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", "bar.more")).firstMatch
        if !tool.exists, more.waitForExistence(timeout: 3) { more.tap() }
        XCTAssertTrue(tool.waitForExistence(timeout: 5), "no \(identifier) behind the bar's …")
        tool.tap()
    }

    /// Prints the requests the fake server saw since `from`, and saves the whole log next to the screenshots.
    private func dumpLog(_ name: String, from: Int) -> Int {
        let data = fakeCall("GET", "_log")
        if let dir = env["SHOT_DIR"] { try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + "-log.json")) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let reqs = obj["requests"] as? [[String: Any]] else { return from }
        for r in reqs.dropFirst(from) where (r["path"] as? String ?? "").hasPrefix("/v1/") {
            let body = (r["body"]).flatMap { JSONSerialization.isValidJSONObject($0) ? try? JSONSerialization.data(withJSONObject: $0) : nil }.map { String(decoding: $0, as: UTF8.self) } ?? ""
            print("FAKE_LOG \(name) \(r["method"] ?? "") \(r["path"] ?? "") \(r["status"] ?? "") \(body)")
        }
        return reqs.count
    }

    private func logCount() -> Int { dumpLog("count", from: Int.max) }

    // MARK: keyboard in Messages

    /// Opens the Messages search field with our keyboard up and the field empty.
    private func openKeyboard() -> XCUIElement {
        messages.launch()
        let search = messages.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8), messages.debugDescription)
        search.tap()
        let ours = id(messages, "muninn.more")
        for _ in 0..<5 where !ours.waitForExistence(timeout: 2) { label(messages, "label == %@", "Next keyboard").tap() }
        XCTAssertTrue(ours.exists, messages.debugDescription)
        clear(search)
        return search
    }

    private func clear(_ field: XCUIElement) {
        let delete = id(messages, "delete")
        for _ in 0..<4 where !((field.value as? String ?? "").isEmpty || field.value as? String == field.placeholderValue) {
            delete.press(forDuration: 3)
        }
    }

    /// Pastes all but the last character, then types the last one on our keys: one suggest call for the whole line.
    private func enter(_ field: XCUIElement, _ text: String, next answer: String? = nil) {
        UIPasteboard.general.string = String(text.dropLast())
        field.press(forDuration: 1.2)
        let paste = label(messages, "label == %@", "Paste")
        if !paste.waitForExistence(timeout: 2) { field.tap(); field.press(forDuration: 1.2) }
        XCTAssertTrue(paste.waitForExistence(timeout: 3), messages.debugDescription)
        let before = aiCalls()
        paste.tap()
        // The paste makes its own suggest call; set the fake answer after it, for the call on the last key.
        waitForAICalls(above: before)
        if let answer { next(answer) }
        typeKeys(String(text.last!))
    }

    private func key(_ ch: String) -> XCUIElement {
        messages.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] %@ AND identifier BEGINSWITH 'k.'", ch)).firstMatch
    }

    private func typeKeys(_ text: String) {
        var symbols = false
        for ch in text {
            if ch == " " { id(messages, "space").tap(); symbols = false; continue }
            let want = !ch.isLetter
            if symbols != want { id(messages, "muninn.more").tap(); symbols = want }
            let k = key(String(ch))
            XCTAssertTrue(k.waitForExistence(timeout: 3), "no key \(ch)")
            k.tap()
        }
        if symbols { id(messages, "muninn.more").tap() }
    }

    // MARK: tests

    /// A fresh app goes in through the intro's Skip and "Get started": one tap, no sign-in. The fake server makes the account.
    /// An app that is already in is pointed at the fake server with the Debug pairing link.
    func test00GetStarted() {
        let app = XCUIApplication()
        app.launchArguments = ["-calendarDemo", "-serverURL", fake.absoluteString]
        app.launch()
        if id(app, "onboarding.add").waitForExistence(timeout: 6) { id(app, "onboarding.add").tap() }
        if id(app, "onboarding.later").waitForExistence(timeout: 3) { id(app, "onboarding.later").tap() }
        if id(app, "onboarding.calendar.later").waitForExistence(timeout: 3) { id(app, "onboarding.calendar.later").tap() }
        let start = id(app, "onboarding.start")
        if start.waitForExistence(timeout: 3) {
            shot("00-get-started")
            start.tap()
            if id(app, "onboarding.paypal.demo").waitForExistence(timeout: 10) { id(app, "onboarding.paypal.demo").tap() }
            // The business question follows the PayPal step; these runs leave it for later.
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
        for a in [app, springboard] where a.buttons["Not Now"].waitForExistence(timeout: 2) { a.buttons["Not Now"].tap() }
        shot("00-home-on-fake")
    }

    func test01KeyboardInvoice() {
        var mark = logCount()
        let field = openKeyboard()
        shot("01a-keyboard-empty")
        enter(field, "that's $45 for the haircut, sam@example.com",
              next: #"{"cls":{"intent":"create_invoice","confidence":0.95},"ext":{"client_name":"Sam","client_email":"sam@example.com","amount":45,"currency":"USD","item":"haircut"}}"#)
        let chip = id(messages, "chip.invoice")
        XCTAssertTrue(chip.waitForExistence(timeout: 15), messages.debugDescription)
        print("CHIP_LABEL", chip.label)
        shot("01b-keyboard-invoice-chips")
        mark = dumpLog("01b", from: mark)
        chip.tap()
        let confirm = id(messages, "chip.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), messages.debugDescription)
        print("CONFIRM_LABEL", confirm.label)
        shot("01c-keyboard-invoice-confirm")
        confirm.tap()
        let sent = label(messages, "identifier IN %@", "chip.waiting,chip.done,chip.error,chip.retry")
        _ = sent.waitForExistence(timeout: 20)
        Thread.sleep(forTimeInterval: 1)
        print("AFTER_LABEL", sent.identifier, sent.label)
        print("FIELD_VALUE", field.value as? String ?? "")
        shot("01d-keyboard-invoice-sent")
        _ = dumpLog("01d", from: mark)
        XCTAssertTrue((field.value as? String ?? "").contains("paypal"), field.value as? String ?? "")
    }

    func test02KeyboardRemind() {
        var mark = logCount()
        let field = openKeyboard()
        enter(field, "remind Jordan", next: #"{"cls":{"intent":"send_reminder","confidence":0.95},"ext":{"client_name":"Jordan","client_email":null,"amount":null,"item":null}}"#)
        let chip = id(messages, "chip.remind")
        XCTAssertTrue(chip.waitForExistence(timeout: 15), messages.debugDescription)
        print("CHIP_LABEL", chip.label)
        shot("02a-keyboard-remind-chip")
        mark = dumpLog("02a", from: mark)
        chip.tap()
        let confirm = id(messages, "chip.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), messages.debugDescription)
        print("CONFIRM_LABEL", confirm.label)
        shot("02b-keyboard-remind-confirm")
        confirm.tap()
        let after = label(messages, "identifier IN %@", "chip.done,chip.error,chip.retry,chip.waiting")
        XCTAssertTrue(after.waitForExistence(timeout: 20), messages.debugDescription)
        print("AFTER_LABEL", after.identifier, after.label)
        shot("02c-keyboard-remind-done")
        _ = dumpLog("02c", from: mark)
        XCTAssertEqual(after.identifier, "chip.done", after.label)
    }

    func test03PayShortcut() {
        let mark = logCount()
        let field = openKeyboard()
        typeKeys(";pay 45")
        id(messages, "space").tap()
        let pay = id(messages, "chip.paylink")
        XCTAssertTrue(pay.waitForExistence(timeout: 5), messages.debugDescription)
        print("CHIP_LABEL", pay.label)
        shot("03a-keyboard-pay-shortcut-chip")
        pay.tap()
        let confirm = id(messages, "chip.confirm")
        if confirm.waitForExistence(timeout: 3) { shot("03b-keyboard-pay-confirm"); confirm.tap() }
        let linked = NSPredicate(format: "value CONTAINS %@", "paypal")
        expectation(for: linked, evaluatedWith: field)
        waitForExpectations(timeout: 20)
        print("FIELD_VALUE", field.value as? String ?? "")
        shot("03c-keyboard-pay-link-inserted")
        _ = dumpLog("03c", from: mark)
    }

    func test04AskBar() {
        var mark = logCount()
        let app = XCUIApplication()
        app.launch()
        let field = id(app, "ask.field")
        XCTAssertTrue(field.waitForExistence(timeout: 15), app.debugDescription)
        field.tap()
        let other = label(app, "label == %@", "Next keyboard")
        for _ in 0..<5 where !(app.keys["q"].waitForExistence(timeout: 1.5) || app.keys["Q"].exists) { if other.exists { other.tap() } }
        func ask(_ text: String, _ setNext: String) {
            field.tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 50))
            next(setNext)
            field.typeText(text + "\n")
        }

        ask("who hasn't paid", #"{"group":{"group":"info"},"route":{"route":"who_paid"}}"#)
        XCTAssertTrue(id(app, "unpaid.card.Jordan Ray").waitForExistence(timeout: 10), app.debugDescription)
        shot("04a-ask-who-paid")

        ask("invoice Jordan Ray $120 for the logo", #"{"group":{"group":"money"},"route":{"route":"invoice"},"ext":{"client_name":"Jordan Ray","client_email":null,"amount":120,"currency":"USD","item":"logo"}}"#)
        let chip = id(app, "ask.chip.invoice")
        XCTAssertTrue(chip.waitForExistence(timeout: 10), app.debugDescription)
        print("CHIP_LABEL", chip.label)
        shot("04b-ask-invoice-chip")
        chip.tap()
        // "Email Jordan Ray (jordan.ray@…) a $120 invoice?" or, with no email, "Make a $120 invoice link for Jordan Ray?"
        let confirm = label(app, "label BEGINSWITH %@", "Email ")
        let confirmLink = label(app, "label BEGINSWITH %@", "Make a $")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5) || confirmLink.exists, app.debugDescription)
        let c = confirm.exists ? confirm : confirmLink
        print("CONFIRM_LABEL", c.label)
        shot("04c-ask-invoice-confirm")
        c.tap()
        let result = id(app, "ask.result")
        _ = result.waitForExistence(timeout: 15)
        print("AFTER", result.exists ? result.label : String(app.debugDescription.suffix(3000)))
        shot("04d-ask-invoice-result")
        mark = dumpLog("04d", from: mark)
        if id(app, "Done").exists { id(app, "Done").tap() } else if app.buttons["Done"].exists { app.buttons["Done"].tap() }

        ask("add a note: buy shampoo", #"{"group":{"group":"device"},"route":{"route":"add_note"}}"#)
        XCTAssertTrue(label(app, "label BEGINSWITH %@", "Note saved").waitForExistence(timeout: 10), app.debugDescription)
        shot("04e-ask-add-note")

        ask("what's on today", #"{"group":{"group":"device"},"route":{"route":"today_calendar"}}"#)
        let line = label(app, "label CONTAINS %@", " · ")
        _ = line.waitForExistence(timeout: 10)
        shot("04f-ask-today")
        _ = dumpLog("04f", from: mark)

        id(app, "nav.notes").tap()
        XCTAssertTrue(label(app, "label CONTAINS[c] %@", "shampoo").waitForExistence(timeout: 5), "the note is on the Notes screen")
        shot("04g-notes-has-shampoo")
    }

    func test05WritingTools() {
        let mark = logCount()
        let field = openKeyboard()
        typeKeys("i can do teh job")
        let fix = id(messages, "chip.fix")
        let fixShown = fix.waitForExistence(timeout: 6)
        shot("05a-keyboard-fix-offered")
        if fixShown {
            fix.tap()
            _ = id(messages, "chip.undo").waitForExistence(timeout: 10)
            print("AFTER_FIX", field.value as? String ?? "")
            shot("05b-keyboard-fix-done")
        } else {
            print("NO_FIX_CHIP", messages.debugDescription.suffix(3000))
        }

        tapTool(messages, "write.toggle")
        XCTAssertTrue(id(messages, "write.friendly").waitForExistence(timeout: 5), messages.debugDescription)
        shot("05c-keyboard-refine-panel")
        id(messages, "write.friendly").tap()
        XCTAssertTrue(id(messages, "write.use").waitForExistence(timeout: 10), messages.debugDescription)
        shot("05d-keyboard-refine-preview")
        id(messages, "write.use").tap()
        print("AFTER_REFINE", field.value as? String ?? "")

        tapTool(messages, "write.toggle")
        id(messages, "write.grammar").tap()
        let grammarUse = id(messages, "write.use")
        let grammarFine = label(messages, "label BEGINSWITH %@", "The grammar looks good")
        _ = grammarUse.waitForExistence(timeout: 10) || grammarFine.exists
        shot("05e-keyboard-fix-grammar")
        print("GRAMMAR", grammarFine.exists ? grammarFine.label : "use button: \(grammarUse.exists)")
        _ = dumpLog("05e", from: mark)
        if id(messages, "write.toggle").exists { id(messages, "write.toggle").tap() }
    }

    func test06NotesAndCalendar() {
        let field = openKeyboard()
        let bill = id(messages, "chip.bill")
        let billShown = bill.waitForExistence(timeout: 6)
        let nextUp = label(messages, "label BEGINSWITH %@", "Next: ")
        print("BILL_CHIP", billShown ? bill.label : "none", "NEXT", nextUp.exists ? nextUp.label : "none")
        shot("06a-keyboard-calendar-chip")

        tapTool(messages, "notes.toggle")
        let prices = label(messages, "label BEGINSWITH %@", "Prices: cut $45")
        XCTAssertTrue(prices.waitForExistence(timeout: 3), messages.debugDescription)
        shot("06b-keyboard-notes-panel")
        prices.tap()
        print("FIELD_VALUE", field.value as? String ?? "")
        shot("06c-keyboard-note-inserted")
        clear(field)

        guard billShown else { return }
        let mark = logCount()
        XCTAssertTrue(bill.waitForExistence(timeout: 5), "bill chip is back on an empty field")
        bill.tap()
        let prompt = id(messages, "chip.done")
        _ = prompt.waitForExistence(timeout: 5)
        print("BILL_PROMPT", prompt.exists ? prompt.label : "none")
        shot("06d-keyboard-calendar-type-amount")
        next(#"{"cls":{"intent":"create_invoice","confidence":0.95},"ext":{"client_name":"Ava Chen","client_email":null,"amount":45,"currency":"USD","item":"Color"}}"#)
        typeKeys("45")
        let chip = id(messages, "chip.invoice")
        _ = chip.waitForExistence(timeout: 15)
        print("BILL_INVOICE_CHIP", chip.exists ? chip.label : "none")
        shot("06e-keyboard-calendar-invoice-chip")
        _ = dumpLog("06e", from: mark)
    }

    /// "Who hasn't paid" in the keyboard and in the Ask bar. Remind asks first, then sends through the remind route with the client's name.
    func test07WhoPaidRemind() {
        var mark = logCount()
        let remindsBefore = reminds()
        _ = openKeyboard()
        typeKeys(";late")
        id(messages, "space").tap()
        let header = id(messages, "whopaid.header")
        XCTAssertTrue(header.waitForExistence(timeout: 10), messages.debugDescription)
        print("WHOPAID_HEADER", header.label)
        XCTAssertTrue(header.label.contains("unpaid"))
        XCTAssertTrue(key("q").exists, "the keys stay under the list")
        shot("07a-keyboard-who-paid-list")
        id(messages, "whopaid.remind.Jordan Ray").tap()
        let confirm = id(messages, "chip.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), messages.debugDescription)
        print("CONFIRM_LABEL", confirm.label)
        XCTAssertEqual(confirm.label, "Email Jordan Ray a reminder for $120?")
        shot("07b-keyboard-who-paid-confirm")
        XCTAssertEqual(reminds(), remindsBefore, "no reminder goes out before the confirm tap")
        confirm.tap()
        let after = label(messages, "identifier IN %@", "chip.done,chip.error,chip.retry")
        XCTAssertTrue(after.waitForExistence(timeout: 20), messages.debugDescription)
        print("AFTER_LABEL", after.identifier, after.label)
        shot("07c-keyboard-who-paid-reminded")
        XCTAssertEqual(after.identifier, "chip.done", after.label)
        XCTAssertEqual(reminds(), remindsBefore + 1, "one reminder for one confirm tap")
        mark = dumpLog("07c", from: mark)
        id(messages, "whopaid.close").tap()
        XCTAssertFalse(header.waitForExistence(timeout: 1))

        let app = XCUIApplication()
        app.launch()
        let field = id(app, "ask.field")
        XCTAssertTrue(field.waitForExistence(timeout: 15), app.debugDescription)
        field.tap()
        next(#"{"group":{"group":"info"},"route":{"route":"who_paid"}}"#)
        field.typeText("who hasn't paid\n")
        let total = id(app, "unpaid.header")
        XCTAssertTrue(total.waitForExistence(timeout: 10), app.debugDescription)
        print("UNPAID_HEADER", total.label)
        shot("07d-ask-who-paid-cards")
        // The test runner may not read the app's pasteboard, so the check is the button's own answer.
        let copy = id(app, "unpaid.copy.Jordan Ray")
        copy.tap()
        XCTAssertTrue(label(app, "identifier == 'unpaid.copy.Jordan Ray' AND label == %@", "Copied").waitForExistence(timeout: 3), copy.label)
        id(app, "unpaid.remind.Jordan Ray").tap()
        let askConfirm = id(app, "ask.confirm")
        XCTAssertTrue(askConfirm.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(askConfirm.label, "Email Jordan Ray a reminder for $120?")
        shot("07e-ask-who-paid-confirm")
        askConfirm.tap()
        XCTAssertTrue(label(app, "label BEGINSWITH %@", "Reminder emailed").waitForExistence(timeout: 15), app.debugDescription)
        shot("07f-ask-who-paid-reminded")
        _ = dumpLog("07f", from: mark)
    }

    private func reminds() -> Int { String(decoding: fakeCall("GET", "_log"), as: UTF8.self).components(separatedBy: "/v1/actions/remind").count }

    /// Repeat billing from the Ask bar: the chip, the confirm with amount, interval and recipient, then the approve link.
    func test08Subscribe() {
        let mark = logCount()
        let app = XCUIApplication()
        app.launch()
        let field = id(app, "ask.field")
        XCTAssertTrue(field.waitForExistence(timeout: 15), app.debugDescription)
        field.tap()
        next(#"{"group":{"group":"money"},"route":{"route":"subscribe"},"ext":{"client_name":"Sam","client_email":null,"amount":40,"currency":"USD","item":null}}"#)
        field.typeText("bill Sam $40 monthly\n")
        let chip = id(app, "ask.chip.subscribe")
        XCTAssertTrue(chip.waitForExistence(timeout: 10), app.debugDescription)
        print("CHIP_LABEL", chip.label)
        shot("08a-ask-repeat-chip")
        chip.tap()
        let confirm = id(app, "ask.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        print("CONFIRM_LABEL", confirm.label)
        XCTAssertTrue(confirm.label.hasPrefix("Repeat $40 monthly to Sam") || confirm.label.hasPrefix("Repeat $40 monthly to sam@"), confirm.label)
        shot("08b-ask-repeat-confirm")
        let log = { String(decoding: self.fakeCall("GET", "_log"), as: UTF8.self) }
        let sentBefore = log().components(separatedBy: "/v1/actions/subscribe").count
        confirm.tap()
        let link = id(app, "ask.link")
        XCTAssertTrue(link.waitForExistence(timeout: 15), app.debugDescription)
        print("APPROVE_LINK", link.label)
        shot("08c-ask-repeat-link")
        XCTAssertEqual(log().components(separatedBy: "/v1/actions/subscribe").count, sentBefore + 1, "one subscribe call for one confirm tap")
        XCTAssertTrue(link.label.hasPrefix("https://"), link.label)
        id(app, "ask.copy").tap()
        XCTAssertTrue(label(app, "identifier == 'ask.copy' AND label == %@", "Copied").waitForExistence(timeout: 3))
        _ = dumpLog("08c", from: mark)
    }
}
