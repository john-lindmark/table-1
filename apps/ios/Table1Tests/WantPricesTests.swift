import XCTest
@testable import Table1

/* Want prices (contract/want-prices-2026-10-26.md) against testdata/want-prices/cases.json (make_cases.py). */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/want-prices/cases.json").standardized

private struct Cases: Decodable {
    struct Money: Decodable { let v: Double; let want: String }
    struct Trend: Decodable { let dir: String; let text: String }
    struct TrendCase: Decodable { let now: Double?; let then: Double?; let days: Int?; let want: Trend? }
    struct Detail: Decodable {
        let which: String; let max: Double?; let now: Double?; let any: Bool; let want: String
    }
    let money: [Money]
    let trend: [TrendCase]
    let detail: [Detail]
}

final class WantPricesTests: XCTestCase {
    private func load() throws -> Cases { try JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL)) }

    func testMoney() throws {
        for c in try load().money { XCTAssertEqual(WantPrices.money(c.v), c.want, "\(c.v)") }
    }

    func testTrend() throws {
        for c in try load().trend {
            let got = WantPrices.trend(now: c.now, then: c.then, days: c.days)
            XCTAssertEqual(got?.dir, c.want?.dir, "\(String(describing: c.now)) vs \(String(describing: c.then))")
            XCTAssertEqual(got?.text, c.want?.text, "\(String(describing: c.now)) vs \(String(describing: c.then))")
        }
    }

    func testDetail() throws {
        for c in try load().detail {
            XCTAssertEqual(WantPrices.detail(which: c.which, max: c.max, now: c.now, any: c.any), c.want)
        }
    }

    func testDecodesTheAnswer() throws {
        let json = #"{"oracle_id": "o", "card_id": null, "finish": null, "now": 1.4, "now_card_id": "c", "now_finish": "foil", "then": 1.8, "then_days": 7, "avg30": null}"#
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let p = try d.decode(WantPrice.self, from: Data(json.utf8))
        XCTAssertEqual(p.key, Want.key("o", nil, nil))
        XCTAssertEqual(WantPrices.trend(now: p.now, then: p.then, days: p.thenDays)?.text, "▼ 22% this week")
    }

    func testPushOpensWants() {
        XCTAssertEqual(PushRoutes.library(["kind": "want.price"]), [.wants])
    }
}
