import XCTest
@testable import Table1

/* Advanced search and the Library polish rules (contract/library-polish-2026-10-19.md). Queries and form fields come
   from testdata/card-query/cases.json, shared with web and Android. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/card-query/cases.json").standardized

private struct Cases: Decodable {
    struct Printing: Decodable { let set, cn, rarity, released, lang, finishes: String }
    struct Card: Decodable {
        let name, type, cost: String
        let cmc: Double
        let colors, legal, produced: String
        let printings: [Printing]
    }
    struct Query: Decodable { let q: String; let syntax: Bool; let local: Bool?; let names: [String]? }
    struct Advanced: Decodable { let fields: [String: String]; let query: String }
    let cards: [Card]
    let queries: [Query]
    let advanced: [Advanced]
}

final class CardQueryTests: XCTestCase {
    private func load() throws -> Cases { try JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL)) }

    private func catalog(_ c: Cases) -> [(CatalogOracle, [CatalogPrinting])] {
        c.cards.enumerated().map { i, card in
            let o = CatalogOracle(idx: i, oracleId: "o\(i)", name: card.name, norm: CardName.norm(card.name), typeLine: card.type,
                                  manaCost: card.cost, printings: card.printings.count, legal: card.legal, cmc: card.cmc,
                                  colors: card.colors, produced: card.produced)
            let ps = card.printings.enumerated().map { j, p in
                CatalogPrinting(cardId: "p\(i)-\(j)", oracleIdx: i, ord: j, set: p.set, cn: p.cn, lang: p.lang, rarity: p.rarity,
                                finishes: p.finishes, releasedAt: p.released, imageTs: "", imageFaces: 1, printedName: "")
            }
            return (o, ps)
        }
    }

    func testQueries() throws {
        let c = try load()
        let cards = catalog(c)
        for q in c.queries {
            XCTAssertEqual(CardQuery.hasSyntax(q.q), q.syntax, "syntax: \(q.q)")
            guard q.syntax, let local = q.local else { continue }
            let node = CardQuery.parse(q.q)
            XCTAssertEqual(node.map(CardQuery.isLocal) ?? false, local, "local: \(q.q)")
            guard local, let node, let want = q.names else { continue }
            let got = cards.filter { o, ps in
                CardQuery.usesPrinting(node) ? ps.contains { CardQuery.matches(node, o, $0) } : CardQuery.matches(node, o, nil)
            }.map(\.0.name).sorted()
            XCTAssertEqual(got, want.sorted(), q.q)
        }
    }

    func testAdvancedFields() throws {
        for a in try load().advanced {
            var f = AdvancedSearchFields()
            f.name = a.fields["name"] ?? ""
            f.text = a.fields["text"] ?? ""
            f.type = a.fields["type"] ?? ""
            f.colors = Set(a.fields["colors"] ?? "")
            f.colorMode = AdvancedSearchFields.ColorMode(rawValue: a.fields["colorMode"] ?? "") ?? .including
            f.mvOp = a.fields["mvOp"] ?? "="
            f.mv = a.fields["mv"] ?? ""
            f.rarities = Set(a.fields["rarities"] ?? "")
            f.set = a.fields["set"] ?? ""
            f.format = a.fields["format"] ?? ""
            XCTAssertEqual(f.query, a.query, "\(a.fields)")
            // What the form writes always runs locally unless it searches card text.
            if f.text.isEmpty { XCTAssertEqual(CardQuery.parse(f.query).map(CardQuery.isLocal), true, f.query) }
        }
    }

    func testOldestPrintingFirst() {
        func p(_ id: String, _ released: String, ord: Int) -> CatalogPrinting {
            CatalogPrinting(cardId: id, oracleIdx: 0, ord: ord, set: "x", cn: "1", lang: "en", rarity: "c", finishes: "n",
                            releasedAt: released, imageTs: "", imageFaces: 1, printedName: "")
        }
        // Pack order is newest first; same-day printings keep the older pack position first.
        let sorted = [p("new", "2024-01-01", ord: 0), p("old", "1993-08-05", ord: 3), p("mid-b", "2010-07-16", ord: 1), p("mid-a", "2010-07-16", ord: 2)]
            .sorted(by: CatalogPrinting.oldestFirst).map(\.cardId)
        XCTAssertEqual(sorted, ["old", "mid-a", "mid-b", "new"])
    }

    func testPrintingsDisclosure() {
        var d = PrintingsDisclosure()
        XCTAssertFalse(d.open("a"), "collapsed by default")
        d.toggle("a")
        XCTAssertTrue(d.open("a"))
        d.setAll(true)
        XCTAssertTrue(d.open("a") && d.open("b"))
        d.toggle("b")
        XCTAssertFalse(d.open("b"), "a card can close while every other one is open")
        d.setAll(false)
        XCTAssertFalse(d.open("a") || d.open("b"))
    }

    func testLineGroupsOneRowPerCardAndSection() {
        func line(_ card: String, _ oracle: String, _ board: String, _ qty: Int, _ finish: String = "nonfoil") -> ListLine {
            ListLine(id: "\(board)|\(card)|\(finish)", cardId: card, printing: nil, oracleId: oracle, name: oracle, group: "g",
                     board: board, qty: qty, finish: finish)
        }
        let groups = LineGroup.of([line("b1", "Bolt", "main", 1), line("b2", "Bolt", "main", 3), line("b1", "Bolt", "main", 1, "foil"),
                                   line("b1", "Bolt", "side", 2), line("o1", "Opt", "main", 4)])
        XCTAssertEqual(groups.map(\.id), ["main|Bolt", "side|Bolt", "main|Opt"])
        XCTAssertEqual(groups[0].qty, 5)
        XCTAssertEqual(groups[0].lead.cardId, "b2", "the line with the most copies leads")
        XCTAssertEqual(groups[0].lines.count, 3)
    }

    func testHeroScopes() {
        XCTAssertEqual(HeroScope(nil), .collection)
        XCTAssertEqual(HeroScope(.list("l1")), .list("l1"))
        XCTAssertEqual(HeroScope(.binder("b1")), .binder("b1"))
        XCTAssertNil(HeroScope(.binder(BinderRoute.unsorted)), "Unsorted has no heroes")
        XCTAssertEqual(HeroScope.list("l1").key, "list:l1")
    }
}
