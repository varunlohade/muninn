import Combine
import SwiftUI
import UIKit

/// The input view adopts UIInputViewAudioFeedback, so UIDevice.playInputClick follows the user's Keyboard Clicks setting.
final class ClickInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

final class KeyboardViewController: UIInputViewController, TextHost {
    private var model = KeyboardModel()
    private var heightWatch: AnyCancellable?
    private var hosting: UIHostingController<KeyboardView>?
    /// The App Group's wipe count when this model was made. A log out in the app moves it on.
    private var wipeGeneration = LocalWipe.generation

    override func loadView() {
        let v = ClickInputView(frame: .zero, inputViewStyle: .keyboard)
        v.allowsSelfSizing = true
        inputView = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        mount()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (vc: KeyboardViewController, _) in vc.updateAppearance() }
    }

    /// Puts a KeyboardView for `model` in the input view.
    private func mount() {
        model.host = self
        let hosting = UIHostingController(rootView: KeyboardView(model: model))
        self.hosting = hosting
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
    }

    /// The app logged out since this keyboard last showed: drop the old model, with every client, chip and cache in it,
    /// and this process's own caches, then start clean.
    private func reset() {
        model.keyboardDisappeared(saveTouches: false)
        heightWatch = nil
        if let old = hosting {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        model = KeyboardModel()
        mount()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if LocalWipe.generation != wipeGeneration {
            wipeGeneration = LocalWipe.generation
            reset()
            Task { await LocalWipe.process() }
        }
        updateAppearance()
        keyHaptics = SharedStore.keyHaptics
        model.keyboardAppeared()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.keyboardDisappeared()
    }

    /// A keyboard is killed near its memory limit, so on a warning it drops every cache that reloads by itself.
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        if Thread.isMainThread { model.releaseCaches() } else { DispatchQueue.main.async { [weak self] in self?.model.releaseCaches() } }
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
