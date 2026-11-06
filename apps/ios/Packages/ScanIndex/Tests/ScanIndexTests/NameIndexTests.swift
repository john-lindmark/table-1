import XCTest
import ScanIndex

/// The index's own rules; the scanner's accuracy is Table1Tests/CardMatcherTests. `swift test` in Packages/ScanIndex.
final class NameIndexTests: XCTestCase {
    private func index() -> NameIndex {
        NameIndex(
            english: [("lightning bolt", 1, 40), ("counterspell", 2, 60), ("lightning bolt", 3, 2), ("fire", 4, 5), ("fire", 5, 9)],
            foreign: [("blitzschlag", 1, 1), ("contresort", 2, 4), ("fulmine", 1, 8), ("fulmine", 1, 16),
                      ("gemeinsam", 6, 1), ("gemeinsam", 7, 2), ("counterspell", 8, 1)])
    }

    func testMerge() {
        let x = index()
        // Most printings wins a shared English name; a foreign name never replaces an English one.
        XCTAssertEqual(x.position("lightning bolt").map { x.idxs[$0] }, 1)
        XCTAssertEqual(x.position("fire").map { x.idxs[$0] }, 5)
        XCTAssertEqual(x.position("counterspell").map { x.idxs[$0] }, 2)
        XCTAssertEqual(x.position("counterspell").map { x.langBits[$0] }, 0)
        // One card's languages merge; a printed name two cards share is left out.
        XCTAssertEqual(x.position("fulmine").map { x.langBits[$0] }, 24)
        XCTAssertNil(x.position("gemeinsam"))
        XCTAssertEqual(x.keys, x.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
    }

    func testLookups() {
        let x = index()
        XCTAssertEqual(x.keys[x.lowerBound("light")], "lightning bolt")
        let tg = NameIndex.trigrams("lightnin bolt")
        let top = x.sharing(tg, Int((Double(tg.count) * 0.4).rounded(.up)))
        XCTAssertEqual(top.first.map { x.keys[$0] }, "lightning bolt")
        let a = "lightnin bolt".utf8.map { UInt32($0) }, b = "lightning bolt".utf8.map { UInt32($0) }
        XCTAssertEqual(NameIndex.distance(a, b, cap: 2), 1)
        XCTAssertEqual(NameIndex.distance(a, "fire".utf8.map { UInt32($0) }, cap: 2), 3)
    }
}
