import XCTest
@testable import Table1

/* event_bundle (contract/privacy-lockdown-2026-10-18.md) decoded from testdata/event-bundle/bundle.json, which
   testdata/event-bundle/make.sh writes from the real RPC: a server shape change fails here, not in the app. */

private let bundleURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/event-bundle/bundle.json").standardized

final class EventBundleTests: XCTestCase {
    func testDecodesTheServersEventBundle() throws {
        let w = try wireDecoder.decode(Repo.BundleWire.self, from: Data(contentsOf: bundleURL))
        let b = Repo.bundle(w)
        XCTAssertTrue(b.isOrganizer)
        XCTAssertEqual(b.event.shortCode, "FIXT")
        XCTAssertEqual(b.event.status, "in_progress")
        XCTAssertEqual(b.event.currentRound, 2)
        XCTAssertEqual(b.participants.map(\.displayName), ["Ana Organizer", "Ben Player", "Guest Cara"])
        XCTAssertEqual(b.rounds.map(\.number), [1, 2])
        XCTAssertEqual(b.activeRound?.number, 2)
        let r2 = try XCTUnwrap(b.rounds.last)
        XCTAssertEqual(r2.matches.count, 2)
        // Tables first by number; the bye (no table) sorts first as 0, as the screens expect.
        XCTAssertEqual(r2.matches.map(\.isBye), [true, false])
        let played = try XCTUnwrap(b.rounds.first?.matches.first)
        XCTAssertEqual(played.matchSides.map(\.gameWins), [2, 1])
        XCTAssertEqual(played.gameDraws, 1)
        XCTAssertEqual(b.name(played.side(1)?.participantId), "Guest Cara")
    }
}
