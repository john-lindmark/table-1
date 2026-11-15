import XCTest
import UIKit
@testable import Table1

/* The tab bar and sub-tabs hide while the keyboard covers the screen (SignedInView). Back from Insights → Cards with the
   search box focused left a "will show" without a "will hide", so the bars never came back on the Constructed root
   (2026-11-15). KeyboardCover takes the keyboard's end frame and clears itself once a screen settles with no box
   holding the keyboard. */
@MainActor
final class KeyboardCoverTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 402, height: 874)
    private var shown: CGRect { CGRect(x: 0, y: 874 - 336, width: 402, height: 336) }
    private var gone: CGRect { CGRect(x: 0, y: 874, width: 402, height: 336) }

    func testAShowWithNoHideClearsOnceTheScreenSettles() {
        var k = KeyboardCover()
        k.frame(shown, in: screen)
        XCTAssertTrue(k.up)
        // Back: the box is gone and no hide came.
        k.settled(editing: false)
        XCTAssertFalse(k.up)
    }

    func testAFocusedBoxKeepsItUp() {
        var k = KeyboardCover()
        k.frame(shown, in: screen)
        k.settled(editing: true)
        XCTAssertTrue(k.up)
    }

    func testSettlingNeverRaisesIt() {
        var k = KeyboardCover()
        k.settled(editing: true)
        XCTAssertFalse(k.up)
    }

    func testFramesOffScreenOrAStripAreNotUp() {
        var k = KeyboardCover()
        k.frame(shown, in: screen)
        k.frame(gone, in: screen)
        XCTAssertFalse(k.up)
        // A hardware keyboard's shortcut bar.
        k.frame(CGRect(x: 0, y: 874 - 55, width: 402, height: 55), in: screen)
        XCTAssertFalse(k.up)
        k.frame(shown, in: screen)
        k.hidden()
        XCTAssertFalse(k.up)
    }

    func testNotificationFrames() throws {
        let note = Notification(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                                userInfo: [UIResponder.keyboardFrameEndUserInfoKey: shown])
        let f = try XCTUnwrap(Keyboard.frames(note))
        XCTAssertEqual(f.end, shown)
        XCTAssertNil(Keyboard.frames(Notification(name: UIResponder.keyboardWillChangeFrameNotification)))
    }
}
