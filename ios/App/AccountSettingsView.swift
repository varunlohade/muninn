import SwiftUI

/// Settings, "Account": how this account signs in (GET /v1/account), "Add an email" for an Apple or device account,
/// Log out, and Delete account with a confirm step on the page.
struct AccountSection: View {
    @EnvironmentObject var session: Session
    @State private var info: AccountInfo?
    @State private var error: String?
    @State private var addEmail = false
    @State private var confirmDelete = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.cardGap) {
            SectionHeader(title: "Account")
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Signed in with").font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                    ForEach(Array(methods.enumerated()), id: \.offset) { i, m in
                        if i > 0 { DashedLine() }
                        Text(m).font(Theme.Font.sans(15, 500)).foregroundStyle(Theme.Color.text1)
                    }
                    .accessibilityIdentifier("account.method")
                    if let info, info.email == nil {
                        Button("Add an email") { addEmail = true }
                            .buttonStyle(QuietButton(small: true, wide: false))
                            .accessibilityIdentifier("account.addEmail")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Theme.Metric.cardInset)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("account.methods")
            if let error {
                Text(error).font(Theme.Font.label).foregroundStyle(Theme.Color.due).padding(.horizontal, Theme.Metric.margin)
                    .accessibilityIdentifier("account.error")
            }
            Button(busy ? "One moment\u{2026}" : "Log out") { Task { busy = true; await session.logout(); busy = false } }
                .buttonStyle(QuietButton())
                .disabled(busy)
                .padding(.horizontal, Theme.Metric.cardInset)
                .accessibilityIdentifier("account.logout")
            if confirmDelete {
                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Delete your account?").font(Theme.Font.sans(17, 500)).foregroundStyle(Theme.Color.text1)
                            Spacer()
                            StatusPill(text: "Needs your OK", tone: .due)
                        }
                        Text("Your clients, invoices, catalog and settings go for good. PayPal keeps its own records.")
                            .font(Theme.Font.label).foregroundStyle(Theme.Color.text2).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: Theme.Space.s) {
                            Button("Cancel") { confirmDelete = false }
                                .buttonStyle(QuietButton())
                                .accessibilityIdentifier("account.delete.cancel")
                            Button("Delete", role: .destructive) { Task { await delete() } }
                                .buttonStyle(TactileButton(kind: .dark))
                                .disabled(busy)
                                .accessibilityIdentifier("account.delete.confirm")
                        }
                    }
                }
                .padding(.horizontal, Theme.Metric.cardInset)
            } else {
                Button("Delete account", role: .destructive) { error = nil; confirmDelete = true }
                    .font(Theme.Font.sans(14, 500)).foregroundStyle(Theme.Color.due)
                    .frame(minHeight: Theme.Metric.iconButton).padding(.horizontal, Theme.Metric.margin)
                    .accessibilityIdentifier("account.delete")
            }
        }
        .task(id: session.account) { await load() }
        .sheet(isPresented: $addEmail, onDismiss: { Task { await load() } }) {
            EmailAuthForm(link: true) { addEmail = false }
        }
    }

    private var methods: [String] {
        guard let info else { return ["\u{2026}"] }
        var out: [String] = []
        if info.apple { out.append("Apple") }
        if let email = info.email { out.append("Email: \(email)") }
        return out.isEmpty ? ["This phone only"] : out
    }

    private func load() async {
        do { info = try await APIClient.shared().account(); error = nil } catch { self.error = plainLine(error) }
    }

    private func delete() async {
        busy = true
        error = await session.deleteAccount()
        busy = false
    }
}
