import ImageIO
import SwiftUI
import UIKit

/// The keyboard's catalog: open or not, the cached items, the picked ones, and the chip the typed words earned.
struct CatalogPanelState: Equatable {
    var open = false
    var items: [CatalogItem] = []
    var tab = CatalogTabs.all
    var selection = CatalogSelection()
    /// Insert adds each item's description on the line below it.
    var descriptions = false
    /// One short line in the panel, such as "Photo copied".
    var note: String?
    var trigger: CatalogTrigger?
    /// The client's copied message, for "do you have X" read there.
    var copied: String?
    /// The items are samples (the intro), not the owner's catalog.
    var examples = false

    var shown: [CatalogItem] { CatalogTabs.filter(items, tab: tab) }

    /// The bar chip for the typed or copied words: "Share catalog", "Share Beard trim", or nil.
    var barItem: BarItems.Item? {
        guard !open, let trigger else { return nil }
        switch trigger {
        case .share(let t):
            return BarItems.Item(id: "catalog", title: "Share catalog", action: .catalog(nil), trigger: t, short: "Catalog")
        case .item(let item, let t):
            return BarItems.Item(id: "catalog", title: "Share \(item.name)", detail: item.in_stock ? item.money : "sold out",
                                 tone: item.in_stock ? .label : .secondary, action: .catalog(item), trigger: t, short: item.name)
        }
    }
}

extension KeyboardModel {
    /// Re-reads the catalog the app cached. Called when the keyboard appears and when the panel opens.
    func reloadCatalog() {
        let items = deps.catalog.items
        if items != catalog.items { catalog.items = items }
        if catalog.examples != deps.catalog.examples { catalog.examples = deps.catalog.examples }
    }

    /// On every edit: the typed words, else the copied message, may ask for the catalog.
    func updateCatalogTrigger(_ typed: String) {
        let t = CatalogTrigger.match(typed, items: catalog.items) ?? catalog.copied.flatMap { CatalogTrigger.match($0, items: catalog.items) }
        if t != catalog.trigger { catalog.trigger = t }
    }

    func toggleCatalog() {
        catalog.open ? closeCatalog() : openCatalog(nil)
    }

    /// Opens the panel in place of the keys. `item`, when in stock, starts picked.
    func openCatalog(_ item: CatalogItem?) {
        host?.playClick()
        notesOpen = false
        writeOpen = false
        whoPaid = nil
        lookup = nil
        reloadCatalog()
        catalog.selection.clear()
        catalog.tab = CatalogTabs.all
        catalog.note = nil
        if let item, let fresh = catalog.items.first(where: { $0.id == item.id }) { catalog.selection.toggle(fresh) }
        catalog.open = true
    }

    func closeCatalog() {
        host?.playClick()
        catalog.open = false
        catalog.note = nil
    }

    func pickCatalogTab(_ tab: String) {
        host?.playClick()
        catalog.tab = tab
    }

    func toggleCatalogItem(_ item: CatalogItem) {
        host?.playClick()
        catalog.note = item.in_stock ? nil : "\(item.name) is sold out"
        catalog.selection.toggle(item)
    }

    func toggleCatalogDescriptions() {
        host?.playClick()
        catalog.descriptions.toggle()
    }

    /// Types one line per picked item, then shows the keys again.
    func insertCatalog() {
        let picked = catalog.selection.items(in: catalog.items)
        guard !picked.isEmpty else { return }
        host?.playClick()
        catalog.open = false
        catalog.trigger = nil
        place(CatalogShare.block(picked, descriptions: catalog.descriptions), gap: "\n", readAt: host?.contextBeforeInput ?? "")
    }

    /// Types the item's line, then offers the same pay link chip as a typed price. The link is made only on the owner's tap.
    func insertCatalogWithPayLink() {
        guard let item = catalog.selection.payLinkItem(in: catalog.items) else { return }
        host?.playClick()
        catalog.open = false
        catalog.trigger = nil
        place(CatalogShare.block([item], descriptions: catalog.descriptions), gap: "\n", readAt: host?.contextBeforeInput ?? "")
        offerPayLink(item.price, currency: item.currency, item: item.name)
    }

    /// Puts the picked item's photo on the pasteboard, for a paste into WhatsApp or Instagram. A keyboard needs Full Access for this.
    func copyCatalogPhoto() {
        guard let item = catalog.selection.photoItem(in: catalog.items), let pid = item.photo_id else { return }
        host?.playClick()
        guard host?.hasFullAccess == true else { catalog.note = "Allow Full Access to copy photos"; return }
        guard let data = deps.catalog.photo(pid) else { catalog.note = "Open \(AppConfig.displayName) to load this photo"; return }
        deps.copyImage(data)
        catalog.note = "Photo copied. Paste it in the chat."
    }

    func catalogThumb(_ item: CatalogItem) -> UIImage? {
        item.photo_id.flatMap { CatalogThumbs.shared.image(id: $0, cache: deps.catalog) }
    }
}

/// Small decoded photos for the panel. A keyboard has little memory, so photos are never decoded at full size.
final class CatalogThumbs {
    static let shared = CatalogThumbs()
    private let cache = NSCache<NSString, UIImage>()
    static let maxPixel = 120

    func image(id: String, cache store: CatalogCache) -> UIImage? {
        if let hit = cache.object(forKey: id as NSString) { return hit }
        guard let url = store.photoURL(id), let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: Self.maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = UIImage(cgImage: cg)
        cache.setObject(img, forKey: id as NSString)
        return img
    }
}

/// The catalog in place of the keys, per M1-4: category tabs, a two-column grid of item cards on the dotted board,
/// then the extras and the total. Share (Insert) sits in the bar above.
struct CatalogPanel: View {
    @ObservedObject var model: KeyboardModel
    let palette: Theme.SystemKeyboard.Palette
    typealias M = Theme.SystemKeyboard

    var body: some View {
        let c = model.catalog
        VStack(spacing: Theme.Space.xs) {
            if c.items.isEmpty {
                VStack(spacing: Theme.Space.s) {
                    PixelIcon(name: .tag, fill: Color(hex: 0xF4D35E), size: 36)
                    Text("Add what you sell in \(AppConfig.displayName) \u{2192} Catalog. It shows here.")
                        .font(Theme.Font.sans(15)).foregroundStyle(Theme.Color.text2).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("catalog.empty")
            } else {
                let tabs = CatalogTabs.tabs(c.items)
                if !tabs.isEmpty { tabRow(tabs, current: c.tab) }
                if c.examples {
                    Text("Examples. Add your own in \(AppConfig.displayName) \u{2192} Catalog.").font(Theme.Font.sans(12))
                        .foregroundStyle(Theme.Color.text2).lineLimit(1).minimumScaleFactor(0.8)
                        .accessibilityIdentifier("catalog.examples")
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.xs), GridItem(.flexible(), spacing: Theme.Space.xs)], spacing: Theme.Space.xs) {
                        ForEach(c.shown) { cell($0, picked: c.selection.contains($0)) }
                    }
                    .padding(3)
                }
                .scrollIndicators(.hidden)
                if let note = c.note {
                    Text(note).font(Theme.Font.sans(12)).foregroundStyle(Theme.Color.text2).lineLimit(1)
                        .accessibilityIdentifier("catalog.note")
                }
                actions(c)
            }
        }
        .padding(.horizontal, Theme.Space.s - 3)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tabRow(_ tabs: [String], current: String) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(tabs, id: \.self) { t in
                    Button { model.pickCatalogTab(t) } label: {
                        Text(t).font(Theme.Font.sans(13, t == current ? 500 : 400))
                            .foregroundStyle(t == current ? Theme.Color.darkButtonText : Theme.Color.text1)
                            .padding(.horizontal, Theme.Space.s).frame(height: 26)
                            .background(t == current ? Theme.Color.darkButton : Theme.Color.surface, in: Capsule())
                            .overlay(Capsule().stroke(Theme.Color.edge, lineWidth: t == current ? 0 : 0.8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("catalog.tab.\(t)")
                }
            }
            .padding(.horizontal, 3)
        }
        .scrollIndicators(.hidden)
        .frame(height: 28)
    }

    private func cell(_ item: CatalogItem, picked: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button { model.toggleCatalogItem(item) } label: {
            HStack(spacing: 10) {
                Group {
                    if let img = model.catalogThumb(item) {
                        Image(uiImage: img).resizable().scaledToFill().frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    } else {
                        let icon = PixelIcon.forItem(item.name)
                        IconTile(icon: icon, fill: PixelIcon.fill(for: icon))
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(Theme.Font.sans(14.5, 500)).foregroundStyle(Theme.Color.text1).lineLimit(1).minimumScaleFactor(0.8)
                    Text(item.in_stock ? item.money : "Sold out").font(Theme.Font.sans(13)).monospacedDigit()
                        .foregroundStyle(item.in_stock ? Theme.Color.text2 : Theme.Color.due).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 10).padding(.trailing, 24)
            .frame(height: 54)
            .background(picked ? Theme.Color.card : Theme.Color.surface, in: shape)
            .overlay(shape.strokeBorder(picked ? Theme.Color.text1 : Theme.Color.edge, lineWidth: picked ? 1.5 : 0.8))
            .shadow(color: .black.opacity(picked ? 0.08 : 0.05), radius: 6, y: 4)
            .overlay(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(picked ? Theme.Color.text1 : Theme.Color.card)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.Color.chipEdge, lineWidth: picked ? 0 : 1))
                    .overlay { if picked { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.Color.bg) } }
                    .frame(width: 18, height: 18)
                    .padding(8)
            }
            .opacity(item.in_stock ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChipPress())
        .accessibilityLabel("\(item.name), \(item.in_stock ? item.money : "sold out")\(picked ? ", selected" : "")")
        .accessibilityIdentifier("catalog.item.\(item.name)")
    }

    /// The extras and the total of what is picked: "Sends as one PayPal pay link · $135" when one item can carry a link.
    private func actions(_ c: CatalogPanelState) -> some View {
        let one = c.selection.payLinkItem(in: c.items) != nil
        let photo = c.selection.photoItem(in: c.items) != nil
        let picked = c.selection.items(in: c.items)
        let currency = picked.first?.currency ?? "USD"
        let total = picked.filter { $0.currency == currency }.reduce(0.0) { $0 + (Double($1.price) ?? 0) }
        return HStack(spacing: 6) {
            Button(action: model.toggleCatalogDescriptions) {
                Image(systemName: "text.alignleft").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(c.descriptions ? Theme.Color.darkButtonText : Theme.Color.text1)
            }
            .buttonStyle(TactileButton(kind: c.descriptions ? .dark : .quiet, small: true, wide: false))
            .accessibilityLabel(c.descriptions ? "Descriptions on" : "Descriptions off")
            .accessibilityIdentifier("catalog.descriptions")
            action("With pay link", id: "catalog.paylink", enabled: one, run: model.insertCatalogWithPayLink)
            action("Copy photo", id: "catalog.copyphoto", enabled: photo, run: model.copyCatalogPhoto)
            Spacer(minLength: 0)
            if !picked.isEmpty {
                Text(formatMoney(String(format: "%.2f", total), currency)).font(Theme.Font.sans(15, 500)).monospacedDigit()
                    .foregroundStyle(Theme.Color.text1).padding(.trailing, 4)
                    .accessibilityIdentifier("catalog.total")
            }
        }
        .padding(.horizontal, 3)
        .frame(height: 36)
    }

    private func action(_ title: String, id: String, enabled: Bool, run: @escaping () -> Void) -> some View {
        Button(title, action: run)
            .buttonStyle(TactileButton(kind: .quiet, small: true, wide: false))
            .disabled(!enabled)
            .accessibilityIdentifier(id)
    }
}
