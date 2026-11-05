import XCTest
@testable import Table1

/* Sideboard guides (contract/sideboard-guide-2026-11-04.md) against testdata/sideboard-guide/cases.json, and the
   printed page against guide.html byte for byte. */

private let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/sideboard-guide").standardized

final class SideboardGuideTests: XCTestCase {
    private var cases: [String: Any]!
    private var lines: [SideboardRules.Line]!
    private var guide: SideboardGuide!

    override func setUpWithError() throws {
        let data = try Data(contentsOf: dir.appending(path: "cases.json"))
        cases = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        lines = Self.lines(cases["lines"])
        guide = try JSONDecoder().decode(SideboardGuide.self, from: JSONSerialization.data(withJSONObject: cases["guide"]!))
    }

    private static func lines(_ any: Any?) -> [SideboardRules.Line] {
        (any as? [[String: Any]] ?? []).map {
            SideboardRules.Line(oracle: $0["oracle"] as! String, name: $0["name"] as! String, board: $0["board"] as! String, qty: $0["qty"] as! Int)
        }
    }

    private static func cards(_ any: Any?) -> [SideboardGuide.Card] {
        (any as? [[Any]] ?? []).map { SideboardGuide.Card($0[0] as! String, $0[1] as! Int) }
    }

    private static func key(_ i: SideboardRules.Issue) -> String {
        switch i {
        case let .gone(side, o): "gone:\(side.rawValue):\(o)"
        case let .inOver(o, have): "in_over:\(o):\(have)"
        case let .outOver(o, have): "out_over:\(o):\(have)"
        case let .considering(o, qty): "considering:\(o):\(qty)"
        case let .belowMin(deck, min): "below_min:\(deck):\(min)"
        }
    }

    private static func key(_ d: [String: Any]) -> String {
        switch d["code"] as! String {
        case "gone": "gone:\(d["side"]!):\(d["oracle"]!)"
        case "in_over": "in_over:\(d["oracle"]!):\(d["have"]!)"
        case "out_over": "out_over:\(d["oracle"]!):\(d["have"]!)"
        case "considering": "considering:\(d["oracle"]!):\(d["qty"]!)"
        default: "below_min:\(d["deck"]!):\(d["min"]!)"
        }
    }

    func testFormats() {
        for (f, want) in cases["has_guide"] as! [String: Bool] { XCTAssertEqual(SideboardRules.hasGuide(f), want, f) }
        for (f, want) in cases["deck_min"] as! [String: Any] { XCTAssertEqual(SideboardRules.deckMin(f), want as? Int, f) }
    }

    func testDecodesTheWire() {
        XCTAssertEqual(guide.matchups.map(\.name), ["Boros Energy", "Esper Goryo's & <friends>", "Mirror"])
        XCTAssertEqual(guide.matchups[0].archetype, 12)
        XCTAssertEqual(guide.matchups[0].ins, [.init("o-fury", 2), .init("o-blood", 1)])
    }

    func testCheck() {
        for c in cases["check"] as! [[String: Any]] {
            let id = c["matchup"] as! String
            let m = guide.matchup(id) ?? SideboardGuide.Matchup(id: id, name: id, ins: Self.cards(c["in"]), outs: Self.cards(c["out"]))
            let got = SideboardRules.check(m, lines, format: c["format"] as! String)
            let want = c["expect"] as! [String: Any]
            let label = "\(id) \(c["format"]!)"
            XCTAssertEqual(got.ins, want["in"] as? Int, label)
            XCTAssertEqual(got.outs, want["out"] as? Int, label)
            XCTAssertEqual(got.deck, want["deck"] as? Int, label)
            XCTAssertEqual(got.label, want["label"] as? String, label)
            XCTAssertEqual(got.issues.map(Self.key), (want["issues"] as! [[String: Any]]).map(Self.key), label)
        }
    }

    func testSideboardAndUses() {
        XCTAssertEqual(SideboardRules.sideboardCount(lines), cases["sideboard_count"] as? Int)
        for c in cases["over_sideboard"] as! [[String: Any]] {
            XCTAssertEqual(SideboardRules.overSideboard(Self.lines(c["lines"]), format: c["format"] as! String), c["expect"] as? Int)
        }
        XCTAssertEqual(SideboardRules.uses(guide), cases["uses"] as? [String: Int])
    }

    func testSetKeepsOrder() {
        var m = SideboardGuide.Matchup(id: "a", name: "A")
        m.set("x", 2, on: .in); m.set("y", 1, on: .in); m.set("x", 3, on: .in)
        XCTAssertEqual(m.ins, [.init("x", 3), .init("y", 1)])
        m.set("x", 0, on: .in)
        XCTAssertEqual(m.ins, [.init("y", 1)])
    }

    func testPrint() throws {
        let p = cases["print"] as! [String: Any]
        let r = SideboardRules.printModel(deck: "Izzet Murktide", formatName: "Modern", date: "2026-11-04", lines: lines, guide: guide, format: "modern")
        XCTAssertEqual(r.sheets, p["sheets"] as? Int)
        let wantWarnings = (p["warnings"] as! [[String: Any]]).map { "\($0["code"]!):\($0["qty"]!)" }
        XCTAssertEqual(r.warnings.map { w -> String in
            switch w {
            case .considering(let n): "considering:\(n)"
            case .gone(let n): "gone:\(n)"
            case .sideboardOver(let n): "sideboard_over:\(n)"
            case .sheets(let n): "sheets:\(n)"
            }
        }, wantWarnings)
        let model = p["model"] as! [String: Any]
        XCTAssertEqual(r.model.sideboard.map { "\($0.0) \($0.1)" }, (model["sideboard"] as! [[Any]]).map { "\($0[0]) \($0[1])" })
        let html = try String(contentsOf: dir.appending(path: "guide.html"), encoding: .utf8)
        XCTAssertEqual(SideboardRules.html(r.model), html)
    }

    func testSheets() {
        for c in cases["sheets"] as! [[String: Any]] {
            let n = c["matchups"] as! Int
            let m = SideboardRules.PrintModel(deck: "", format: "", date: "", sideboard: Array(repeating: (1, "x"), count: 15),
                                              matchups: Array(repeating: .init(name: "m", ins: Array(repeating: (1, "a"), count: 5),
                                                                                  outs: Array(repeating: (1, "b"), count: 5), notes: String(repeating: "x", count: 120)), count: n))
            XCTAssertEqual(SideboardRules.sheets(m), c["expect"] as? Int, "\(n)")
        }
    }

    func testWireRoundTrip() throws {
        let data = try JSONEncoder().encode(guide)
        XCTAssertEqual(try JSONDecoder().decode(SideboardGuide.self, from: data), guide)
        XCTAssertEqual(SideboardGuide().wire, .null)
    }
}
