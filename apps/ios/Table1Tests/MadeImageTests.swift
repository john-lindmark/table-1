import XCTest
import UIKit
@testable import Table1

/// Long press on a made picture (deck image, top 100): Copy puts the picture on the pasteboard
/// (contract/deck-image-2026-10-20.md § Long press).
final class MadeImageTests: XCTestCase {
    func testCopyPutsThePictureOnThePasteboard() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 18)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 18))
        }
        UIPasteboard.general.items = []
        XCTAssertEqual(MadeImageActions.copy(image), "Copied the image.")
        XCTAssertTrue(UIPasteboard.general.hasImages)
        XCTAssertEqual(UIPasteboard.general.image?.size.width, 32)
    }
}
