import XCTest
@testable import Table1

/* Basic lands are never missing (contract/basics-2026-10-24.md) against testdata/basics/cases.json, and the catalog's
   set of basic printings. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/basics/cases.json").standardized

private struct Cases: Decodable {
    struct Entry: Decodable { let card_id, board, finish: String; let qty: Int }
    struct List: Decodable { let name, kind: String; let entries: [Entry] }
    struct Line: Decodable { let card_id, finish: String; let short: Int; let lists: [String] }
    struct Op: Decodable { let card_id, finish: String; let delta: Int }
    struct Add: Decodable { let list, mode: String; let ops: [Op] }
    let basics: [String]
    let lists: [List]
    let owned: [String: Int]
    let missing: [String: Int]
    let missingWithoutBasics: [String: Int]
    let lines: [Line]
    let add: [Add]
}

final class BasicsTests: XCTestCase {
    func testSharedCases() throws {
        let c = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL))
        let basics = Set(c.basics)
        let lists = c.lists.map { l in
            CardList(id: l.name, kind: CardList.Kind(rawValue: l.kind)!, name: l.name, format: "modern",
                     versions: [CardList.Version(number: 1, at: .now, note: "", entries: l.entries.map {
                         CardList.Entry(cardId: $0.card_id, board: $0.board, qty: $0.qty, finish: $0.finish)
                     })])
        }
        for l in lists {
            XCTAssertEqual(missing(in: l, owned: c.owned, basics: basics), c.missing[l.name], l.name)
            XCTAssertEqual(missing(in: l, owned: c.owned, basics: []), c.missingWithoutBasics[l.name], l.name)
        }
        XCTAssertEqual(MissingView.lines(lists, owned: c.owned, basics: basics),
                       c.lines.map { MissingLine(cardId: $0.card_id, finish: $0.finish, short: $0.short, lists: $0.lists) })
        for a in c.add {
            let l = try XCTUnwrap(lists.first { $0.name == a.list })
            let ops = ListToCollection.ops(l.entries, kind: l.kind, owned: c.owned, mode: try XCTUnwrap(ListToCollection.Mode(rawValue: a.mode)),
                                           basics: basics)
            XCTAssertEqual(ops, a.ops.map { ListToCollection.Op(cardId: $0.card_id, finish: $0.finish, delta: $0.delta) }, "\(a.list) \(a.mode)")
        }
    }

    /// Only printings of cards with the Basic supertype are basics: not Snow lands, not lands with basic land types.
    func testCatalogBasics() throws {
        let pack = [
            "#t1catalog\t1\tv1-test\t4\t5",
            "O\t0\t11111111-1111-1111-1111-111111111111\tIsland\tisland\tBasic Land — Island\t\t0\t\t\tLLLLLLLL",
            "O\t1\t22222222-2222-2222-2222-222222222222\tSnow-Covered Forest\tsnow covered forest\tBasic Snow Land — Forest\t\t0\t\t\tLLLLLLLL",
            "O\t2\t33333333-3333-3333-3333-333333333333\tVolcanic Island\tvolcanic island\tLand — Island Mountain\t\t0\t\t\t---LL-L-",
            "O\t3\t44444444-4444-4444-4444-444444444444\tScrying Sheets\tscrying sheets\tSnow Land\t\t0\t\t\t--LLLLL-",
            "P\ta\t0\tlea\t287\ten\tc\tn\t1993-08-05\t\t1\t",
            "P\tb\t0\tdmu\t264\ten\tc\tfn\t2022-09-09\t\t1\t",
            "P\tc\t1\tkhm\t285\ten\tc\tfn\t2021-02-05\t\t1\t",
            "P\td\t2\tlea\t283\ten\tr\tn\t1993-08-05\t\t1\t",
            "P\te\t3\tcsp\t157\ten\tu\tfn\t2006-07-21\t\t1\t",
        ].joined(separator: "\n")
        let path = FileManager.default.temporaryDirectory.appending(path: "basics-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try CatalogDB.build(pack: Data(pack.utf8), at: path)
        let db = try CatalogDB(path: path, version: "v1-test")
        defer { db.close() }
        XCTAssertEqual(db.basicCardIds(), ["a", "b", "c"])
    }
}
