import XCTest
@testable import Table1

/* A copy's price follows its condition (contract/condition-prices-2026-10-24.md) against
   testdata/condition-prices/cases.json. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/condition-prices/cases.json").standardized

private struct Cases: Decodable {
    struct Unit: Decodable { let nm: Double?; let condition: String; let price: Double? }
    struct Copy: Decodable { let nm: Double?; let condition: String; let qty: Int }
    let percent: [String: Int]
    let unit: [Unit]
    let copies: [Copy]
    let total: Double
}

final class ConditionPriceTests: XCTestCase {
    func testSharedCases() throws {
        let c = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL))
        for (k, v) in c.percent { XCTAssertEqual(Conditions.percent(k), v, k) }
        XCTAssertEqual(Set(c.percent.keys), Set(Conditions.all))
        for u in c.unit { XCTAssertEqual(Conditions.price(u.nm, u.condition), u.price, "\(String(describing: u.nm)) \(u.condition)") }
        let total = c.copies.compactMap { x in Conditions.price(x.nm, x.condition).map { $0 * Double(x.qty) } }.reduce(0, +)
        XCTAssertEqual(total, c.total, accuracy: 0.001)
    }

    @MainActor func testBetterAndLabel() {
        XCTAssertTrue(Conditions.better("NM", "LP"))
        XCTAssertFalse(Conditions.better("DMG", "HP"))
        XCTAssertEqual(PriceBook.conditionText(10, "NM"), PriceBook.text(10))
        XCTAssertEqual(PriceBook.conditionText(10, "LP"), "\(PriceBook.text(8.5)!) · LP (NM \(PriceBook.text(10)!))")
        XCTAssertNil(PriceBook.conditionText(nil, "LP"))
    }
}
