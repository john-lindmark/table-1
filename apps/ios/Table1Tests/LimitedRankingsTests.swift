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
    }
}
