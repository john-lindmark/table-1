import XCTest
@testable import Table1

/* Scanned cards took a round trip to show in the collection and binders: added copies now show before the server
   answers and are taken back if the call fails. Shared cases testdata/show-adds/cases.json (also web
   showAdds.test.ts and Android ShowAddsTest.kt). */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/show-adds/cases.json").standardized

private struct Cases: Decodable {
    struct Op: Decodable {
        let card_id: String
        var finish: String?
        var condition: String?
        var lang: String?
        var delta: Int?
        var qty: Int?
        var binder_id: String?
        var op: CollectionOp {
            CollectionOp(cardId: card_id, finish: finish ?? "nonfoil", condition: condition ?? "NM", lang: lang ?? "en",
                         delta: delta, qty: qty, binderId: binder_id)
        }
    }
    struct State: Decodable { let items: [String: Int]; let allocs: [String: Int] }
    struct Case: Decodable { let name: String; let items: [String: Int]; let allocs: [String: Int]; let ops: [Op]; let shown: State }
    let cases: [Case]
}

final class ShowAddsTests: XCTestCase {
    func testSharedCases() throws {
        let c = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL))
        XCTAssertFalse(c.cases.isEmpty)
        for k in c.cases {
            var items = Dictionary(uniqueKeysWithValues: k.items.map { key, qty in
                let p = key.split(separator: "|").map(String.init)
                return (key, CollectionItem(cardId: p[0], finish: p[1], condition: p[2], lang: p[3], qty: qty, seq: 7))
            })
            var allocs = Dictionary(uniqueKeysWithValues: k.allocs.map { key, qty in
                let p = key.split(separator: "|").map(String.init)
                return (key, BinderAlloc(binderId: p[0], cardId: p[1], finish: p[2], condition: p[3], lang: p[4], qty: qty, seq: 3))
            })
            let ops = k.ops.map(\.op)

            BindersStore.shift(&allocs, CollectionStore.shiftAdds(&items, ops, by: 1))
            XCTAssertEqual(items.mapValues(\.qty), k.shown.items, k.name)
            XCTAssertEqual(allocs.mapValues(\.qty), k.shown.allocs, k.name)
            // A held item keeps its seq, so the sync row that follows is never skipped as older.
            for key in k.items.keys { XCTAssertEqual(items[key]?.seq, 7, k.name) }

            BindersStore.shift(&allocs, CollectionStore.shiftAdds(&items, ops, by: -1))
            XCTAssertEqual(items.mapValues(\.qty), k.items, "\(k.name): taken back")
            XCTAssertEqual(allocs.mapValues(\.qty), k.allocs, "\(k.name): taken back")
        }
    }
}
