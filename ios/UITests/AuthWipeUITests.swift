import XCTest

/// Sign in as user A, see A's client; log out; sign in as user B: A's client is nowhere in the app or the keyboard.
/// Runs against `npm run fake` (FAKE_URL), with the keyboard already on with Full Access (ExplainShots/test1Setup).
/// Screenshots go to SHOT_DIR: the sign-in step, Settings with Log out.
final class AuthWipeUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
    private let clientA = "Alice Anders"
    private let password = "plum-orchard-river-42"

    override func setUp() { continueAfterFailure = false }

    /// Log out really ends the session, so when the app started paired with the fake's shared pkd_fake token, that token is gone.
    /// A fresh fake keeps the other UI tests working.
    override func tearDown() { call("POST", "_reset", [:]) }

    private var fake: URL { URL(string: env["FAKE_URL"] ?? "http://127.0.0.1:8799")! }

    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = env["SHOT_DIR"] { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")) }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png"); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func id(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
    }

    private func mentions(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@ OR identifier CONTAINS %@", text, text, text)).firstMatch
    }

    @discardableResult
    private func call(_ method: String, _ path: String, _ body: [String: String], token: String? = nil) -> [String: Any] {
        var r = URLRequest(url: fake.appendingPathComponent(path))
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            r.setValue("tap", forHTTPHeaderField: "X-User-Action")
            r.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
        }
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        var out: [String: Any] = [:]
        let done = expectation(description: path)
        URLSession.shared.dataTask(with: r) { d, _, _ in
            out = (d.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return out
    }

    /// From any state to the sign-in step: Home logs out through Settings; onboarding skips to the sign-in step.
    private func toSignIn(_ app: XCUIApplication) {
        if id(app, "nav.integrations").waitForExistence(timeout: 5) { logOut(app, shotName: nil) }
        if id(app, "onboarding.skip").waitForExistence(timeout: 2) { id(app, "onboarding.skip").tap() }
        if id(app, "onboarding.later").waitForExistence(timeout: 2) { id(app, "onboarding.later").tap() }
        if id(app, "onboarding.default.later").waitForExistence(timeout: 2) { id(app, "onboarding.default.later").tap() }
        if id(app, "onboarding.default.next").waitForExistence(timeout: 1) { id(app, "onboarding.default.next").tap() }
        if id(app, "onboarding.calendar.later").waitForExistence(timeout: 2) { id(app, "onboarding.calendar.later").tap() }
        XCTAssertTrue(id(app, "signin.email").waitForExistence(timeout: 8), "no sign-in step: \(app.debugDescription.suffix(2000))")
    }

    private func logOut(_ app: XCUIApplication, shotName: String?) {
        let nav = id(app, "nav.integrations")
        XCTAssertTrue(nav.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        nav.tap()
        XCTAssertTrue(id(app, "settings.business").waitForExistence(timeout: 8), "Settings did not open")
        let out = id(app, "account.logout")
        for _ in 0..<8 where !(out.exists && out.isHittable) { app.swipeUp() }
        XCTAssertTrue(out.waitForExistence(timeout: 5))
        if let shotName {
            XCTAssertTrue(mentions(app, "Email: ").waitForExistence(timeout: 5), "Settings lists the linked email")
            shot(shotName)
        }
        out.tap()
    }

    /// The email form: pick the mode, type, submit, then the PayPal and business steps take their skip buttons.
    private func signIn(_ app: XCUIApplication, email: String, login: Bool) {
        id(app, "signin.email").tap()
        if login { app.segmentedControls.buttons["Log in"].tap() }
        let field = id(app, "signin.field.email")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(email)
        let pw = id(app, "signin.field.password")
        pw.tap()
        // iOS offers a strong password on sign-up; this test types its own.
        for name in ["Choose My Own Password", "Close"] where app.buttons[name].waitForExistence(timeout: 1.5) {
            app.buttons[name].tap()
            pw.tap()
            break
        }
        pw.typeText(password)
        for name in ["Not Now", "Close"] where app.buttons[name].waitForExistence(timeout: 1) { app.buttons[name].tap(); break }
        id(app, "signin.submit").tap()
        if id(app, "onboarding.paypal.demo").waitForExistence(timeout: 10) { id(app, "onboarding.paypal.demo").tap() }
        if id(app, "onboarding.business.later").waitForExistence(timeout: 5) { id(app, "onboarding.business.later").tap() }
        XCTAssertTrue(id(app, "nav.integrations").waitForExistence(timeout: 15), "Home did not open: \(app.debugDescription.suffix(2000))")
    }

    /// The keyboard's "who owes" list in Messages. With no one owing, the bar says so instead.
    private func keyboardWhoOwes(expectList: Bool) {
        messages.terminate()
        XCUIDevice.shared.system.open(URL(string: "sms:+15555550123")!)
        XCTAssertTrue(messages.wait(for: .runningForeground, timeout: 10), "Messages did not open")
        let body = messages.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'messageBodyField' OR placeholderValue IN {'iMessage', 'Text Message', 'Message', 'Text Message • SMS'}")).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 8), "no message box")
        body.tap()
        let intro = messages.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Continue")).firstMatch
        if intro.waitForExistence(timeout: 2) { intro.tap() }
        let ours = id(messages, "muninn.more")
        for _ in 0..<5 where !ours.waitForExistence(timeout: 1.5) { messages.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Next keyboard")).firstMatch.tap() }
        XCTAssertTrue(ours.exists, "Muninn keyboard not shown")
        for ch in ";late" {
            if ch == ";" { ours.tap() }
            let k = messages.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] %@ AND identifier BEGINSWITH 'k.'", String(ch))).firstMatch
            XCTAssertTrue(k.waitForExistence(timeout: 3), "no key \(ch)")
            k.tap()
            if ch == ";" { ours.tap() }
        }
        id(messages, "space").tap()
        if expectList {
            XCTAssertTrue(id(messages, "whopaid.header").waitForExistence(timeout: 10), messages.debugDescription)
        } else {
            XCTAssertTrue(mentions(messages, "Everyone's paid").waitForExistence(timeout: 10) || id(messages, "whopaid.header").exists, messages.debugDescription)
        }
        Thread.sleep(forTimeInterval: 1)
    }

    func testLogoutLeavesNoTraceOfTheLastUser() {
        let tag = String(UUID().uuidString.prefix(8)).lowercased()
        let emailA = "a-\(tag)@example.com", emailB = "b-\(tag)@example.com"
        // User A exists on the server with one client, made over HTTP like another phone would.
        guard let tokenA = call("POST", "v1/auth/email/signup", ["email": emailA, "password": password])["device_token"] as? String else {
            return XCTFail("fake server did not sign up A")
        }
        XCTAssertNotNil(call("POST", "v1/actions/paylink", ["amount": "45", "item": "Haircut", "client_name": clientA], token: tokenA)["id"])

        let app = XCUIApplication()
        app.launchArguments = ["-serverURL", fake.absoluteString]
        app.launch()
        toSignIn(app)
        shot("auth-01-sign-in")

        // A: logs in and sees the client in the app and in the keyboard.
        signIn(app, email: emailA, login: true)
        XCTAssertTrue(mentions(app, clientA).waitForExistence(timeout: 15), "A's client not on Home")
        keyboardWhoOwes(expectList: true)
        XCTAssertTrue(id(messages, "whopaid.row.\(clientA)").exists, "A's client not in the keyboard")
        messages.terminate()

        // Log out from Settings: back to the sign-in step.
        app.activate()
        logOut(app, shotName: "auth-02-settings-logout")
        XCTAssertTrue(id(app, "signin.email").waitForExistence(timeout: 10), "log out did not return to sign-in")
        XCTAssertFalse(mentions(app, clientA).exists)

        // B: signs up. A's client is nowhere.
        signIn(app, email: emailB, login: false)
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(mentions(app, clientA).exists, "A's client shows for B on Home")
        id(app, "nav.integrations").tap()
        XCTAssertTrue(mentions(app, emailB).waitForExistence(timeout: 8), "Settings shows B's email")
        XCTAssertFalse(mentions(app, clientA).exists, "A's client shows for B in Settings")
        XCTAssertFalse(mentions(app, emailA).exists, "A's email shows for B in Settings")
        keyboardWhoOwes(expectList: false)
        XCTAssertFalse(mentions(messages, clientA).exists, "A's client shows in B's keyboard")
        shot("auth-03-keyboard-b")
        messages.terminate()
    }
}
