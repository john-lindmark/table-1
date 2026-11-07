import SwiftUI
import XCTest
@testable import Table1

/// Tapping a person opens their profile (contract/friends-sharing-2026-10-18.md § Tapping a person).
final class PersonLinkTests: XCTestCase {
    func testGuestsAreNotTappable() {
        XCTAssertNil(PersonLink.target(nil))
        XCTAssertNil(PersonLink.target(""))
        XCTAssertNil(PersonLink.target("  "))
        XCTAssertEqual(PersonLink.target("D0000000-0000-0000-0000-0000000F0001"), "d0000000-0000-0000-0000-0000000f0001")
    }

    @MainActor
    func testEventsPathCarriesTheProfile() {
        var events: [Route] = [.event("e1")]
        let path = Binding(get: { events }, set: { events = $0 })
        let library = Route.library(path)
        XCTAssertEqual(library.wrappedValue, [])

        // The opener pushes the profile on the Events path; its own pushes (a shared deck) follow it.
        events.append(.library(.social(.profile("u1"))))
        XCTAssertEqual(library.wrappedValue, [.social(.profile("u1"))])
        library.wrappedValue.append(.social(.profileCards("u1", "deck", "d1", "Burn")))
        XCTAssertEqual(events.count, 3)
        guard case .event("e1") = events[0] else { return XCTFail("the event stays under the profile") }

        // Back from the profile returns to the event.
        library.wrappedValue = []
        XCTAssertEqual(events, [.event("e1")])
    }
}
