import XCTest
@testable import Table1

/* Fold-aware layouts (contract/foldables-2026-11-10.md) against testdata/foldables/cases.json (make_cases.py). */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/foldables/cases.json").standardized

private struct Cases: Decodable {
    struct Constants: Decodable { let clear, minPane, wide, heightMin: Double }
    struct F: Decodable { let x, y, w, h: Double; let vertical, separating: Bool; let margin: Double }
    struct Out: Decodable { let width, height, mode: String; let panes: [[Double]]; let rail, rotates: Bool }
    struct Case: Decodable { let name: String; let w, h: Double; let folds: [F]; let out: Out }
    let constants: Constants
    let cases: [Case]
}

final class FoldLayoutTests: XCTestCase {
    private func load() throws -> Cases { try JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL)) }

    func testConstants() throws {
        let c = try load().constants
        XCTAssertEqual(Double(FoldLayout.clear), c.clear)
        XCTAssertEqual(Double(FoldLayout.minPane), c.minPane)
        XCTAssertEqual(Double(FoldLayout.wide), c.wide)
        XCTAssertEqual(Double(FoldLayout.heightMin), c.heightMin)
    }

    func testSharedCases() throws {
        let cases = try load().cases
        XCTAssertGreaterThan(cases.count, 15)
        for c in cases {
            let folds = c.folds.map { Fold(x: $0.x, y: $0.y, w: $0.w, h: $0.h, vertical: $0.vertical, separating: $0.separating, margin: $0.margin) }
            let got = FoldLayout.of(CGSize(width: c.w, height: c.h), folds: folds)
            XCTAssertEqual(got.width.rawValue, c.out.width, c.name)
            XCTAssertEqual(got.height.rawValue, c.out.height, c.name)
            XCTAssertEqual(got.mode.rawValue, c.out.mode, c.name)
            XCTAssertEqual(got.rail, c.out.rail, c.name)
            XCTAssertEqual(got.rotates, c.out.rotates, c.name)
            XCTAssertEqual(got.panes.count, c.out.panes.count, c.name)
            for (p, want) in zip(got.panes, c.out.panes) {
                for (a, b) in zip([p.minX, p.minY, p.width, p.height], want) { XCTAssertEqual(Double(a), b, accuracy: 0.01, c.name) }
            }
        }
    }

    /// The fold that made the panes, and CLEAR on each side of it, belongs to neither pane.
    func testPanesStayOffTheFold() throws {
        for c in try load().cases {
            let folds = c.folds.map { Fold(x: $0.x, y: $0.y, w: $0.w, h: $0.h, vertical: $0.vertical, separating: $0.separating, margin: $0.margin) }
            let got = FoldLayout.of(CGSize(width: c.w, height: c.h), folds: folds)
            guard got.mode == .tabletop || got.mode == .book else { continue }
            let book = got.mode == .book
            let gapStart = book ? got.panes[0].maxX : got.panes[0].maxY
            let gapEnd = book ? got.panes[1].minX : got.panes[1].minY
            let inGap = folds.contains { f in
                f.separating && f.vertical == book
                    && (book ? f.x : f.y) - FoldLayout.clear >= gapStart - 0.01
                    && (book ? f.x + f.w : f.y + f.h) + FoldLayout.clear <= gapEnd + 0.01
            }
            XCTAssertTrue(inGap, "\(c.name): the fold isn't in the gap between the panes")
        }
    }

    /// Tabletop keeps the tab bar on the flat half; phones stay portrait.
    func testRailAndRotation() {
        let tabletop = FoldLayout.of(CGSize(width: 841, height: 673), folds: [Fold(x: 0, y: 336, w: 841, h: 0, vertical: false)])
        XCTAssertEqual(tabletop.mode, .tabletop)
        XCTAssertFalse(tabletop.rail)
        XCTAssertTrue(tabletop.rotates)
        XCTAssertFalse(FoldLayout.of(CGSize(width: 390, height: 844), folds: []).rotates)
        XCTAssertTrue(FoldLayout.of(CGSize(width: 844, height: 390), folds: []).rail)
    }
}
