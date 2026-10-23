import XCTest
@testable import Table1

/* Saving a ranking (Library/RankSync.swift) against the shared cases in testdata/ranking-save/cases.json, written by the
   reference make_cases.py; web rankSync.test.ts and Android RankSyncTest read the same file. */

final class RankSyncTests: XCTestCase {
    private struct Want: Decodable { let log: [RankScreen]; let add: [RankScreen]; let drop: [RankScreen]; let keep: Int; let removed: Int }
    private struct Case: Decodable { let name: String; let server: [RankScreen]; let adds: [RankScreen]; let drops: [RankScreen]; let want: Want }
    private struct File: Decodable { let cases: [Case] }

    func testSharedCases() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../testdata/ranking-save/cases.json").standardized
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(file.cases.count, 16)
        for c in file.cases {
            let p = RankSync.plan(server: c.server, adds: c.adds, drops: c.drops)
            XCTAssertEqual(p.log.map(RankSync.key), c.want.log.map(RankSync.key), c.name)
            XCTAssertEqual(p.add.map(RankSync.key), c.want.add.map(RankSync.key), c.name)
            XCTAssertEqual(p.drop.map(RankSync.key), c.want.drop.map(RankSync.key), c.name)
            XCTAssertEqual(p.keep, c.want.keep, c.name)
            XCTAssertEqual(p.removed, c.want.removed, c.name)
        }
    }

    func testWhatsWaitingSurvivesARelaunch() throws {
        RankPendingStore.directory = FileManager.default.temporaryDirectory.appending(path: "rank-pending-\(UUID().uuidString)")
        let s = RankScreen(s: "W", o: ["a", "b"], t: 1)
        var p = RankPending()
        p.adds = [s]
        p.drops = [RankScreen(s: "U", o: ["c", "d"], t: 2)]
        RankPendingStore.save("R1", p)
        XCTAssertEqual(RankPendingStore.load("R1"), p)
        XCTAssertEqual(RankPendingStore.load("r1"), p, "ids in any case")
        RankPendingStore.save("R1", RankPending())
        XCTAssertTrue(RankPendingStore.load("R1").isEmpty, "nothing waiting: the file goes")
    }

    func testSettleKeepsWhatWasDoneMeanwhile() {
        var p = RankPending()
        p.adds = [RankScreen(s: "W", o: ["a", "b"], t: 1)]
        let op = RankPending.Op(id: "x", rev: 3, count: 10, adds: 1, drops: 0, changes: 0)
        p.adds.append(RankScreen(s: "W", o: ["c", "d"], t: 2))  // locked in while the push was out
        p.drops.append(RankScreen(s: "W", o: ["a", "b"], t: 1)) // and the first one undone
        p.settle(op)
        XCTAssertEqual(p.adds.map(\.t), [2])
        XCTAssertEqual(p.drops.map(\.t), [1], "the undo of the screen just saved is still to be sent")
    }
}
