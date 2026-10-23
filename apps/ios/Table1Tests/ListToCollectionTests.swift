import XCTest
@testable import Table1

/* Add a deck or cube to the collection (Library/ListToCollection.swift) against testdata/list-to-collection/cases.json. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/list-to-collection/cases.json").standardized

private struct Cases: Decodable {
    struct Entry: Decodable { let card_id, board, finish: String; let qty: Int }
    struct Op: Decodable { let card_id, finish: String; let delta: Int }
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
            let entries = c.entries.map { CardList.Entry(cardId: $0.card_id, board: $0.board, qty: $0.qty, finish: $0.finish) }
            let ops = ListToCollection.ops(entries, kind: try XCTUnwrap(CardList.Kind(rawValue: c.kind)), owned: c.owned,
                                           mode: try XCTUnwrap(ListToCollection.Mode(rawValue: c.mode)),
                                           sideboard: c.sideboard ?? true, only: c.only.map(Set.init))
            XCTAssertEqual(ops, c.ops.map { ListToCollection.Op(cardId: $0.card_id, finish: $0.finish, delta: $0.delta) }, c.name)
            XCTAssertEqual(ListToCollection.copies(ops), c.copies, c.name)
        }
    }
}
