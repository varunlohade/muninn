import Foundation
import Security

/// Device token lives in the shared Keychain group. Server URL lives in the App Group defaults.
/// The main app writes both. The keyboard only reads them.
enum SharedStore {
    private static let service = "com.orseliyas.muninn.device"
    private static let account = "device_token"
    private static let serverKey = "server_url"
    private static let pasteboardKey = "pasteboard_change_count"
    private static let keyboardSeenKey = "keyboard_last_seen"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: AppConfig.appGroupID) }

    static var serverURL: String {
        get { defaults?.string(forKey: serverKey) ?? AppConfig.defaultServerURL }
        set { defaults?.set(newValue, forKey: serverKey) }
    }

    /// The last pasteboard changeCount the keyboard used, so one copy is sent at most once.
    static var lastPasteboardChange: Int {
        get { defaults?.integer(forKey: pasteboardKey) ?? 0 }
        set { defaults?.set(newValue, forKey: pasteboardKey) }
    }

    /// Set by the keyboard each time it appears with Full Access, so the app can say "Keyboard is on".
    static var keyboardLastSeen: Date? {
        get { defaults?.object(forKey: keyboardSeenKey) as? Date }
        set { defaults?.set(newValue, forKey: keyboardSeenKey) }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: AppConfig.keychainGroup,
        ]
    }

    static var deviceToken: String? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func setDeviceToken(_ token: String?) -> OSStatus {
        SecItemDelete(baseQuery() as CFDictionary)
        guard let token else { return errSecSuccess }
        var q = baseQuery()
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil)
    }
}
