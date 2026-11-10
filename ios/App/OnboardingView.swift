import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var session: Session
    @State private var server = SharedStore.serverURL
    @State private var token = ""
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(AppConfig.displayName).font(Theme.Font.wordmark).tracking(Theme.Tracking.wordmark).foregroundStyle(Theme.Color.text1)

                Section(title: "1. Pair this device") {
                    TextField("Server URL", text: $server)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .modifier(FieldStyle())
                    SecureField("Device token (pkd_…)", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .modifier(FieldStyle())
                        .accessibilityIdentifier("token")
                    Text("Dev: run `cd server && npm run device` and paste the device_token.")
                        .font(Theme.Font.secondary).foregroundStyle(Theme.Color.text3)
                    Button(busy ? "Pairing…" : "Pair") {
                        busy = true
                        Task { await session.pair(token: token, server: server); busy = false }
                    }
                    .buttonStyle(PrimaryButton())
                    .disabled(token.isEmpty || busy)
                    if let error = session.error {
                        Text(error).font(Theme.Font.secondary).foregroundStyle(Theme.Color.due)
                    }
                }

                EnableKeyboardSteps()
            }
            .padding(Theme.Metric.margin)
        }
    }
}

struct EnableKeyboardSteps: View {
    var body: some View {
        Section(title: "2. Turn on the keyboard") {
            ForEach(Array([
                "Open Settings › General › Keyboard › Keyboards.",
                "Tap Add New Keyboard and pick \(AppConfig.keyboardName).",
                "Tap \(AppConfig.keyboardName) and turn on Allow Full Access. The keyboard needs it to reach the network.",
                "In any text field, tap the globe key to switch to \(AppConfig.keyboardName).",
            ].enumerated()), id: \.offset) { i, step in
                Text("\(i + 1). \(step)").font(Theme.Font.body).foregroundStyle(Theme.Color.text2)
            }
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(PrimaryButton())
        }
    }
}

struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.Font.secondary).foregroundStyle(Theme.Color.text3)
            content
        }
    }
}

struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Theme.Font.body)
            .padding(12)
            .background(Theme.Color.surface1, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(Theme.Color.text1)
    }
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Color.text1)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Theme.Color.surface3, in: RoundedRectangle(cornerRadius: 14))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
