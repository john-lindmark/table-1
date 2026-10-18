import XCTest
@testable import Table1

/* Create event / Setup → Details: which Library cube the cube fields point at. Same cases as
   table-1-events-web/src/lib/chosenCube.test.ts. */
final class CubeFieldsTests: XCTestCase {
    private func list(_ id: String, _ kind: CardList.Kind, _ name: String) -> CardList {
        CardList(id: id, kind: kind, name: name, format: kind == .cube ? "cube" : "modern",
                 versions: [CardList.Version(number: 1, at: Date(timeIntervalSince1970: 0), note: "", entries: [])])
    }
    private var lists: [CardList] {
        [list("d1", .deck, "Vintage Cube"), list("c1", .cube, "Vintage Cube"), list("c2", .cube, "Pauper Cube"), list("c3", .cube, "pauper cube")]
    }

    func testMatchesCubeByNameIgnoringCaseAndSpaces() {
        XCTAssertEqual(CubeFields.chosenLibraryCube(lists, name: "  vintage CUBE ", url: "")?.id, "c1")
    }
    func testNeverPicksADeck() {
        XCTAssertNil(CubeFields.chosenLibraryCube([lists[0]], name: "Vintage Cube", url: ""))
    }
    func testCubeCobraLinkIsNotTheLibraryCube() {
        XCTAssertNil(CubeFields.chosenLibraryCube(lists, name: "Vintage Cube", url: "https://cubecobra.com/cube/overview/abc"))
    }
    func testNoNameNoMatch() {
        XCTAssertNil(CubeFields.chosenLibraryCube(lists, name: "  ", url: ""))
    }
    func testFirstOfTwoSameNamedCubes() {
        XCTAssertEqual(CubeFields.chosenLibraryCube(lists, name: "Pauper Cube", url: "")?.id, "c2")
    }
}
