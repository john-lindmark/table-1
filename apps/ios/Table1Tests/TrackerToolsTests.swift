import XCTest
@testable import Table1

/* The life tracker's Options (contract/life-tracker-options-2026-10-20.md): dice, the chooser, Reset. */

/// SplitMix64, so every run rolls and picks the same.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class TrackerToolsTests: XCTestCase {
    func testDiceStayOnTheirFacesAndCoverThemAll() {
        var rng = Seeded(state: 1)
        for sides in Dice.sides {
            var seen = Set<Int>()
            for _ in 0..<200 {
                let rolls = Dice.roll(sides: sides, count: 3, using: &rng)
                XCTAssertEqual(rolls.count, 3)
                XCTAssertTrue(rolls.allSatisfy { (1...sides).contains($0) }, "D\(sides): \(rolls)")
                seen.formUnion(rolls)
            }
            XCTAssertEqual(seen, Set(1...sides), "every face of a D\(sides) comes up")
        }
    }

    func testDiceCountIsClamped() {
        var rng = Seeded(state: 2)
        XCTAssertEqual(Dice.roll(sides: 6, count: 0, using: &rng).count, 1)
        XCTAssertEqual(Dice.roll(sides: 6, count: 99, using: &rng).count, Dice.maxCount)
    }

    func testBreakdownOnlyForSeveralDice() {
        XCTAssertNil(Dice.breakdown([17]))
        XCTAssertEqual(Dice.breakdown([3, 5, 1]), "3 + 5 + 1")
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testChooserPicksTwoSecondsAfterTheLastFingerLands() {
        var c = Chooser()
        var rng = Seeded(state: 3)
        c.down(1, x: 10, y: 10, at: t0)
        XCTAssertNil(c.progress(at: t0.addingTimeInterval(5)), "one finger never picks")
        XCTAssertNil(c.tick(at: t0.addingTimeInterval(5), using: &rng))
        c.down(2, x: 50, y: 50, at: t0.addingTimeInterval(1))
        XCTAssertNil(c.tick(at: t0.addingTimeInterval(2.9), using: &rng), "not yet: the second finger reset the wait")
        XCTAssertEqual(c.progress(at: t0.addingTimeInterval(2)) ?? 0, 0.5, accuracy: 0.001)
        let winner = c.tick(at: t0.addingTimeInterval(3), using: &rng)
        XCTAssertNotNil(winner)
        XCTAssertTrue([1, 2].contains(winner!))
        XCTAssertEqual(c.winner, winner)
        XCTAssertNil(c.tick(at: t0.addingTimeInterval(4), using: &rng), "picks once")
    }

    func testMovingAFingerDoesNotRestartTheWait() {
        var c = Chooser()
        var rng = Seeded(state: 4)
        c.down(1, x: 0, y: 0, at: t0)
        c.down(2, x: 0, y: 0, at: t0)
        c.move(1, x: 40, y: 40)
        XCTAssertEqual(c.fingers.first?.x, 40)
        XCTAssertNotNil(c.tick(at: t0.addingTimeInterval(2), using: &rng))
    }

    func testLiftingAFingerBeforeThePickRestartsTheWait() {
        var c = Chooser()
        var rng = Seeded(state: 5)
        for id in 1...3 { c.down(id, x: 0, y: 0, at: t0) }
        c.up(3, at: t0.addingTimeInterval(1.5))
        XCTAssertEqual(c.fingers.map(\.id), [1, 2])
        XCTAssertNil(c.tick(at: t0.addingTimeInterval(3), using: &rng))
        XCTAssertNotNil(c.tick(at: t0.addingTimeInterval(3.5), using: &rng))
    }

    func testAfterThePickNewFingersAreIgnoredUntilEveryoneLifts() {
        var c = Chooser()
        var rng = Seeded(state: 6)
        c.down(1, x: 0, y: 0, at: t0)
        c.down(2, x: 0, y: 0, at: t0)
        _ = c.tick(at: t0.addingTimeInterval(2), using: &rng)
        c.down(3, x: 0, y: 0, at: t0.addingTimeInterval(2.5))
        XCTAssertEqual(c.fingers.count, 2, "late finger ignored")
        c.up(1, at: t0.addingTimeInterval(3))
        XCTAssertTrue(c.picked, "circles stay while a finger is still down")
        XCTAssertEqual(c.fingers.count, 2)
        c.up(3, at: t0.addingTimeInterval(3))
        XCTAssertTrue(c.picked, "the ignored finger lifting changes nothing")
        c.up(2, at: t0.addingTimeInterval(3.2))
        XCTAssertFalse(c.picked)
        XCTAssertTrue(c.fingers.isEmpty, "ready to go again")
    }

    func testEveryFingerCanWin() {
        var rng = Seeded(state: 7)
        var winners = Set<Int>()
        for _ in 0..<100 {
            var c = Chooser()
            for id in 1...4 { c.down(id, x: 0, y: 0, at: t0) }
            if let w = c.tick(at: t0.addingTimeInterval(2), using: &rng) { winners.insert(w) }
        }
        XCTAssertEqual(winners, [1, 2, 3, 4])
    }

    @MainActor
    func testResetMatchClearsLocalGamesButResetGameKeepsThem() async {
        let saved = UserDefaults.standard.data(forKey: "tracker.local.v1")
        defer { UserDefaults.standard.set(saved, forKey: "tracker.local.v1") }
        UserDefaults.standard.removeObject(forKey: "tracker.local.v1")
        let model = TrackerModel(matchId: nil)
        await model.start()
        model.tap(side: 0, counter: .life, delta: -20)
        try? await model.record(winner: 1, draw: false)
        model.tap(side: 0, counter: .life, delta: -3)
        model.tap(side: 1, counter: .poison, delta: 2)
        XCTAssertTrue(model.canResetMatch)

        model.resetGame()
        XCTAssertEqual(model.total(0, .life), 20)
        XCTAssertEqual(model.total(1, .poison), 0)
        XCTAssertEqual(model.games.count, 1, "Reset game keeps recorded games")

        model.tap(side: 0, counter: .life, delta: -3)
        model.resetMatch()
        XCTAssertTrue(model.games.isEmpty)
        XCTAssertEqual(model.currentGame, 1)
        XCTAssertEqual(model.total(0, .life), 20)
        XCTAssertFalse(model.canResetMatch)
    }
}
