import XCTest
@testable import Table1

/* The scanner reads only the card in the guide box (contract/card-scanning, "guide box"): cards around it are ignored. */

final class ScanRegionTests: XCTestCase {
    private let image = CGSize(width: 1080, height: 1920)

    func testGuideBoxLandsInTheImage() {
        // A 402 × 560 camera view: the image (1080 × 1920) fills it by width and is cropped top and bottom.
        let view = CGSize(width: 402, height: 560)
        let box = ScanRegion.viewBox(view)
        XCTAssertEqual(box.midX, 201, accuracy: 0.5)
        XCTAssertEqual(box.midY, 280, accuracy: 0.5)
        let n = ScanRegion.normalized(box, view: view, image: image)
        XCTAssertEqual(n.midX, 0.5, accuracy: 0.001, "centred across")
        XCTAssertEqual(n.midY, 0.5, accuracy: 0.001, "centred down")
        // Scale 402/1080: the box is 72% of the view's width, so 72% of the image's; its height in image pixels
        // over the image's 1920.
        let scale = 402.0 / 1080
        XCTAssertEqual(n.width, 0.72, accuracy: 0.001)
        XCTAssertEqual(n.height, box.height / scale / 1920, accuracy: 0.001)
    }

    func testTopOfTheViewIsTheTopOfTheImage() {
        let view = CGSize(width: 400, height: 711.1)
        let top = ScanRegion.normalized(CGRect(x: 0, y: 0, width: 400, height: 71.11), view: view, image: image)
        XCTAssertEqual(top.maxY, 1, accuracy: 0.001, "Vision's y grows upward")
        XCTAssertEqual(top.minY, 0.9, accuracy: 0.001)
    }

    private func quad(cx: CGFloat, cy: CGFloat, w: CGFloat = 0.3, h: CGFloat = 0.25) -> [CGPoint] {
        [CGPoint(x: cx - w / 2, y: cy + h / 2), CGPoint(x: cx + w / 2, y: cy + h / 2),
         CGPoint(x: cx + w / 2, y: cy - h / 2), CGPoint(x: cx - w / 2, y: cy - h / 2)]
    }

    func testPicksTheCardInTheGuideNotTheBiggestAround() {
        let guide = CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.4)
        let quads = [
            quad(cx: 0.15, cy: 0.9, w: 0.6, h: 0.5), // a bigger card above, outside the guide
            quad(cx: 0.55, cy: 0.52),                // the one in the guide, a little off centre
            quad(cx: 0.45, cy: 0.1),                 // one below
        ]
        XCTAssertEqual(ScanRegion.pick(quads, guide: guide, image: image), 1)
    }

    func testNearestTheCentreWhenTwoOverlapTheGuide() {
        let guide = CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.4)
        XCTAssertEqual(ScanRegion.pick([quad(cx: 0.75, cy: 0.6), quad(cx: 0.48, cy: 0.49)], guide: guide, image: image), 1)
    }

    func testNoCardInTheGuide() {
        let guide = CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.4)
        XCTAssertNil(ScanRegion.pick([quad(cx: 0.05, cy: 0.95), quad(cx: 0.95, cy: 0.05)], guide: guide, image: image))
    }
}
