import SwiftUI

/// Folder opens: the glass front squashes, papers fan out, then the invoice list slides in.
struct ClientDetailView: View {
    let client: Client
    let papers: [Payment]
    @State private var open = false
    @State private var fanned: [Bool] = [false, false, false]
    @State private var rowsIn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                FolderView(papers: Array(papers.filter { $0.state == "unpaid" }.prefix(2)) + Array(papers.filter { $0.state == "paid" }.prefix(1)), width: 250, channel: channelIcon(client.channels), openness: open ? 1 : 0, fanned: fanned)
                    .padding(.top, 120)
                    .padding(.bottom, Theme.Space.xl)
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(client.displayName).font(Theme.Font.title).foregroundStyle(Theme.Color.text1)
                    ClientLine(client: client)
                    if let paid = mainTotal(client.total_paid) {
                        Text("\(formatMoney(paid.amount, paid.currency)) paid in all").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Metric.margin)
                .padding(.bottom, Theme.Space.m)
                VStack(spacing: 0) {
                    ForEach(Array(papers.enumerated()), id: \.element.id) { i, p in
                        PaymentRow(payment: p, showClient: false)
                            .opacity(rowsIn ? 1 : 0)
                            .offset(x: rowsIn || reduceMotion ? 0 : 9)
                            .animation(reduceMotion ? Theme.Motion.crossfade : Theme.Motion.rowsIn.delay(Double(i) * 0.07), value: rowsIn)
                    }
                    if papers.isEmpty {
                        Text("No invoices yet").font(Theme.Font.label).foregroundStyle(Theme.Color.text3).padding(.vertical, Theme.Space.l)
                    }
                }
                .padding(.horizontal, Theme.Metric.margin)
            }
            .padding(.bottom, Theme.Space.l)
        }
        .background(Theme.Color.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { await playOpen() }
    }

    private func playOpen() async {
        if reduceMotion {
            withAnimation(Theme.Motion.crossfade) { open = true; fanned = [true, true, true]; rowsIn = true }
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        withAnimation(Theme.Motion.glassSquash) { open = true }
        for i in 0..<3 {
            try? await Task.sleep(for: .seconds(Theme.Motion.papersStagger))
            withAnimation(Theme.Motion.papersFan) { fanned[i] = true }
        }
        try? await Task.sleep(for: .milliseconds(150))
        rowsIn = true
    }
}

struct IntegrationsView: View {
    @EnvironmentObject var session: Session
    @State private var items: [Integration] = []
    @State private var error: String?
    @ObservedObject private var calendar = CalendarModel.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.cardGap) {
                Text("Integrations").font(Theme.Font.title).foregroundStyle(Theme.Color.text1).padding(.horizontal, Theme.Metric.margin)
                ForEach(items.filter { $0.status != "coming_soon" }) { i in
                    Card {
                        HStack(spacing: Theme.Space.s) {
                            IconCircle(systemImage: "dollarsign")
                            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                                Text(i.name).font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                                Text(i.status == "connected" ? "Connected" : "Not connected").font(Theme.Font.label)
                                    .foregroundStyle(i.status == "connected" ? Theme.Color.paid : Theme.Color.text2)
                            }
                            Spacer()
                            if i.status == "connected" { Image(systemName: "checkmark").foregroundStyle(Theme.Color.paid) }
                        }
                    }
                    .padding(.horizontal, Theme.Metric.cardInset)
                    .accessibilityIdentifier("integration.\(i.id)")
                }
                calendarTile
                SectionHeader(title: "Coming soon").padding(.top, Theme.Metric.sectionGap - Theme.Metric.cardGap)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Metric.cardGap), GridItem(.flexible(), spacing: Theme.Metric.cardGap)], spacing: Theme.Metric.cardGap) {
                    ForEach(items.filter { $0.status == "coming_soon" && $0.id != "google_calendar" }) { i in
                        Card {
                            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                IconCircle(systemImage: icon(i.id), size: 36)
                                Text(i.name).font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text2)
                                Text("Coming soon").font(Theme.Font.label).foregroundStyle(Theme.Color.text3)
                            }
                        }
                        .allowsHitTesting(false)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, Theme.Metric.cardInset)
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
        .task {
            do { items = try await APIClient.shared().integrations() } catch { self.error = error.localizedDescription }
        }
    }

    /// The phone calendar, read with EventKit. Google calendars synced to the phone come with it.
    private var calendarTile: some View {
        Card {
            HStack(spacing: Theme.Space.s) {
                IconCircle(systemImage: "calendar")
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text("Calendar").font(Theme.Font.cardTitle).foregroundStyle(Theme.Color.text1)
                    Text(calendar.connected ? "Connected · Apple + Google synced" : "Apple + Google synced").font(Theme.Font.label)
                        .foregroundStyle(calendar.connected ? Theme.Color.paid : Theme.Color.text2)
                }
                Spacer()
                if calendar.connected {
                    Image(systemName: "checkmark").foregroundStyle(Theme.Color.paid)
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

    private func icon(_ id: String) -> String {
        switch id {
        case "stripe": "creditcard"
        case "square": "square"
        case "shopify": "bag"
        case "google_calendar": "calendar"
        case "gmail": "envelope"
        default: "puzzlepiece"
        }
    }
}

struct DisputesView: View {
    @State private var items: [Dispute] = []

    var body: some View {
        List(items) { d in
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(d.reason.replacingOccurrences(of: "_", with: " ").capitalized).font(Theme.Font.body).foregroundStyle(Theme.Color.text1)
                Text(d.status.replacingOccurrences(of: "_", with: " ").capitalized).font(Theme.Font.label).foregroundStyle(Theme.Color.due)
                if let a = d.amount { Text(formatMoney(a.value, a.currency_code)).font(Theme.Font.label).foregroundStyle(Theme.Color.text2) }
            }
            .listRowBackground(Theme.Color.bg)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.Color.bg.ignoresSafeArea())
        .navigationTitle("Disputes")
        .task { items = (try? await APIClient.shared().disputes()) ?? [] }
    }
}
