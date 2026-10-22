import XCTest
@testable import Table1

/* RankingModel (Library/Rankings.swift) on the demo backend: locking in saves, undo and redo take screens out and ask
   their cards again, and the server's copy ends up equal to the device's. The engine itself is CubeRankingTests. */

@MainActor
final class RankingModelTests: XCTestCase {
    private let cube = "e7000000-0000-0000-0000-000000000001"
    private var cards: [String: RankJob] = [:]

    override func setUp() async throws {
        let ids = (0..<24).map { String(format: "00000000-0000-4000-8000-%012d", $0) }
        let jobs: [RankJob] = [.w, .u, .r]
        cards = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, jobs[$0 % 3]) })
        let resolved = cards
        RankingModel.resolve = { wanted in
            Dictionary(uniqueKeysWithValues: wanted.compactMap { id in resolved[id].map { (id, (RankCard(oracleId: id, name: id, printing: nil), $0)) } })
        }
        RankingsStore.shared.stop()
        RankingsStore.shared.demo = RankingsDemoBackend(cubeId: cube, cubeName: "Test cube", cards: ids, categories: cards)
    }

    override func tearDown() async throws {
        RankingsStore.shared.demo = nil
        RankingsStore.shared.stop()
    }

    private func settle(_ m: RankingModel) async {
        for _ in 0..<50 where m.unsaved { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testLockInUndoRedoSave() async throws {
        let row = try await RankingsStore.shared.create(listId: cube, name: "Mine", depth: "full", top: 50, sharing: "cube", ownCube: true)
        let m = RankingsStore.shared.model(row.id)
        await m.load()
        let st = try XCTUnwrap(m.state)
        XCTAssertEqual(st.jobs, [.w, .u, .r])

        // Lock in three White screens, best first by id.
        for _ in 0..<3 {
            let q = try XCTUnwrap(m.question(.w))
            m.lockIn(.w, order: q.cards.sorted { st.id($0) < st.id($1) })
        }
        await settle(m)
        XCTAssertEqual(m.log.count, 3)
        XCTAssertFalse(m.unsaved)
        var server = try RankingsStore.shared.demo!.get(row.id)
        XCTAssertEqual(server.log, m.log)
        XCTAssertEqual(server.row.screens, 3)

        // Undo takes the last White screen out and asks those cards again (a placement screen's order may differ).
        let last = m.log[2]
        m.undo(.w)
        await settle(m)
        XCTAssertEqual(m.log.count, 2)
        XCTAssertEqual(Set(m.question(.w)?.cards.map { m.state!.id($0) } ?? []), Set(last.o))
        server = try RankingsStore.shared.demo!.get(row.id)
        XCTAssertEqual(server.log, m.log)

        // Redo of the first screen: it comes out, the second stays.
        let second = m.log[1]
        m.redo(0)
        await settle(m)
        XCTAssertEqual(m.log, [second])
        server = try RankingsStore.shared.demo!.get(row.id)
        XCTAssertEqual(server.log, [second])

        // Finish White; progress reaches the list row.
        while let q = m.question(.w), !q.session.done {
            let st = m.state!
            m.lockIn(.w, order: q.cards.sorted { st.id($0) < st.id($1) })
        }
        await settle(m)
        XCTAssertEqual(m.list(.w)?.placed.map(\.oracleId), cards.filter { $0.value == .w }.keys.sorted())
        server = try RankingsStore.shared.demo!.get(row.id)
        XCTAssertEqual(server.row.sorted, 1)
        XCTAssertEqual(server.row.categories, 3)
        XCTAssertTrue(m.listText(.w).hasPrefix("1. 00000000-0000-4000-8000-000000000000\n"))
    }

    func testPicksAndChangeLog() async throws {
        let row = try await RankingsStore.shared.create(listId: cube, name: "Picks", depth: "full", top: 50, sharing: "cube", ownCube: true)
        let m = RankingsStore.shared.model(row.id)
        await m.load()
        // Sort White by id, so the ranking says lower ids are better.
        while let q = m.question(.w), !q.session.done {
            let st = m.state!
            m.lockIn(.w, order: q.cards.sorted { st.id($0) < st.id($1) })
        }
        await settle(m)
        XCTAssertFalse(m.changes.isEmpty, "placing White is in the change log")
        XCTAssertTrue(m.changes.allSatisfy { $0.by == "screen" && $0.f == nil && $0.to != nil })
        let saved = try RankingsStore.shared.demo!.get(row.id).changes
        XCTAssertEqual(saved, m.changes)

        // A pick against the ranking: the worst White card in the pack over the best.
        let pack = m.pack
        XCTAssertEqual(pack.count, 15)
        let whites = pack.filter { cards[$0] == .w }.sorted()
        try XCTSkipIf(whites.count < 2, "this pack has fewer than two White cards")
        let worst = whites.last!
        XCTAssertEqual(m.disagreements(picked: worst, pack: pack), pack.filter { cards[$0] == .w && $0 < worst })
        let removals = m.pickWinRemovals(picked: worst, pack: pack)
        XCTAssertFalse(removals.isEmpty)
        let before = m.changes.count
        m.pick(worst, pack: pack, wins: true)
        await settle(m)
        XCTAssertEqual(m.disagreements(picked: worst, pack: pack), [], "the pick won")
        XCTAssertEqual(m.log.last?.o.first, worst)
        XCTAssertTrue(m.changes[before...].allSatisfy { $0.by == "pick_win" })
        XCTAssertTrue(m.changes[before...].contains { $0.c == worst })
        XCTAssertEqual(try RankingsStore.shared.demo!.get(row.id).changes, m.changes)
        XCTAssertEqual(m.picks.count, 1)
    }

    func testRankSomeoneElsesCube() async throws {
        let theirs = RankingsDemoBackend.maraCube
        let listed = try await RankingsStore.shared.rankable()
        XCTAssertEqual(listed.map(\.id), [theirs])
        XCTAssertEqual(listed.first?.mine, 0)
        let cube = try await RankingsStore.shared.rankings(listId: theirs)
        XCTAssertTrue(cube.canRank)
        XCTAssertEqual(cube.cube?.mine, false)
        XCTAssertEqual(cube.rankings.map(\.mine), [false], "only Mara's own ranking so far")

        let row = try await RankingsStore.shared.create(listId: theirs, name: "My take", depth: "half", top: 50, sharing: "cube", ownCube: false)
        XCTAssertTrue(row.mine)
        let m = RankingsStore.shared.model(row.id)
        await m.load()
        XCTAssertTrue(m.mine, "it's your ranking even though the cube is Mara's")
        XCTAssertEqual(m.cube?.mine, false)
        let q = try XCTUnwrap(m.question(.w))
        m.lockIn(.w, order: q.cards)
        await settle(m)
        XCTAssertEqual(try RankingsStore.shared.demo!.get(row.id).log.count, 1)
        let after = try await RankingsStore.shared.rankable()
        XCTAssertEqual(after.first?.mine, 1)
        let yours = try await RankingsStore.shared.rankings(listId: nil).rankings
        let mineOfHers = yours.first { $0.id == row.id }
        XCTAssertNotNil(mineOfHers, "your rankings list it")
        XCTAssertEqual(mineOfHers?.cube?.name, RankingsDemoBackend.maraCubeName)
        XCTAssertEqual(mineOfHers?.cube?.mine, false)
    }

    func testSomeoneElsesRankingIsReadOnly() async throws {
        let m = RankingsStore.shared.model("d0000000-0000-0000-0000-0000000aa002")
        await m.load()
        XCTAssertFalse(m.mine)
        let before = m.log
        if let q = m.question(.final) { m.lockIn(.final, order: q.cards) }
        m.undo(.final)
        XCTAssertEqual(m.log, before)
    }

    /// The ranker shows each card as the cube has it; a printing the card data lacks keeps the usual art.
    func testCardsShowInTheCubesPrinting() {
        func p(_ id: String) -> CatalogPrinting {
            CatalogPrinting(cardId: id, oracleIdx: 0, ord: 0, set: "x", cn: "1", lang: "en", rarity: "c", finishes: "n",
                            releasedAt: "", imageTs: "", imageFaces: 1, printedName: "")
        }
        let cards = ["bolt": RankCard(oracleId: "bolt", name: "Lightning Bolt", printing: p("alpha-bolt")),
                     "opt": RankCard(oracleId: "opt", name: "Opt", printing: p("xln-opt")),
                     "goyf": RankCard(oracleId: "goyf", name: "Tarmogoyf", printing: p("fut-goyf"))]
        let shown = RankingModel.asInCube(cards, printings: ["bolt": "sld-bolt", "opt": "missing-opt"], found: ["sld-bolt": p("sld-bolt")])
        XCTAssertEqual(shown["bolt"]?.printing?.cardId, "sld-bolt", "the cube's Secret Lair Bolt, not Alpha")
        XCTAssertEqual(shown["opt"]?.printing?.cardId, "xln-opt", "a printing the card data doesn't have keeps the usual art")
        XCTAssertEqual(shown["goyf"]?.printing?.cardId, "fut-goyf", "no printing from the cube: the usual art")
    }
}
