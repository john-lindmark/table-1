import XCTest
@testable import Table1

/* Telemetry stays off while XCTest hosts the app. A unit-test run on a phone (build 5) sent a regex-heavy test's
   main-thread work to Sentry as "Fatal App Hang Fully Blocked" (TABLE-1-IOS-1, 2026-10-16). */

final class TelemetryTests: XCTestCase {
    func testOffUnderXCTest() {
        XCTAssertFalse(Telemetry.allowed(arguments: ["-T1Telemetry"],
                                         environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
        XCTAssertFalse(Telemetry.allowed(arguments: ["-T1Telemetry"], environment: ["XCTestSessionIdentifier": "abc"]))
        // This process is itself an XCTest host.
        XCTAssertFalse(Telemetry.allowed(arguments: ["-T1Telemetry"], environment: ProcessInfo.processInfo.environment))
    }

    func testDebugNeedsTheLaunchArgument() {
        XCTAssertTrue(Telemetry.allowed(arguments: ["-T1Telemetry"], environment: [:]))
        XCTAssertFalse(Telemetry.allowed(arguments: [], environment: [:]))
    }
}
