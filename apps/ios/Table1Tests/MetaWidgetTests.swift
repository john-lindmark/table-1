import XCTest
@testable import Table1

/* The Insights widgets' logic (contract/widgets-2026-10-22.md § Meta widgets) against testdata/meta-widgets/cases.json,
   written by the Python reference there from the live Modern pack it keeps (modern.json); Android's
   MetaWidgetDataTest reads the same files. */

private let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../testdata/meta-widgets").standardized

private struct HeatCase: Decodable { let label: String; let tone: String; let strength: Double; let dim: Bool; let ink: Bool }
private struct RowCase: Decodable { let a: Int; let name: String; let share: Double; let delta: Double?; let wr: Double?; let slot: Int? }
private struct Cases: Decodable {
    struct TierFor: Decodable { let pack: String; let want: String; let days: Int; let out: String }
    struct Breakdown: Decodable {
        struct Out: Decodable { let decks: Int; let rows: [RowCase]; let rest: Double }
        let tier: String; let days: Int; let n: Int; let out: Out?
    }
    struct Chart: Decodable {
        struct Line: Decodable { let a: Int; let slot: Int?; let v: [Double?] }
        struct Out: Decodable { let days: Int; let lines: [Line]; let top: Double }
        let tier: String; let days: Int; let ids: [Int]; let out: Out
    }
    struct Codes: Decodable { let names: [String]; let out: [String] }
    struct Grid: Decodable {
        struct Col: Decodable { let a: Int; let name: String; let code: String; let slot: Int? }
        struct Row: Decodable { let a: Int; let name: String; let slot: Int? }
        struct Out: Decodable { let title: String; let cols: [Col]; let rows: [Row]; let cells: [[HeatCase?]] }
        let tier: String; let days: Int; let rows: Int; let cols: Int; let out: Out
    }
    struct Matchups: Decodable {
        struct Row: Decodable { let vs: Int; let name: String; let slot: Int?; let wins: Int; let losses: Int; let draws: Int; let wr: Double; let heat: HeatCase }
        struct Out: Decodable {
            let a: Int; let name: String; let slot: Int?; let title: String; let share: Double?; let wr: Double?; let record: [Int]?
            let rows: [Row]; let good: [Int]; let bad: [Int]
        }
        let tier: String; let days: Int; let a: Int; let out: Out
    }
    let slots: Int
    let tier_for: [TierFor]
    let breakdown: [Breakdown]
    let chart: [Chart]
    let codes: [Codes]
    let grid: [Grid]
    let grid_thin: Grid
    let matchups: [Matchups]
    let choices: [Int]
    struct CellDetail: Decodable {
        struct Out: Decodable { let title: String; let line: String; let record: String }
        let tier: String; let days: Int; let a: Int; let b: Int; let out: Out?
    }
    let cell_detail: [CellDetail]
}

final class MetaWidgetTests: XCTestCase {
    private var cases: Cases!
    private var pack: MetaPack!
    private var thin: MetaPack!

    override func setUpWithError() throws {
        cases = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: dir.appending(path: "cases.json")))
        let raw = try Data(contentsOf: dir.appending(path: "modern.json"))
        pack = try XCTUnwrap(MetaPackStore.decode(raw))
        // make_cases.py's "thin" pack: Big events' 7 days without decks, no 14 days, All events' windows without grids.
        var j = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        var tiers = j["tiers"] as! [String: Any]
        var big = tiers["big"] as! [String: Any], bigW = big["windows"] as! [String: Any]
        var w7 = bigW["7"] as! [String: Any]; w7["decks"] = 0; bigW["7"] = w7; bigW["14"] = nil
        big["windows"] = bigW; tiers["big"] = big
        var all = tiers["all"] as! [String: Any], allW = all["windows"] as! [String: Any]
        for (k, v) in allW { var w = v as! [String: Any]; w["matchups"] = nil; allW[k] = w }
        all["windows"] = allW; tiers["all"] = all; j["tiers"] = tiers
        thin = try XCTUnwrap(MetaPackStore.decode(JSONSerialization.data(withJSONObject: j)))
    }

    private func heat(_ h: InsightCharts.Heat?, _ c: HeatCase?, _ what: String) {
        XCTAssertEqual(h == nil, c == nil, what)
        guard let h, let c else { return }
        XCTAssertEqual(h.label, c.label, what); XCTAssertEqual(h.tone, c.tone, what)
        XCTAssertEqual(h.strength, c.strength, accuracy: 1e-4, what); XCTAssertEqual(h.dim, c.dim, what); XCTAssertEqual(h.ink, c.ink, what)
    }

    private func near(_ a: Double?, _ b: Double?, _ what: String) {
        XCTAssertEqual(a == nil, b == nil, what)
        if let a, let b { XCTAssertEqual(a, b, accuracy: 1e-4, what) }
    }

    func testSlotsAndTier() {
        XCTAssertEqual(MetaWidgets.slots, cases.slots)
        XCTAssertEqual(MetaPalette.colors.count, cases.slots)
        for c in cases.tier_for {
            XCTAssertEqual(MetaWidgets.tierFor(c.pack == "thin" ? thin : pack, want: c.want, days: c.days), c.out, "\(c.pack) \(c.want) \(c.days)")
        }
    }

    func testBreakdown() throws {
        for c in cases.breakdown {
            let b = MetaWidgets.breakdown(pack, c.tier, c.days, n: c.n)
            guard let o = c.out else { XCTAssertNil(b); continue }
            let got = try XCTUnwrap(b)
            XCTAssertEqual(got.decks, o.decks)
            near(got.rest, o.rest, "rest")
            XCTAssertEqual(got.rows.map(\.a), o.rows.map(\.a))
            for (g, e) in zip(got.rows, o.rows) {
                XCTAssertEqual(g.name, e.name); XCTAssertEqual(g.slot, e.slot)
                near(g.share, e.share, "share \(e.a)"); near(g.delta, e.delta, "delta \(e.a)"); near(g.wr, e.wr, "wr \(e.a)")
            }
        }
    }

    func testChart() {
        for c in cases.chart {
            let got = MetaWidgets.chart(pack, c.tier, c.days, ids: c.ids)
            XCTAssertEqual(got.days, c.out.days)
            near(got.top, c.out.top, "top")
            XCTAssertEqual(got.lines.map(\.a), c.out.lines.map(\.a))
            for (g, e) in zip(got.lines, c.out.lines) {
                XCTAssertEqual(g.slot, e.slot)
                XCTAssertEqual(g.v.count, e.v.count)
                for (x, y) in zip(g.v, e.v) { near(x, y, "line \(e.a)") }
            }
            XCTAssertFalse(got.labels.isEmpty || got.labels.contains { $0.0 >= got.days })
        }
    }

    func testCodes() {
        for c in cases.codes { XCTAssertEqual(MetaWidgets.codes(c.names), c.out) }
    }

    func testGrid() {
        for (c, p) in cases.grid.map({ ($0, pack!) }) + [(cases.grid_thin, thin!)] {
            let got = MetaWidgets.grid(p, c.tier, c.days, rows: c.rows, cols: c.cols)
            XCTAssertEqual(got.title, c.out.title)
            XCTAssertEqual(got.cols, c.out.cols.map { .init(a: $0.a, name: $0.name, code: $0.code, slot: $0.slot) })
            XCTAssertEqual(got.rows, c.out.rows.map { .init(a: $0.a, name: $0.name, slot: $0.slot) })
            XCTAssertEqual(got.cells.count, c.out.cells.count)
            for (i, line) in c.out.cells.enumerated() {
                for (j, e) in line.enumerated() { heat(got.cells[i][j], e, "\(c.tier) \(c.days) \(i),\(j)") }
            }
        }
    }

    func testMatchups() {
        for c in cases.matchups {
            let got = MetaWidgets.matchups(pack, c.tier, c.days, archetype: c.a)
            let o = c.out
            XCTAssertEqual(got.name, o.name); XCTAssertEqual(got.slot, o.slot); XCTAssertEqual(got.title, o.title)
            near(got.share, o.share, "share"); near(got.wr, o.wr, "wr"); XCTAssertEqual(got.record, o.record)
            XCTAssertEqual(got.rows.map(\.vs), o.rows.map(\.vs))
            for (g, e) in zip(got.rows, o.rows) {
                XCTAssertEqual([g.wins, g.losses, g.draws], [e.wins, e.losses, e.draws]); XCTAssertEqual(g.slot, e.slot)
                near(g.wr, e.wr, "wr \(e.vs)"); heat(g.heat, e.heat, "heat \(e.vs)")
            }
            XCTAssertEqual(got.good, o.good, "good \(c.a)"); XCTAssertEqual(got.bad, o.bad, "bad \(c.a)")
        }
    }

    /// A tapped square reads as the Insights tab's grid does.
    func testCellDetail() {
        for c in cases.cell_detail {
            let got = MetaWidgets.cellDetail(pack, c.tier, c.days, c.a, c.b)
            XCTAssertEqual(got.map { [$0.title, $0.line, $0.record] }, c.out.map { [$0.title, $0.line, $0.record] }, "\(c.a) vs \(c.b)")
        }
    }

    /// A tap picks a square or row; the same tap again lets it go; another picks that one.
    func testSelectionToggle() {
        XCTAssertEqual(MetaSelection.toggled(nil, "1:18"), "1:18")
        XCTAssertNil(MetaSelection.toggled("1:18", "1:18"))
        XCTAssertEqual(MetaSelection.toggled("1:18", "18:1"), "18:1")
        XCTAssertTrue(MetaSelection.cell("1:18")! == (1, 18))
        XCTAssertNil(MetaSelection.cell("12"))
        XCTAssertNil(MetaSelection.cell(nil))
        XCTAssertEqual(MetaSelection.key("grid", MetaPicks(format: "pauper", tier: "all", days: 7)), "grid|pauper|all|7")
    }

    func testChoices() { XCTAssertEqual(MetaWidgets.choices(pack), cases.choices) }

    /// The archetype widget falls back to the most played when its pick isn't in the format.
    func testArchetypeFallback() {
        XCTAssertEqual(ArchetypeWidgetView.archetype(pack, MetaPicks(tier: "all", days: 30, archetype: 17)), 17)
        let top = pack.window("all", 30)?.share.first { $0.a != 0 }?.a
        XCTAssertEqual(ArchetypeWidgetView.archetype(pack, MetaPicks(tier: "all", days: 30, archetype: 999)), top)
        XCTAssertEqual(ArchetypeWidgetView.archetype(pack, MetaPicks(tier: "all", days: 30)), top)
    }

    func testWidgetLinks() {
        let url = MetaPicks(format: "pauper", tier: "all", days: 7).link("archetype/12", src: "widget_archetype")
        XCTAssertEqual(url.absoluteString, "table1://insights/pauper/archetype/12?tier=all&days=7&src=widget_archetype")
        XCTAssertEqual(PushRoutes.insightsWidget(url), InsightsPush(section: "constructed", key: "pauper", what: "archetype:12", tier: "all", days: 7))
        XCTAssertEqual(PushRoutes.insightsWidget(URL(string: "table1://insights/modern/matchups?tier=big&days=30")!)?.what, "matchups")
        XCTAssertEqual(PushRoutes.insightsWidget(URL(string: "table1://insights/modern?tier=nope&days=5")!),
                       InsightsPush(section: "constructed", key: "modern", what: "data"))
        XCTAssertNil(PushRoutes.insightsWidget(URL(string: "table1://insights")!))
        XCTAssertNil(PushRoutes.insightsWidget(URL(string: "table1://events")!))
    }
}
