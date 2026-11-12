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

/// The catalog in place of the keys: category tabs, a scrolling grid to pick from, then the three actions.
struct CatalogPanel: View {
    @ObservedObject var model: KeyboardModel
    let palette: Theme.SystemKeyboard.Palette
    typealias M = Theme.SystemKeyboard

    var body: some View {
        let c = model.catalog
        VStack(spacing: M.keyGap) {
            if c.items.isEmpty {
                Text("Add what you sell in \(AppConfig.displayName) \u{2192} Catalog. It shows here.")
                    .font(M.mode).foregroundStyle(palette.secondaryLabel).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("catalog.empty")
            } else {
                let tabs = CatalogTabs.tabs(c.items)
                if !tabs.isEmpty { tabRow(tabs, current: c.tab) }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: M.keyGap), GridItem(.flexible(), spacing: M.keyGap)], spacing: M.keyGap) {
                        ForEach(c.shown) { cell($0, picked: c.selection.contains($0)) }
                    }
                }
                .scrollIndicators(.hidden)
                if let note = c.note {
                    Text(note).font(M.predictionSmall).foregroundStyle(palette.secondaryLabel).lineLimit(1)
                        .accessibilityIdentifier("catalog.note")
                }
                actions(c)
            }
        }
        .padding(.horizontal, M.sideInset)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tabRow(_ tabs: [String], current: String) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: M.keyGap) {
                ForEach(tabs, id: \.self) { t in
                    Button { model.pickCatalogTab(t) } label: {
                        Text(t).font(M.smallMode.weight(t == current ? .semibold : .regular))
                            .foregroundStyle(t == current ? Color.white : palette.label)
                            .padding(.horizontal, Theme.Space.s).frame(height: 28)
                            .background(t == current ? palette.accent : palette.key, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("catalog.tab.\(t)")
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 28)
    }

    private func cell(_ item: CatalogItem, picked: Bool) -> some View {
        Button { model.toggleCatalogItem(item) } label: {
            HStack(spacing: Theme.Space.xs) {
                Group {
                    if let img = model.catalogThumb(item) {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Image(systemName: "tag").font(M.predictionSmall).foregroundStyle(palette.secondaryLabel)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(palette.bed)
                    }
                }
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.name).font(M.smallMode.weight(.medium)).foregroundStyle(palette.label).lineLimit(1)
                    Text(item.in_stock ? item.money : "Sold out").font(M.predictionSmall)
                        .foregroundStyle(item.in_stock ? palette.secondaryLabel : Theme.Color.due).lineLimit(1)
                }
                Spacer(minLength: 0)
                if picked {
                    Image(systemName: "checkmark.circle.fill").font(M.icon).foregroundStyle(palette.accent)
                }
            }
            .padding(.horizontal, Theme.Space.xs)
            .frame(height: 46)
            .background(palette.key, in: RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous).strokeBorder(picked ? palette.accent : .clear, lineWidth: 2))
            .opacity(item.in_stock ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.name), \(item.in_stock ? item.money : "sold out")\(picked ? ", selected" : "")")
        .accessibilityIdentifier("catalog.item.\(item.name)")
    }

    private func actions(_ c: CatalogPanelState) -> some View {
        let one = c.selection.payLinkItem(in: c.items) != nil
        let photo = c.selection.photoItem(in: c.items) != nil
        return HStack(spacing: M.keyGap) {
            Button(action: model.toggleCatalogDescriptions) {
                Image(systemName: "text.alignleft").font(M.icon)
                    .foregroundStyle(c.descriptions ? Color.white : palette.label)
                    .frame(width: 44, height: 40)
                    .background(c.descriptions ? palette.accent : palette.key, in: RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(c.descriptions ? "Descriptions on" : "Descriptions off")
            .accessibilityIdentifier("catalog.descriptions")
            action(c.selection.count > 1 ? "Insert \(c.selection.count)" : "Insert", id: "catalog.insert", accent: true,
                   enabled: c.selection.count > 0, run: model.insertCatalog)
            action("With pay link", id: "catalog.paylink", enabled: one, run: model.insertCatalogWithPayLink)
            action("Copy photo", id: "catalog.copyphoto", enabled: photo, run: model.copyCatalogPhoto)
        }
        .frame(height: 40)
    }

    private func action(_ title: String, id: String, accent: Bool = false, enabled: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title).font(M.smallMode.weight(.medium)).foregroundStyle(accent && enabled ? Color.white : palette.label)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(accent && enabled ? palette.accent : palette.key, in: RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityIdentifier(id)
    }
}
