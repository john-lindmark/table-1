import XCTest
import Supabase
@testable import Table1

/* Add a deck or cube to the collection (Library/ListToCollection.swift) against testdata/list-to-collection/cases.json. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/list-to-collection/cases.json").standardized

private struct Cases: Decodable {
    struct Entry: Decodable { let card_id, board, finish: String; let qty: Int; let lang: String?; let cond: String? }
    struct Op: Decodable { let card_id, finish: String; let delta: Int; let lang: String?; let cond: String? }
    struct Case: Decodable {
        let name, kind, mode: String
        let sideboard: Bool?
        let only: [String]?
        let entries: [Entry]
        let owned: [String: Int]
        let ops: [Op]
        let copies: Int
    }
    let cases: [Case]
}

final class ListToCollectionTests: XCTestCase {
    func testSharedCases() throws {
        let cases = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL)).cases
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let entries = c.entries.map { CardList.Entry(cardId: $0.card_id, board: $0.board, qty: $0.qty, finish: $0.finish, lang: $0.lang ?? "en", cond: $0.cond ?? "NM") }
            let ops = ListToCollection.ops(entries, kind: try XCTUnwrap(CardList.Kind(rawValue: c.kind)), owned: c.owned,
                                           mode: try XCTUnwrap(ListToCollection.Mode(rawValue: c.mode)),
                                           sideboard: c.sideboard ?? true, only: c.only.map(Set.init))
            XCTAssertEqual(ops, c.ops.map { ListToCollection.Op(cardId: $0.card_id, finish: $0.finish, delta: $0.delta, lang: $0.lang ?? "en", cond: $0.cond ?? "NM") }, c.name)
            XCTAssertEqual(ListToCollection.copies(ops), c.copies, c.name)
        }
    }

    /// Each copy goes in as the language and condition its line records; a non-English printing is always its own;
    /// never the language or condition picked for other adds.
    func testCollectionOpsKeepTheListedLanguageAndCondition() {
        let ops = ListToCollection.collectionOps([.init(cardId: "a", finish: "foil", delta: 2, cond: "LP"), .init(cardId: "a", finish: "nonfoil", delta: 1, lang: "de"),
                                                  .init(cardId: "j", finish: "nonfoil", delta: 1, cond: "DMG"), .init(cardId: "u", finish: "nonfoil", delta: 1)],
                                                 printingLang: { ["a": "en", "j": "ja"][$0] })
        XCTAssertEqual(ops.map(\.lang), ["en", "de", "ja", "en"])
        XCTAssertEqual(ops.map(\.condition), ["LP", "NM", "DMG", "NM"])
        XCTAssertEqual(ops.map(\.delta), [2, 1, 1, 1])
    }
}

/// Deck and cube lines name a language (contract/lists-2026-10-15.md, "Languages").
final class ListLanguageTests: XCTestCase {
    func testShiftMovesCopiesToAnotherLanguage() {
        var entries = [CardList.Entry(cardId: "bolt", board: "main", qty: 3), CardList.Entry(cardId: "bolt", board: "main", qty: 1, lang: "ja")]
        ListsStore.shift(&entries, cardId: "bolt", board: "main", finish: "nonfoil", lang: "en", toCardId: "bolt", toBoard: "main",
                         toFinish: "nonfoil", toLang: "ja", qty: 2)
        XCTAssertEqual(entries, [CardList.Entry(cardId: "bolt", board: "main", qty: 1), CardList.Entry(cardId: "bolt", board: "main", qty: 3, lang: "ja")])
    }

    func testDiffSeesALanguageChange() {
        let a = CardList.Version(number: 1, at: .now, note: "", entries: [CardList.Entry(cardId: "bolt", board: "main", qty: 2)])
        let b = CardList.Version(number: 2, at: .now, note: "", entries: [CardList.Entry(cardId: "bolt", board: "main", qty: 2, lang: "de")])
        let d = CardList.diff(a, b)
        XCTAssertEqual(d.map(\.lang), ["en", "de"])
        XCTAssertEqual(d.map(\.delta), [-2, 2])
    }

    func testWireWritesTheLanguageOnlyWhenNotEnglish() {
        XCTAssertEqual(ListsStore.wire(CardList.Entry(cardId: "x", board: "main", qty: 1)), .array([.string("x"), .string("main"), .integer(1)]))
        XCTAssertEqual(ListsStore.wire(CardList.Entry(cardId: "x", board: "main", qty: 1, lang: "ja")),
                       .array([.string("x"), .string("main"), .integer(1), .string("nonfoil"), .string("ja")]))
    }
}
