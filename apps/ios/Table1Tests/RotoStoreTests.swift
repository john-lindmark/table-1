import XCTest
@testable import Table1

/// RotoStore against the Debug demo draft (RotoDemoBackend): 8 players, 114 picks made, seat 3 (you) on the clock.
/// Covers the optimistic pick, deltas from realtime, the debounced list and undo without a server.
@MainActor
final class RotoStoreTests: XCTestCase {
    private func loaded() async -> RotoStore {
        let store = RotoStore(eventId: RotoDemoBackend.eventId, backend: RotoDemoBackend())
        await store.load()
        return store
    }

    private func firstFree(_ store: RotoStore) -> Int {
        store.poolOrder.first { store.takenBy(slot: $0) == nil && store.inList($0) == nil }!
    }

    func testLoadsTheDraft() async {
        let store = await loaded()
        XCTAssertEqual(store.pool.count, 360)
        XCTAssertEqual(store.picksMade, 114)
        XCTAssertEqual(store.phase, .drafting)
        XCTAssertTrue(store.isMyTurn)
        XCTAssertEqual(store.picksUntilMine, 0)
        XCTAssertEqual(store.picks(seat: 3).count, 14)
    }

    func testPickIsAcceptedAndLandsInYourColumn() async {
        let store = await loaded()
        let slot = firstFree(store)
        let ok = await store.pick(slot: slot, from: .cube)
        XCTAssertTrue(ok)
        XCTAssertNil(store.pending)
        XCTAssertEqual(store.takenBy(slot: slot)?.seat, 3)
        XCTAssertEqual(store.takenBy(slot: slot)?.pickNo, 115)
        XCTAssertFalse(store.isMyTurn)
        // Seat 3 next picks at 126 (round 16 runs 8 → 1): ten picks away.
        XCTAssertEqual(store.picksUntilMine, 10)
        // Someone else's turn: only an organizer can pick now (Pick for); the server records it as theirs.
        let other = firstFree(store)
        let forThem = await store.pick(slot: other, from: .cube)
        XCTAssertTrue(forThem)
        XCTAssertEqual(store.takenBy(slot: other)?.how, "organizer")
        XCTAssertEqual(store.takenBy(slot: other)?.seat, 4)
    }

    func testOthersPicksArriveByDelta() async throws {
        let store = await loaded()
        let listening = Task { await store.listen() }
        defer { listening.cancel() }
        _ = await store.pick(slot: firstFree(store), from: .grid)
        try await Task.sleep(for: .milliseconds(1700))
        XCTAssertGreaterThanOrEqual(store.picksMade, 116)
        XCTAssertEqual(store.picks.map(\.pickNo), Array(1...store.picks.count))
        XCTAssertEqual(Set(store.picks.map(\.slot)).count, store.picks.count)
    }

    func testListSavesAfterAPauseAndAutoPicks() async throws {
        let store = await loaded()
        // Your turn and auto-pick on: the list is sent ~600 ms after the last change and the server picks its top card.
        let slot = firstFree(store)
        store.removeFromList(store.queue.first ?? -1)
        store.addToList(slot)
        store.moveInList(from: IndexSet(integer: store.queue.count - 1), to: 0)
        XCTAssertEqual(store.queue.first, slot)
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertEqual(store.takenBy(slot: slot)?.seat, 3)
        XCTAssertEqual(store.takenBy(slot: slot)?.how, "auto")
        XCTAssertFalse(store.queue.contains(slot))
    }

    func testUndoTakesBackThePick() async {
        let store = await loaded()
        let slot = firstFree(store)
        _ = await store.pick(slot: slot, from: .cube)
        await store.undo()
        XCTAssertNil(store.takenBy(slot: slot))
        XCTAssertEqual(store.picksMade, 114)
        XCTAssertTrue(store.isMyTurn)
    }

    func testClockPauseAndClear() async {
        let store = await loaded()
        XCTAssertNotNil(store.secondsLeft(at: .now))
        _ = await store.setClock(nil, paused: true)
        XCTAssertTrue(store.draft.clockPaused)
        _ = await store.setClock([])
        XCTAssertNil(store.draft.clock)
    }
}
