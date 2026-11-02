import XCTest
@testable import Table1

/* Back on the scanner asks before leaving scanned cards behind (contract/trades-2026-10-16.md § Scanning, "Back"). */

final class ScanLeaveTests: XCTestCase {
    func testNothingScannedLeavesWithoutAsking() {
        XCTAssertNil(CardScanView.LeavePrompt.of(count: 0, doneLabel: "Add"))
    }

    func testScannedCardsAskWithTheScreensOwnAction() {
        let one = CardScanView.LeavePrompt.of(count: 1, doneLabel: "Add")
        XCTAssertEqual(one?.title, "Add the 1 card you scanned?")
        XCTAssertEqual(one?.add, "Add 1")
        let wants = CardScanView.LeavePrompt.of(count: 3, doneLabel: "Want")
        XCTAssertEqual(wants?.title, "Want the 3 cards you scanned?")
        XCTAssertEqual(wants?.add, "Want 3")
    }
}
