import XCTest
@testable import Table1

/* Popular cubes (contract/cube-rankings-2026-10-21.md § Popular cubes) against testdata/popular-cubes/cases.json: a cube's
   row detail and the word a ranked subject goes by. Shared with web popularCubes.test.ts and Android PopularCubesTest. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/popular-cubes/cases.json").standardized

final class PopularCubesTests: XCTestCase {
    private func cases() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: casesURL)) as! [String: Any]
    }

    func testDetail() throws {
        for c in try cases()["detail"] as! [[String: Any]] {
            var cube = c["cube"] as! [String: Any]
            cube["url"] = "https://example.com"
            let decoded = try JSONDecoder().decode(PopularCube.self, from: JSONSerialization.data(withJSONObject: cube))
            XCTAssertEqual(decoded.detail, c["want"] as? String)
            XCTAssertEqual(decoded.subjectId, "set:\(decoded.key)")
        }
    }

    func testNoun() throws {
        for c in try cases()["noun"] as! [[String: Any]] {
            XCTAssertEqual(RankSubject.noun(c["kind"] as? String), c["want"] as? String, "\(c["kind"] ?? "nil")")
        }
    }

    func testAPopularSubjectReadsAsACube() throws {
        let json = #"{"id": "set:PLSV", "set": "PLSV", "kind": "popular", "name": "PowerLSV", "curator": "LSV", "mine": false, "can_see": true}"#
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        let cube = try d.decode(RankingCube.self, from: Data(json.utf8))
        XCTAssertTrue(cube.isSet)
        XCTAssertEqual(cube.noun, "cube")
        XCTAssertEqual(cube.curator, "LSV")
    }
}
