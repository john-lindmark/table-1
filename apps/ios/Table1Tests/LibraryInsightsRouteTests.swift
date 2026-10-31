import SwiftUI
import XCTest
@testable import Table1

/// An Insights page opened from a deck sits on the deck's own stack, so Back returns to the deck (LibraryRoute.insights).
final class LibraryInsightsRouteTests: XCTestCase {
    func testInsightsPushOnTheDecksStack() {
        var path: [LibraryRoute] = [.lists(.deck), .list("d1")]
        let lib = Binding(get: { path }, set: { path = $0 })
        let insights = LibraryRoute.insights(lib)
        XCTAssertEqual(insights.wrappedValue, [])

        // The deck's archetype row, then a card on its page, then an example list's card (a Library screen).
        lib.wrappedValue.append(.insights(.archetype("modern", 3)))
        insights.wrappedValue.append(.card("modern", "o1", "Ragavan"))
        insights.wrappedValue.append(.library(.card("o2")))
        XCTAssertEqual(path, [.lists(.deck), .list("d1"), .insights(.archetype("modern", 3)), .insights(.card("modern", "o1", "Ragavan")), .card("o2")])
        XCTAssertEqual(insights.wrappedValue, [.archetype("modern", 3), .card("modern", "o1", "Ragavan"), .library(.card("o2"))])

        // Back, back, back: the deck again.
        insights.wrappedValue.removeLast()
        insights.wrappedValue.removeLast()
        insights.wrappedValue.removeLast()
        XCTAssertEqual(path, [.lists(.deck), .list("d1")])
    }
}
