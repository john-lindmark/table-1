import XCTest
@testable import Table1

/* Insights packs (contract/insights-2026-10-24.md § Packs) as the server builds them: testdata/insights holds
   constructed packs built from real MTGO pages and a Limited pack from 17Lands data (tools/insights/). */

private let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../testdata/insights").standardized

final class InsightsPackTests: XCTestCase {
    func testConstructedPacksDecode() throws {
        for f in ["standard", "pioneer", "modern", "pauper"] {
            let p = try JSONDecoder().decode(Insights.ConstructedPack.self, from: Data(contentsOf: dir.appending(path: "constructed-\(f).json")))
            XCTAssertEqual(p.format, f)
            XCTAssertEqual(p.archetypes.first?.id, 0, "Other comes first")
            for t in Insights.Tier.allCases {
                let v = try XCTUnwrap(p.view(t), "\(f) \(t)")
                XCTAssertEqual(Set(v.windows.keys), ["7", "14", "30", "90"])
                XCTAssertTrue(v.series.lines.allSatisfy { $0.v.count == v.series.days }, "\(f) \(t): one value a day")
                for s in v.windows["30"]!.share { XCTAssertNotNil(p.archetype(s.a), "every share names a known archetype") }
            }
        }
    }

    func testModernNames() throws {
        let p = try JSONDecoder().decode(Insights.ConstructedPack.self, from: Data(contentsOf: dir.appending(path: "constructed-modern.json")))
        XCTAssertEqual(p.name(0), "Other")
        XCTAssertEqual(p.name(-99), "Other")
        XCTAssertTrue(p.changes.contains { $0.kind == "ban" && $0.words.hasPrefix("Banned: ") })
    }

    func testMatchupCellsReadBothWays() {
        let m = Insights.Matchups(archetypes: [1, 2], cells: [[1, 2, 31, 22, 1]])
        XCTAssertEqual(m.cell(1, 2)?.wins, 31)
        XCTAssertEqual(m.cell(2, 1)?.wins, 22)
        XCTAssertEqual(m.cell(2, 1)?.losses, 31)
        XCTAssertNil(m.cell(1, 3))
    }

    func testBanStudyUsesTheLongestEndedWindow() {
        let s = Insights.AShare(a: 1, share: 0.2)
        let b = Insights.BanStudy(change: 1, on: "2026-05-18", before: [s], after: ["14": [s], "30": [s]], losers: [], gainers: [], replacements: [],
                                  settled_days: nil, brief: nil)
        XCTAssertEqual(b.afterWindow?.days, 30)
        let none = Insights.BanStudy(change: 1, on: "2026-05-18", before: [], after: [:], losers: [], gainers: [], replacements: [], settled_days: nil, brief: nil)
        XCTAssertNil(none.afterWindow)
    }

    func testHiddenPickers() {
        let all = ["standard", "pioneer", "modern", "pauper", "canlander"]
        XCTAssertEqual(Insights.visibleKeys(all, ["pioneer", "canlander"]), ["standard", "modern", "pauper"])
        XCTAssertEqual(Insights.visibleKeys(all, all), all)
        XCTAssertTrue(Insights.canHide(all, ["pioneer"], "modern"))
        XCTAssertFalse(Insights.canHide(["modern", "pauper"], ["pauper"], "modern"))
        XCTAssertFalse(Insights.canHide(["modern"], [], "modern"))
    }

    func testPointsChanges() {
        let c = Insights.Change(id: 9, on: "2026-10-26", kind: "points", cards: ["Mana Crypt"], set_code: nil, note: "Mana Crypt 3 → 4, Gush 0 → 1", url: nil)
        XCTAssertEqual(c.words, "Points: Mana Crypt 3 → 4, Gush 0 → 1")
        XCTAssertTrue(c.isBan)
        XCTAssertEqual(Insights.bansTitle(["points", "points"]), "Points changes")
        XCTAssertEqual(Insights.bansTitle(["ban", "unban"]), "Bans and unbans")
    }

    func testSourcesCredit() {
        XCTAssertEqual(Insights.sourcesCredit(["mtgo"]).label, "Results from Magic Online")
        XCTAssertEqual(Insights.sourcesCredit(["mtgo", "topdeck"]).label, "Results from Magic Online and TopDeck.gg")
        XCTAssertEqual(Insights.sourcesCredit(["topdeck"]).label, "Results from TopDeck.gg")
        XCTAssertEqual(Insights.sourcesCredit(["topdeck"]).url.host, "topdeck.gg")
        XCTAssertEqual(Insights.formats.map(\.key), ["standard", "pioneer", "modern", "pauper", "canlander"])
    }

    func testChangeWords() {
        let c = Insights.Change(id: 1, on: "2026-05-18", kind: "unban", cards: ["A", "B", "C", "D"], set_code: nil, note: nil, url: nil)
        XCTAssertEqual(c.words, "Unbanned: A, B, C and others")
        XCTAssertEqual(Insights.Change(id: 2, on: "2026-10-02", kind: "set_release", cards: [], set_code: "fra", note: "Reality Fracture", url: nil).words,
                       "Released: Reality Fracture")
    }

    func testLimitedPackDecodes() throws {
        let p = try JSONDecoder().decode(Insights.LimitedPack.self, from: Data(contentsOf: dir.appending(path: "limited-FRA.json")))
        XCTAssertEqual(p.set_code, "FRA")
        XCTAssertEqual(p.credit.name, "17Lands")
        let v = try XCTUnwrap(p.events["PremierDraft"]?.groups["all"])
        XCTAssertGreaterThan(v.games, 100_000)
        XCTAssertTrue(v.cards.contains { $0.gih != nil && $0.c != nil })
        XCTAssertTrue(v.cards.contains { $0.ata != nil }, "draft data gives the pick taken at")
        XCTAssertTrue(v.pairs.contains { $0.p == "3C" })
        XCTAssertTrue(v.colors?.contains { !$0.s.isEmpty } == true, "deck colours carry their splashes")
    }

    func testDeckColourNames() {
        XCTAssertEqual(Insights.colorsName("UB", ""), "Dimir UB")
        XCTAssertEqual(Insights.colorsName("UB", "R"), "Dimir UB + r")
        XCTAssertEqual(Insights.colorsName("WUB", ""), "Esper WUB")
        XCTAssertEqual(Insights.colorsName("WRG", "U"), "Naya WRG + u")
        XCTAssertEqual(Insights.colorsName("WUBR", ""), "Four-colour WUBR")
    }
}
