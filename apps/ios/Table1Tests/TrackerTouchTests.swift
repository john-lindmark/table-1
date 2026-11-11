import XCTest
@testable import Table1

/* The life tracker's touch rule (contract/life-tracker-options-2026-10-20.md § Taps and the pull band) against
   testdata/tracker-touch/cases.json: a tap always counts however far it drifts; only a touch that starts in the
   band along the player's far edge and travels toward them opens the counter picker. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/tracker-touch/cases.json").standardized

private struct Cases: Decodable {
    struct Touch: Decodable {
        let note: String
        let seat: String
        let box: [Double]
        let start: [Double]
        let move: [Double]
        let far: Double
        let band: Bool
        let pull: Bool
        let holds: Bool
    }
    let band: Double
    let swipe: Double
    let holdSlop: Double
    let moved: Double
    let touches: [Touch]
}

final class TrackerTouchTests: XCTestCase {
    private func cases() throws -> Cases {
        try JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL))
    }

    func testConstants() throws {
        let c = try cases()
        XCTAssertEqual(Double(TrackerTouch.band), c.band)
        XCTAssertEqual(Double(TrackerTouch.swipe), c.swipe)
        XCTAssertEqual(Double(TrackerTouch.holdSlop), c.holdSlop)
        XCTAssertEqual(Double(TrackerTouch.moved), c.moved)
    }

    func testTouches() throws {
        let c = try cases()
        XCTAssertFalse(c.touches.isEmpty)
        for t in c.touches {
            let seat = try XCTUnwrap(TrackerSeat(rawValue: t.seat), t.note)
            let size = CGSize(width: t.box[0], height: t.box[1])
            let start = CGPoint(x: t.start[0], y: t.start[1])
            let move = CGSize(width: t.move[0], height: t.move[1])
            XCTAssertEqual(Double(seat.far(start, in: size)), t.far, t.note)
            XCTAssertEqual(TrackerTouch.inBand(seat, at: start, in: size), t.band, t.note)
            XCTAssertEqual(TrackerTouch.pulls(seat, from: start, in: size, by: move), t.pull, t.note)
            XCTAssertEqual(TrackerTouch.holds(move), t.holds, t.note)
        }
    }

    /// The complaint (2026-11-11): a tap whose finger drifts a little, or a little toward the player in the middle
    /// of a zone, must still count. The old rule cancelled past 10 pt and opened the picker from anywhere.
    func testDriftingTapsCountAndOnlyTheBandPulls() {
        let size = CGSize(width: 390, height: 380)
        let mid = CGPoint(x: 195, y: 190)
        XCTAssertFalse(TrackerTouch.pulls(.bottom, from: mid, in: size, by: CGSize(width: 2, height: 12)))
        XCTAssertFalse(TrackerTouch.pulls(.bottom, from: mid, in: size, by: CGSize(width: 0, height: 80)))
        XCTAssertTrue(TrackerTouch.pulls(.bottom, from: CGPoint(x: 195, y: 10), in: size, by: CGSize(width: 0, height: 40)))
    }
}
