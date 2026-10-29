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

/* Buy on TCGplayer (contract/tcgplayer-cart-2026-10-26.md): the server's answer and the parts menu. */
final class TCGplayerCartTests: XCTestCase {
    func testDecodesTheAnswer() throws {
        let json = #"{"urls": ["https://www.tcgplayer.com/massentry?productline=Magic&c=1%20Opt"], "lines": 1, "enabled": true, "unknown": 0}"#
        let a = try JSONDecoder().decode(TCGplayerCart.Answer.self, from: Data(json.utf8))
        XCTAssertTrue(a.enabled)
        XCTAssertEqual(a.urls.compactMap(URL.init(string:)).count, 1)
    }

    func testPartTitles() {
        XCTAssertEqual(TCGplayerCart.partTitle(0, of: 3), "Part 1 of 3")
        XCTAssertEqual(TCGplayerCart.partTitle(2, of: 3), "Part 3 of 3")
    }

    /// testdata/tcgplayer-cart/cases.json: what a tap opens, or the menu.
    func testMenuCases() throws {
        struct Case: Decodable {
            struct Row: Decodable { let title: String; let detail: String; let url: String }
            let name: String; let urls: [String]; let products: [TCGplayerCart.Product]; let open: String?; let menu: [Row]
        }
        struct File: Decodable { let cases: [Case] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../testdata/tcgplayer-cart/cases.json").standardized
        for c in try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).cases {
            let json = #"{"enabled": true, "lines": 0, "unknown": 0, "urls": \#(String(data: try JSONEncoder().encode(c.urls), encoding: .utf8)!), "products": []}"#
            var a = try JSONDecoder().decode(TCGplayerCart.Answer.self, from: Data(json.utf8))
            a.products = c.products
            XCTAssertEqual(TCGplayerCart.direct(a), c.open, c.name)
            XCTAssertEqual(TCGplayerCart.menu(a), c.menu.map { TCGplayerCart.Entry(title: $0.title, detail: $0.detail, url: $0.url) }, c.name)
        }
    }

    func testOldAnswerHasNoProducts() throws {
        let json = #"{"urls": [], "lines": 0, "enabled": true, "unknown": 0}"#
        XCTAssertEqual(try JSONDecoder().decode(TCGplayerCart.Answer.self, from: Data(json.utf8)).products.count, 0)
    }
}
