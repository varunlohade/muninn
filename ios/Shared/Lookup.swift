import SwiftUI

/// What the server found for "invoice for sam": up to 3 clients, each with its latest record and up to 2 older ones.
/// It comes as a "lookup" chip's payload from /v1/suggest, or as the "lookup" route of /v1/ask. Read only.
struct LookupResult: Codable, Equatable {
    struct Record: Codable, Equatable, Identifiable {
        /// invoice, pay_link, repeat or item.
        let kind: String
        let id: String
        let title: String
        let amount: String
        let currency: String
        /// unpaid, paid, refunded, cancelled; a repeat bill: pending, active; an item: price.
        let state: String
        let date_label: String?
        let link: String?
        /// The short line Insert types for the client.
        let line: String
        /// An unpaid invoice's Remind chip. It goes through the same confirm as every reminder.
        let remind: Chip?
    }
    struct Candidate: Codable, Equatable, Identifiable {
        let name: String
        let records: [Record]
        /// "No invoices for Sam yet" when nothing fits.
        let empty_line: String?
        var id: String { name }
    }
    /// money, any or catalog.
    let kind: String
    let noun: String?
    let query: String
    /// exact, did_you_mean, ambiguous or none.
    let match: String
    let candidates: [Candidate]
    /// "Nothing from last week. Showing the latest."
    let note: String?
    /// "invoice sam": it may also mean a new invoice, so the card offers New invoice beside the records. Older servers send none.
    let new_invoice: Bool?

    init?(chip: Chip) {
        guard chip.kind == "lookup", let data = try? JSONEncoder().encode(chip.payload),
              let r = try? JSONDecoder().decode(LookupResult.self, from: data) else { return nil }
        self = r
    }
}

/// The words on the lookup card. Pure, so tests read them without a view.
enum LookupCopy {
    static let kindWord = ["invoice": "invoice", "pay_link": "pay link", "repeat": "repeat bill", "item": "price"]

    /// "Sam Lee · latest invoice", "Did you mean Samantha Cruz?", "2 clients match “sam”".
    static func header(_ r: LookupResult, _ c: LookupResult.Candidate?) -> String {
        if r.match == "ambiguous" && c == nil { return "\(r.candidates.count) clients match \u{201C}\(r.query)\u{201D}" }
        guard let c else { return "" }
        if r.match == "did_you_mean" { return "Did you mean \(c.name)?" }
        guard let top = c.records.first else { return c.name }
        if top.kind == "item" { return top.title }
        return "\(c.name) \u{00B7} latest \(kindWord[top.kind] ?? top.kind)"
    }

    /// "$120 · unpaid · Nov 9".
    static func row(_ rec: LookupResult.Record) -> String {
        [formatMoney(rec.amount, rec.currency), rec.kind == "item" ? nil : rec.state, rec.date_label].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    /// One muted line under the buttons that says what each one does. `insertWord` is "Insert" in the keyboard, "Copy" in the app.
    static func hint(_ rec: LookupResult.Record?, insertWord: String, offersNew: Bool = false) -> String {
        guard let rec else { return "New invoice asks for the amount, then you confirm before anything is sent." }
        if offersNew {
            let first = "\(insertWord) gives you a line with this \(kindWord[rec.kind] ?? "record")."
            return first + (rec.remind == nil ? " New invoice asks for the amount, then you confirm." : " Remind and New invoice ask you to confirm first.")
        }
        let what = rec.kind == "item" ? "the price" : "this \(kindWord[rec.kind] ?? "record")"
        let link = rec.line.contains("https://") ? " and its link" : ""
        let insert = "\(insertWord) gives you a line with \(what)\(link)."
        return rec.remind == nil ? insert : insert + " Remind asks before it sends."
    }

    /// "Invoice Sam Lee $": the Ask bar's start of a new invoice. The amount comes next, then the confirm.
    static func newInvoiceRequest(_ name: String) -> String { "Invoice \(name) $" }

    /// The client a "New invoice" starts with: only a real name, never a catalog item. Offered when nothing was found,
    /// or when the owner typed "invoice sam", which may mean a new one.
    static func newInvoiceName(_ r: LookupResult, _ c: LookupResult.Candidate) -> String? {
        r.kind == "catalog" || !(c.records.isEmpty || r.new_invoice == true) ? nil : c.name
    }
}

/// The small card above the keys (and under the Ask bar): the latest record, up to 2 older ones, and what to do with it.
struct LookupCard: View {
    let result: LookupResult
    let palette: Theme.SystemKeyboard.Palette
    /// "Insert" in the keyboard, "Copy" in the app.
    var insertWord = "Insert"
    let onInsert: (LookupResult.Record) -> Void
    let onRemind: (Chip) -> Void
    let onNewInvoice: (String) -> Void
    let onClose: () -> Void
    @State private var picked: String?
    typealias M = Theme.SystemKeyboard

    static let height: CGFloat = 214
    /// The app's colors in the keyboard's palette shape, for the Ask bar.
    static let appPalette = Theme.SystemKeyboard.Palette(bed: Theme.Color.card, key: Theme.Color.button, keyPressed: Theme.Color.button,
                                                         label: Theme.Color.text1, divider: Theme.Color.hairline,
                                                         secondaryLabel: Theme.Color.text2, accent: Theme.Color.text1)

    private var candidate: LookupResult.Candidate? {
        if let picked { return result.candidates.first { $0.name == picked } }
        return result.match == "ambiguous" ? nil : result.candidates.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            HStack(spacing: Theme.Space.xs) {
                Text(LookupCopy.header(result, candidate)).font(M.mode.weight(.medium)).foregroundStyle(palette.label).lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityIdentifier("lookup.header")
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(M.icon).foregroundStyle(palette.secondaryLabel).frame(width: 44, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("lookup.close")
            }
            if let note = result.note { muted(note) }
            if let c = candidate { records(c) } else { pickList }
        }
        .padding(.horizontal, M.sideInset + Theme.Space.xxs)
        .padding(.vertical, Theme.Space.xxs)
        .frame(height: Self.height, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lookup.card")
    }

    private var pickList: some View {
        VStack(alignment: .leading, spacing: M.keyGap) {
            ForEach(result.candidates) { c in
                Button { picked = c.name } label: {
                    HStack {
                        Text(c.name).font(M.mode).foregroundStyle(palette.label)
                        Spacer()
                        Text(c.records.first.map(LookupCopy.row) ?? (c.empty_line ?? "")).font(M.predictionSmall).foregroundStyle(palette.secondaryLabel)
                    }
                    .padding(.horizontal, Theme.Space.s).frame(height: 36)
                    .background(palette.key, in: RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("lookup.pick.\(c.name)")
            }
            muted("Pick who you meant.")
        }
    }

    @ViewBuilder private func records(_ c: LookupResult.Candidate) -> some View {
        if let top = c.records.first {
            VStack(alignment: .leading, spacing: M.keyGap) {
                ForEach(Array(c.records.enumerated()), id: \.element.id) { i, rec in
                    HStack(spacing: Theme.Space.xs) {
                        Text(LookupCopy.row(rec)).font(i == 0 ? M.mode : M.smallMode).foregroundStyle(i == 0 ? palette.label : palette.secondaryLabel)
                            .monospacedDigit()
                        Spacer(minLength: 0)
                        Text(rec.title).font(M.predictionSmall).foregroundStyle(palette.secondaryLabel).lineLimit(1)
                    }
                    .padding(.horizontal, Theme.Space.s).frame(height: i == 0 ? 36 : 26)
                    .background(i == 0 ? palette.key : .clear, in: RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
                    .accessibilityIdentifier("lookup.row.\(i)")
                }
                let newFor = LookupCopy.newInvoiceName(result, c)
                HStack(spacing: Theme.Space.xs) {
                    action(insertWord, id: "lookup.insert") { onInsert(top) }
                    if let remind = top.remind { action("Remind", id: "lookup.remind") { onRemind(remind) } }
                    if let newFor { action("New invoice", id: "lookup.new") { onNewInvoice(newFor) } }
                }
                muted(LookupCopy.hint(top, insertWord: insertWord, offersNew: newFor != nil))
            }
        } else {
            VStack(alignment: .leading, spacing: M.keyGap) {
                Text(c.empty_line ?? "Nothing yet").font(M.mode).foregroundStyle(palette.label).accessibilityIdentifier("lookup.empty")
                if let name = LookupCopy.newInvoiceName(result, c) {
                    action("New invoice", id: "lookup.new") { onNewInvoice(name) }
                    muted(LookupCopy.hint(nil, insertWord: insertWord))
                }
            }
        }
    }

    private func action(_ title: String, id: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title).font(M.mode.weight(.medium)).foregroundStyle(palette.accent)
                .padding(.horizontal, Theme.Space.m).frame(height: 34)
                .background(palette.key, in: RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func muted(_ text: String) -> some View {
        Text(text).font(M.predictionSmall).foregroundStyle(palette.secondaryLabel).lineLimit(2).fixedSize(horizontal: false, vertical: true)
    }
}
