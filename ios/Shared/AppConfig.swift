import Foundation

/// Names and ids. The display name comes from PRODUCT_DISPLAY_NAME in project.yml.
enum AppConfig {
    /// The app name, also inside the keyboard extension.
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "AppName") as? String ?? "Muninn"
    }
    static var keyboardName: String {
        Bundle.main.object(forInfoDictionaryKey: "KeyboardName") as? String ?? displayName + " Keyboard"
    }
    static var appGroupID: String {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String ?? "group.com.orseliyas.muninn"
    }
    static var keychainGroup: String {
        let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String ?? ""
        return prefix + "com.orseliyas.muninn.shared"
    }
    static let defaultServerURL = "http://localhost:8787"
    static let suggestDebounce: Duration = .milliseconds(350)
}
