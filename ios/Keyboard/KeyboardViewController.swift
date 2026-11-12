import Combine
import SwiftUI
import UIKit

/// The input view adopts UIInputViewAudioFeedback, so UIDevice.playInputClick follows the user's Keyboard Clicks setting.
final class ClickInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

final class KeyboardViewController: UIInputViewController, TextHost {
    private let model = KeyboardModel()
    private var heightWatch: AnyCancellable?

    override func loadView() {
        let v = ClickInputView(frame: .zero, inputViewStyle: .keyboard)
        v.allowsSelfSizing = true
        inputView = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.host = self
        let hosting = UIHostingController(rootView: KeyboardView(model: model))
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.backgroundColor = .clear
        let height = hosting.view.heightAnchor.constraint(equalToConstant: Theme.SystemKeyboard.height)
        addChild(hosting)
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height,
        ])
        // The keyboard grows while the "Who hasn't paid" list or a lookup card is open above the keys, or the visual panel is open.
        // @Published sends before the property changes, so the height comes from the sent values, not the model.
        heightWatch = model.$whoPaid.combineLatest(model.$lookup, model.$explainPanel).sink { [weak self] list, found, panel in
            var visual = false
            if case .visual? = panel { visual = true }
            height.constant = KeyboardView.height(whoPaid: list, lookup: found != nil, visual: visual)
            self?.view.setNeedsLayout()
        }
        hosting.didMove(toParent: self)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (vc: KeyboardViewController, _) in vc.updateAppearance() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateAppearance()
        keyHaptics = SharedStore.keyHaptics
        model.keyboardAppeared()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.keyboardDisappeared()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        updateAppearance()
        model.textChanged()
    }

    /// The field's keyboardAppearance wins; .default follows the system light/dark setting.
    private func updateAppearance() {
        switch textDocumentProxy.keyboardAppearance ?? .default {
        case .dark: model.isDark = true
        case .light: model.isDark = false
        default: model.isDark = traitCollection.userInterfaceStyle == .dark
        }
    }

    // MARK: TextHost

    var contextBeforeInput: String? { textDocumentProxy.documentContextBeforeInput }
    var needsGlobeKey: Bool { needsInputModeSwitchKey }
    var returnKeyType: UIReturnKeyType { textDocumentProxy.returnKeyType ?? .default }
    var autocapitalization: UITextAutocapitalizationType { textDocumentProxy.autocapitalizationType ?? .sentences }
    var autocorrection: UITextAutocorrectionType {
        if [.URL, .emailAddress, .webSearch].contains(textDocumentProxy.keyboardType ?? .default) { return .no }
        return textDocumentProxy.autocorrectionType ?? .default
    }
    var enablesReturnKeyAutomatically: Bool { textDocumentProxy.enablesReturnKeyAutomatically ?? false }
    func insert(_ text: String) { textDocumentProxy.insertText(text) }
    func deleteBackward() { textDocumentProxy.deleteBackward() }
    func adjustCursor(by offset: Int) { textDocumentProxy.adjustTextPosition(byCharacterOffset: offset) }
    func nextKeyboard() { advanceToNextInputMode() }
    /// A keyboard can click and tap the phone only with Full Access. The click follows the Keyboard Clicks setting;
    /// the tap follows "Key haptics" in the app, off by default.
    func playClick() {
        guard hasFullAccess else { return }
        UIDevice.current.playInputClick()
        if keyHaptics { haptic.impactOccurred() }
    }
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private var keyHaptics = false
}
