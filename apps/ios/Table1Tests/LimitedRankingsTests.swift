import XCTest
@testable import Table1

/* Ranking a Limited set (contract/cube-rankings-2026-10-21.md § Sets) and New in Insights pushes, against
   testdata/limited-rankings/cases.json: subject ids, rows from either kind of subject, sharing labels, push routes. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/limited-rankings/cases.json").standardized

private func cases() throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: casesURL)) as! [String: Any]
}

final class LimitedRankingsTests: XCTestCase {
    func testSubjectIds() throws {
        for c in try cases()["subjects"] as! [[String: Any]] {
            XCTAssertEqual(RankSubject.setId(c["set_key"] as! String), c["id"] as? String)
        }
        for c in try cases()["keys"] as! [[String: Any]] {
            XCTAssertEqual(RankSubject.setKey(c["id"] as? String), c["key"] as? String, "\(c["id"] ?? "nil")")
        }
    }

    func testRowsFromCubesAndSets() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for c in try cases()["rows"] as! [[String: Any]] {
            let data = try JSONSerialization.data(withJSONObject: c["json"]!)
            let row = try decoder.decode(RankingRow.self, from: data)
            XCTAssertEqual(row.listId, c["subject"] as? String)
            XCTAssertEqual(row.isSet, c["is_set"] as? Bool)
            if row.isSet { XCTAssertEqual(row.cube?.isSet, true); XCTAssertEqual(row.cube?.id, row.listId) }
        }
    }

    func testSharingLabels() throws {
        for c in try cases()["sharing"] as! [[String: Any]] {
            XCTAssertEqual(RankSubject.sharingLabel(c["sharing"] as! String, set: c["set"] as! Bool), c["label"] as? String)
        }
    }

    func testPushRoutes() throws {
        for c in try cases()["pushes"] as! [[String: Any]] {
            let info = c["info"] as! [String: Any]
            let got = PushRoutes.insights(info)
            if let want = c["route"] as? [String: String] {
                XCTAssertEqual(got, InsightsPush(section: want["section"]!, key: want["key"]!, what: want["what"]!), "\(info)")
            } else {
                XCTAssertNil(got, "\(info)")
            }
            // An Insights push is never read as a Collection or Account one.
            if info["kind"] as? String == "insights.new" { XCTAssertNil(PushRoutes.library(info)); XCTAssertNil(PushRoutes.route(info)) }
        }
    }

    func testRankableSetDetail() {
        let cube = RankableSet(key: "PWR-2510", name: "Arena Powered Cube · Oct 2025", released: "2025-10-30", kind: "cube", cards: 540,
                               pack: true, mine: 1, rankings: 3)
        XCTAssertEqual(cube.detail, "Arena cube · 540 cards · 3 rankings (1 yours)")
        XCTAssertEqual(cube.subjectId, "set:PWR-2510")
        let old = RankableSet(key: "FRA", name: "Foundations Remastered", released: "2026-09-23", kind: "set", cards: 281, pack: true, mine: 0, rankings: 0)
        XCTAssertEqual(old.detail, "281 cards")
        // A release day is a UTC day: west of UTC it read a day early ("Out Nov 3" for Nov 4).
        let zone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        defer { NSTimeZone.default = zone }
        let soon = RankableSet(key: "NHZ", name: "New Horizons", released: "2099-11-14", kind: "set", cards: 264, pack: false, mine: 0, rankings: 0)
        XCTAssertEqual(soon.detail, "Out Nov 14 · 264 cards")
    }

    func testLimitedPicker() throws {
        let c = try cases()
        for l in c["labels"] as! [[String: Any]] {
            XCTAssertEqual(LimitedPicker.label(l["key"] as! String, l["name"] as? String), l["label"] as? String)
        }
        let decoder = JSONDecoder()
        func sets(_ v: Any?) throws -> [RankableSet] { try decoder.decode([RankableSet].self, from: JSONSerialization.data(withJSONObject: v ?? [])) }
        for p in c["picker"] as! [[String: Any]] {
            let packs = (p["packs"] as! [[String: Any]]).map { (key: $0["key"] as! String, name: $0["name"] as? String) }
            let got = LimitedPicker.chips(packs: packs, rankable: try sets(p["rankable"]), today: p["today"] as! String)
            let want = (p["chips"] as! [[String: Any]]).map { LimitedPicker.Chip(key: $0["key"] as! String, label: $0["label"] as! String, pack: $0["pack"] as! Bool) }
            XCTAssertEqual(got, want, "\(p["today"]!)")
        }
        for s in c["soon"] as! [[String: Any]] {
            let set = try sets([s["set"]!])[0]
            XCTAssertEqual(LimitedPicker.soonText(set, today: s["today"] as! String), s["text"] as? String)
        }
    }
}
