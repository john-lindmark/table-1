import XCTest
@testable import Table1

/* Converted prices (contract/converted-prices-2026-10-28.md) against testdata/converted-prices/cases.json. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/converted-prices/cases.json").standardized

private struct Cases: Decodable {
    struct Row: Decodable { let row: [Double?]; let finish: String; let usd: Double?; let converted: Bool }
    let rows: [Row]
}

final class ConvertedPriceTests: XCTestCase {
    func testSharedRows() throws {
        let c = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL))
        XCTAssertFalse(c.rows.isEmpty)
        for r in c.rows {
            XCTAssertEqual(PriceBook.converted(r.row, r.finish), r.converted, "\(r.row) \(r.finish)")
            let i = r.finish == "foil" ? 1 : r.finish == "etched" ? 2 : 0
            XCTAssertEqual(i < r.row.count ? r.row[i] : nil, r.usd, "\(r.row) \(r.finish)")
        }
    }

    func testMark() {
        XCTAssertEqual(PriceBook.marked("$7,992.55", converted: true), "≈ $7,992.55")
        XCTAssertEqual(PriceBook.marked("$7,992.55", converted: true, source: true), "≈ $7,992.55 · from Cardmarket")
        XCTAssertEqual(PriceBook.marked("$647.32", converted: false, source: true), "$647.32")
        XCTAssertNil(PriceBook.marked(nil, converted: true))
    }
}
