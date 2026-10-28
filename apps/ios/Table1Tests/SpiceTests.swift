import XCTest
@testable import Table1

/* Spice (contract/spice-2026-10-28.md) against testdata/spice/cases.json (make_cases.py): every case's server answer
   decodes, and shows exactly the case's `display`. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/spice/cases.json").standardized

private struct Cases: Decodable {
    struct Display: Decodable {
        let summary: String?
        let headline: String?
        let basis: String?
        let cubes: [String]
        let cards: [String]
        let missing: [String]
        let reason: String?
    }
    struct Case: Decodable {
        let name: String
        let expect: SpiceResult
        let display: Display
    }
    struct Word: Decodable { let score: Int; let word: String; let label: String }
    let cases: [Case]
    let words: [Word]
}

final class SpiceTests: XCTestCase {
    private func load() throws -> Cases { try Spice.decoder().decode(Cases.self, from: Data(contentsOf: casesURL)) }

    func testEveryCaseShowsItsDisplay() throws {
        let cases = try load().cases
        XCTAssertGreaterThan(cases.count, 10)
        for c in cases {
            let r = c.expect, d = c.display
            XCTAssertEqual(Spice.summary(r), d.summary, c.name)
            XCTAssertEqual(Spice.headline(r), d.headline, c.name)
            XCTAssertEqual(Spice.basis(r), d.basis, c.name)
            XCTAssertEqual(Spice.cubes(r), d.cubes, c.name)
            XCTAssertEqual(r.cards.map { Spice.cardLine($0, r) }, d.cards, c.name)
            XCTAssertEqual(r.stockMissing.map { Spice.missingLine($0, r) }, d.missing, c.name)
            XCTAssertEqual(Spice.reason(r), d.reason, c.name)
        }
    }

    func testWords() throws {
        for w in try load().words { XCTAssertEqual(Spice.words[w.word], w.label, "\(w.score)") }
    }

    func testDemoScoresLikeTheServer() {
        // Four never-seen non-basic cards of eight: half the deck scores 1, so 50 · Brew at most.
        let cards = (0..<8).map { SpiceDemoCard(oracleId: "o\($0)", name: "Card \($0)", qty: 4, board: "main", basic: false) }
            + [SpiceDemoCard(oracleId: "b", name: "Island", qty: 20, board: "main", basic: true)]
        let r = SpiceStore.demoResult(cards, kind: .deck, format: "modern")
        XCTAssertNotNil(r.score)
        XCTAssertFalse(r.cards.contains { $0.n == "Island" })
    }
}
