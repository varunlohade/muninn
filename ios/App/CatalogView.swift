import PhotosUI
import SwiftUI
import UIKit

/// The catalog on the server, mirrored into the App Group so the keyboard can share it offline.
@MainActor
final class CatalogStore: ObservableObject {
    @Published var items: [CatalogItem]
    @Published var error: String?
    @Published var loaded = false
    private let cache: CatalogCache
    private let api: () -> APIClient

    init(cache: CatalogCache = .live, api: @escaping () -> APIClient = { .shared() }) {
        self.cache = cache
        self.api = api
        items = cache.items
    }

    func load() async {
        do {
            store(try await api().catalog())
            error = nil
        } catch {
            // Offline: the cached list stays on screen.
            self.error = items.isEmpty ? plainLine(error) : nil
        }
        loaded = true
        await syncPhotos()
    }

    /// Saves the draft and, when picked, the photo. Returns false when the server refused.
    func save(_ d: CatalogDraft, editing: CatalogItem?, photo: Data?, removePhoto: Bool) async -> Bool {
        do {
            var item: CatalogItem
            if let editing { item = try await api().editCatalogItem(editing.id, d) } else { item = try await api().addCatalogItem(d) }
            if let photo {
                item = try await api().uploadCatalogPhoto(item.id, jpeg: photo)
                if let id = item.photo_id { cache.savePhoto(photo, id: id) }
            } else if removePhoto, item.photo_id != nil {
                item = try await api().deleteCatalogPhoto(item.id)
            }
            var next = items
            if let i = next.firstIndex(where: { $0.id == item.id }) { next[i] = item } else { next.append(item) }
            store(next)
            error = nil
            return true
        } catch {
            self.error = plainLine(error)
            return false
        }
    }

    func delete(_ item: CatalogItem) async {
        do {
            try await api().deleteCatalogItem(item.id)
            store(items.filter { $0.id != item.id })
        } catch { self.error = plainLine(error) }
    }

    /// Moves one item up or down a place.
    func move(_ item: CatalogItem, by step: Int) async {
        guard let i = items.firstIndex(of: item), items.indices.contains(i + step) else { return }
        var ids = items.map(\.id)
        ids.swapAt(i, i + step)
        do { store(try await api().reorderCatalog(ids)) } catch { self.error = plainLine(error) }
    }

    func photo(_ item: CatalogItem) -> UIImage? { item.photo_id.flatMap(cache.photo).flatMap(UIImage.init(data:)) }

    private func store(_ list: [CatalogItem]) {
        items = list
        cache.save(list)
    }

    /// Downloads each photo the phone does not have yet, so the keyboard can show and copy it offline.
    private func syncPhotos() async {
        var changed = false
        for item in items {
            guard let pid = item.photo_id, !cache.hasPhoto(pid), let data = try? await api().catalogPhoto(item.id) else { continue }
            cache.savePhoto(data, id: pid)
            changed = true
        }
        if changed { objectWillChange.send() }
    }
}

/// What you sell, with photos and prices. The keyboard's Catalog button shares any of it in a chat.
struct CatalogView: View {
    @StateObject private var store = CatalogStore()
    @State private var editing: Editing?
    @State private var kind: CatalogExamples.Kind = .salon

    struct Editing: Identifiable {
        let id = UUID()
        var item: CatalogItem?
        var draft: CatalogDraft
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.cardGap) {
                HStack(alignment: .top) {
                    twoTone("Catalog.", "What you sell, ready to share in any chat.")
                        .font(Theme.Font.title).tracking(-0.3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Theme.Space.s)
                    Button { editing = Editing(item: nil, draft: CatalogDraft()) } label: { IconCircle(systemImage: "plus", size: 40) }
                        .buttonStyle(PressScale())
                        .disabled(store.items.count >= CatalogCache.maxItems)
                        .accessibilityLabel("Add item")
                        .accessibilityIdentifier("catalog.new")
                }
                .padding(.leading, Theme.Metric.cardInset + 2)
                .padding(.trailing, Theme.Metric.cardInset)
                .padding(.bottom, Theme.Space.xs)
                if let e = store.error {
                    Text(e).font(Theme.Font.label).foregroundStyle(Theme.Color.due).padding(.horizontal, Theme.Metric.margin)
                }
                if store.items.isEmpty && store.loaded {
                    empty
                } else {
                    Text("Tap the tag button on the keyboard to share items, prices and photos in any chat.")
                        .font(Theme.Font.label).foregroundStyle(Theme.Color.text2).padding(.horizontal, Theme.Metric.cardInset + 2)
                        .fixedSize(horizontal: false, vertical: true)
                    if store.items.count >= CatalogCache.maxItems {
                        Text("Your catalog is full (\(CatalogCache.maxItems) items). Delete one to add another.")
                            .font(Theme.Font.label).foregroundStyle(Theme.Color.due).padding(.horizontal, Theme.Metric.margin)
                    }
                    ForEach(store.items) { item in row(item) }
                }
            }
            .padding(.top, Theme.Space.xs)
            .padding(.bottom, Theme.Space.l)
        }
        .background(Theme.Color.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
        .refreshable { await store.load() }
        .sheet(item: $editing) { e in
            CatalogEditor(item: e.item, draft: e.draft, photo: e.item.flatMap(store.photo), store: store)
        }
    }

    private func row(_ item: CatalogItem) -> some View {
        Button { editing = Editing(item: item, draft: CatalogDraft(item)) } label: {
            HStack(spacing: Theme.Space.s) {
                CatalogThumb(image: store.photo(item), size: 44, name: item.name)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(Theme.Font.sans(15, 500)).foregroundStyle(Theme.Color.text1).lineLimit(1)
                    if !item.category.isEmpty {
                        Text(item.category).font(Theme.Font.label).foregroundStyle(Theme.Color.text2).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if !item.in_stock { StatusPill(text: "Sold out", tone: .due) }
                Text(item.money).font(Theme.Font.sans(15, 500).monospacedDigit()).foregroundStyle(item.in_stock ? Theme.Color.text1 : Theme.Color.text3)
            }
            .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 8)
            .rowSurface()
        }
        .buttonStyle(PressScale())
        .padding(.horizontal, Theme.Metric.cardInset)
        .accessibilityIdentifier("catalog.row.\(item.name)")
        .contextMenu {
            Button("Move up", systemImage: "arrow.up") { Task { await store.move(item, by: -1) } }.disabled(item == store.items.first)
            Button("Move down", systemImage: "arrow.down") { Task { await store.move(item, by: 1) } }.disabled(item == store.items.last)
            Button("Delete", systemImage: "trash", role: .destructive) { Task { await store.delete(item) } }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.cardGap) {
            Text("Add what you sell").font(Theme.Font.section).foregroundStyle(Theme.Color.text1).padding(.horizontal, Theme.Metric.cardInset + 2)
            Text("Start from an example. Tap one to fill in the form, then change it to yours.")
                .font(Theme.Font.label).foregroundStyle(Theme.Color.text2).padding(.horizontal, Theme.Metric.cardInset + 2)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Business", selection: $kind) {
                ForEach(CatalogExamples.Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.Metric.cardInset)
            .accessibilityIdentifier("catalog.kind")
            ForEach(CatalogExamples.drafts(kind), id: \.name) { d in
                Button { editing = Editing(item: nil, draft: d) } label: {
                    HStack(spacing: Theme.Space.s) {
                        CatalogThumb(image: nil, size: 44, name: d.name)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name).font(Theme.Font.sans(15, 500)).foregroundStyle(Theme.Color.text1)
                            Text(d.description).font(Theme.Font.label).foregroundStyle(Theme.Color.text2).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text(formatMoney(d.cleanPrice ?? d.price, "USD")).font(Theme.Font.sans(15).monospacedDigit()).foregroundStyle(Theme.Color.text2)
                        Image(systemName: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Color.text3)
                    }
                    .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 8)
                    .background(Theme.Color.bg.opacity(0.01))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Metric.rowRadius, style: .continuous)
                        .strokeBorder(Theme.Color.dash, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
                .buttonStyle(PressScale())
                .padding(.horizontal, Theme.Metric.cardInset)
                .accessibilityIdentifier("catalog.example.\(d.name)")
            }
        }
    }
}

/// A rounded photo, or a grey square with a tag when there is none.
struct CatalogThumb: View {
    let image: UIImage?
    let size: CGFloat
    var name = ""

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                let icon = PixelIcon.forItem(name)
                PixelIcon(name: icon, fill: PixelIcon.fill(for: icon), size: size * 0.55)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.Color.card)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).strokeBorder(Theme.Color.edge, lineWidth: 1))
    }
}

/// Add or edit one item: photo, name, price, description, category, in stock.
struct CatalogEditor: View {
    let item: CatalogItem?
    @State var draft: CatalogDraft
    @State var photo: UIImage?
    @ObservedObject var store: CatalogStore
    @Environment(\.dismiss) private var dismiss
    @State private var pick: PhotosPickerItem?
    @State private var newPhoto: Data?
    @State private var removePhoto = false
    @State private var saving = false
    @State private var photoError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    HStack(spacing: Theme.Space.m) {
                        CatalogThumb(image: photo, size: 88)
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            PhotosPicker(selection: $pick, matching: .images) {
                                Text(photo == nil ? "Add photo" : "Change photo").font(Theme.Font.smallButton).foregroundStyle(Theme.Color.text1)
                                    .padding(.horizontal, Theme.Space.m).frame(height: 36)
                                    .cardSurface(radius: 8, fill: Theme.Color.quietButton)
                            }
                            .accessibilityIdentifier("catalog.photo")
                            if photo != nil {
                                Button("Remove photo") { photo = nil; newPhoto = nil; removePhoto = true }
                                    .font(Theme.Font.label).foregroundStyle(Theme.Color.text2)
                            }
                            if let photoError { Text(photoError).font(Theme.Font.label).foregroundStyle(Theme.Color.due) }
                            Text(CatalogCache.photoLimitLine).font(Theme.Font.axis).foregroundStyle(Theme.Color.text3)
                        }
                    }
                    field("Name, like Haircut", text: $draft.name, id: "catalog.name")
                    field("Price, like 45", text: $draft.price, id: "catalog.price").keyboardType(.decimalPad)
                    VStack(alignment: .trailing, spacing: Theme.Space.xxs) {
                        TextField("", text: $draft.description, prompt: Text("Short description (optional)").foregroundStyle(Theme.Color.text3), axis: .vertical)
                            .lineLimit(2...4)
                            .font(Theme.Font.body).foregroundStyle(Theme.Color.text1)
                            .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                            .cardSurface(radius: Theme.Metric.buttonRadius, fill: Theme.Color.surface, lifted: false)
                            .accessibilityIdentifier("catalog.description")
                        Text("\(draft.description.count)/\(CatalogDraft.maxDescription)").font(Theme.Font.axis)
                            .foregroundStyle(draft.description.count > CatalogDraft.maxDescription ? Theme.Color.due : Theme.Color.text3)
                            .padding(.trailing, Theme.Space.s)
                    }
                    field("Category, like Hair (optional)", text: $draft.category, id: "catalog.category")
                    Toggle(isOn: $draft.inStock) {
                        Text("In stock").font(Theme.Font.body).foregroundStyle(Theme.Color.text1)
                    }
                    .tint(Theme.Color.paid)
                    .padding(.horizontal, Theme.Space.m)
                    .frame(height: Theme.Metric.secondaryButton)
                    .cardSurface(radius: Theme.Metric.buttonRadius, fill: Theme.Color.surface, lifted: false)
                    .accessibilityIdentifier("catalog.instock")
                    if let e = store.error, !saving {
                        Text(e).font(Theme.Font.label).foregroundStyle(Theme.Color.due).padding(.horizontal, Theme.Space.xs)
                    }
                    if let item {
                        Button("Delete item", role: .destructive) { Task { await store.delete(item); dismiss() } }
                            .font(Theme.Font.label).padding(.horizontal, Theme.Space.xs)
                            .accessibilityIdentifier("catalog.delete")
                    }
                }
                .padding(Theme.Metric.cardInset)
            }
            .background(Theme.Color.bg.ignoresSafeArea())
            .navigationTitle(item == nil ? "New item" : "Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            let ok = await store.save(draft, editing: item, photo: newPhoto, removePhoto: removePhoto)
                            saving = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(!draft.canSave || saving)
                    .accessibilityIdentifier("catalog.save")
                }
            }
            .onChange(of: pick) { _, p in
                guard let p else { return }
                Task {
                    guard let data = try? await p.loadTransferable(type: Data.self), let img = UIImage(data: data),
                          let jpeg = CatalogPhoto.jpeg(img) else { photoError = "Could not use that photo."; return }
                    photoError = nil
                    newPhoto = jpeg
                    photo = UIImage(data: jpeg)
                    removePhoto = false
                }
            }
        }
    }

    private func field(_ prompt: String, text: Binding<String>, id: String) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(Theme.Color.text3))
            .modifier(FieldStyle())
            .accessibilityIdentifier(id)
    }
}

/// Every photo is drawn again as a JPEG of at most 1080 px and 1 MB, so no camera metadata (place, time, device) leaves the phone.
enum CatalogPhoto {
    static let maxSide: CGFloat = 1080
    static let maxBytes = 1024 * 1024

    static func jpeg(_ image: UIImage) -> Data? {
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        guard size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let drawn = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        for q in stride(from: 0.8, through: 0.3, by: -0.1) {
            if let d = drawn.jpegData(compressionQuality: q), d.count <= maxBytes { return d }
        }
        return nil
    }
}
