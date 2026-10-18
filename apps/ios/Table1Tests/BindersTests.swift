import XCTest
@testable import Table1

/* Binders, "for trade" and wants on the device (contract/binders-wants-2026-10-17.md): the allocation rules the
   demo applies (the server's are tested in supabase/tests/70_binders_wants_test.sql), the Missing view, which want
   a trade's get meets, and the CSV binder and tradelist columns. Same cases as the web's binders.test.ts. */

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/collection-import").standardized

final class BinderRulesTests: XCTestCase {
    private let binders: [String: Binder] = [
        "t": Binder(id: "t", name: "Trade binder", forTrade: true, seq: 1),
        "a": Binder(id: "a", name: "Alpha", forTrade: false, seq: 2),
        "b": Binder(id: "b", name: "Box 3", forTrade: false, seq: 3),
    ]

    func testUnsortedGoesFirst() {
        // 6 copies: Alpha 1, Box 2, Trade 2, Unsorted 1. Removing one takes the Unsorted copy.
        let out = BinderRules.plan(current: ["a": 1, "b": 2, "t": 2], hints: [:], newQty: 5, binders: binders)
        XCTAssertEqual(out, ["a": 1, "b": 2, "t": 2])
    }

    func testNonTradeBindersByNameThenTrade() {
        let out = BinderRules.plan(current: ["a": 1, "b": 2, "t": 2], hints: [:], newQty: 2, binders: binders)
        XCTAssertEqual(out, ["a": 0, "b": 0, "t": 2])
        let all = BinderRules.plan(current: ["a": 1, "b": 2, "t": 2], hints: [:], newQty: 1, binders: binders)
        XCTAssertEqual(all, ["a": 0, "b": 0, "t": 1])
    }

    func testANamedBinderGivesFirstAndAddsGoIn() {
        // Giving one from the trade binder: it shrinks even though Box has copies.
        XCTAssertEqual(BinderRules.plan(current: ["b": 2, "t": 1], hints: ["t": -1], newQty: 2, binders: binders), ["b": 2, "t": 0])
        // Adding two into Box.
        XCTAssertEqual(BinderRules.plan(current: ["b": 2], hints: ["b": 2], newQty: 6, binders: binders), ["b": 4])
        // A binder that's gone is ignored.
        XCTAssertEqual(BinderRules.plan(current: [:], hints: ["gone": 3], newQty: 3, binders: binders), [:])
    }

    func testWantsMetInOrder() {
        var wants: [String: Want] = [:]
        for w in [Want(oracleId: "o", cardId: nil, finish: nil, qty: 2, maxUsd: nil, seq: 1),
                  Want(oracleId: "o", cardId: "p", finish: nil, qty: 1, maxUsd: nil, seq: 2),
                  Want(oracleId: "o", cardId: "p", finish: "foil", qty: 1, maxUsd: nil, seq: 3)] { wants[w.id] = w }
        XCTAssertEqual(BinderRules.wantFor(oracleId: "o", cardId: "p", finish: "foil", in: Array(wants.values))?.finish, "foil")
        XCTAssertEqual(BinderRules.wantFor(oracleId: "o", cardId: "p", finish: "nonfoil", in: Array(wants.values))?.cardId, "p")
        XCTAssertNil(BinderRules.wantFor(oracleId: "o", cardId: "q", finish: "nonfoil", in: Array(wants.values))?.cardId)
        XCTAssertNil(BinderRules.wantFor(oracleId: "x", cardId: "q", finish: "nonfoil", in: Array(wants.values)))
        let changed = BinderRules.meet(oracleId: "o", cardId: "p", finish: "foil", qty: 3, wants: &wants)
        XCTAssertEqual(changed.count, 3)
        XCTAssertEqual(wants[Want.key("o", "p", "foil")]?.qty, 0)
        XCTAssertEqual(wants[Want.key("o", "p", nil)]?.qty, 0)
        XCTAssertEqual(wants[Want.key("o", nil, nil)]?.qty, 1)
    }

    func testMissingTakesTheLargestNeedAcrossLists() {
        func list(_ id: String, _ entries: [CardList.Entry], event: String? = nil) -> CardList {
            var l = CardList(id: id, kind: .deck, name: "Deck \(id)", format: "modern",
                             versions: [CardList.Version(number: 1, at: .now, note: "", entries: entries)])
            l.eventId = event
            return l
        }
        let lists = [
            list("1", [.init(cardId: "bolt", board: "main", qty: 4), .init(cardId: "opt", board: "maybe", qty: 4)]),
            list("2", [.init(cardId: "bolt", board: "main", qty: 2), .init(cardId: "bolt", board: "side", qty: 1),
                       .init(cardId: "bolt", board: "main", qty: 2, finish: "foil")]),
            list("3", [.init(cardId: "shock", board: "main", qty: 4)], event: "roto"),
        ]
        let lines = MissingView.lines(lists, owned: ["bolt|nonfoil": 1])
        XCTAssertEqual(lines.map(\.id), ["bolt|nonfoil", "bolt|foil"])
        XCTAssertEqual(lines[0].short, 3)
        XCTAssertEqual(lines[0].lists, ["Deck 1", "Deck 2"])
        XCTAssertEqual(lines[1].short, 2)
        XCTAssertTrue(MissingView.lines(lists, owned: ["bolt|nonfoil": 4, "bolt|foil": 2]).isEmpty)
    }
}

final class BinderCSVTests: XCTestCase {
    private func fixture(_ name: String) throws -> String { try String(contentsOf: fixtures.appending(path: name), encoding: .utf8) }

    func testManaBoxBindersAndLists() throws {
        let p = try CollectionCSV.parse(try fixture("manabox.csv"))
        XCTAssertEqual(p.rows.first?.binder, "My collection")
        XCTAssertEqual(p.rows.filter { $0.binder == "Trade binder" }.count, 16)
        let text = """
        Binder Name,Binder Type,Name,Set code,Collector number,Foil,Quantity
        Box 3,binder,Lightning Bolt,M11,149,normal,4
        Wishlist,list,Lightning Bolt,M11,149,foil,2
        Burn,deck,Lightning Bolt,M11,149,normal,1
        """
        let rows = try CollectionCSV.parse(text).rows
        XCTAssertEqual(rows.map(\.binder), ["Box 3", nil, nil])
        XCTAssertEqual(rows.map(\.wanted), [false, true, false])
        let resolved = ImportResolver(db: TestCatalog.db, setNames: TestCatalog.setNames).resolve(rows).matched
        XCTAssertEqual(ImportResolver.items(resolved).reduce(0) { $0 + $1.qty }, 5, "list rows aren't owned copies")
        XCTAssertEqual(ImportResolver.placements(resolved).map { "\($0.binder) \($0.qty)" }, ["Box 3 4"])
        XCTAssertEqual(ImportResolver.wants(resolved).map { "\($0.finish) \($0.qty)" }, ["foil 2"])
    }

    func testTradelistCounts() throws {
        let deckbox = "Count,Tradelist Count,Name,Edition,Edition Code,Card Number\n4,3,Lightning Bolt,Magic 2011,m11,149\n2,9,Opt,Ixalan,xln,65\n1,,Shock,M19,m19,156\n"
        XCTAssertEqual(try CollectionCSV.parse(deckbox).rows.map(\.tradeQty), [3, 2, 0])
        let mox = "\"Count\",\"Tradelist Count\",\"Name\",\"Edition\",\"Collector Number\"\n\"4\",\"1\",\"Lightning Bolt\",\"m11\",\"149\"\n"
        XCTAssertEqual(try CollectionCSV.parse(mox).rows.first?.tradeQty, 1)
        let ds = "\"sep=,\"\nFolder Name,Quantity,Trade Quantity,Card Name,Set Code,Card Number\nBox,4,1,Lightning Bolt,M11,149\n"
        let row = try CollectionCSV.parse(ds).rows.first
        XCTAssertEqual(row?.binder, "Box")
        XCTAssertEqual(row?.tradeQty, 1)
        let resolved = ImportResolver(db: TestCatalog.db, setNames: TestCatalog.setNames).resolve(try CollectionCSV.parse(ds).rows).matched
        XCTAssertEqual(Set(ImportResolver.placements(resolved).map { "\($0.binder) \($0.qty)" }), ["Trade binder 1", "Box 3"])
    }

    func testExportCarriesBindersAndReadsBack() throws {
        func card(_ qty: Int, _ binder: String?, trade: Bool = false, wanted: Bool = false) -> CollectionCSV.ExportCard {
            .init(name: "Lightning Bolt", set: "m11", setName: "Magic 2011", cn: "149", rarity: "c", cardId: "bolt", finish: "nonfoil",
                  condition: "NM", lang: "en", qty: qty, binder: binder, forTrade: trade, wanted: wanted)
        }
        let cards = [card(2, "Trade binder", trade: true), card(1, "Box 3"), card(1, nil), card(3, nil, wanted: true)]
        let manabox = try CollectionCSV.parse(CollectionCSV.export(cards, layout: .manabox)).rows
        XCTAssertEqual(manabox.filter { !$0.wanted }.map { "\($0.binder ?? "-") \($0.qty)" }.sorted(), ["- 1", "Box 3 1", "Trade binder 2"])
        XCTAssertEqual(manabox.filter(\.wanted).map(\.qty), [3])
        let mox = try CollectionCSV.parse(CollectionCSV.export(cards, layout: .moxfield)).rows
        XCTAssertEqual(mox.map { "\($0.qty)/\($0.tradeQty)" }, ["4/2"], "one row per item; for-trade copies are the tradelist")
    }
}

/* Searching inside screens, wants pointed at another printing, Move in and cube Replace
   (contract/library-search-2026-10-18.md). Search cases are shared with web and Android. */
final class LibrarySearchTests: XCTestCase {
    private struct Cases: Decodable {
        struct Card: Decodable { let query: String; let name: String; let type: String; let match: Bool }
        struct Printing: Decodable { let query: String; let set: String; let cn: String; let releasedAt: String; let match: Bool }
        let cards: [Card]
        let printings: [Printing]
    }

    func testSharedCases() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../testdata/library-search/cases.json").standardized
        let cases = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: url))
        for c in cases.cards {
            XCTAssertEqual(CardSearch.matches(c.query, name: c.name, type: c.type), c.match, "\(c.query) / \(c.name)")
        }
        for c in cases.printings {
            XCTAssertEqual(CardSearch.matches(c.query, set: c.set, cn: c.cn, releasedAt: c.releasedAt), c.match, "\(c.query) / \(c.set) \(c.cn)")
        }
    }

    func testRepointMovesCountAndMax() {
        let w = Want(oracleId: "o", cardId: nil, finish: nil, qty: 3, maxUsd: 5, seq: 1)
        let ops = BinderRules.repoint(w, cardId: "p", finish: "foil")!
        XCTAssertEqual(ops.count, 2)
        XCTAssertEqual(ops[0].qty, 0)
        XCTAssertNil(ops[0].cardId)
        XCTAssertEqual(ops[1].cardId, "p")
        XCTAssertEqual(ops[1].finish, "foil")
        XCTAssertEqual(ops[1].delta, 3)
        XCTAssertEqual(ops[1].maxUsd, .some(5))
        // Same place: nothing. Any printing drops the finish.
        XCTAssertNil(BinderRules.repoint(w, cardId: nil, finish: "foil"))
        let back = BinderRules.repoint(Want(oracleId: "o", cardId: "p", finish: "foil", qty: 1, maxUsd: nil, seq: 2), cardId: nil, finish: "foil")!
        XCTAssertNil(back[1].cardId)
        XCTAssertNil(back[1].finish)
    }

    func testMoveInTakesUnsortedThenNonTradeThenTrade() {
        let trade = Binder(id: "t", name: "A trade", forTrade: true, seq: 1)
        let box = Binder(id: "b", name: "Box", forTrade: false, seq: 2)
        let a = CollectionItem(cardId: "c1", finish: "nonfoil", condition: "NM", lang: "en", qty: 4, seq: 1)
        let b = CollectionItem(cardId: "c2", finish: "foil", condition: "NM", lang: "en", qty: 1, seq: 2)
        var places: [(item: CollectionItem, from: Binder?, qty: Int)] = [(a, trade, 2), (a, box, 1), (b, nil, 1)]
        XCTAssertEqual(BinderRules.moveInSource(places, into: "x")?.item.cardId, "c2")
        places.removeLast()
        XCTAssertEqual(BinderRules.moveInSource(places, into: "x")?.from, "b")
        XCTAssertEqual(BinderRules.moveInSource(places, into: "b")?.from, "t")
        XCTAssertNil(BinderRules.moveInSource([(a, box, 1)], into: "b"))
    }

    func testReplaceSwapsOneCopyForAnotherCard() {
        var entries = [CardList.Entry(cardId: "bolt", board: "main", qty: 1),
                       CardList.Entry(cardId: "chain", board: "main", qty: 2, finish: "foil")]
        ListsStore.shift(&entries, cardId: "bolt", board: "main", finish: "nonfoil", toCardId: "helix", toBoard: "main", toFinish: "nonfoil", qty: 1)
        XCTAssertEqual(entries.map(\.cardId).sorted(), ["chain", "helix"])
        ListsStore.shift(&entries, cardId: "chain", board: "main", finish: "foil", toCardId: "helix", toBoard: "main", toFinish: "nonfoil", qty: 1)
        XCTAssertEqual(entries.first { $0.cardId == "helix" }?.qty, 2)
        XCTAssertEqual(entries.first { $0.cardId == "chain" }?.qty, 1)
    }

    func testRemoveSearchOnlyOffersTheListsOwnCards() {
        let lines = [ListLine(id: "1", cardId: "a", printing: nil, oracleId: "oa", name: "Lightning Bolt", group: "Red", board: "main", qty: 1, type: "Instant"),
                     ListLine(id: "2", cardId: "b", printing: nil, oracleId: "ob", name: "Lightning Helix", group: "Multicolor", board: "maybe", qty: 1, type: "Instant"),
                     ListLine(id: "3", cardId: "c", printing: nil, oracleId: "oc", name: "Counterspell", group: "Blue", board: "main", qty: 1, type: "Instant")]
        XCTAssertEqual(ListLine.matching(lines, "light").map(\.name), ["Lightning Bolt", "Lightning Helix"])
        XCTAssertEqual(ListLine.matching(lines, "").count, 0)
        XCTAssertEqual(ListLine.matching(lines, "lightning strike").count, 0)
    }
}
