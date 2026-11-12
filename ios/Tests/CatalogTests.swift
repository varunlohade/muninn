import XCTest
@testable import Muninn

private func item(_ name: String, _ price: String, id: String? = nil, description: String = "", category: String = "",
                  inStock: Bool = true, photo: String? = nil) -> CatalogItem {
    CatalogItem(id: id ?? name.lowercased(), name: name, price: price, currency: "USD", description: description, category: category,
                in_stock: inStock, sort_order: 0, photo_id: photo)
}

final class CatalogShareTests: XCTestCase {
    func testOneLinePerItemWithDashAndMoney() {
        let block = CatalogShare.block([item("Haircut", "45.00"), item("Beard trim", "20.50")])
        XCTAssertEqual(block, "Haircut \u{2014} $45\nBeard trim \u{2014} $20.50")
    }

    func testDescriptionGoesOnTheLineBelowOnlyWhenAsked() {
        let items = [item("Haircut", "45.00", description: "Wash, cut and style"), item("Beard trim", "20.00")]
        XCTAssertEqual(CatalogShare.block(items), "Haircut \u{2014} $45\nBeard trim \u{2014} $20")
        XCTAssertEqual(CatalogShare.block(items, descriptions: true), "Haircut \u{2014} $45\nWash, cut and style\nBeard trim \u{2014} $20")
    }

    func testOtherCurrencies() {
        let euro = CatalogItem(id: "a", name: "Pizza", price: "14.00", currency: "EUR", description: "", category: "", in_stock: true, sort_order: 0, photo_id: nil)
        XCTAssertEqual(CatalogShare.block([euro]), "Pizza \u{2014} \u{20AC}14")
    }
}

final class CatalogSelectionTests: XCTestCase {
    let cut = item("Haircut", "45.00", photo: "ph_cut")
    let trim = item("Beard trim", "20.00")
    let color = item("Color", "120.00", inStock: false)

    func testPickOrderIsKeptAndATapAgainUnpicks() {
        var s = CatalogSelection()
        s.toggle(trim); s.toggle(cut)
        XCTAssertEqual(s.items(in: [cut, trim, color]).map(\.name), ["Beard trim", "Haircut"])
        s.toggle(trim)
        XCTAssertEqual(s.items(in: [cut, trim, color]).map(\.name), ["Haircut"])
    }

    func testSoldOutCannotBePicked() {
        var s = CatalogSelection()
        s.toggle(color)
        XCTAssertEqual(s.count, 0)
    }

    func testPayLinkAndPhotoNeedExactlyOneItem() {
        var s = CatalogSelection()
        XCTAssertNil(s.payLinkItem(in: [cut, trim]))
        s.toggle(cut)
        XCTAssertEqual(s.payLinkItem(in: [cut, trim]), cut)
        XCTAssertEqual(s.photoItem(in: [cut, trim]), cut)
        s.toggle(trim)
        XCTAssertNil(s.payLinkItem(in: [cut, trim]), "a pay link is for one item")
        XCTAssertNil(s.photoItem(in: [cut, trim]))
        s.toggle(cut)
        XCTAssertNil(s.photoItem(in: [cut, trim]), "Beard trim has no photo")
    }

    func testAnItemDeletedInTheAppDropsOut() {
        var s = CatalogSelection()
        s.toggle(cut); s.toggle(trim)
        XCTAssertEqual(s.items(in: [trim]).map(\.name), ["Beard trim"])
    }

    func testTabsAndFilter() {
        let items = [item("Haircut", "45", category: "Hair"), item("Color", "120", category: "Color"), item("Trim", "20", category: "hair"), item("Gift card", "50")]
        XCTAssertEqual(CatalogTabs.tabs(items), ["All", "Hair", "Color"])
        XCTAssertEqual(CatalogTabs.filter(items, tab: "Hair").map(\.name), ["Haircut", "Trim"])
        XCTAssertEqual(CatalogTabs.filter(items, tab: "All").count, 4)
        XCTAssertEqual(CatalogTabs.tabs([item("A", "1", category: "Hair")]), [], "one category needs no tabs")
    }
}

final class CatalogTriggerTests: XCTestCase {
    let items = [item("Haircut", "45.00"), item("Beard trim", "20.00"), item("Color", "120.00", inStock: false)]

    private func share(_ s: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .share? = CatalogTrigger.match(s, items: items) else { return XCTFail("\(s): no share chip", file: file, line: line) }
    }

    func testShareWords() {
        for s in ["menu", "Here is our menu", "send catalog", "Send the catalogue", "price list?", "can you share your price list",
                  "what do you sell", "What do u offer", "send me the menu please", "sure, let me send prices"] {
            share(s)
        }
    }

    func testDoYouHaveWithAMatchingItemNamesIt() {
        guard case .item(let it, let trigger)? = CatalogTrigger.match("hi! do you have a beard trim today?", items: items) else { return XCTFail() }
        XCTAssertEqual(it.name, "Beard trim")
        XCTAssertEqual(trigger.lowercased(), "do you have a beard trim today")
        guard case .item(let cut, _)? = CatalogTrigger.match("Do you do haircuts", items: items) else { return XCTFail("plural") }
        XCTAssertEqual(cut.name, "Haircut")
    }

    func testDoYouHaveSoldOutItemStillNamesIt() {
        guard case .item(let it, _)? = CatalogTrigger.match("do you have color", items: items) else { return XCTFail() }
        XCTAssertFalse(it.in_stock)
        let chip = CatalogPanelState(items: items, trigger: .item(it, trigger: "do you have color")).barItem
        XCTAssertEqual(chip?.detail, "sold out")
    }

    func testDoYouHaveWithNoMatchSharesTheCatalog() {
        share("do you have nail art")
    }

    func testNegatives() {
        for s in ["the menu bar is broken", "click the menu button", "open the start menu", "right click for the context menu",
                  "a menu item is missing", "hey are you free tomorrow", "I sell nothing", "", "menus", "how much is it",
                  "the dropdown menu"] {
            XCTAssertNil(CatalogTrigger.match(s, items: items), s)
        }
    }

    func testOnlyTheLastSentenceCounts() {
        XCTAssertNil(CatalogTrigger.match("Send the menu. Thanks, see you at 5", items: items))
        share("Thanks for the visit. Here is the menu")
    }

    func testNoItemsNoChip() {
        XCTAssertNil(CatalogTrigger.match("send catalog", items: []))
    }

    func testBarItem() {
        let s = CatalogPanelState(items: items, trigger: .share(trigger: "menu"))
        XCTAssertEqual(s.barItem?.title, "Share catalog")
        XCTAssertEqual(s.barItem?.action, .catalog(nil))
        var open = s
        open.open = true
        XCTAssertNil(open.barItem, "no chip while the panel is open")
    }
}

final class CatalogCacheTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-test-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testItemsAndPhotosSurviveARestartWithNoNetwork() {
        let items = [item("Haircut", "45.00", photo: "ph_abc"), item("Beard trim", "20.00")]
        let app = CatalogCache(dir: dir)
        app.save(items)
        app.savePhoto(Data([0xFF, 0xD8, 0xFF, 1, 2]), id: "ph_abc")
        // A fresh reader, like the keyboard after the app wrote the cache.
        let keyboard = CatalogCache(dir: dir)
        XCTAssertEqual(keyboard.items, items)
        XCTAssertEqual(keyboard.photo("ph_abc"), Data([0xFF, 0xD8, 0xFF, 1, 2]))
    }

    func testAPhotoNoItemUsesIsRemoved() {
        let c = CatalogCache(dir: dir)
        c.savePhoto(Data([1]), id: "ph_old")
        c.savePhoto(Data([2]), id: "ph_new")
        c.save([item("Haircut", "45.00", photo: "ph_new")])
        XCTAssertFalse(c.hasPhoto("ph_old"))
        XCTAssertTrue(c.hasPhoto("ph_new"))
    }

    func testAPhotoIdNeverBecomesAPathOutsideTheFolder() {
        let c = CatalogCache(dir: dir)
        XCTAssertNil(c.photoURL("../items.json"))
        XCTAssertNil(c.photoURL("a/b"))
        XCTAssertNotNil(c.photoURL("ph_Zx-9_"))
    }

    func testEmptyWhenNothingCached() {
        XCTAssertEqual(CatalogCache(dir: dir).items, [])
        XCTAssertEqual(CatalogCache(dir: nil).items, [])
    }
}

final class CatalogDraftTests: XCTestCase {
    func testPriceAndLimits() {
        XCTAssertEqual(CatalogDraft(name: "Cut", price: "45").cleanPrice, "45.00")
        XCTAssertEqual(CatalogDraft(name: "Cut", price: "$45.5").cleanPrice, "45.50")
        XCTAssertNil(CatalogDraft(name: "Cut", price: "0").cleanPrice)
        XCTAssertNil(CatalogDraft(name: "Cut", price: "4.555").cleanPrice)
        XCTAssertFalse(CatalogDraft(name: " ", price: "45").canSave)
        XCTAssertFalse(CatalogDraft(name: "Cut", price: "45", description: String(repeating: "x", count: 141)).canSave)
        XCTAssertTrue(CatalogDraft(name: "Cut", price: "45", description: String(repeating: "x", count: 140)).canSave)
    }

    func testEveryBusinessHasThreeExamplesThatCanBeSaved() {
        for k in CatalogExamples.Kind.allCases {
            let d = CatalogExamples.drafts(k)
            XCTAssertEqual(d.count, 3, k.rawValue)
            XCTAssertTrue(d.allSatisfy(\.canSave), k.rawValue)
        }
    }

    func testReadyChipShowsWithItems() {
        XCTAssertTrue(ReadyChips.build(.init(unpaidCount: 0, catalogCount: 3)).contains { $0.id == "catalog" && $0.detail == "3 items" })
        XCTAssertFalse(ReadyChips.build(.init(unpaidCount: 0, catalogCount: 0)).contains { $0.id == "catalog" })
    }
}

@MainActor
final class CatalogKeyboardTests: XCTestCase {
    private var host: FakeHost!
    private var api: FakeAPI!
    private var model: KeyboardModel!
    private var dir: URL!
    private var copied: [Data] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-kb-\(UUID().uuidString)")
        let cache = CatalogCache(dir: dir)
        cache.save([item("Haircut", "45.00", description: "Wash, cut and style", category: "Hair", photo: "ph_cut"),
                    item("Beard trim", "20.00", category: "Hair"), item("Color", "120.00", category: "Color", inStock: false)])
        cache.savePhoto(Data([0xFF, 0xD8, 0xFF, 9]), id: "ph_cut")
        host = FakeHost()
        api = FakeAPI()
        var deps = KeyboardDeps.fake(api: api)
        deps.catalog = cache
        deps.copyImage = { [unowned self] in self.copied.append($0) }
        model = KeyboardModel(deps: deps)
        model.host = host
        model.keyboardAppeared()
    }

    override func tearDown() async throws {
        model.keyboardDisappeared()
        try? FileManager.default.removeItem(at: dir)
    }

    private func until(_ what: String, _ cond: () -> Bool) async {
        for _ in 0..<500 where !cond() { await Task.yield() }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }

    private func pick(_ name: String) { model.toggleCatalogItem(model.catalog.items.first { $0.name == name }!) }

    func testKeyboardReadsTheCacheOnAppearWithNoServerCall() {
        XCTAssertEqual(model.catalog.items.count, 3)
        XCTAssertTrue(model.barItems.contains { $0.id == "catalog" }, "ready chip on the empty bar")
        XCTAssertEqual(api.calls, [])
    }

    func testInsertTypesTheBlockAfterTheTypedText() {
        host.text = "Hi Ana! Here you go:"
        model.openCatalog(nil)
        pick("Haircut"); pick("Beard trim")
        XCTAssertEqual(model.catalog.selection.count, 2)
        model.insertCatalog()
        XCTAssertEqual(host.text, "Hi Ana! Here you go:\nHaircut \u{2014} $45\nBeard trim \u{2014} $20")
        XCTAssertFalse(model.catalog.open)
        XCTAssertEqual(api.calls, [], "insert never calls the server")
    }

    func testSoldOutTapSaysSoAndPicksNothing() {
        model.openCatalog(nil)
        pick("Color")
        XCTAssertEqual(model.catalog.selection.count, 0)
        XCTAssertEqual(model.catalog.note, "Color is sold out")
    }

    func testPayLinkGoesThroughTheChipAndOnlyOnTap() async {
        host.text = ""
        model.openCatalog(nil)
        pick("Haircut")
        model.insertCatalogWithPayLink()
        XCTAssertEqual(host.text, "Haircut \u{2014} $45")
        XCTAssertEqual(api.calls, [], "no link before the owner taps the chip")
        guard case .chips(let chips, _) = model.bar, let chip = chips.first else { return XCTFail("no pay link chip: \(model.bar)") }
        XCTAssertEqual(chip.kind, "paylink")
        XCTAssertEqual(chip.payload["item"], .string("Haircut"))
        XCTAssertEqual(chip.payload["amount"], .string("45.00"))
        model.tapChip(chip)
        await until("link") { host.text.hasSuffix("https://fake.pay/PL-1") }
        XCTAssertEqual(api.calls, ["paylink"])
        XCTAssertEqual(host.text, "Haircut \u{2014} $45 https://fake.pay/PL-1")
    }

    func testCopyPhotoPutsTheBytesOnThePasteboard() {
        model.openCatalog(nil)
        pick("Haircut")
        model.copyCatalogPhoto()
        XCTAssertEqual(copied, [Data([0xFF, 0xD8, 0xFF, 9])])
        host.hasFullAccess = false
        model.copyCatalogPhoto()
        XCTAssertEqual(copied.count, 1, "no copy without Full Access")
        XCTAssertEqual(model.catalog.note, "Allow Full Access to copy photos")
    }

    func testTypedTriggerOffersTheChipAndOpensThePanelWithTheItem() {
        host.text = "do you have a beard trim"
        model.textChanged()
        let chip = model.barItems.first { $0.id == "catalog" }
        XCTAssertEqual(chip?.title, "Share Beard trim")
        model.perform(chip!.action!)
        XCTAssertTrue(model.catalog.open)
        XCTAssertEqual(model.catalog.selection.items(in: model.catalog.items).map(\.name), ["Beard trim"])
    }

    func testDescriptionsToggle() {
        model.openCatalog(nil)
        pick("Haircut")
        model.toggleCatalogDescriptions()
        model.insertCatalog()
        XCTAssertEqual(host.text, "Haircut \u{2014} $45\nWash, cut and style")
    }
}
