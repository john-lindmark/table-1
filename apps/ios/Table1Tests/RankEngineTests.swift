import XCTest
@testable import Table1

/* The server's engine file run in JavaScriptCore (Library/RankEngine.swift; contract/cube-rankings-2026-10-21.md § The
   engine as a file): testdata/cube-ranking/rank-engine.js, the file tools/rank-engine/build.mjs last built, replays every
   shared run through RankingState with the file deciding, screen by screen and summary by summary. And when the file's
   rules aren't newer than ours, the app keeps its own engine. */

private let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../testdata/cube-ranking").standardized

final class RankEngineTests: XCTestCase {
    private var cases: [String: Any] = [:]
    private var cards: [String: RankJob] = [:]
    private var code = ""

    override func setUpWithError() throws {
        cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: "cases.json"))) as? [String: Any])
        let cube = try XCTUnwrap(cases["cube"] as? [String: Any])
        cards = try XCTUnwrap(cube["category"] as? [String: String]).compactMapValues { RankJob(rawValue: $0) }
        code = try String(contentsOf: dir.appending(path: "rank-engine.js"), encoding: .utf8)
    }

    override func tearDown() { RankEngine.shared.unload() }

    private func manifest(rules: String, api: Int = RankEngine.api) -> RankEngine.Manifest {
        RankEngine.Manifest(api: api, rules: rules, version: "rank-test", file: "rank-test.js", sha256: "", bytes: nil)
    }

    func testRulesMatchTheReference() {
        XCTAssertEqual(CubeRanking.rules, cases["rules"] as? String)
    }

    func testTheFileReplaysEveryRun() throws {
        XCTAssertTrue(RankEngine.shared.use(manifest(rules: CubeRanking.rules), code: code, from: "test", force: true))
        let jobs = ["W", "U", "B", "R", "G", "M", "C", "L", "F"]
        for run in cases["runs"] as! [[String: Any]] {
            let label = String((run["id"] as! String).suffix(2))
            var st = RankingState(rankingId: run["id"] as! String, cards: cards, log: [], depth: run["depth"] as! String, top: run["top"] as! Int)
            XCTAssertNotNil(st.js, "run \(label) runs in the file")
            for (i, step) in (run["steps"] as! [[String: Any]]).enumerated() {
                let s = step["s"] as! String
                if s != "P" {
                    let session = st.session(RankJob(rawValue: s)!)
                    XCTAssertEqual(session.question?.map(st.id), step["question"] as? [String], "run \(label) step \(i)")
                    XCTAssertEqual(session.check, step["check"] as? Bool ?? false, "run \(label) step \(i) check")
                }
                st = st.appending(RankScreen(s: s, o: step["answer"] as! [String]))
                XCTAssertNotNil(st.js)
            }
            let summary = run["summary"] as! [String: [String: Any]]
            for job in jobs {
                guard let want = summary[job] else { continue }
                let s = st.session(RankJob(rawValue: job)!)
                XCTAssertEqual(s.top.map(st.id), want["top"] as! [String], "run \(label) \(job) top")
                XCTAssertEqual(s.done, want["done"] as! Bool, "run \(label) \(job) done")
                XCTAssertEqual(s.checked, want["checked"] as! Int, "run \(label) \(job) checked")
                XCTAssertEqual(s.question?.map(st.id), want["question"] as? [String], "run \(label) \(job) question")
            }
        }
    }

    func testOurOwnRulesKeepOurEngine() {
        XCTAssertFalse(RankEngine.shared.use(manifest(rules: CubeRanking.rules), code: code, from: "test"))
        XCTAssertFalse(RankEngine.shared.use(manifest(rules: "2026-01-01"), code: code, from: "test"))
        XCTAssertFalse(RankEngine.shared.active)
        XCTAssertNil(RankingState(rankingId: "x", cards: cards, log: [], depth: "half", top: 20).js)
    }

    func testAnotherApiOrABrokenFileIsRefused() {
        XCTAssertFalse(RankEngine.shared.use(manifest(rules: "2099-01-01", api: RankEngine.api + 1), code: code, from: "test"))
        XCTAssertFalse(RankEngine.shared.use(manifest(rules: "2099-01-01"), code: "globalThis.T1Rank = {api: 1, rules: '2099-01-01', selfTest() { return false }}", from: "test"))
        XCTAssertFalse(RankEngine.shared.use(manifest(rules: "2099-01-01"), code: "this is not javascript", from: "test"))
        XCTAssertFalse(RankEngine.shared.active)
    }

    /// The file's rules must be the manifest's: a file built from other rules than it claims isn't used.
    func testTheFileMustCarryTheManifestsRules() {
        XCTAssertFalse(RankEngine.shared.use(manifest(rules: "2099-01-01"), code: code, from: "test"))
    }
}
