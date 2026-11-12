import SwiftUI

/// What Muninn is connected to. The rows and their one-line descriptions come from the server.
struct IntegrationsView: View {
    @EnvironmentObject var session: Session
    @State private var items: [Integration] = []
    @State private var error: String?
    @ObservedObject private var calendar = CalendarModel.shared
    @Environment(\.openURL) private var openURL
    @State private var keyHaptics = SharedStore.keyHaptics

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.cardGap) {
                Text("Integrations").font(Theme.Font.title).foregroundStyle(Theme.Color.text1).padding(.horizontal, Theme.Metric.margin)
                ForEach(items.filter { $0.status != "coming_soon" }) { i in
                    Group {
                        switch i.id {
                        case "google_reviews": NavigationLink { ReviewLinkView() } label: { row(i, opens: true) }.buttonStyle(PressScale())
                        case "slack": NavigationLink { SlackAlertsView(connected: i.status == "connected") } label: { row(i, opens: true) }.buttonStyle(PressScale())
                        case "paypal": PayPalIntegrationRow()
                        default: row(i, opens: false)
                        }
                    }
                    .padding(.horizontal, Theme.Metric.cardInset)
                    .accessibilityIdentifier("integration.\(i.id)")
                }
                calendarTile
                Card {
                    Toggle(isOn: $keyHaptics) {
                        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                            Text("Key haptics").font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                            Text("A light tap on each key. Needs Full Access.").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                        }
                    }
                    .tint(Theme.Color.paid)
                    .onChange(of: keyHaptics) { _, on in SharedStore.keyHaptics = on }
                }
                .padding(.horizontal, Theme.Metric.cardInset)
                .accessibilityIdentifier("settings.keyHaptics")
                Group {
                    if session.appleLinked {
                        Card {
                            HStack(spacing: Theme.Space.s) {
                                IconCircle(systemImage: "person.crop.circle.badge.checkmark")
                                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                                    Text("Your details").font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                                    Text("Saved with your Apple account.").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "checkmark").foregroundStyle(Theme.Color.paid).accessibilityLabel("Saved")
                            }
                        }
                    } else {
                        SaveDetailsCard(title: "Save your details")
                    }
                }
                .padding(.horizontal, Theme.Metric.cardInset)
                .padding(.top, Theme.Metric.sectionGap - Theme.Metric.cardGap)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("integration.apple")
                let soon = items.filter { $0.status == "coming_soon" && $0.id != "google_calendar" }
                if !soon.isEmpty {
                    SectionHeader(title: "Coming soon").padding(.top, Theme.Metric.sectionGap - Theme.Metric.cardGap)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Metric.cardGap), GridItem(.flexible(), spacing: Theme.Metric.cardGap)], spacing: Theme.Metric.cardGap) {
                        ForEach(soon) { i in
                            Card {
                                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                    IconCircle(systemImage: Self.icon(i.id), size: 36)
                                    Text(i.name).font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text2)
                                    Text("Coming soon").font(Theme.Font.label).foregroundStyle(Theme.Color.text3)
                                }
                            }
                            .allowsHitTesting(false)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.horizontal, Theme.Metric.cardInset)
                }
                if let error { Text(error).font(Theme.Font.label).foregroundStyle(Theme.Color.due).padding(.horizontal, Theme.Metric.margin) }
                #if DEBUG
                NavigationLink("Keyboard Lab (debug)") { KeyboardLabView() }
                    .font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                    .frame(minHeight: Theme.Metric.iconButton).padding(.horizontal, Theme.Metric.margin)
                    .padding(.top, Theme.Metric.sectionGap - Theme.Metric.cardGap)
                #endif
                Button("Unpair this device", role: .destructive) { session.unpair() }
                    .font(Theme.Font.label).frame(minHeight: Theme.Metric.iconButton).padding(.horizontal, Theme.Metric.margin)
            }
            .padding(.top, Theme.Space.xs)
            .padding(.bottom, Theme.Space.l)
        }
        .background(Theme.Color.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        // Runs again on the way back from a setting, so the row shows the new state.
        .task {
            do { items = try await APIClient.shared().integrations(); error = nil } catch { self.error = plainLine(error) }
        }
    }

    private func row(_ i: Integration, opens: Bool) -> some View {
        Card {
            HStack(spacing: Theme.Space.s) {
                IconCircle(systemImage: Self.icon(i.id))
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(i.name).font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                    Text(i.description ?? Self.statusWord(i.status)).font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if i.status == "connected" {
                    Image(systemName: "checkmark").foregroundStyle(Theme.Color.paid).accessibilityLabel("Connected")
                } else if opens {
                    Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(Theme.Color.text3)
                }
            }
        }
    }

    static func statusWord(_ status: String) -> String {
        switch status {
        case "connected": "Connected"
        case "on_device": "On this phone"
        case "coming_soon": "Coming soon"
        default: "Not connected"
        }
    }

    /// The phone calendar, read with EventKit. Google calendars synced to the phone come with it.
    private var calendarTile: some View {
        Card {
            HStack(spacing: Theme.Space.s) {
                IconCircle(systemImage: "calendar")
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text("Calendar").font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                    Text("See who to bill today. Stays on this phone.").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if calendar.connected {
                    Image(systemName: "checkmark").foregroundStyle(Theme.Color.paid).accessibilityLabel("Connected")
                } else if calendar.status == .notDetermined {
                    AskChip(title: "Connect", detail: nil) { Task { await calendar.connect() } }
                        .accessibilityIdentifier("calendar.connect")
                } else {
                    AskChip(title: "Open Settings", detail: nil) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Metric.cardInset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("integration.calendar")
    }

    static func icon(_ id: String) -> String {
        switch id {
        case "paypal", "paypal_payouts": "dollarsign"
        case "contacts": "person.crop.circle"
        case "google_reviews": "star"
        case "slack": "bell"
        case "reminders": "checklist"
        case "shopify": "bag"
        case "calendly", "google_calendar": "calendar"
        default: "puzzlepiece"
        }
    }
}

/// One setting screen: a title, plain help, then its content.
private struct SettingPage<Content: View>: View {
    let title: String
    let help: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(title).font(Theme.Font.title).foregroundStyle(Theme.Color.text1)
                    Text(help).font(Theme.Font.body).foregroundStyle(Theme.Color.text2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Theme.Space.xs)
                content
            }
            .padding(.horizontal, Theme.Metric.cardInset)
            .padding(.top, Theme.Space.xs)
            .padding(.bottom, Theme.Space.l)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.Color.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct Steps: View {
    let steps: [String]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, text in
                    HStack(alignment: .top, spacing: Theme.Space.s) {
                        Text("\(i + 1)").font(Theme.Font.count).foregroundStyle(Theme.Color.text1)
                            .frame(width: Theme.Space.xl, height: Theme.Space.xl).background(Theme.Color.button, in: Circle())
                        Text(text).font(Theme.Font.body).foregroundStyle(Theme.Color.text1).fixedSize(horizontal: false, vertical: true)
                            .frame(minHeight: Theme.Space.xl, alignment: .leading)
                    }
                }
            }
        }
    }
}

/// The owner's Google review link. Muninn puts it in a thank-you message; "Ask for a review" writes that message.
struct ReviewLinkView: View {
    @State private var saved: String?
    @State private var link = ""
    @State private var busy = false
    @State private var note: String?
    @State private var failed = false
    @State private var message: String?
    @State private var copied = false

    static let badLink = "That is not a Google review link. Copy it from your Google Business Profile: Ask for reviews."

    var body: some View {
        SettingPage(title: "Google reviews", help: "Paste your Google review link once. Muninn adds it to a thank-you message, so a happy client is one tap from a review.") {
            Steps(steps: ["Open your Google Business Profile.", "Tap Ask for reviews and copy the link.", "Paste it here and save."])
            TextField("", text: $link, prompt: Text("https://g.page/r/\u{2026}/review").foregroundStyle(Theme.Color.text3))
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .modifier(FieldStyle())
                .accessibilityIdentifier("review.link")
            if let note {
                Text(note).font(Theme.Font.label).foregroundStyle(failed ? Theme.Color.due : Theme.Color.paid)
                    .padding(.horizontal, Theme.Space.xs).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("review.note")
            }
            Button(busy ? "Saving\u{2026}" : "Save") { Task { await save(clean) } }
                .buttonStyle(PrimaryButton())
                .disabled(busy || clean.isEmpty || clean == saved)
                .opacity(busy || clean.isEmpty || clean == saved ? 0.4 : 1)
                .accessibilityIdentifier("review.save")
            if saved != nil {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    if let message {
                        Card {
                            Text(message).font(Theme.Font.body).foregroundStyle(Theme.Color.text1).fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("review.message")
                        }
                    }
                    HStack(spacing: Theme.Space.xs) {
                        if let message {
                            AskChip(title: copied ? "Copied" : "Copy message", detail: nil) { UIPasteboard.general.string = message; copied = true }
                                .accessibilityIdentifier("review.copy")
                        } else {
                            AskChip(title: "Ask for a review", detail: nil) { Task { await ask() } }
                                .accessibilityIdentifier("review.ask")
                        }
                        AskChip(title: "Remove link", detail: nil) { Task { await save(nil) } }
                            .accessibilityIdentifier("review.remove")
                    }
                }
                .padding(.top, Theme.Space.xs)
            }
        }
        .task {
            guard let p = try? await APIClient.shared().profile() else { return }
            saved = p.review_url
            link = p.review_url ?? ""
        }
    }

    private var clean: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save(_ url: String?) async {
        busy = true
        defer { busy = false }
        do {
            saved = try await APIClient.shared().setReviewLink(url)?.review_url
            if url == nil { link = "" }
            message = nil
            copied = false
            failed = false
            note = url == nil ? "Link removed." : "Saved \u{2713}"
        } catch {
            failed = true
            if case APIError.http(400, _) = error { note = Self.badLink } else { note = plainLine(error) }
        }
    }

    /// The same request the Ask bar sends: the server answers with the thank-you and the link.
    private func ask() async {
        do {
            if case .review(let text) = try await APIClient.shared().ask("ask for a review").result { message = text; note = nil }
            else { failed = true; note = "Could not write that right now. Try again." }
        } catch { failed = true; note = plainLine(error) }
    }
}

/// Payment alerts in Slack, through an incoming webhook the owner makes.
struct SlackAlertsView: View {
    @State var connected: Bool
    @State private var link = ""
    @State private var busy = false
    @State private var note: String?
    @State private var failed = false

    static let badLink = "That is not a Slack webhook link. It starts with https://hooks.slack.com/services/"

    var body: some View {
        SettingPage(title: "Slack", help: "Get one line in Slack when a client pays, like \u{201C}Ana paid $90 \u{00B7} Haircut\u{201D}. No emails or card details go to Slack.") {
            Steps(steps: ["In Slack, open Apps and add Incoming Webhooks.", "Pick the channel for your payment alerts.", "Copy the webhook link and paste it here."])
            TextField("", text: $link, prompt: Text("https://hooks.slack.com/services/\u{2026}").foregroundStyle(Theme.Color.text3))
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .modifier(FieldStyle())
                .accessibilityIdentifier("slack.link")
            Text(note ?? (connected ? "Connected \u{2713} Muninn keeps the link encrypted and never shows it again." : "The link is a secret. Muninn keeps it encrypted and never shows it again."))
                .font(Theme.Font.label).foregroundStyle(failed ? Theme.Color.due : connected ? Theme.Color.paid : Theme.Color.text2)
                .padding(.horizontal, Theme.Space.xs).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("slack.note")
            Button(busy ? "Saving\u{2026}" : connected ? "Replace link" : "Connect") { Task { await save(clean) } }
                .buttonStyle(PrimaryButton())
                .disabled(busy || clean.isEmpty)
                .opacity(busy || clean.isEmpty ? 0.4 : 1)
                .accessibilityIdentifier("slack.save")
            if connected {
                AskChip(title: "Disconnect", detail: nil) { Task { await save(nil) } }
                    .accessibilityIdentifier("slack.disconnect")
            }
        }
    }

    private var clean: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save(_ url: String?) async {
        busy = true
        defer { busy = false }
        do {
            connected = try await APIClient.shared().setSlackWebhook(url).status == "connected"
            link = ""
            failed = false
            note = nil
        } catch {
            failed = true
            if case APIError.http(400, _) = error { note = Self.badLink } else { note = plainLine(error) }
        }
    }
}
