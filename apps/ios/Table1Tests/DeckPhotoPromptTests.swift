import XCTest
@testable import Table1

/* Add a deck photo once your last match is in (contract/event-night-2026-10-16.md § 7) against
   testdata/deck-photos/prompt.json from make_prompt.py (also web deckPhotos.test.ts and Android DeckPhotosTest). */

private let promptURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/deck-photos/prompt.json").standardized

private struct PromptCases: Decodable {
    struct Event: Decodable { let status: String; let rounds: Int; var top_cut: Int? }
    struct Me: Decodable { let status: String; let dropped_in_round: Int? }
    struct Case: Decodable {
        let name: String
        let event: Event
        let me: Me?
        let rounds: [DeckPhotoPrompt.Played]
        let photo: Bool
        let why: String?
        let show: String?
    }
    let cases: [Case]
}

final class DeckPhotoPromptTests: XCTestCase {
    func testSharedCases() throws {
        let cases = try JSONDecoder().decode(PromptCases.self, from: Data(contentsOf: promptURL)).cases
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let why = DeckPhotoPrompt.done(status: c.event.status, rounds: c.event.rounds, topCut: c.event.top_cut ?? 0,
                                           isPlayer: c.me != nil, meStatus: c.me?.status,
                                           droppedInRound: c.me?.dropped_in_round, played: c.rounds)
            XCTAssertEqual(why, c.why, c.name)
            XCTAssertEqual(DeckPhotoPrompt.show(why, photos: c.photo ? 1 : 0), c.show, c.name)
        }
    }

    func testLabels() {
        XCTAssertEqual(DeckPhotoPrompt.label("last"), "Last match in")
        XCTAssertEqual(DeckPhotoPrompt.label("dropped"), "Dropped")
        XCTAssertEqual(DeckPhotoPrompt.label("over"), "Event over")
    }
}
