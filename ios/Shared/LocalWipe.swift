import Foundation
import Security
import WebKit

/// Log out wipes every trace of the last user on this phone. docs/AUTH-AND-WIPE.md lists each store.
/// The app runs `device()`. The keyboard is a separate process: it sees the new `generation` the next time it appears,
/// drops its in-memory state and runs `process()` for its own caches.
enum LocalWipe {
    private static let generationKey = "wipe_generation"
    private static var group: UserDefaults? { UserDefaults(suiteName: AppConfig.appGroupID) }

    /// Goes up by one on each wipe. It is the only key the wipe writes back.
    static var generation: Int { group?.integer(forKey: generationKey) ?? 0 }

    /// Everything on the phone: Keychain, App Group (defaults and files), this app's defaults and files, URL and web caches.
    @MainActor
    static func device() async {
        let next = generation + 1
        // Caches first, while their database files are still there, then the files.
        await process()
        keychain()
        appGroup()
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        sandboxFiles()
        group?.set(next, forKey: generationKey)
    }

    /// What lives in this process only: URL cache, cookies, saved credentials, web data, decoded photos.
    @MainActor
    static func process() async {
        URLCache.shared.removeAllCachedResponses()
        for storage in [HTTPCookieStorage.shared, HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: AppConfig.appGroupID)] {
            storage.removeCookies(since: .distantPast)
            for c in storage.cookies ?? [] { storage.deleteCookie(c) }
        }
        let creds = URLCredentialStorage.shared
        for (space, all) in creds.allCredentials { for c in all.values { creds.remove(c, for: space) } }
        let web = WKWebsiteDataStore.default()
        await web.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    /// Every Keychain item this app can reach: the device token, the install id, and anything else.
    static func keychain() {
        for cls in [kSecClassGenericPassword, kSecClassInternetPassword, kSecClassKey, kSecClassCertificate, kSecClassIdentity] {
            SecItemDelete([kSecClass as String: cls] as CFDictionary)
            SecItemDelete([kSecClass as String: cls, kSecAttrAccessGroup as String: AppConfig.keychainGroup] as CFDictionary)
        }
    }

    /// Every key in the App Group defaults suite and every file in the group container. The defaults file itself stays, empty.
    static func appGroup() {
        // Key by key: removePersistentDomain on a shared suite can drop the next writes, and the keyboard reads this suite live.
        if let g = group { for key in g.dictionaryRepresentation().keys { g.removeObject(forKey: key) } }
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupID) else { return }
        empty(root, keep: ["Library"])
        empty(root.appendingPathComponent("Library"), keep: ["Preferences"])
    }

    /// This app's own Documents, Application Support, Caches and tmp.
    static func sandboxFiles() {
        let fm = FileManager.default
        for dir in [FileManager.SearchPathDirectory.documentDirectory, .applicationSupportDirectory, .cachesDirectory] {
            if let url = fm.urls(for: dir, in: .userDomainMask).first { empty(url) }
        }
        empty(fm.temporaryDirectory)
    }

    private static func empty(_ dir: URL, keep: Set<String> = []) {
        let fm = FileManager.default
        // iOS's own container record (".com.apple.mobile_container_manager.metadata.plist") stays.
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !keep.contains(name) && !name.hasPrefix(".com.apple.") {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
