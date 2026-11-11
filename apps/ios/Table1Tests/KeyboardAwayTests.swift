import UIKit
import XCTest
@testable import Table1

/* A tap outside a text box puts the keyboard away (John, 2026-11-11: on Insights a tap on anything but a control left
   it up, and it stayed up after going back; contract/keyboard-2026-11-11.md). Taps themselves can't be sent in a unit
   test, so this checks the two halves of the rule: which taps count, and what happens after one. */
@MainActor
final class KeyboardAwayTests: XCTestCase {
    private var window: UIWindow!
    private var box: UITextField!
    private var other: UITextField!

    override func setUp() async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let root = UIViewController()
        window.rootViewController = root
        box = UITextField(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        other = UITextField(frame: CGRect(x: 0, y: 60, width: 300, height: 44))
        root.view.addSubview(box)
        root.view.addSubview(other)
        window.makeKeyAndVisible()
    }

    override func tearDown() async throws {
        box.resignFirstResponder(); other.resignFirstResponder()
        window.isHidden = true
        window = nil
    }

    func testTapsInATextBoxKeepTheKeyboard() {
        XCTAssertFalse(KeyboardAway.putsAway(box))
        let inside = UIView(); box.addSubview(inside) // the box's own parts (its text, its clear button)
        XCTAssertFalse(KeyboardAway.putsAway(inside))
        let row = UILabel(); window.rootViewController!.view.addSubview(row) // a row's label, a heading, a chart
        XCTAssertTrue(KeyboardAway.putsAway(row))
        XCTAssertTrue(KeyboardAway.putsAway(nil))
    }

    func testATapElsewherePutsItAway() {
        XCTAssertTrue(box.becomeFirstResponder())
        XCTAssertTrue(Keyboard.current() === box)
        let gone = expectation(description: "put away")
        KeyboardAway.shared.putAway(box, tappedAt: CACurrentMediaTime(), after: 0.01) { gone.fulfill() }
        wait(for: [gone], timeout: 2)
        XCTAssertFalse(box.isFirstResponder)
    }

    func testAKeptViewsTapLeavesItUp() {
        XCTAssertTrue(box.becomeFirstResponder())
        let down = CACurrentMediaTime()
        Keyboard.keep() // the box's own padding, its Clear button, a guest's Add
        let checked = expectation(description: "checked")
        KeyboardAway.shared.putAway(box, tappedAt: down, after: 0.01) { checked.fulfill() }
        wait(for: [checked], timeout: 2)
        XCTAssertTrue(box.isFirstResponder)
    }

    func testFocusThatMovedIsntUndone() {
        // A tap that opens a screen focusing its own box, or moves to another box: the new box keeps the keyboard.
        XCTAssertTrue(box.becomeFirstResponder())
        let down = CACurrentMediaTime()
        XCTAssertTrue(other.becomeFirstResponder())
        let checked = expectation(description: "checked")
        KeyboardAway.shared.putAway(box, tappedAt: down, after: 0.01) { checked.fulfill() }
        wait(for: [checked], timeout: 2)
        XCTAssertTrue(other.isFirstResponder)
    }
}
