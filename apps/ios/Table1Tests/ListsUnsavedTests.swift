import XCTest
@testable import Table1

/// Lists the server never saved (bug 2026-10-22): an imported cube the server refused stayed on the phone as if it
/// were saved, so Rankings said "That's private" about the owner's own cube. Now a list made here is unsaved until the
/// server sends it back, an old cache gets one full pull to find such lists, and each sync sends them again.
final class ListsUnsavedTests: XCTestCase {
    func testAFullPullMarksListsTheServerDidNotSend() {
        let after = ListsStore.unsavedAfterPull([:], seen: ["deck-1", "deck-2"], local: ["deck-1", "deck-2", "cube-1"], full: true)
        XCTAssertEqual(after, ["cube-1": ""], "the cube only this phone has is sent again")
    }

    func testAPartialPullNeverGuesses() {
        // A pull from a cursor only returns what changed: a list it doesn't mention is simply unchanged.
        XCTAssertEqual(ListsStore.unsavedAfterPull([:], seen: ["deck-1"], local: ["deck-1", "cube-1"], full: false), [:])
    }

    func testAListTheServerSendsIsSaved() {
        let after = ListsStore.unsavedAfterPull(["cube-1": "That printing doesn't come in that finish", "deck-9": ""],
                                                seen: ["cube-1"], local: ["cube-1", "deck-9"], full: false)
        XCTAssertEqual(after, ["deck-9": ""])
    }

    func testAFullPullKeepsTheLastFailure() {
        let after = ListsStore.unsavedAfterPull(["cube-1": "At most 500 decks and cubes"], seen: [], local: ["cube-1"], full: true)
        XCTAssertEqual(after, ["cube-1": "At most 500 decks and cubes"])
    }

    func testAnOldCacheIsAuditedOnce() throws {
        let old = try XCTUnwrap(#"{"cursor":12,"lists":[]}"#.data(using: .utf8))
        let o = ListsStore.decodeCache(old)
        XCTAssertFalse(o.audited, "written before unsaved lists were kept")
        XCTAssertEqual(o.cursor, 12)

        let new = try XCTUnwrap(#"{"cursor":12,"lists":[],"unsaved":{"cube-1":""}}"#.data(using: .utf8))
        let n = ListsStore.decodeCache(new)
        XCTAssertTrue(n.audited)
        XCTAssertEqual(n.unsaved, ["cube-1": ""])

        XCTAssertFalse(ListsStore.decodeCache(Data("nonsense".utf8)).audited)
    }

    func testTheNoticeSaysWhy() {
        let cube = CardList(id: "cube-1", kind: .cube, name: "Vintage", format: "vintage",
                            versions: [.init(number: 1, at: .now, note: "Created", entries: [])])
        XCTAssertEqual(ListsStore.unsavedNotice(cube, ""), "Saving this cube to your account…")
        XCTAssertEqual(ListsStore.unsavedNotice(cube, "Unknown card: x"),
                       "This cube isn't saved to your account yet: Unknown card: x It's sent again each time Table 1 syncs.")
    }
}
