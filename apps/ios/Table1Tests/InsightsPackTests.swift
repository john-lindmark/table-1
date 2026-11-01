import XCTest
@testable import Table1
import Supabase

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

    func testMatchupRowsAreEveryDiscernibleArchetype() throws {
        XCTAssertEqual(Insights.Matchups(archetypes: [1, 2], rows: [1, 2, 7, 0], cells: []).rowIds, [1, 2, 7, 0])
        XCTAssertEqual(Insights.Matchups(archetypes: [1, 2], cells: []).rowIds, [1, 2], "an older pack: the columns")
        XCTAssertEqual(Insights.Matchups(archetypes: [1, 2], rows: [], cells: []).rowIds, [1, 2])
        let p = try JSONDecoder().decode(Insights.ConstructedPack.self, from: Data(contentsOf: dir.appending(path: "constructed-modern.json")))
        XCTAssertEqual(p.matchups.archetypes.count, 10)
        XCTAssertEqual(p.matchups.rowIds.count, 23)
        XCTAssertEqual(Array(p.matchups.rowIds.prefix(10)), p.matchups.archetypes, "the columns lead the rows")
        XCTAssertEqual(p.matchups.rowIds.last, 0, "Other last")
        XCTAssertEqual(p.matchups.cell(11, 1)?.wins, 63, "Boros Land Destruction against the top archetype")
    }

    func testYoursFirstSharedCases() throws {
        struct Case: Decodable { let name: String; let rows: [Int]; let mine: Insights.Mine; let want: [[Want]] }
        enum Want: Decodable, Equatable {
            case id(Int), note(String), none
            init(from d: Decoder) throws {
                let c = try d.singleValueContainer()
                if c.decodeNil() { self = .none } else if let i = try? c.decode(Int.self) { self = .id(i) } else { self = .note(try c.decode(String.self)) }
            }
        }
        struct File: Decodable { let close: Double; let cases: [Case] }
        let f = try JSONDecoder().decode(File.self, from: Data(contentsOf: dir.appending(path: "yours-first.json")))
        XCTAssertEqual(Insights.close, f.close)
        for c in f.cases {
            let got = Insights.yoursFirst(c.rows, c.mine).map { [Want.id($0.a), $0.note.map(Want.note) ?? .none] }
            XCTAssertEqual(got, c.want, c.name)
        }
        XCTAssertEqual(Insights.yoursFirst([1, 0], nil).map(\.a), [1, 0])
    }

    func testDeckInsightSharedCases() throws {
        struct Want: Decodable, Equatable { let title: String?; let win: String?; let change: String?; let good: [String]; let bad: [String]; let note: String? }
        struct Case: Decodable { let name: String; let answer: Insights.DeckInsightAnswer; let want: Want }
        struct File: Decodable { let min: Int; let cases: [Case] }
        let f = try JSONDecoder().decode(File.self, from: Data(contentsOf: dir.appending(path: "deck-insight.json")))
        XCTAssertEqual(Insights.deckMin, f.min)
        for c in f.cases {
            let d = Insights.deckInsight(c.answer)
            XCTAssertEqual(Want(title: d.title, win: d.win, change: d.change, good: d.good, bad: d.bad, note: d.note), c.want, c.name)
        }
    }

    func testGridFollowsThePickedWindow() throws {
        let data = try Data(contentsOf: dir.appending(path: "constructed-modern.json"))
        let old = try JSONDecoder().decode(Insights.ConstructedPack.self, from: data)
        XCTAssertEqual(old.grid(.big, days: 30).m, old.matchups)
        XCTAssertEqual(old.grid(.big, days: 30).scope, "All events, last 90 days")
        // the same pack with a grid in Big events, 30 days
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var tiers = json["tiers"] as! [String: Any], big = tiers["big"] as! [String: Any], windows = big["windows"] as! [String: Any]
        var w30 = windows["30"] as! [String: Any]
        w30["matchups"] = ["archetypes": [1], "rows": [1, 0], "cells": [[1, 0, 3, 2, 0]]]
        windows["30"] = w30; big["windows"] = windows; tiers["big"] = big; json["tiers"] = tiers
        let p = try JSONDecoder().decode(Insights.ConstructedPack.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(p.grid(.big, days: 30).m.rowIds, [1, 0])
        XCTAssertEqual(p.grid(.big, days: 30).scope, "Big events, last 30 days")
        XCTAssertEqual(p.grid(.all, days: 30).scope, "All events, last 90 days")
    }

    func testBanStudyUsesTheLongestEndedWindow() {
        let s = Insights.AShare(a: 1, share: 0.2)
        let b = Insights.BanStudy(change: 1, on: "2026-05-18", before: [s], after: ["14": [s], "30": [s]], losers: [], gainers: [], replacements: [],
                                  settled_days: nil, brief: nil)
        XCTAssertEqual(b.afterWindow?.days, 30)
        let none = Insights.BanStudy(change: 1, on: "2026-05-18", before: [], after: [:], losers: [], gainers: [], replacements: [], settled_days: nil, brief: nil)
        XCTAssertNil(none.afterWindow)
    }

    func testExampleFinish() {
        let main60 = #"[["Lightning Bolt", 4], ["Mountain", 56]]"#, short = #"[["Lightning Bolt", 4]]"#
        func f(_ tier: String, _ rank: Int?, _ on: String, _ main: String = main60) throws -> Insights.ArchetypePage.Finish {
            let json = #"{"event": "E", "on": "\#(on)", "players": 64, "tier": "\#(tier)", "rank": \#(rank.map(String.init) ?? "null"), "url": null, "main": \#(main), "side": []}"#
            return try JSONDecoder().decode(Insights.ArchetypePage.Finish.self, from: Data(json.utf8))
        }
        XCTAssertEqual(Insights.exampleFinish([try f("regular", 1, "2026-10-20"), try f("large", 5, "2026-10-01"), try f("large", 2, "2026-09-20")]), 2)
        XCTAssertEqual(Insights.exampleFinish([try f("major", 3, "2026-10-01"), try f("major", 3, "2026-10-10")]), 1)
        XCTAssertEqual(Insights.exampleFinish([try f("major", 1, "2026-10-01", short), try f("small", nil, "2026-10-02")]), 1)
        XCTAssertNil(Insights.exampleFinish([]))
        XCTAssertEqual([1, 2, 3, 4, 11, 12, 13, 21, 22, 101].map(Insights.place), ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "101st"])
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
        XCTAssertEqual(Insights.sourcesCredit(["melee", "topdeck", "mtgo"]).label, "Results from Magic Online, TopDeck.gg and Melee")
        XCTAssertEqual(Insights.sourcesCredit(["melee", "topdeck", "mtgo"]).url.host, "topdeck.gg")
        XCTAssertEqual(Insights.sourcesCredit(["mtgo", "melee"]).label, "Results from Magic Online and Melee")
        XCTAssertEqual(Insights.sourcesCredit(["melee"]).url.host, "melee.gg")
        XCTAssertEqual(Insights.sourcesCredit([]).label, "Results from Magic Online")
        XCTAssertEqual(Insights.formats.map(\.key), ["standard", "pioneer", "modern", "legacy", "vintage", "pauper", "canlander"])
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
        XCTAssertTrue(v.colors?.contains { !$0.s.isEmpty } == true, "deck colors carry their splashes")
    }

    func testDeckColorNames() {
        XCTAssertEqual(Insights.colorsName("UB", ""), "Dimir UB")
        XCTAssertEqual(Insights.colorsName("UB", "R"), "Dimir UB + r")
        XCTAssertEqual(Insights.colorsName("WUB", ""), "Esper WUB")
        XCTAssertEqual(Insights.colorsName("WRG", "U"), "Naya WRG + u")
        XCTAssertEqual(Insights.colorsName("WUBR", ""), "Four-color WUBR")
    }

    /// The format page's rows (testdata/insights/parts.json, also web insights.test.ts and Android InsightsPackTest).
    func testFormatParts() throws {
        struct Cases: Decodable {
            struct Part: Decodable { let key, title, detail: String }
            struct Case: Decodable { let format: String; let tier: Insights.Tier; let days: Int; let parts: [Part] }
            let cases: [Case]
        }
        let c = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: dir.appending(path: "parts.json")))
        for k in c.cases {
            let p = try JSONDecoder().decode(Insights.ConstructedPack.self, from: Data(contentsOf: dir.appending(path: "constructed-\(k.format).json")))
            XCTAssertEqual(Insights.formatParts(p, tier: k.tier, days: k.days),
                           k.parts.map { Insights.Part(key: $0.key, title: $0.title, detail: $0.detail) }, "\(k.format) \(k.tier) \(k.days)")
        }
    }
}

/// Insights picks follow the account: testdata/insights-picks/cases.json, shared with web and Android.
final class InsightsPicksTests: XCTestCase {
    private struct Cases: Decodable {
        struct W: Decodable { let name: String; let held: [String: AnyJSON]?; let picks: [String: AnyJSON]; let want: [String: AnyJSON] }
        struct R: Decodable { let name: String; let stored: [String: AnyJSON]; let want: Insights.Picks }
        let write: [W]
        let read: [R]
    }

    private func cases() throws -> Cases {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../testdata/insights-picks/cases.json").standardized
        return try JSONDecoder().decode(Cases.self, from: Data(contentsOf: url))
    }

    func testWriteSharedCases() throws {
        for c in try cases().write {
            XCTAssertEqual(Insights.Picks.write(Insights.Picks.read(c.picks), held: c.held), c.want, c.name)
        }
    }

    func testReadSharedCases() throws {
        for c in try cases().read { XCTAssertEqual(Insights.Picks.read(c.stored), c.want, c.name) }
    }

    func testReuseLoadOnlyWithThePackOnScreen() {
        let at = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(Insights.reuseLoad(loadedAt: nil, now: at, packOnScreen: true), "never loaded")
        XCTAssertTrue(Insights.reuseLoad(loadedAt: at, now: at + 60, packOnScreen: true))
        XCTAssertFalse(Insights.reuseLoad(loadedAt: at, now: at + 60, packOnScreen: false), "index in, pack cut short")
        XCTAssertFalse(Insights.reuseLoad(loadedAt: at, now: at + 600, packOnScreen: true), "ten minutes on")
    }
}
