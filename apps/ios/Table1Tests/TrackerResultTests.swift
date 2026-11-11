import XCTest
@testable import Table1

/* Record is off once the match's result is in (contract/life-tracker-options-2026-10-20.md § After the result is in). */
@MainActor
final class TrackerResultTests: XCTestCase {
    func testStateCarriesResultIn() throws {
        let json = #"{"session_id":"s1","match_id":"m1","event_id":"e1","starting_life":20,"my_side":0,"result_in":true}"#
        let state = try wireDecoder.decode(TrackerState.self, from: Data(json.utf8))
        XCTAssertEqual(state.resultIn, true)
        let old = #"{"session_id":"s1","match_id":"m1","my_side":0}"#
        XCTAssertNil(try wireDecoder.decode(TrackerState.self, from: Data(old.utf8)).resultIn, "older servers leave it out")
    }

    func testRecordOffOnceTheResultIsIn() {
        let synced = TrackerModel(matchId: "m1")
        synced.mySide = 0
        XCTAssertTrue(synced.canRecord)
        synced.resultIn = true
        XCTAssertFalse(synced.canRecord)
        synced.resultIn = false
        synced.mySide = nil
        XCTAssertFalse(synced.canRecord, "watching never records")
    }

    func testLocalTablesAlwaysRecord() {
        let local = TrackerModel(matchId: nil)
        local.resultIn = true
        XCTAssertTrue(local.canRecord)
    }

    func testRecordIsANoOpOnceTheResultIsIn() async throws {
        let synced = TrackerModel(matchId: "m1")
        synced.mySide = 0
        synced.resultIn = true
        try await synced.record(winner: 0, draw: false)
        XCTAssertTrue(synced.games.isEmpty)
    }
}
