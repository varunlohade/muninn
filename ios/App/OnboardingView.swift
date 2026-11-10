import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var session: Session
    @State private var server = SharedStore.serverURL
    @State private var token = ""
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image("Wordmark")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 64)
                    .padding(.leading, 4)
                    .accessibilityLabel(AppConfig.displayName)
                Text("Get paid from any chat. Muninn suggests the invoice while you type.")
                    .font(Theme.Font.body).foregroundStyle(Theme.Color.text2)
                    .padding(.horizontal, Theme.Metric.margin - Theme.Metric.cardInset)
                    .padding(.bottom, 8)

                StepCard(number: 1, title: "Pair this device") {
                    TextField("", text: $server, prompt: Text("Server URL").foregroundStyle(Theme.Color.text3))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .modifier(FieldStyle())
                    if let demo = AppConfig.demoServerURL {
                        HStack(spacing: 8) {
                            ServerOption(title: "This Mac", selected: server == "http://localhost:8787") { server = "http://localhost:8787" }
                            ServerOption(title: "Demo server", selected: server == demo) { server = demo }
                                .accessibilityIdentifier("server.demo")
                        }
                    }
                    SecureField("", text: $token, prompt: Text("Device token (pkd_…)").foregroundStyle(Theme.Color.text3))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textContentType(.oneTimeCode)
                        .modifier(FieldStyle())
                        .accessibilityIdentifier("token")
                    Text("Dev: run `cd server && npm run device` and paste the device_token.")
                        .font(Theme.Font.label).foregroundStyle(Theme.Color.text3)
                    Button(busy ? "Pairing…" : "Pair") {
                        busy = true
                        Task { await session.pair(token: token, server: server); busy = false }
                    }
                    .buttonStyle(PrimaryButton())
                    .disabled(token.isEmpty || busy)
                    if let error = session.error {
                        Text(error).font(Theme.Font.label).foregroundStyle(Theme.Color.due)
                    }
                }

                EnableKeyboardSteps()
            }
            .padding(.horizontal, Theme.Metric.cardInset)
            .padding(.vertical, 16)
        }
        .background(Theme.Color.bg.ignoresSafeArea())
    }
}

struct EnableKeyboardSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepCard(number: 2, title: "Turn on the keyboard") {
                ForEach(Array([
                    "Open Settings › General › Keyboard › Keyboards.",
                    "Tap Add New Keyboard and pick \(AppConfig.keyboardName).",
                    "Tap \(AppConfig.keyboardName) and turn on Allow Full Access. The keyboard needs it to reach the network.",
                    "In any chat, tap the globe key to switch to \(AppConfig.keyboardName).",
                ].enumerated()), id: \.offset) { _, step in
                    Text(step).font(Theme.Font.body).foregroundStyle(Theme.Color.text2).fixedSize(horizontal: false, vertical: true)
                }
                OpenSettingsButton()
            }
            StepCard(number: 3, title: "Optional: skip the paste prompt") {
                Text("To use a client's copied message, iOS asks each time. To stop the prompt, open Settings › \(AppConfig.displayName) › Paste from Other Apps and pick Allow.")
                    .font(Theme.Font.body).foregroundStyle(Theme.Color.text2).fixedSize(horizontal: false, vertical: true)
                OpenSettingsButton()
            }
            .accessibilityIdentifier("step.paste")
        }
    }
}

struct OpenSettingsButton: View {
    var body: some View {
        Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
        .buttonStyle(PrimaryButton())
    }
}

struct ServerOption: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.label)
                .foregroundStyle(selected ? Theme.Color.bg : Theme.Color.text2)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(selected ? Theme.Color.text1 : Theme.Color.button, in: Capsule())
        }
        .buttonStyle(PressScale())
    }
}

struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("\(number)").font(Theme.Font.count).foregroundStyle(Theme.Color.text1)
                        .frame(width: 28, height: 28).background(Theme.Color.button, in: Circle())
                    Text(title).font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                }
                content
            }
        }
    }
}

struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Color.text1)
            .padding(.horizontal, 18)
            .frame(height: 48)
            .background(Theme.Color.button, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.Color.edge, lineWidth: 1))
    }
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.cardTitle)
            .foregroundStyle(Theme.Color.bg)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Theme.Color.text1, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}
