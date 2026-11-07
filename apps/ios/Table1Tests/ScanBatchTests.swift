import XCTest
@testable import Table1

/* Scan from the Collection: the scanned list as Add to lines, and each row's price line
   (contract/trades-2026-10-16.md § Scanning; cases testdata/scan-batch/cases.json). */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../../testdata/scan-batch/cases.json").standardized

private struct Cases: Decodable {
    struct Copy: Decodable { let card: String; let finish: String; let condition: String; let lang: String; var qty: Int? }
    struct Lines: Decodable { let name: String; let scanned: [Copy]; let lines: [Copy] }
    struct PriceLine: Decodable { let usd: Double?; let loaded: Bool; let converted: Bool; let text: String? }
    struct Total: Decodable { let prices: [Double?]; let total: Double? }
    let lines: [Lines]
    let priceLine: [PriceLine]
    let total: [Total]
}

@MainActor
final class ScanBatchTests: XCTestCase {
    private func load() throws -> Cases { try JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL)) }

    func testScannedCardsBecomeAddToLines() throws {
        for c in try load().lines {
            let got = ScanBatch.lines(copies: c.scanned.map {
                CardVersion(cardId: $0.card, finish: $0.finish, condition: $0.condition, lang: $0.lang, qty: 1)
            })
            XCTAssertEqual(got.map { "\($0.cardId)|\($0.finish)|\($0.condition)|\($0.lang)|\($0.qty)" },
                           c.lines.map { "\($0.card)|\($0.finish)|\($0.condition)|\($0.lang)|\($0.qty ?? 0)" }, c.name)
        }
    }

    func testPriceLine() throws {
        for c in try load().priceLine {
            XCTAssertEqual(ScanBatch.priceLine(usd: c.usd, loaded: c.loaded, converted: c.converted), c.text)
        }
    }

    func testTotal() throws {
        for c in try load().total {
            XCTAssertEqual(ScanBatch.total(c.prices), c.total, "\(c.prices)")
        }
    }
}
