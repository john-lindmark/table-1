import XCTest
@testable import Table1

/* Sync a cube with Cube Cobra (Library/CubeSync.swift) against testdata/cube-sync/cases.json. */

private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/cube-sync/cases.json").standardized

final class CubeSyncTests: XCTestCase {
    /// [card, board, qty, finish?, lang?, cond?] → an entry.
    private func entry(_ a: Any) -> CardList.Entry {
        let e = a as! [Any]
        return CardList.Entry(cardId: e[0] as! String, board: e[1] as! String, qty: e[2] as! Int,
                              finish: e.count > 3 ? e[3] as! String : "nonfoil", lang: e.count > 4 ? e[4] as! String : "en",
                              cond: e.count > 5 ? e[5] as! String : "NM")
    }

    private func line(_ a: Any) -> CubeSync.Line {
        let d = a as! [String: Any]
        return CubeSync.Line(board: d["board"] as! String, cardId: d["card"] as! String, finish: d["finish"] as! String,
                             lang: d["lang"] as! String, cond: d["cond"] as? String ?? "NM", qty: d["qty"] as! Int)
    }

    func testSharedCases() throws {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: casesURL)) as? [String: Any])
        let printings = (root["printings"] as! [String: [String: String]]).mapValues { CubeSync.Printing(oracle: $0["oracle"]!, lang: $0["lang"]!) }
        let cases = root["cases"] as! [[String: Any]]
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let name = c["name"] as! String
            let want = c["want"] as! [String: Any]
            let r = CubeSync.diff(current: (c["current"] as! [Any]).map(entry), incoming: (c["incoming"] as! [Any]).map(entry), printings: printings)
            XCTAssertEqual(r.into, (want["in"] as! [Any]).map(line), name)
            XCTAssertEqual(r.out, (want["out"] as! [Any]).map(line), name)
            XCTAssertEqual(r.changed, (want["changed"] as! [[String: Any]]).map {
                CubeSync.Changed(board: $0["board"] as! String, fromCard: $0["from_card"] as! String, fromFinish: $0["from_finish"] as! String,
                                 fromLang: $0["from_lang"] as! String, toCard: $0["to_card"] as! String, toFinish: $0["to_finish"] as! String,
                                 toLang: $0["to_lang"] as! String, qty: $0["qty"] as! Int)
            }, name)
            XCTAssertEqual(r.same, want["same"] as! Int, name)
            XCTAssertEqual(r.entries, (want["entries"] as! [Any]).map(entry), name)
            XCTAssertEqual(r.summary, c["summary"] as! String, name)
        }
    }

    func testCubeIdFromLinks() {
        XCTAssertEqual(CubeSync.cubeId("https://cubecobra.com/cube/list/lindmark"), "lindmark")
        XCTAssertEqual(CubeSync.cubeId("https://cubecobra.com/cube/overview/abc-1"), "abc-1")
        XCTAssertEqual(CubeSync.cubeId("https://www.cubecobra.com/c/xyz"), "xyz")
        XCTAssertNil(CubeSync.cubeId("https://moxfield.com/decks/abc"))
        XCTAssertNil(CubeSync.cubeId(nil))
    }

    /// The device cache keeps a list's seq and link across launches.
    func testCacheKeepsSeqAndLink() throws {
        var l = CardList(id: "a", kind: .cube, name: "C", format: "vintage", versions: [.init(number: 1, at: .now, note: "x", entries: [])])
        l.seq = 42
        l.sourceUrl = "https://cubecobra.com/cube/list/a"
        let back = ListDTO(l).list
        XCTAssertEqual(back?.seq, 42)
        XCTAssertEqual(back?.sourceUrl, "https://cubecobra.com/cube/list/a")
    }
}
