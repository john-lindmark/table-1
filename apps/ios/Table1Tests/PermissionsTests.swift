import XCTest
@testable import Table1

/// contract/permissions-onboarding-2026-10-28.md § When it shows.
final class PermissionsTests: XCTestCase {
    func testShowsWhileSomethingIsUnasked() {
        XCTAssertTrue(PermissionsStep.shouldShow(seen: false, notifications: .unasked, location: .unasked))
        XCTAssertTrue(PermissionsStep.shouldShow(seen: false, notifications: .on, location: .unasked))
        XCTAssertTrue(PermissionsStep.shouldShow(seen: false, notifications: .unasked, location: .off))
    }

    func testNotWhenBothAnswered() {
        XCTAssertFalse(PermissionsStep.shouldShow(seen: false, notifications: .on, location: .off))
        XCTAssertFalse(PermissionsStep.shouldShow(seen: false, notifications: .off, location: .on))
    }

    func testNeverAgainOnceSeenOrSkipped() {
        XCTAssertFalse(PermissionsStep.shouldShow(seen: true, notifications: .unasked, location: .unasked))
    }
}
