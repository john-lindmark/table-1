import XCTest
@testable import Table1

/* Changing a card's language (contract/card-language-2026-10-19.md): copies move to the new language in the places
   they're in, Unsorted first unless a place is chosen. */

final class LanguageTests: XCTestCase {
    private let item = CollectionItem(cardId: "c1", finish: "foil", condition: "LP", lang: "en", qty: 5, seq: 1)
    private let places: [(place: String, qty: Int)] = [(place: "b-trade", qty: 2), (place: "b-box", qty: 1), (place: BinderRoute.unsorted, qty: 2)]

    private func summary(_ ops: [CollectionOp]?) -> [String] {
        (ops ?? []).map { "\($0.lang) \($0.delta ?? 0) \($0.binderId ?? "unsorted") \($0.finish) \($0.condition)" }
    }

    func testUnsortedFirstThenBindersInOrder() {
        XCTAssertEqual(summary(LanguageChange.ops(item, places: places, to: "ja", qty: 3)), [
            "en -2 unsorted foil LP", "ja 2 unsorted foil LP",
            "en -1 b-trade foil LP", "ja 1 b-trade foil LP",
        ])
    }

    func testAllCopiesKeepTheirPlaces() {
        let ops = LanguageChange.ops(item, places: places, to: "de", qty: 5) ?? []
        XCTAssertEqual(ops.compactMap(\.delta).reduce(0, +), 0)
        XCTAssertEqual(Set(ops.filter { $0.lang == "de" }.map { "\($0.binderId ?? "unsorted") \($0.delta ?? 0)" }),
                       ["b-trade 2", "b-box 1", "unsorted 2"])
    }

    func testFromOnePlace() {
        XCTAssertEqual(summary(LanguageChange.ops(item, places: places, to: "fr", qty: 1, from: "b-box")),
                       ["en -1 b-box foil LP", "fr 1 b-box foil LP"])
        XCTAssertNil(LanguageChange.ops(item, places: places, to: "fr", qty: 2, from: "b-box"), "the place holds only 1")
    }

    func testNothingToChange() {
        XCTAssertNil(LanguageChange.ops(item, places: places, to: "en", qty: 1))
        XCTAssertNil(LanguageChange.ops(item, places: places, to: "ja", qty: 0))
        XCTAssertNil(LanguageChange.ops(item, places: places, to: "ja", qty: 6))
    }

    func testNewCopiesFollowTheirPrinting() {
        func p(_ lang: String) -> CatalogPrinting {
            CatalogPrinting(cardId: "p", oracleIdx: 0, ord: 0, set: "dom", cn: "1", lang: lang, rarity: "c", finishes: "n",
                            releasedAt: "", imageTs: "", imageFaces: 1, printedName: "")
        }
        XCTAssertEqual(Languages.forNew(p("ja"), picked: "de"), "ja")
        XCTAssertEqual(Languages.forNew(p("en"), picked: "de"), "de")
    }

    func testEveryCodeFitsTheServer() {
        // collection_items.lang: ^[a-z]{2,3}$
        for l in Languages.all { XCTAssertNotNil(l.code.range(of: "^[a-z]{2,3}$", options: .regularExpression), l.code) }
        XCTAssertEqual(Languages.name("zhs"), "Chinese Simplified")
    }
}
