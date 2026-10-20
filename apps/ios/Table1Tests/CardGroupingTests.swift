import XCTest
@testable import Table1

/* Group by (Library/CardGrouping.swift) against the shared cases in testdata/card-grouping/cases.json. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/card-grouping/cases.json").standardized

private struct Cases: Decodable {
    struct Card: Decodable { let name, typeLine, manaCost, colors: String; let cmc: Double; let type, color, manaValue: String }
    let cards: [Card]
    let order: [String: [String]]
}

final class CardGroupingTests: XCTestCase {
    func testSharedCases() throws {
        let cases = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL))
        for c in cases.cards {
            let k = GroupKeys(typeLine: c.typeLine, manaCost: c.manaCost, colors: c.colors, cmc: c.cmc)
            XCTAssertEqual(k[.type], c.type, c.name)
            XCTAssertEqual(k[.color], c.color, c.name)
            XCTAssertEqual(k[.manaValue], c.manaValue, c.name)
        }
        for g in [CardGrouping.type, .color, .manaValue] {
            let order = try XCTUnwrap(cases.order[g.rawValue])
            XCTAssertEqual(g.order, order, g.rawValue)
            XCTAssertEqual(g.sorted(order.reversed()), order, g.rawValue)
        }
    }

    func testLabelsAndOptions() {
        XCTAssertEqual(CardGrouping.manaValue.label("3"), "Mana value 3")
        XCTAssertEqual(CardGrouping.manaValue.label("Lands"), "Lands")
        XCTAssertEqual(CardGrouping.type.label("Creatures"), "Creatures")
        XCTAssertEqual(CardGrouping.options(list: true), [.type, .color, .manaValue])
        XCTAssertEqual(CardGrouping.options(list: false), [.none, .type, .color, .manaValue])
    }
}
