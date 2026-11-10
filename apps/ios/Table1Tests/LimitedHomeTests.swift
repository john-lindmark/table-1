import XCTest
@testable import Table1

/// The Limited page's cards and search, the grid's Overall column, mana symbols and pasted event codes, against the
/// shared cases web and Android check too (testdata/insights/limited-home.json, overall.json,
/// testdata/mana-symbols/cases.json, testdata/join-code/cases.json).
final class LimitedHomeTests: XCTestCase {
    private let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../..").standardized

    private func json(_ path: String) throws -> Data { try Data(contentsOf: top.appending(path: path)) }

    private struct Card: Decodable {
        let n: String; let r: String?; let col: String?; let gih: Double?; let gih_n: Int; let oh: Double?; let iwd: Double?; let ata: Double?
        func lcard(rated: Bool = true) -> Insights.LCard {
            Insights.LCard(c: nil, n: n, r: rated ? r : nil, col: col, gih: gih, gih_n: gih_n, oh: oh, gd: nil, gns: nil, iwd: iwd, ata: ata,
                           deck: 0, week_gih: nil, pair_gih: nil)
        }
    }

    func testLimitedCardsSharedCases() throws {
        struct Filter: Decodable { let name: String; let sort: String; let rarity: [String]; let color: [String]; var unrated: Bool?; let want: [String] }
        struct Label: Decodable { let picked: [String]; let want: String }
        struct Labels: Decodable { let rarity: [Label]; let color: [Label] }
        struct Value: Decodable { let card: String; let sort: String; let want: Want; struct Want: Decodable { let value: String; let vs: String? } }
        struct Hit: Decodable { let here: [String]; let elsewhere: [[String]] }
        struct Search: Decodable { let query: String; let want: Hit }
        struct Other: Decodable { let key: String; let cards: [Name]; struct Name: Decodable { let n: String } }
        struct File: Decodable {
            let top: Int; let others_max: Int; let min_query: Int; let avg: Double
            let cards: [Card]; let others: [Other]; let filters: [Filter]; let labels: Labels; let values: [Value]; let search: [Search]
        }
        let f = try JSONDecoder().decode(File.self, from: json("testdata/insights/limited-home.json"))
        XCTAssertEqual(Insights.limitedTop, f.top)
        XCTAssertEqual(Insights.othersMax, f.others_max)
        XCTAssertEqual(Insights.minQuery, f.min_query)
        for c in f.filters {
            let cards = c.unrated == true ? f.cards.prefix(12).map { $0.lcard(rated: false) } : f.cards.map { $0.lcard() }
            XCTAssertEqual(Insights.limitedCards(cards, sort: c.sort, rarity: c.rarity, color: c.color).map(\.n), c.want, c.name)
        }
        for l in f.labels.rarity { XCTAssertEqual(LimitedFilter.rarityLabel(l.picked), l.want, l.picked.joined(separator: "+")) }
        for l in f.labels.color { XCTAssertEqual(LimitedFilter.colorLabel(l.picked), l.want, l.picked.joined(separator: "+")) }
        XCTAssertEqual(LimitedFilter.toggle(["W", "U"], "W"), ["U"])
        XCTAssertEqual(LimitedFilter.toggle(["W"], LimitedFilter.any), [])
        let byName = Dictionary(f.cards.map { ($0.n, $0.lcard()) }, uniquingKeysWith: { a, _ in a })
        for v in f.values {
            let got = Insights.limitedValue(byName[v.card]!, sort: v.sort, average: f.avg)
            XCTAssertEqual(got.value, v.want.value, "\(v.card) \(v.sort)")
            XCTAssertEqual(got.vs, v.want.vs, "\(v.card) \(v.sort)")
        }
        let others = f.others.map { (key: $0.key, names: $0.cards.map(\.n)) }
        for s in f.search {
            let got = Insights.limitedSearch(s.query, here: f.cards.map(\.n), others: others)
            XCTAssertEqual(got.here, s.want.here, s.query)
            XCTAssertEqual(got.elsewhere.map { [$0.set, $0.name] }, s.want.elsewhere, s.query)
        }
    }

    func testOverallSharedCases() throws {
        struct Want: Decodable { let wins: Int; let losses: Int; let draws: Int; let from: String }
        struct Case: Decodable { let a: Int; let want: Want? }
        struct Share: Decodable { let a: Int; let rec: [Int]? }
        struct File: Decodable { let share: [Share]; let matchups: Insights.Matchups; let cases: [Case] }
        let f = try JSONDecoder().decode(File.self, from: json("testdata/insights/overall.json"))
        let share = f.share.map { Insights.ShareRow(a: $0.a, share: 0, prev: nil, decks: 0, top8: 0, conv: nil, rec: $0.rec) }
        for c in f.cases {
            let got = Insights.overall(share, f.matchups, c.a)
            XCTAssertEqual(got?.wins, c.want?.wins, "\(c.a)")
            XCTAssertEqual(got?.losses, c.want?.losses, "\(c.a)")
            XCTAssertEqual(got?.draws, c.want?.draws, "\(c.a)")
            XCTAssertEqual(got.map { $0.fromMeta ? "meta" : "grid" }, c.want?.from, "\(c.a)")
        }
    }

    func testManaSymbolsSharedCases() throws {
        struct Case: Decodable { let cost: String; let want: [String] }
        struct File: Decodable { let symbols: [String]; let cases: [Case] }
        let f = try JSONDecoder().decode(File.self, from: json("testdata/mana-symbols/cases.json"))
        for c in f.cases { XCTAssertEqual(ManaSymbols.parse(c.cost), c.want, c.cost) }
        for s in f.symbols { XCTAssertNotNil(UIImage(named: "mana-\(s)"), "mana-\(s) is bundled") }
    }

    func testJoinCodeSharedCases() throws {
        struct Want: Decodable { let kind: String; let code: String; var secret: String? }
        struct Case: Decodable { let text: String; let want: Want? }
        struct File: Decodable { let cases: [Case] }
        let f = try JSONDecoder().decode(File.self, from: json("testdata/join-code/cases.json"))
        for c in f.cases {
            let got: Want? = switch JoinCode.parse(c.text) {
            case .code(let code)?: Want(kind: "code", code: code)
            case .qr(let l)?: Want(kind: "qr", code: l.code, secret: l.secret)
            case nil: nil
            }
            XCTAssertEqual(got?.kind, c.want?.kind, c.text)
            XCTAssertEqual(got?.code, c.want?.code, c.text)
            XCTAssertEqual(got?.secret, c.want?.secret, c.text)
        }
    }
}

/// The Limited cards widget (contract/widgets-2026-10-22.md § Limited cards widget): the app's Top cards order, its
/// caption, and the tap that opens the set in Insights.
final class LimitedWidgetTests: XCTestCase {
    func testWidgetRowsAreTheAppsTopCards() throws {
        let url = Bundle.main.url(forResource: "insights-demo-limited-FRA", withExtension: "json")!
        let data = try Data(contentsOf: url)
        let pack = try XCTUnwrap(LimitedPackStore.decode(data))
        let app = try JSONDecoder().decode(Insights.LimitedPack.self, from: data)
        let v = try XCTUnwrap(app.events["PremierDraft"]?.groups["all"])
        for (sort, rarity, color) in [("gih", [String](), [String]()), ("ata", ["common", "uncommon"], ["W", "U"]), ("iwd", [], ["M"])] {
            let rows = LimitedWidgets.rows(pack, sort: sort, rarity: rarity, color: color, n: 12)
            let want = Insights.limitedCards(v.cards, sort: sort, rarity: rarity, color: color).prefix(12)
            XCTAssertEqual(rows.map(\.name), want.map(\.n), sort)
            XCTAssertEqual(rows.map(\.value), want.map { Insights.limitedValue($0, sort: sort, average: v.wr).value }, sort)
        }
        XCTAssertEqual(LimitedWidgets.caption(sort: "gih", rarity: [], color: []), "GIH WR")
        XCTAssertEqual(LimitedWidgets.caption(sort: "ata", rarity: ["common", "uncommon"], color: ["U", "W"]), "ATA · C · U · WU")
        let link = LimitedWidgets.link("FRA", src: "widget_limited")
        XCTAssertEqual(PushRoutes.insightsWidget(link), InsightsPush(section: "limited", key: "FRA", what: "data"))
    }
}
