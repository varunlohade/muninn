import SwiftUI
import WebKit
import os

/// The visual panel, in place of the keys: a white board where the Excalidraw page draws the scene step by step;
/// pen, eraser, undo, replay and voice on the board; the step and what it says; then Send and Insert.
/// Muninn's keyboard look (key-coloured controls, accent for the tool in use and Insert), kept in its own file for the redesign.
struct VisualPanelView: View {
    @ObservedObject var model: KeyboardModel
    let state: VisualState
    let palette: Theme.SystemKeyboard.Palette
    typealias M = Theme.SystemKeyboard

    var body: some View {
        VStack(alignment: .leading, spacing: M.keyGap) {
            ZStack(alignment: .topTrailing) {
                VisualWebView(model: model, dark: false)
                    .accessibilityIdentifier("visual.canvas")
                if let line = overlayLine {
                    Text(line).font(M.mode).foregroundStyle(Theme.SystemKeyboard.light.secondaryLabel).multilineTextAlignment(.center)
                        .padding(Theme.Space.s).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("visual.status")
                }
                if state.scene != nil { tools.padding(Theme.Space.xs) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A whiteboard: white in light and dark, so the drawing and the sent image look the same.
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
            .overlay(alignment: .bottom) {
                if let note = state.note {
                    Text(note).font(M.smallMode.weight(.medium)).foregroundStyle(.white)
                        .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
                        .background(Color.black.opacity(0.75), in: Capsule())
                        .padding(.bottom, Theme.Space.xs)
                        .accessibilityIdentifier("visual.note")
                }
            }
            stepLine
            buttons
        }
        .padding(.horizontal, M.sideInset)
        .padding(.vertical, 4)
    }

    /// Pen, eraser, undo, redo, replay and voice, top right on the board. The tool in use is an accent square.
    private var tools: some View {
        HStack(spacing: 2) {
            tool("pencil", .draw, id: "visual.draw", label: "Draw")
            tool("eraser", .eraser, id: "visual.eraser", label: "Erase")
            iconButton("arrow.uturn.backward", id: "visual.undo", label: "Undo", action: model.undoVisual)
            iconButton("arrow.uturn.forward", id: "visual.redo", label: "Redo", action: model.redoVisual)
            iconButton("arrow.counterclockwise", id: "visual.replay", label: "Replay", action: model.replayVisual)
            voiceButton
        }
        .padding(3)
        .background(Theme.SystemKeyboard.light.bed, in: RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
    }

    private static let ink = Theme.SystemKeyboard.light.label
    private static let accent = Theme.SystemKeyboard.light.accent

    private func tool(_ icon: String, _ t: VisualState.Tool, id: String, label: String) -> some View {
        let on = state.tool == t
        return Button { model.selectVisualTool(t) } label: {
            Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(on ? .white : Self.ink)
                .frame(width: 30, height: 30)
                .background(on ? Self.accent : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    /// "Play with voice" / "Stop voice". Nothing plays without this tap.
    private var voiceButton: some View {
        Button(action: model.toggleVoice) {
            Image(systemName: state.voice ? "speaker.wave.2.fill" : "speaker.wave.2").font(.system(size: 14, weight: .medium))
                .foregroundStyle(state.voice ? .white : Self.ink)
                .frame(width: 30, height: 30)
                .background(state.voice ? Self.accent : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!drawn)
        .opacity(drawn ? 1 : 0.4)
        .accessibilityLabel(state.voice ? "Stop voice" : "Play with voice")
        .accessibilityIdentifier("visual.voice")
    }

    private func iconButton(_ icon: String, id: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(Self.ink).frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .disabled(!drawn)
        .opacity(drawn ? 1 : 0.4)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    /// The step dashes, then what that step says.
    @ViewBuilder private var stepLine: some View {
        switch state.status {
        case .drawing(let n, let m): step(n, of: m).accessibilityIdentifier("visual.step")
        case .done(let m): step(m, of: m)
        default: EmptyView()
        }
    }

    private func step(_ n: Int, of m: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            HStack(spacing: Theme.Space.xxs) {
                ForEach(1...max(m, 1), id: \.self) { i in
                    Capsule().fill(i <= n ? palette.accent : palette.divider).frame(height: 3)
                }
            }
            .frame(maxWidth: 120)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(n) of \(m)")
            if let say = state.say { Text(say).font(M.mode).foregroundStyle(palette.label).lineLimit(2) }
        }
        .padding(.horizontal, Theme.Space.xxs)
    }

    /// Send and Insert. Send opens the two ways to send.
    @ViewBuilder private var buttons: some View {
        HStack(spacing: M.keyGap) {
            if state.exporting {
                ExplainButton(title: "Send as image", id: "visual.send.image", palette: palette) { model.sendVisual(.image) }
                ExplainButton(title: "Send as link", id: "visual.send.link", palette: palette) { model.sendVisual(.link) }
                Button(action: model.toggleExport) {
                    Image(systemName: "xmark").font(M.icon).foregroundStyle(palette.label)
                        .frame(width: 48, height: M.keyHeight)
                        .background(palette.key, in: RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .accessibilityIdentifier("visual.export.back")
            } else {
                ExplainButton(title: "Send", id: "visual.export", palette: palette, action: model.toggleExport)
                    .disabled(!drawn || state.sending != nil).opacity(drawn ? 1 : 0.5)
                ExplainButton(title: "Insert", id: "visual.insert", accent: true, palette: palette, action: model.insertExplain)
            }
        }
    }

    private var drawn: Bool {
        switch state.status {
        case .drawing, .done: true
        default: false
        }
    }

    private var overlayLine: String? {
        switch state.status {
        case .loading: "Drawing \u{201C}\(state.subject)\u{201D}\u{2026}"
        case .failed(let s): s
        default: nil
        }
    }
}

/// Hosts the bundled Excalidraw page (ios/Visual, built from visual/). A content rule blocks every http(s) load, so the page
/// can never reach a network; it talks to the keyboard only through the "pip" message handler (the page contract kept from Pip).
struct VisualWebView: UIViewRepresentable {
    let model: KeyboardModel
    let dark: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakHandler(context.coordinator), name: "pip")
        // Nothing is cached or kept on disk: each open loads the bundled page as shipped.
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        #if DEBUG
        web.isInspectable = true
        #endif
        context.coordinator.web = web
        context.coordinator.dark = dark
        Coordinator.noNetwork { rules in
            if let rules { config.userContentController.add(rules) }
            guard let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Visual") else {
                context.coordinator.model?.visualFailed("page missing")
                return
            }
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.dark != dark else { return }
        context.coordinator.dark = dark
        context.coordinator.js("pip.theme(\(dark))")
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "pip")
        web.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, VisualPage {
        weak var model: KeyboardModel?
        weak var web: WKWebView?
        var dark = false
        private let log = Logger(subsystem: "com.orseliyas.muninn", category: "visual")

        init(model: KeyboardModel) { self.model = model }

        private static var rules: WKContentRuleList?
        /// Compiled once per process: block every http and https load from the page.
        static func noNetwork(_ done: @escaping (WKContentRuleList?) -> Void) {
            if let rules { done(rules); return }
            let json = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "muninn.visual.nonetwork", encodedContentRuleList: json) { list, _ in
                MainActor.assumeIsolated {
                    rules = list
                    done(list)
                }
            }
        }

        func js(_ code: String) { web?.evaluateJavaScript(code, completionHandler: nil) }

        func play(_ scene: Data) { js("pip.play(\(String(decoding: scene, as: UTF8.self)))") }
        func replay() { js("pip.replay()") }
        func setTool(_ tool: VisualState.Tool) { js("pip.tool('\(tool.rawValue)')") }
        func undo() { js("pip.undo()") }
        func redo() { js("pip.redo()") }
        func setVoice(_ on: Bool) { js("pip.voice(\(on))") }
        func next() { js("pip.next()") }
        func exportPNG() { js("pip.export()") }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String, let model else { return }
            switch type {
            case "ready":
                js("pip.theme(\(dark))")
                model.visualPageReady(self)
            case "step":
                model.visualStep(body["n"] as? Int ?? 1, of: body["m"] as? Int ?? 1, say: body["say"] as? String)
            case "stepDrawn":
                model.visualStepDrawn(body["n"] as? Int ?? 0)
            case "done":
                model.visualDone()
            case "png":
                guard let b64 = body["data"] as? String, let png = Data(base64Encoded: b64) else { return model.visualFailed("bad image") }
                log.notice("MUNINN_VISUAL png_bytes=\(png.count, privacy: .public)")
                model.visualExported(png)
            case "error":
                log.error("MUNINN_VISUAL page error \(body["message"] as? String ?? "", privacy: .public)")
                model.visualFailed(body["message"] as? String ?? "")
            default:
                break
            }
        }
    }

    /// WKUserContentController keeps its handler strongly; this keeps the coordinator weakly instead.
    final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?
        init(_ target: WKScriptMessageHandler) { self.target = target }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
    }
}
