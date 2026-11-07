import XCTest
@testable import Table1

/* Cube rankings engine (Library/CubeRanking.swift) against the shared cases in testdata/cube-ranking/cases.json, which
   the reference make_cases.py writes: replaying two runs screen by screen, their lists, comparisons, why-chains, redo,
   a contradiction and a card that left the cube, and the estimates. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/cube-ranking/cases.json").standardized

final class CubeRankingTests: XCTestCase {
    private var cases: [String: Any] = [:]
    private var cards: [String: RankJob] = [:]

    override func setUpWithError() throws {
        cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: casesURL)) as? [String: Any])
        let cube = try XCTUnwrap(cases["cube"] as? [String: Any])
        let cats = try XCTUnwrap(cube["category"] as? [String: String])
        cards = cats.compactMapValues { RankJob(rawValue: $0) }
    }

    private var runs: [[String: Any]] { cases["runs"] as! [[String: Any]] }

    private func log(_ run: [String: Any]) -> [RankScreen] {
        (run["steps"] as! [[String: Any]]).map { RankScreen(s: $0["s"] as! String, o: $0["answer"] as! [String]) }
    }

    private func state(_ run: [String: Any], _ log: [RankScreen]) -> RankingState {
        RankingState(rankingId: run["id"] as! String, cards: cards, log: log, depth: run["depth"] as! String, top: run["top"] as! Int)
    }

    private func checkSummary(_ st: RankingState, _ want: [String: Any], _ label: String) {
        XCTAssertEqual(Set(st.jobs.map(\.rawValue) + ["F"]), Set(want.keys), label)
        for (key, v) in want {
            let w = v as! [String: Any]
            let s = st.session(RankJob(rawValue: key)!)
            XCTAssertEqual(s.top.map(st.id), w["top"] as! [String], "\(label) \(key) top")
            XCTAssertEqual(s.done, w["done"] as! Bool, "\(label) \(key) done")
            XCTAssertEqual(s.target, w["target"] as! Int, "\(label) \(key) target")
            XCTAssertEqual(s.size, w["size"] as! Int, "\(label) \(key) size")
            XCTAssertEqual(st.knowledge.perJob[key] ?? 0, w["screens"] as! Int, "\(label) \(key) screens")
            XCTAssertEqual(s.question?.map(st.id), w["question"] as? [String], "\(label) \(key) question")
            if let p = w["pinned"] as? [String] { XCTAssertEqual(s.pinned.map(st.id), p, "\(label) \(key) pinned") }
            XCTAssertEqual(s.waiting.map(st.id), w["waiting"] as? [String] ?? [], "\(label) \(key) waiting")
            XCTAssertEqual(s.check, w["check"] as? Bool ?? false, "\(label) \(key) check")
            XCTAssertEqual(s.checked, w["checked"] as? Int ?? -1, "\(label) \(key) checked")
        }
    }

    /// The cube changes after a ranking finished: removed cards leave the lists and new ones wait, the order holds, and a
    /// re-rank asks only what it must until every list is whole again.
    func testCubeChange() {
        let cc = cases["cubeChange"] as! [String: Any]
        let run = runs.first { $0["id"] as? String == cc["id"] as? String }!
        let removed = Set(cc["removed"] as! [String])
        var cube = cards.filter { !removed.contains($0.key) }
        for (c, j) in cc["added"] as! [String: String] { cube[c] = RankJob(rawValue: j) }
        let fresh = Set(cc["new"] as! [String])
        func at(_ l: [RankScreen]) -> RankingState {
            RankingState(rankingId: cc["id"] as! String, cards: cube, log: l, depth: cc["depth"] as! String, top: cc["top"] as! Int, fresh: fresh)
        }
        var l = log(run)
        checkSummary(at(l), cc["before"] as! [String: Any], "before")
        XCTAssertEqual(at(l).waiting, fresh.sorted())
        let start = at(l)
        var st = start
        for step in cc["steps"] as! [[String: Any]] {
            let job = RankJob(rawValue: step["s"] as! String)!
            let s = st.session(job)
            XCTAssertEqual(s.question?.map(st.id), step["question"] as? [String], "change screen \(step["at"]!)")
            XCTAssertEqual(s.pinned.map(st.id), step["pinned"] as! [String])
            XCTAssertEqual(s.waiting.map(st.id), step["waiting"] as! [String])
            XCTAssertEqual(s.top.map(st.id), step["top"] as! [String], "the list stays whole at \(step["at"]!)")
            let screen = RankScreen(s: job.rawValue, o: step["answer"] as! [String])
            st = st.appending(screen)
            l.append(screen)
        }
        checkSummary(at(l), cc["after"] as! [String: Any], "after")
        XCTAssertEqual(at(l).waiting, [])
        let want = (cc["changes"] as! [[Any]]).map { r in [r[0] as! String, r[1] as! String, (r[2] as? Int).map(String.init) ?? "-", (r[3] as? Int).map(String.init) ?? "-"] }
        let got = RankChange.diff(start.places, at(l).places).map { [$0.s, $0.c, $0.f.map(String.init) ?? "-", $0.to.map(String.init) ?? "-"] }
        XCTAssertEqual(got, want)
    }

    func testCubeChangeOfABaseline() {
        let c = CubeChange(cubeCards: ["a", "B", "c"], baseline: ["b", "c", "d"])
        XCTAssertEqual(c.added, ["a"])
        XCTAssertEqual(c.removed, ["d"])
        XCTAssertTrue(CubeChange(cubeCards: ["a"], baseline: nil).isEmpty, "no baseline yet: nothing to say")
    }

    func testReplayEveryScreen() {
        for run in runs {
            var st = state(run, [])
            for step in run["steps"] as! [[String: Any]] {
                let job = RankJob(rawValue: step["s"] as! String)!
                XCTAssertEqual(st.knowledge.screens, step["at"] as! Int)
                if job == .pick {
                    let pack = CubeRanking.pack(rankingId: run["id"] as! String, st.knowledge)
                    XCTAssertEqual(pack, step["pack"] as! [String], "pack at \(step["at"]!)")
                    let answer = step["answer"] as! [String]
                    XCTAssertEqual(CubeRanking.disagreements(st.knowledge, picked: answer[0], pack: pack), step["disagree"] as! [String])
                    st = st.appending(RankScreen(s: "P", o: answer))
                    continue
                }
                let s = st.session(job)
                XCTAssertEqual(s.question?.map(st.id), step["question"] as? [String], "\(run["id"]!) screen \(step["at"]!)")
                XCTAssertEqual(s.pinned.map(st.id), step["pinned"] as! [String], "\(run["id"]!) pinned \(step["at"]!)")
                XCTAssertEqual(s.check, step["check"] as? Bool ?? false, "\(run["id"]!) check \(step["at"]!)")
                st = st.appending(RankScreen(s: job.rawValue, o: step["answer"] as! [String]))
            }
            checkSummary(st, run["summary"] as! [String: Any], run["id"] as! String)
            checkSummary(state(run, log(run)), run["summary"] as! [String: Any], "rebuilt")
            if let want = run["contradicted"] as? [String: [[String]]] {
                let got = st.knowledge.contradicted
                XCTAssertEqual(Set(got.keys.map(String.init)), Set(want.keys))
                for (k, pairs) in got { XCTAssertEqual(pairs.map { [st.id($0.0), st.id($0.1)] }, want[String(k)]) }
            }
        }
    }

    func testPickWins() {
        let run = runs[2]
        let w = cases["pickWins"] as! [String: Any]
        let l = log(run)
        let st = state(run, l)
        XCTAssertEqual(st.knowledge.screens, w["at"] as! Int)
        let pack = CubeRanking.pack(rankingId: run["id"] as! String, st.knowledge)
        XCTAssertEqual(pack, w["pack"] as! [String])
        let picked = w["picked"] as! String
        XCTAssertEqual(CubeRanking.disagreements(st.knowledge, picked: picked, pack: pack), w["disagree"] as! [String])
        let removed = CubeRanking.pickWins(cards: Array(cards.keys), log: l, picked: picked, pack: pack)
        XCTAssertEqual(removed, w["removed"] as! [Int])
        let after = state(run, l.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
                          + [RankScreen(s: "P", o: [picked] + pack.filter { $0 != picked })])
        checkSummary(after, w["after"] as! [String: Any], "pick wins")
        XCTAssertEqual(Self.changeRows(RankChange.diff(st.places, after.places)), (w["changes"] as! [[Any]]).map(Self.cells))
    }

    private static func changeRows(_ cs: [RankChange]) -> [[String]] {
        cs.map { [$0.s, $0.c, $0.f.map(String.init) ?? "<null>", $0.to.map(String.init) ?? "<null>"] }
    }

    func testCompare() {
        let a = state(runs[0], log(runs[0])), b = state(runs[1], log(runs[1]))
        for (key, v) in cases["compare"] as! [String: [String: Any]] {
            let job = RankJob(rawValue: key)!
            let c = CubeRanking.compare(a.knowledge, a.session(job), b.session(job), scope: a.scope(job))
            XCTAssertEqual(c.compared, v["compared"] as! Int, key)
            XCTAssertEqual(c.avgTenths, v["avgTenths"] as! Int, key)
            XCTAssertEqual(c.atLeast, v["atLeast"] as! Bool, key)
            func rows(_ g: [CubeRanking.Gap]) -> [[String]] { g.map { [$0.card, "\($0.a)", "\($0.aOut)", "\($0.b)", "\($0.bOut)", "\($0.gap)", "\($0.atLeast)"] } }
            XCTAssertEqual(rows(c.biggest), (v["biggest"] as! [[Any]]).map(Self.cells), "\(key) biggest")
            XCTAssertEqual(rows(c.oneSide), (v["oneSide"] as! [[Any]]).map(Self.cells), "\(key) one side")
        }
    }

    private static func cells(_ row: [Any]) -> [String] {
        row.map { v in
            if v is NSNull { return "<null>" }
            if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return "\(v)"
        }
    }

    func testWhy() {
        let run = runs[0]
        let l = log(run), st = state(run, l)
        for w in cases["why"] as! [[String: Any]] {
            let chain = CubeRanking.why(st.knowledge, l, hi: w["hi"] as! String, lo: w["lo"] as! String)
            let want = (w["chain"] as? [[Any]])?.map(Self.cells)
            XCTAssertEqual(chain?.map { [$0.winner, $0.loser, "\($0.screen)"] }, want)
        }
    }

    func testRedo() {
        let run = runs[0]
        let l = log(run), full = state(run, l)
        for r in cases["redo"] as! [[String: Any]] {
            let i = r["remove"] as! Int
            var rest = l
            rest.remove(at: i)
            let st = state(run, rest)
            XCTAssertEqual(st.knowledge.sameKnowledge(full.knowledge), r["changesNothing"] as! Bool, "redo \(i)")
            let job = RankJob(rawValue: r["session"] as! String)!
            XCTAssertEqual(CubeRanking.reaskOpen(st.knowledge, st.session(job), l[i].o), r["reaskOpen"] as! Bool, "reask \(i)")
            checkSummary(st, r["after"] as! [String: Any], "after redo \(i)")
            XCTAssertEqual(Self.changeRows(RankChange.diff(full.places, st.places)), (r["changes"] as! [[Any]]).map(Self.cells), "changes \(i)")
        }
    }

    func testContradictionAndRemovedCard() {
        let edge = cases["edge"] as! [String: Any]
        let screens = (edge["log"] as! [[String: Any]]).map { RankScreen(s: $0["s"] as! String, o: $0["o"] as! [String]) }
        let K = RankKnowledge(cards: Array(cards.keys), log: screens)
        var known: [[String]] = []
        for x in 0..<K.count { for y in K.beatsSet(x).members { known.append([K.ids[x], K.ids[y]]) } }
        XCTAssertEqual(known.sorted { $0.lexicographicallyPrecedes($1) }, edge["known"] as! [[String]])
    }

    func testEstimates() {
        let est = cases["estimates"] as! [String: [[Any]]]
        for row in est["sort"]! {
            let got = CubeRanking.expectedSort(row[0] as! Int, row[1] as! Int)
            XCTAssertLessThanOrEqual(abs(got - (row[2] as! Int)), 1, "sort \(row)")
        }
        for row in est["merge"]! {
            let got = CubeRanking.expectedMerge(row[0] as! [Int], row[1] as! Int)
            XCTAssertLessThanOrEqual(abs(got - (row[2] as! Int)), 1, "merge \(row)")
        }
    }

    func testFnv() {
        XCTAssertEqual(CubeRanking.fnv1a(""), 0x811C_9DC5)
        XCTAssertEqual(CubeRanking.fnv1a("a"), 0xE40C_292C)
    }
}
