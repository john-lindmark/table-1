import XCTest
@testable import Table1

/* Sort (Library/CardSort.swift) against the shared cases in testdata/card-sort/cases.json. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/card-sort/cases.json").standardized

private struct Cases: Decodable {
    struct Card: Decodable { let name: String; let cmc: Double; let land: Bool; let released, set, cn: String }
    let cards: [Card]
    let order: [String: [String]]
    let options: [String: [String]]
    let defaults: [String: String]
}

final class CardSortTests: XCTestCase {
    private func cases() throws -> Cases { try JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL)) }

    func testSharedOrders() throws {
        let cases = try cases()
        for s in [CardSort.name, .manaValue, .set] {
            let order = try XCTUnwrap(cases.order[s.rawValue])
            let got = s.apply(cases.cards) { SortKey(name: $0.name, cmc: $0.cmc, land: $0.land, released: $0.released, set: $0.set, cn: $0.cn) }
            XCTAssertEqual(got.map(\.name), order, s.rawValue)
        }
    }

    func testOptionsAndDefaults() throws {
        let cases = try cases()
        let screens: [(String, CardSort.Screen)] = [("deck", .list), ("cube", .list), ("shared", .shared), ("binder", .binder), ("allCards", .allCards)]
        for (name, s) in screens {
            XCTAssertEqual(CardSort.options(s).map(\.rawValue), cases.options[name], name)
            XCTAssertEqual(CardSort.of("", s).rawValue, cases.defaults[name], name)
        }
        // A sort another screen offers falls back to this screen's own.
        XCTAssertEqual(CardSort.of("recent", .list), .name)
        XCTAssertEqual(CardSort.of("set", .binder), .set)
    }

    func testOwnOrdersLeaveItemsAlone() {
        let items = ["b", "a", "c"]
        XCTAssertEqual(CardSort.count.apply(items) { SortKey(name: $0) }, items)
        XCTAssertEqual(CardSort.name.apply(items) { SortKey(name: $0) }, ["a", "b", "c"])
    }

    func testGroupKeysCarryManaValue() {
        let k = GroupKeys(typeLine: "Legendary Creature — Eldrazi", manaCost: "{15}", colors: "", cmc: 15)
        XCTAssertEqual(SortKey(name: "Emrakul", keys: k, printing: nil).cmc, 15)
        XCTAssertTrue(SortKey(name: "Forest", keys: GroupKeys(typeLine: "Basic Land — Forest", manaCost: "", colors: "", cmc: 0), printing: nil).land)
    }
}
