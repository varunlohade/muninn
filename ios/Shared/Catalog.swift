import Foundation

/// One thing the owner sells, as the server keeps it (GET /v1/catalog).
struct CatalogItem: Codable, Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    /// "45.00"
    var price: String
    var currency: String
    var description: String
    var category: String
    var in_stock: Bool
    var sort_order: Int
    /// Changes each time the photo changes. Nil when the item has no photo.
    var photo_id: String?

    var money: String { formatMoney(price, currency) }
}

struct CatalogResponse: Decodable { let items: [CatalogItem] }
struct CatalogItemResponse: Decodable { let item: CatalogItem }

/// What the owner types in the add sheet. The server cleans and checks it again.
struct CatalogDraft: Equatable {
    var name = ""
    var price = ""
    var description = ""
    var category = ""
    var inStock = true

    static let maxDescription = 140

    init(name: String = "", price: String = "", description: String = "", category: String = "", inStock: Bool = true) {
        self.name = name; self.price = price; self.description = description; self.category = category; self.inStock = inStock
    }

    init(_ item: CatalogItem) {
        self.init(name: item.name, price: item.price.hasSuffix(".00") ? String(item.price.dropLast(3)) : item.price,
                  description: item.description, category: item.category, inStock: item.in_stock)
    }

    /// "45", "$45", "45.5" → "45.50". Nil for anything else.
    var cleanPrice: String? {
        let s = price.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        guard s.range(of: #"^\d{1,7}(\.\d{1,2})?$"#, options: .regularExpression) != nil, let v = Double(s), v > 0 else { return nil }
        return String(format: "%.2f", v)
    }

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && cleanPrice != nil && description.count <= Self.maxDescription
    }

    var body: [String: JSONValue] {
        ["name": .string(name.trimmingCharacters(in: .whitespaces)), "price": .string(cleanPrice ?? ""),
         "description": .string(description.trimmingCharacters(in: .whitespacesAndNewlines)),
         "category": .string(category.trimmingCharacters(in: .whitespaces)), "in_stock": .bool(inStock)]
    }
}

/// The text the keyboard types for the chosen items.
enum CatalogShare {
    /// "Haircut — $45", one line per item. With `descriptions`, each item's description goes on the line below it.
    static func block(_ items: [CatalogItem], descriptions: Bool = false) -> String {
        items.map { i in
            let line = "\(i.name) \u{2014} \(i.money)"
            let d = i.description.trimmingCharacters(in: .whitespacesAndNewlines)
            return descriptions && !d.isEmpty ? line + "\n" + d : line
        }.joined(separator: "\n")
    }
}

/// The items the owner picked in the keyboard panel, in the order they were picked. Sold-out items cannot be picked.
struct CatalogSelection: Equatable {
    private(set) var ids: [String] = []

    var count: Int { ids.count }
    func contains(_ item: CatalogItem) -> Bool { ids.contains(item.id) }

    mutating func toggle(_ item: CatalogItem) {
        if let i = ids.firstIndex(of: item.id) { ids.remove(at: i) } else if item.in_stock { ids.append(item.id) }
    }

    mutating func clear() { ids = [] }

    /// The picked items that still exist, in pick order.
    func items(in all: [CatalogItem]) -> [CatalogItem] {
        ids.compactMap { id in all.first { $0.id == id } }
    }

    /// A pay link is for one item only.
    func payLinkItem(in all: [CatalogItem]) -> CatalogItem? {
        let picked = items(in: all)
        return picked.count == 1 ? picked[0] : nil
    }

    /// Copy photo works on one picked item that has a photo.
    func photoItem(in all: [CatalogItem]) -> CatalogItem? {
        payLinkItem(in: all).flatMap { $0.photo_id == nil ? nil : $0 }
    }
}

/// The category tabs above the panel grid: "All", then each category in catalog order. Items with no category show only under All.
enum CatalogTabs {
    static let all = "All"

    static func tabs(_ items: [CatalogItem]) -> [String] {
        var out: [String] = []
        for i in items {
            let c = i.category.trimmingCharacters(in: .whitespaces)
            if !c.isEmpty, !out.contains(where: { $0.caseInsensitiveCompare(c) == .orderedSame }) { out.append(c) }
        }
        return out.count > 1 ? [all] + out : []
    }

    static func filter(_ items: [CatalogItem], tab: String) -> [CatalogItem] {
        tab == all ? items : items.filter { $0.category.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(tab) == .orderedSame }
    }
}

/// Typed words that ask for the catalog, read on the phone. No server call.
enum CatalogTrigger: Equatable {
    /// "menu", "price list", "send catalog", "what do you sell"
    case share(trigger: String)
    /// "do you have beard trim" with a matching item.
    case item(CatalogItem, trigger: String)

    private static func regex(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }

    private static let share: [NSRegularExpression] = [
        regex(#"\b(?:send|share|see|show|get)\s+(?:me\s+|you\s+)?(?:the\s+|our\s+|my\s+|your\s+|a\s+)?(?:catalog(?:ue)?|price\s*list|prices|menu)\b"#),
        regex(#"\bprice\s*list\b"#),
        regex(#"\bwhat\s+(?:do|does)\s+(?:you|u|y'?all)\s+(?:sell|offer|have)\b"#),
        regex(#"\b(?:your|our|the)\s+(?:catalog(?:ue)?|services\s+list)\b"#),
        // "menu" on its own, or "the menu", "your menu?", but never "the menu bar", "menu button", "start menu", "a menu item".
        regex(#"(?<!start\s)(?<!context\s)(?<!drop\s?down\s)(?<!dropdown\s)(?<!side\s)(?<!hamburger\s)(?<!settings\s)\bmenu\b(?!\s*(?:bar|button|item|items|icon|option|options|screen|page|key|settings|tab))"#),
    ]

    private static let doYouHave = regex(#"\b(?:do|does)\s+(?:you|u|y'?all)\s+(?:have|sell|do|offer|carry|stock)\s+(?:any\s+|a\s+|an\s+|the\s+|some\s+)?([^?.!,\n]{2,40})"#)

    /// The catalog chip for the last sentence of `text`, or nil. `items` are the cached catalog items.
    static func match(_ text: String, items: [CatalogItem]) -> CatalogTrigger? {
        let sentence = lastSentence(text)
        guard !sentence.isEmpty, !items.isEmpty else { return nil }
        let ns = sentence as NSString
        let all = NSRange(location: 0, length: ns.length)
        if let m = doYouHave.firstMatch(in: sentence, range: all) {
            let asked = ns.substring(with: m.range(at: 1))
            if let item = find(asked, in: items) { return .item(item, trigger: ns.substring(with: m.range)) }
            return .share(trigger: ns.substring(with: m.range))
        }
        for r in share {
            if let m = r.firstMatch(in: sentence, range: all) { return .share(trigger: ns.substring(with: m.range)) }
        }
        return nil
    }

    /// The item whose name the asked words hold, longest name first: "a beard trim today" → Beard trim. A plural "haircuts" matches too.
    static func find(_ asked: String, in items: [CatalogItem]) -> CatalogItem? {
        let words = " " + normalize(asked) + " "
        return items.sorted { $0.name.count > $1.name.count }.first { i in
            let n = normalize(i.name)
            return !n.isEmpty && (words.contains(" \(n) ") || words.contains(" \(n)s ") || words.contains(" \(n)es "))
        }
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func lastSentence(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = t.components(separatedBy: CharacterSet(charactersIn: ".!\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.last ?? ""
    }
}

/// The catalog on this phone, so the keyboard works offline. The app writes it after each load or change; the keyboard only reads.
/// Items are one JSON file; each photo is a file named by its photo id.
struct CatalogCache {
    let dir: URL?

    static var live: CatalogCache {
        CatalogCache(dir: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupID)?
            .appendingPathComponent("catalog", isDirectory: true))
    }

    private var itemsURL: URL? { dir?.appendingPathComponent("items.json") }

    func photoURL(_ photoID: String) -> URL? {
        // Photo ids are the server's random tokens; anything else never becomes a path.
        guard photoID.range(of: #"^[A-Za-z0-9_-]{1,80}$"#, options: .regularExpression) != nil else { return nil }
        return dir?.appendingPathComponent("photo-\(photoID)")
    }

    var items: [CatalogItem] {
        guard let url = itemsURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CatalogItem].self, from: data)) ?? []
    }

    func save(_ items: [CatalogItem]) {
        guard let dir, let url = itemsURL, let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        // Photos no item points at any more go.
        let keep = Set(items.compactMap { $0.photo_id.flatMap(photoURL)?.lastPathComponent })
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasPrefix("photo-") && !keep.contains(f) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }

    func hasPhoto(_ photoID: String) -> Bool { photoURL(photoID).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    func photo(_ photoID: String) -> Data? { photoURL(photoID).flatMap { try? Data(contentsOf: $0) } }

    func savePhoto(_ data: Data, id photoID: String) {
        guard let dir, let url = photoURL(photoID) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}

/// Starter items for an empty catalog, by kind of business. A tap fills the add sheet; nothing is saved until Save.
enum CatalogExamples {
    enum Kind: String, CaseIterable, Identifiable {
        case salon = "Salon", restaurant = "Restaurant", shop = "Shop"
        var id: String { rawValue }
    }

    static func drafts(_ kind: Kind) -> [CatalogDraft] {
        switch kind {
        case .salon: [
            CatalogDraft(name: "Haircut", price: "45", description: "Wash, cut and style", category: "Hair"),
            CatalogDraft(name: "Beard trim", price: "20", description: "Shape and line-up", category: "Hair"),
            CatalogDraft(name: "Color", price: "120", description: "All-over color, one shade", category: "Color"),
        ]
        case .restaurant: [
            CatalogDraft(name: "Margherita pizza", price: "14", description: "Tomato, mozzarella, basil", category: "Mains"),
            CatalogDraft(name: "Caesar salad", price: "11", description: "Romaine, parmesan, croutons", category: "Starters"),
            CatalogDraft(name: "Tiramisu", price: "8", description: "Made fresh each morning", category: "Desserts"),
        ]
        case .shop: [
            CatalogDraft(name: "Tote bag", price: "25", description: "Heavy cotton, hand printed", category: "Bags"),
            CatalogDraft(name: "Scented candle", price: "18", description: "Soy wax, 40 hours", category: "Home"),
            CatalogDraft(name: "Gift card", price: "50", description: "Any amount, never expires", category: "Gifts"),
        ]
        }
    }
}
