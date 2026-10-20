import XCTest
@testable import Table1

/* Bug #5: deleting a trade from its editor also pops back to the list, which reloads. That read could start before
   the delete committed and bring the deleted trade back; opening it and editing then failed ("That trade is gone or
   already confirmed"). The store keeps trades deleted this session out of every read. Same cases as web
   trades.test.ts and Android TradesStoreTest.kt. */

@MainActor
final class TradesStoreTests: XCTestCase {
    private func trade(_ id: String) -> Trade {
        Trade(id: id, partner: nil, note: nil, status: "draft", gives: [], gets: [], batchId: nil,
              createdAt: nil, updatedAt: nil, confirmedAt: nil)
    }

    func testAListReadFromBeforeADeleteKeepsItGone() {
        let store = TradesStore()
        store.applyLoaded([trade("a"), trade("b")])
        store.forget("a")
        XCTAssertEqual(store.trades.map(\.id), ["b"])
        store.applyLoaded([trade("a"), trade("b")]) // the stale read lands after the delete
        XCTAssertEqual(store.trades.map(\.id), ["b"])
        XCTAssertNil(store.trade("a"))
    }

    func testASaveOfADeletedTradeIsDropped() async throws {
        let store = TradesStore()
        store.applyLoaded([trade("a")])
        store.forget("a")
        // The editor's pending autosave: no call to the server, nothing comes back into the list.
        let t = try await store.save(trade("a"), partner: "Sam", gives: [], gets: [])
        XCTAssertEqual(t.id, "a")
        XCTAssertTrue(store.trades.isEmpty)
    }
}
