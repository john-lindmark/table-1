import XCTest
@testable import Table1

/* Deck photo size and Rotate left / right (contract/event-night-2026-10-16.md § 7) against
   testdata/deck-photos/cases.json (also web deckPhotos.test.ts and Android DeckPhotosTest). */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/deck-photos/cases.json").standardized

private struct Cases: Decodable {
    struct Turn: Decodable { let turns, by, out: Int }
    struct Size: Decodable { let width, height: Double; let turns: Int; let out: [Double] }
    let turn: [Turn]
    let size: [Size]
}

final class DeckPhotoTests: XCTestCase {
    private func cases() throws -> Cases { try JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL)) }

    func testTurns() throws {
        for c in try cases().turn {
            XCTAssertEqual(DeckPhotoTurns.turn(c.turns, by: c.by), c.out, "\(c.turns) by \(c.by)")
        }
    }

    func testSizes() throws {
        for c in try cases().size {
            let out = DeckPhotoTurns.size(width: c.width, height: c.height, turns: c.turns)
            XCTAssertEqual([out.width, out.height], c.out, "\(c.width)x\(c.height) turned \(c.turns)")
        }
    }
}
