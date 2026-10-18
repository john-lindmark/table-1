import XCTest
@testable import Table1

/* Deck and cube export (contract/lists-2026-10-15.md, Export). Same cases as table-1-events-web/src/lib/listExport.test.ts
   and Android's ListExportTest. testdata/list-export/lists.json is a deck and a cube of real printings from the test
   pack; each format must come out as the file next to it byte for byte. list-import's parser reads those files as
   parsed.json (supabase/functions/list-import/parse.test.ts), and here those lines resolve back to the same entries:
   export → paste → import gives the list back. */

private let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/list-export").standardized

private struct Fixture: Decodable {
    struct Card: Decodable {
        let name: String, type_line: String, cmc: Double, colors: String, set: String, cn: String, rarity: String
    }
    struct List: Decodable {
        let name: String
        let entries: [[Entry]]
    }
    /// One element of `[card_id, board, qty, finish?]`.
    enum Entry: Decodable {
        case text(String), number(Int)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Int.self) { self = .number(n) } else { self = .text(try c.decode(String.self)) }
        }
        var text: String { if case .text(let s) = self { s } else { "" } }
        var number: Int { if case .number(let n) = self { n } else { 0 } }
    }
    let cards: [String: Card]
    let deck: List
    let cube: List

    static func load() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: dir.appending(path: "lists.json")))
    }
    func entries(_ l: List) -> [CardList.Entry] {
        l.entries.map { .init(cardId: $0[0].text, board: $0[1].text, qty: $0[2].number, finish: $0.count > 3 ? $0[3].text : "nonfoil") }
    }
    func lines(_ l: List) -> [ListExport.Line] {
        entries(l).map { e in
            let c = cards[e.cardId]!
            return .init(card: .init(name: c.name, typeLine: c.type_line, cmc: c.cmc, colors: c.colors, set: c.set, cn: c.cn, rarity: c.rarity),
                         board: e.board, qty: e.qty, finish: e.finish)
        }
    }
}

private func file(_ name: String) throws -> String { try String(contentsOf: dir.appending(path: name), encoding: .utf8) }

final class ListExportTests: XCTestCase {
    func testEachFormatMatchesTheFixture() throws {
        let f = try Fixture.load()
        let cases: [(CardList.Kind, Fixture.List, ListExport.Format, String)] = [
            (.deck, f.deck, .arena, "deck.arena.txt"), (.deck, f.deck, .moxfield, "deck.moxfield.txt"),
            (.deck, f.deck, .mtgo, "deck.mtgo.txt"), (.deck, f.deck, .text, "deck.text.txt"),
            (.cube, f.cube, .cubecobra, "cube.cubecobra.csv"), (.cube, f.cube, .text, "cube.text.txt"),
        ]
        for (kind, list, format, name) in cases {
            // Input order mustn't matter.
            let out = ListExport.render(f.lines(list).reversed(), kind: kind, format: format)
            XCTAssertEqual(out, try file(name), name)
        }
    }

    func testNames() {
        func card(_ name: String, _ type: String) -> ListExport.Card { .init(name: name, typeLine: type, cmc: 0, colors: "", set: "", cn: "", rarity: "") }
        XCTAssertEqual(ListExport.name(card("Fire // Ice", "Instant // Instant")), "Fire // Ice")
        XCTAssertEqual(ListExport.name(card("Alive // Well", "Enchantment — Room // Enchantment — Room")), "Alive // Well")
        XCTAssertEqual(ListExport.name(card("There // They're // Their", "Instant — Lesson // Instant — Lesson // Instant — Lesson")), "There // They're // Their")
        XCTAssertEqual(ListExport.name(card("Bonecrusher Giant // Stomp", "Creature — Giant // Instant — Adventure")), "Bonecrusher Giant")
        XCTAssertEqual(ListExport.name(card("Petty Theft Test // Theft", "Instant // Instant — Adventure")), "Petty Theft Test")
        XCTAssertEqual(ListExport.name(card("Agadeem's Awakening // Agadeem, the Undercrypt", "Sorcery // Land")), "Agadeem's Awakening")
        XCTAssertNil(ListExport.printing(.init(name: "Jaya", typeLine: "", cmc: 0, colors: "", set: "pmps08", cn: "a1 2007", rarity: "")))
        XCTAssertEqual(ListExport.printing(.init(name: "Jaya", typeLine: "", cmc: 0, colors: "", set: "pmps08", cn: "a1_2007", rarity: "")), "(PMPS08) a1_2007")
    }

    func testEmptyAndFileNames() {
        XCTAssertEqual(ListExport.render([], kind: .deck, format: .arena), "")
        XCTAssertEqual(ListExport.render([], kind: .cube, format: .cubecobra), ListExport.cubeCobraHeader + "\r\n")
        XCTAssertEqual(ListExport.fileName("Izzet: \"Tempo\" / test", kind: .deck, format: .mtgo), "Izzet Tempo test.txt")
        XCTAssertEqual(ListExport.fileName("///", kind: .cube, format: .cubecobra), "cube.csv")
    }

    /// The catalog gives each entry the card the fixture says (the test pack trims cmc and colors).
    func testLinesFromTheCatalog() throws {
        let f = try Fixture.load()
        let gone = CardList.Entry(cardId: "not-a-card", board: "main", qty: 3)
        let r = ListExport.lines(f.entries(f.deck) + [gone], TestCatalog.db)
        XCTAssertEqual(r.left, 3)
        XCTAssertEqual(r.lines.map { [$0.card.name, $0.card.typeLine, $0.card.set, $0.card.cn, $0.card.rarity] },
                       f.lines(f.deck).map { [$0.card.name, $0.card.typeLine, $0.card.set, $0.card.cn, $0.card.rarity] })
    }

    /// What the server's parser reads from each file resolves back to the list.
    func testRoundTrip() throws {
        let f = try Fixture.load()
        let parsed = try JSONDecoder().decode([String: [ImportedList.Line]].self, from: Data(contentsOf: dir.appending(path: "parsed.json")))
        func resolve(_ name: String, _ kind: CardList.Kind) -> (entries: Set<CardList.Entry>, missing: [String]) {
            let r = ListImportView.resolve(parsed[name]!, kind: kind, TestCatalog.db)
            return (Set(r.entries), r.missing)
        }
        let deck = Set(f.entries(f.deck)), cube = Set(f.entries(f.cube))
        // Moxfield and Cube Cobra carry everything: the same printings, finishes, sections and counts.
        XCTAssertEqual(resolve("deck.moxfield.txt", .deck).entries, deck)
        XCTAssertEqual(resolve("cube.cubecobra.csv", .cube).entries, cube)
        // Arena: the same printings and sections, non-foil, without Considering.
        var arena: [String: Int] = [:]
        for e in deck where e.board != "maybe" { arena["\(e.cardId)|\(e.board)", default: 0] += e.qty }
        XCTAssertEqual(resolve("deck.arena.txt", .deck).entries,
                       Set(arena.map { k, q in CardList.Entry(cardId: String(k.split(separator: "|")[0]), board: String(k.split(separator: "|")[1]), qty: q) }))
        // Names only: every card is found, with the same counts per section.
        for (name, kind, list) in [("deck.text.txt", CardList.Kind.deck, f.entries(f.deck)), ("cube.text.txt", .cube, f.entries(f.cube)),
                                   ("deck.mtgo.txt", .deck, f.entries(f.deck).filter { $0.board != "maybe" })] {
            let r = resolve(name, kind)
            XCTAssertEqual(r.missing, [], name)
            func counts(_ es: some Sequence<CardList.Entry>) -> [String: Int] {
                es.reduce(into: [:]) { $0[name == "deck.mtgo.txt" && $1.board == "commander" ? "side" : $1.board, default: 0] += $1.qty }
            }
            XCTAssertEqual(counts(r.entries), counts(list), name)
        }
    }
}
