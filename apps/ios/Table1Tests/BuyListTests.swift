import XCTest
@testable import Table1

/* The Buy screen's rules (contract/buy-2026-11-06.md) against testdata/buy/cases.json. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/buy/cases.json").standardized

private struct Cases: Decodable {
    struct Line: Decodable {
        let card_id, board, finish: String; let qty: Int; let unit: Int?; let basic: Bool?; let oracle_id: String?; let any: Bool?
        var line: BuyList.Line {
            BuyList.Line(cardId: card_id, oracleId: oracle_id, any: any ?? false, board: board, finish: finish, qty: qty, unit: unit, basic: basic ?? false)
        }
    }
    struct Opts: Decodable {
        let skip_owned, any_printing, exact: Bool; let boards: [String]
        var options: BuyList.Options { BuyList.Options(skipOwned: skip_owned, anyPrinting: any_printing, exact: exact, boards: Set(boards)) }
    }
    struct Row: Decodable, Equatable { let card_id, board, finish: String; let qty, owned, buy: Int }
    struct Totals: Decodable { let cards, owned, buy, price, owned_value, total, unpriced: Int }
    struct Item: Decodable { let card_id: String?; let oracle_id: String?; let qty: Int }
    struct Call: Decodable { let products: Bool; let items: [Item] }
    struct Case: Decodable {
        let name: String; let lines: [Line]; let owned: [String: Int]; let options: Opts; let rows: [Row]; let totals: Totals; let calls: [Call]
    }
    struct Product: Decodable { let card_id, name, set, number: String; let qty: Int; let url: String }
    struct Answer: Decodable { let enabled: Bool; let lines, unknown: Int; let urls: [String]; let products: [Product] }
    struct Merge: Decodable { let name: String; let answers: [Answer]; let merged: Answer }
    let oracles: [String: String]
    let cases: [Case]
    let merge: [Merge]
}

private extension Cases.Answer {
    var answer: TCGplayerCart.Answer {
        TCGplayerCart.Answer(enabled: enabled, lines: lines, unknown: unknown, urls: urls, products: products.map {
            try! JSONDecoder().decode(TCGplayerCart.Product.self, from: JSONSerialization.data(withJSONObject: [
                "name": $0.name, "set": $0.set, "number": $0.number, "qty": $0.qty, "url": $0.url]))
        })
    }
}

final class BuyListTests: XCTestCase {
    private var cases: Cases!
    override func setUpWithError() throws { cases = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL)) }

    func testRowsTotalsAndCalls() {
        for c in cases.cases {
            let rows = BuyList.rows(c.lines.map(\.line), Holdings(owned: c.owned, cardOf: cases.oracles), c.options.options)
            XCTAssertEqual(rows.map { Cases.Row(card_id: $0.line.cardId, board: $0.line.board, finish: $0.line.finish, qty: $0.line.qty, owned: $0.owned, buy: $0.buy) },
                           c.rows, c.name)
            let t = BuyList.totals(rows)
            XCTAssertEqual([t.cards, t.owned, t.buy, t.price, t.ownedValue, t.total, t.unpriced],
                           [c.totals.cards, c.totals.owned, c.totals.buy, c.totals.price, c.totals.owned_value, c.totals.total, c.totals.unpriced], c.name)
            let calls = BuyList.calls(rows, exact: c.options.exact)
            XCTAssertEqual(calls.map(\.products), c.calls.map(\.products), c.name)
            XCTAssertEqual(calls.map { $0.items.map { "\($0.cardId ?? "")|\($0.oracleId ?? "")|\($0.qty)" } },
                           c.calls.map { $0.items.map { "\($0.card_id ?? "")|\($0.oracle_id ?? "")|\($0.qty)" } }, c.name)
        }
    }

    func testMerge() {
        for m in cases.merge {
            let got = BuyList.merge(m.answers.map(\.answer)), want = m.merged.answer
            XCTAssertEqual(got.urls, want.urls, m.name)
            XCTAssertEqual(got.products, want.products, m.name)
            XCTAssertEqual([got.lines, got.unknown], [want.lines, want.unknown], m.name)
            XCTAssertEqual(got.enabled, want.enabled, m.name)
        }
    }
}
