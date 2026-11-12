import SwiftUI

/// Where the owner is with the keyboard. iOS has no API to turn a keyboard on, so the app shows the two switches
/// on its own Settings page and checks each one it can see.
enum KeyboardState: Equatable {
    /// `notFirst`: on, with Full Access, but another keyboard is above it in Settings. A quiet tip, never a blocker.
    case notAdded, needsFullAccess, notFirst, ready

    /// The keyboard has appeared with Full Access, or the owner said it is done, so the app is fully usable.
    var isOn: Bool { self == .notFirst || self == .ready }

    var homeTitle: String {
        switch self {
        case .notAdded: "Add the \(AppConfig.displayName) keyboard"
        // Full Access may be on already: iOS only tells the app once the keyboard has opened with it.
        case .needsFullAccess: "Finish keyboard setup"
        case .notFirst, .ready: "Keyboard is on"
        }
    }

    /// The onboarding button that opens the app's own Settings page, or nil when nothing is left to set.
    var settingsButton: String? {
        switch self {
        case .notAdded, .needsFullAccess: "Open \(AppConfig.displayName) settings"
        case .notFirst, .ready: nil
        }
    }

    /// The two switches on the page that `UIApplication.openSettingsURLString` opens.
    static let settingsSteps = ["Tap Keyboards.", "Turn on \(AppConfig.keyboardName).", "Turn on Allow Full Access."]

    /// The settings URL usually opens the app's own page. If it opens the main page, this is the path.
    static let settingsFallback = "If Settings opens on its main page: Apps › \(AppConfig.displayName)."

    static let finishSetupLine = "Turn on Allow Full Access, then switch to \(AppConfig.displayName) once"

    /// Under the try-it field while the app waits for the keyboard's heartbeat.
    static let switchHint = "Hold the globe key, pick \(AppConfig.displayName)."

    /// Order is only a tip: iOS may not tell the app the true order.
    static let firstTip = "Tip: drag \(AppConfig.displayName) to the top in Settings › General › Keyboard › Keyboards."
}

/// The one keyboard check for onboarding and Home.
@MainActor
final class KeyboardSetup: ObservableObject {
    static let shared = KeyboardSetup()
    nonisolated static let ownerDoneKey = "keyboard_owner_done"

    @Published private(set) var state: KeyboardState = .notAdded
    private let read: () -> (enabled: [String], lastSeen: Date?, ownerSaidDone: Bool)
    private let saveOwnerDone: () -> Void

    /// `enabled`: the AppleKeyboards preference, the keyboards on in Settings, in their Settings order.
    /// `lastSeen`: the heartbeat the keyboard writes each time it appears. It only lands with Full Access.
    /// `ownerSaidDone`: the owner tapped "It's done" before the heartbeat came.
    init(read: @escaping () -> (enabled: [String], lastSeen: Date?, ownerSaidDone: Bool) = {
        (UserDefaults.standard.stringArray(forKey: "AppleKeyboards") ?? [], SharedStore.keyboardLastSeen,
         UserDefaults.standard.bool(forKey: KeyboardSetup.ownerDoneKey))
    }, saveOwnerDone: @escaping () -> Void = { UserDefaults.standard.set(true, forKey: KeyboardSetup.ownerDoneKey) }) {
        self.read = read
        self.saveOwnerDone = saveOwnerDone
        refresh()
    }

    func refresh() {
        let r = read()
        let s = Self.state(enabled: r.enabled, lastSeen: r.lastSeen, ownerSaidDone: r.ownerSaidDone)
        if s != state { state = s }
    }

    /// "It's done": the app cannot see Full Access until the keyboard opens, so the owner's word ends the setup.
    func ownerSaysDone() {
        saveOwnerDone()
        refresh()
    }

    nonisolated static let keyboardID = (Bundle.main.bundleIdentifier ?? "com.orseliyas.muninn") + ".keyboard"

    nonisolated static func state(enabled: [String], lastSeen: Date?, ownerSaidDone: Bool = false,
                                  keyboardID: String = keyboardID) -> KeyboardState {
        let confirmed = lastSeen != nil || ownerSaidDone
        // An empty list means iOS did not share it. Then only the heartbeat or the owner can say the keyboard is there.
        let added = enabled.isEmpty ? confirmed : enabled.contains(keyboardID)
        guard added else { return .notAdded }
        guard confirmed else { return .needsFullAccess }
        // An empty list gives no order, so it counts as first.
        return enabled.isEmpty || enabled.first == keyboardID ? .ready : .notFirst
    }
}

/// The two switches, then a field to switch to the keyboard in. Once the switches are on, the field takes focus
/// by itself, so a keyboard shows; when it is this one, its heartbeat lands and the check shows.
struct KeyboardDefaultGuide: View {
    @ObservedObject var setup = KeyboardSetup.shared
    @State private var tryText = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(Array(KeyboardState.settingsSteps.enumerated()), id: \.offset) { i, text in
                if i > 0 { DashedLine() }
                NumberedLine(number: i + 1, text: text)
            }
            Text(KeyboardState.settingsFallback).font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if setup.state.isOn {
                    Label("\(AppConfig.displayName) is on", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Color.paidInk)
                        .accessibilityIdentifier("keyboard.on")
                    if setup.state == .notFirst {
                        Text(KeyboardState.firstTip)
                            .foregroundStyle(Theme.Color.text2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("keyboard.notFirst")
                    }
                } else {
                    Label(KeyboardState.switchHint, systemImage: "globe")
                        .foregroundStyle(Theme.Color.text2)
                }
            }
            .font(Theme.Font.label)
            .padding(.top, Theme.Space.xs)
            TextField("", text: $tryText, prompt: Text("Type here").foregroundStyle(Theme.Color.text3))
                .modifier(FieldStyle())
                .focused($focused)
                .accessibilityIdentifier("keyboard.tryit")
        }
        // The keyboard can appear while the app stays open, so look for its heartbeat each second until it lands.
        .task(id: setup.state) {
            if setup.state == .needsFullAccess {
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { focused = true }
            }
            while !setup.state.isOn, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                setup.refresh()
            }
        }
    }
}
