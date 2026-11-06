import XCTest
@testable import Table1

/* The card icon widget's list and pick (contract/icon-widget-2026-11-06.md) against testdata/icon-widget/cases.json,
   written by the Python reference there; Android's IconCardsTest reads the same file. */

private let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/icon-widget/cases.json").standardized

private struct Cases: Decodable {
    struct Add: Decodable { let name: String; let cards: [IconCard]; let card: IconCard; let want: [String] }
    struct Remove: Decodable { let name: String; let cards: [IconCard]; let id: String; let want: [String] }
    struct Shown: Decodable { let name: String; let cards: [IconCard]; let chosen: String?; let want: String? }
    struct Logo: Decodable { let width: Double; let want: Double }
    let limit: Int
    let add: [Add]
    let remove: [Remove]
    let shown: [Shown]
    let logo: [Logo]
}

final class IconCardsTests: XCTestCase {
    private func cases() throws -> Cases { try JSONDecoder().decode(Cases.self, from: Data(contentsOf: file)) }

    func testLimit() throws { XCTAssertEqual(IconCards.limit, try cases().limit) }

    func testAdd() throws {
        for c in try cases().add { XCTAssertEqual(IconCards.add(c.cards, c.card).map(\.id), c.want, c.name) }
    }

    func testRemove() throws {
        for c in try cases().remove { XCTAssertEqual(IconCards.remove(c.cards, c.id).map(\.id), c.want, c.name) }
    }

    func testShown() throws {
        for c in try cases().shown { XCTAssertEqual(IconCards.shown(c.cards, chosen: c.chosen)?.id, c.want, c.name) }
    }

    func testLogoMatchesTheAppIcon() throws {
        for c in try cases().logo { XCTAssertEqual(IconCards.logoWidth(c.width), c.want, "\(c.width)") }
    }
}
