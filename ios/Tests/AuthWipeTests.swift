import Security
import WebKit
import XCTest
@testable import Muninn

/// Log out wipes every store in docs/AUTH-AND-WIPE.md. Each test seeds the stores, logs out, and checks each one is empty.
/// The server is unreachable here on purpose: the wipe must run even when POST /v1/auth/logout fails.
@MainActor
final class AuthWipeTests: XCTestCase {
    /// One marker per run, written into every store. After the wipe no file on disk may hold it.
    private let mark = "muninn-wipe-marker-\(UUID().uuidString)"
    private var client: String { "Alice Anders \(mark)" }
    private var group: UserDefaults { UserDefaults(suiteName: AppConfig.appGroupID)! }
    private var container: URL { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupID)! }
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
    private let site = URL(string: "https://example.com/v1/clients")!

    private func keychainCount() -> Int {
        var out: CFTypeRef?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true]
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return 0 }
        return (out as? [[String: Any]])?.count ?? 0
    }

    private func write(_ dir: FileManager.SearchPathDirectory, _ name: String) throws -> URL {
        let base = FileManager.default.urls(for: dir, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent(name)
        try Data(client.utf8).write(to: url)
        return url
    }

    private func groupFiles() -> [String] {
        let fm = FileManager.default
        let top = ((try? fm.contentsOfDirectory(atPath: container.path)) ?? []).filter { $0 != "Library" && !$0.hasPrefix(".com.apple.") }
        let lib = ((try? fm.contentsOfDirectory(atPath: container.appendingPathComponent("Library").path)) ?? []).filter { $0 != "Preferences" }
        return top + lib.map { "Library/" + $0 }
    }

    /// Every store, with the client's name wherever the app would keep one.
    private func seed() async throws -> [URL] {
        // Keychain: the device token, the install id, and one more item.
        XCTAssertEqual(SharedStore.setDeviceToken("pkd_user_a_token_aaaaaaaaaaaaaaaa"), errSecSuccess, "Keychain write")
        _ = SharedStore.deviceID
        SecItemAdd([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "wipe-test", kSecAttrAccount as String: "extra",
                    kSecValueData as String: Data(client.utf8)] as CFDictionary, nil)
        XCTAssertGreaterThanOrEqual(keychainCount(), 2)

        // App Group defaults.
        SharedStore.serverURL = "http://127.0.0.1:9"
        SharedStore.appleLinked = true
        SharedStore.unpaidCount = 3
        SharedStore.keyHaptics = true
        SharedStore.touchOffsets = [1, 2, 3]
        SharedStore.lastPasteboardChange = 42
        SharedStore.keyboardLastSeen = Date()
        group.set("left by an older build \(mark)", forKey: "some_old_key")

        // App Group files: day data, notes, shortcuts, the pending call, learned words, drawings.
        let now = Date()
        SharedStore.appointments = [Appointment(start: now, end: now.addingTimeInterval(3600), title: "Color", clientName: client)]
        SharedStore.notes = [Note(text: "\(client) pays cash")]
        SharedStore.actionShortcuts = [ActionShortcut(action: .pay, trigger: ";alice")]
        SharedStore.pendingAction = PendingAction(chip: Chip(kind: "invoice", label: "Invoice \(client) $45", payload: [:], needs_confirm: false),
                                                  confirmed: client, before: "", key: "k", expires: now.addingTimeInterval(60))
        SharedStore.learned = [Learned(subject: client, line: "a client", kind: .word, date: now)]
        try SharedStore.saveDrawing(png, title: "\(client) sales", scene: Data("{}".utf8))
        XCTAssertFalse(groupFiles().isEmpty)

        // The app's own defaults: brief cache, seen payments, the intro flag.
        UserDefaults.standard.set(["\(client) paid"], forKey: "brief_cache")
        UserDefaults.standard.set(Date(), forKey: "brief_cache.at")
        UserDefaults.standard.set(["INV-1"], forKey: "known_paid_ids")
        UserDefaults.standard.set(true, forKey: "intro_seen")

        // The app's own files.
        let files = try [write(.cachesDirectory, "wipe-test.json"), write(.documentDirectory, "wipe-test.json"),
                         write(.applicationSupportDirectory, "wipe-test.json")]
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wipe-test.png")
        try png.write(to: tmp)

        // URL cache, cookies (URL loading and web view), in-memory singletons.
        // A small body stays in the cache database; a large one goes to its own file next to it.
        let response = HTTPURLResponse(url: site, statusCode: 200, httpVersion: nil, headerFields: ["Cache-Control": "max-age=600"])!
        URLCache.shared.storeCachedResponse(CachedURLResponse(response: response, data: Data(client.utf8)), for: URLRequest(url: site))
        let big = Data(String(repeating: "\(mark) ", count: 2000).utf8)
        URLCache.shared.storeCachedResponse(CachedURLResponse(response: response, data: big), for: URLRequest(url: site.appendingPathComponent("big")))
        let cookie = HTTPCookie(properties: [.domain: "example.com", .path: "/", .name: "session", .value: mark, .expires: Date().addingTimeInterval(3600)])!
        HTTPCookieStorage.shared.setCookie(cookie)
        await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
        PayPalConnector.shared.note = "Connected as \(client)"
        CalendarModel.shared.today = SharedStore.appointments
        return files + [tmp]
    }

    /// Every file under `dirs` whose bytes hold the marker, as UTF-8 or UTF-16.
    private func filesHoldingMark(under dirs: [URL]) -> [String] {
        let needles = [Data(mark.utf8), mark.data(using: .utf16LittleEndian)!, mark.data(using: .utf16BigEndian)!]
        var hits: [String] = []
        for dir in dirs {
            let walk = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
            while let url = walk?.nextObject() as? URL {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      let bytes = try? Data(contentsOf: url) else { continue }
                if needles.contains(where: { bytes.range(of: $0) != nil }) { hits.append(url.path) }
            }
        }
        return hits
    }

    func testLogoutEmptiesEveryStore() async throws {
        let files = try await seed()
        let fm = FileManager.default
        let dirs = [fm.temporaryDirectory, container] + [FileManager.SearchPathDirectory.cachesDirectory, .documentDirectory, .applicationSupportDirectory]
            .map { fm.urls(for: $0, in: .userDomainMask)[0] }
        XCTAssertFalse(filesHoldingMark(under: dirs).isEmpty, "the marker search finds seeded files")
        let generation = LocalWipe.generation
        let session = Session()
        XCTAssertTrue(session.paired)

        await session.logout()

        // Keychain.
        XCTAssertNil(SharedStore.deviceToken)
        XCTAssertEqual(keychainCount(), 0, "no Keychain item left")
        // App Group defaults: only the wipe count is written back.
        XCTAssertEqual(Set(group.dictionaryRepresentation().keys).intersection(
            ["server_url", "apple_linked", "unpaid_count", "key_haptics", "touch_offsets", "pasteboard_change_count", "keyboard_last_seen"]), [])
        XCTAssertEqual(SharedStore.serverURL, AppConfig.defaultServerURL)
        XCTAssertNil(SharedStore.unpaidCount)
        XCTAssertFalse(SharedStore.appleLinked)
        XCTAssertEqual(LocalWipe.generation, generation + 1, "the keyboard sees a new generation")
        // App Group files.
        XCTAssertEqual(groupFiles(), [], "App Group container is empty")
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist").path),
                      "iOS's container record stays")
        XCTAssertEqual(SharedStore.appointments, [])
        XCTAssertNil(SharedStore.pendingAction)
        XCTAssertEqual(SharedStore.learned, [])
        XCTAssertEqual(SharedStore.drawings, [])
        XCTAssertEqual(SharedStore.actionShortcuts, ActionShortcut.defaults)
        XCTAssertEqual(SharedStore.notes, Note.demo)
        // App defaults and files.
        for key in ["brief_cache", "brief_cache.at", "known_paid_ids", "intro_seen"] { XCTAssertNil(UserDefaults.standard.object(forKey: key), key) }
        for f in files { XCTAssertFalse(FileManager.default.fileExists(atPath: f.path), f.lastPathComponent) }
        // URL cache and cookies.
        XCTAssertNil(URLCache.shared.cachedResponse(for: URLRequest(url: site)))
        XCTAssertNil(URLCache.shared.cachedResponse(for: URLRequest(url: site.appendingPathComponent("big"))), "URLCache, large body")
        XCTAssertEqual(HTTPCookieStorage.shared.cookies ?? [], [])
        let webCookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        XCTAssertEqual(webCookies, [])
        let records = await WKWebsiteDataStore.default().dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        XCTAssertEqual(records.count, 0)
        // In-memory state, and the app is back at sign-in.
        XCTAssertNil(PayPalConnector.shared.note)
        XCTAssertNil(PayPalConnector.shared.status)
        XCTAssertEqual(CalendarModel.shared.today, [])
        XCTAssertFalse(session.paired)
        XCTAssertTrue(session.onboarding)
        XCTAssertTrue(session.signInNext)
        XCTAssertFalse(session.appleLinked)
        // The real proof: no file left in temp, caches, documents, app support or the App Group holds the marker.
        XCTAssertEqual(filesHoldingMark(under: dirs), [], "files that still hold the last person's data")
    }

    /// A server that answers every call with `code`.
    private final class Stub: URLProtocol {
        nonisolated(unsafe) static var code = 401
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let resp = HTTPURLResponse(url: request.url!, statusCode: Self.code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"error":"unauthorized"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    /// A 401 on a signed-in call (an expired token) runs the log out wipe and opens sign-in. A wrong password on /v1/auth/ does not.
    func testRejectedTokenWipesAndOpensSignIn() async throws {
        let token = "pkd_user_a_token_aaaaaaaaaaaaaaaa"
        XCTAssertEqual(SharedStore.setDeviceToken(token), errSecSuccess)
        SharedStore.touchOffsets = [1, 2, 3]
        let generation = LocalWipe.generation
        let session = Session()
        XCTAssertTrue(session.paired)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        let api = APIClient(baseURL: "http://127.0.0.1:9", token: token, session: URLSession(configuration: config))

        _ = try? await api.linkEmail(email: "a@example.com", password: "wrong password")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(session.paired, "a wrong password on /v1/auth/ keeps the session")

        _ = try? await api.account()
        for _ in 0..<500 where session.paired { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(session.paired)
        XCTAssertTrue(session.signInNext)
        XCTAssertTrue(session.onboarding)
        XCTAssertNil(SharedStore.deviceToken)
        XCTAssertEqual(SharedStore.touchOffsets, [])
        XCTAssertEqual(LocalWipe.generation, generation + 1, "one wipe")
    }

    /// A failed sign-in gives one plain line for each server answer.
    func testSignInErrorsArePlain() {
        XCTAssertEqual(Session.appleLine(APIError.http(401, #"{"error":"unauthorized"}"#)), "Apple sign-in didn't work. Try again.")
        XCTAssertEqual(Session.appleLine(APIError.http(429, "")), "Too many tries. Wait a few minutes, then try again.")
        XCTAssertEqual(Session.authLine(APIError.http(401, #"{"error":"wrong email or password"}"#)), "Wrong email or password.")
        XCTAssertEqual(Session.authLine(APIError.http(429, #"{"error":"too many tries, wait a few minutes and try again"}"#)),
                       "Too many tries. Wait a few minutes, then try again.")
        XCTAssertEqual(Session.authLine(APIError.http(400, #"{"error":"password must be at least 8 characters"}"#)), "Password must be at least 8 characters")
        XCTAssertEqual(Session.authLine(APIError.http(409, #"{"error":"this email already has an account, log in instead"}"#)),
                       "This email already has an account. Log in instead.")
    }
}
