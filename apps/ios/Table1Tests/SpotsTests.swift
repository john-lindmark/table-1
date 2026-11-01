import XCTest
@testable import Table1

/// The feature spots the app bundles (contract/feature-spots-2026-11-01.md): the file decodes, every carousel page
/// has its shot, the copy is within the file's own limits, and the carousel wraps.
final class SpotsTests: XCTestCase {
    func testBundledSpotsDecode() throws {
        let file = try XCTUnwrap(Spots.load(), "spots/spots.json isn't in the bundle (project.yml resources)")
        XCTAssertGreaterThanOrEqual(Spots.onboarding.count, 3)
        for s in file.spots {
            XCTAssertLessThanOrEqual(s.title.count, file.limits.title, s.key)
            XCTAssertLessThanOrEqual(s.headline.count, file.limits.headline, s.key)
            XCTAssertLessThanOrEqual(s.body.count, file.limits.body, s.key)
        }
        XCTAssertEqual(Set(file.spots.map(\.key)).count, file.spots.count, "keys are unique")
    }

    func testEveryCarouselPageHasItsShot() {
        for s in Spots.onboarding {
            let image = Spots.shot(s.key)
            XCTAssertNotNil(image, "\(s.key).png: run tools/spots/run.sh")
            if let image { XCTAssertGreaterThan(image.size.width, 300, s.key) }
        }
    }

    func testCarouselWraps() {
        XCTAssertEqual(Spots.next(after: 0, count: 3), 1)
        XCTAssertEqual(Spots.next(after: 2, count: 3), 0)
        XCTAssertEqual(Spots.next(after: 0, count: 0), 0)
    }
}
