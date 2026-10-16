import XCTest
@testable import Table1

/// Roto turn maths and state merging (contract/roto-2026-10-16.md). The seat formula must match
/// t1_private.roto_seat_index; the schedule must match events-engine/roundrobin.ts.
final class RotoTests: XCTestCase {
    // MARK: snake order

    func testSnakeOrderEightPlayers() {
        let first16 = (1...16).map { RotoMath.seat(players: 8, pickNo: $0, snake: true) }
        XCTAssertEqual(first16, [1, 2, 3, 4, 5, 6, 7, 8, 8, 7, 6, 5, 4, 3, 2, 1])
        XCTAssertEqual(RotoMath.seat(players: 8, pickNo: 17, snake: true), 1)
    }

    func testLastPickOfFortyFiveRounds() {
        // Round 45 (odd) goes 1 → 8, so pick 360 is seat 8.
        XCTAssertEqual(RotoMath.round(players: 8, pickNo: 360), 45)
        XCTAssertEqual(RotoMath.seat(players: 8, pickNo: 353, snake: true), 1)
        XCTAssertEqual(RotoMath.seat(players: 8, pickNo: 360, snake: true), 8)
    }

    func testSnakeOrderSevenAndTwoPlayers() {
        XCTAssertEqual((1...14).map { RotoMath.seat(players: 7, pickNo: $0, snake: true) },
                       [1, 2, 3, 4, 5, 6, 7, 7, 6, 5, 4, 3, 2, 1])
        XCTAssertEqual((1...6).map { RotoMath.seat(players: 2, pickNo: $0, snake: true) }, [1, 2, 2, 1, 1, 2])
    }

    func testSameOrder() {
        XCTAssertEqual((1...6).map { RotoMath.seat(players: 3, pickNo: $0, snake: false) }, [1, 2, 3, 1, 2, 3])
    }

    func testPickNoIsTheInverseOfSeatAndRound() {
        for snake in [true, false] {
            for n in 1...(8 * 45) {
                let seat = RotoMath.seat(players: 8, pickNo: n, snake: snake)
                let round = RotoMath.round(players: 8, pickNo: n)
                XCTAssertEqual(RotoMath.pickNo(seat: seat, round: round, players: 8, snake: snake), n)
            }
        }
    }

    func testPicksUntilMine() {
        // Seat 3 of 8, snake. After 0 picks: picks 1 and 2 come first.
        XCTAssertEqual(RotoMath.picksUntil(seat: 3, picksMade: 0, players: 8, total: 360, snake: true), 2)
        XCTAssertEqual(RotoMath.picksUntil(seat: 3, picksMade: 2, players: 8, total: 360, snake: true), 0)
        // After pick 3, seat 3 is next at pick 14 (round 2 runs 8 → 1).
        XCTAssertEqual(RotoMath.picksUntil(seat: 3, picksMade: 3, players: 8, total: 360, snake: true), 10)
        // Seat 8 picks twice in a row at the turn.
        XCTAssertEqual(RotoMath.picksUntil(seat: 8, picksMade: 8, players: 8, total: 360, snake: true), 0)
        // No picks left.
        XCTAssertNil(RotoMath.picksUntil(seat: 1, picksMade: 360, players: 8, total: 360, snake: true))
    }

    func testClockScheduleQuickens() {
        let clock = [RotoClockRange(fromRound: 1, seconds: 14400), RotoClockRange(fromRound: 11, seconds: 7200),
                     RotoClockRange(fromRound: 31, seconds: 1800)]
        XCTAssertEqual(RotoMath.clockSeconds(clock, round: 1), 14400)
        XCTAssertEqual(RotoMath.clockSeconds(clock, round: 10), 14400)
        XCTAssertEqual(RotoMath.clockSeconds(clock, round: 11), 7200)
        XCTAssertEqual(RotoMath.clockSeconds(clock, round: 45), 1800)
        XCTAssertNil(RotoMath.clockSeconds(nil, round: 3))
        XCTAssertEqual(RotoMath.countdownText(6130), "1:42:10")
        XCTAssertEqual(RotoMath.countdownText(245), "4:05")
        XCTAssertEqual(RotoMath.durationText(5400), "1 h 30 min")
    }

    func testPairingDefaults() {
        XCTAssertEqual(RotoMath.defaultPairing(players: 2), "round_robin")
        XCTAssertEqual(RotoMath.defaultPairing(players: 8), "round_robin")
        XCTAssertEqual(RotoMath.defaultPairing(players: 9), "swiss")
        XCTAssertEqual(RotoMath.roundRobinRounds(players: 8), 7)
        XCTAssertEqual(RotoMath.roundRobinRounds(players: 7), 7)
    }

    // MARK: merging deltas

    private func picks(_ range: ClosedRange<Int>, slotOffset: Int = 100) -> [RotoPick] {
        range.map { RotoPick(pickNo: $0, seat: RotoMath.seat(players: 8, pickNo: $0, snake: true), slot: $0 + slotOffset, how: "player", at: 0) }
    }

    func testDeltaAppends() {
        let r = RotoMerge.apply(held: picks(1...35), delta: picks(36...40), picksMade: 40)
        XCTAssertEqual(r.picks.map(\.pickNo), Array(1...40))
        XCTAssertFalse(r.needsFull)
    }

    func testEmptyDeltaKeepsEverything() {
        let r = RotoMerge.apply(held: picks(1...35), delta: [], picksMade: 35)
        XCTAssertEqual(r.picks.count, 35)
        XCTAssertFalse(r.needsFull)
    }

    func testUndoDropsPicksAboveAndAsksForAFullFetch() {
        // Undo back to 30: the held 31…35 go; numbers 31…33 may have been picked again, so fetch everything.
        let r = RotoMerge.apply(held: picks(1...35), delta: [], picksMade: 30)
        XCTAssertEqual(r.picks.map(\.pickNo), Array(1...30))
        XCTAssertTrue(r.needsFull)
    }

    func testRewrittenPickShowsAsDuplicateSlot() {
        // Held 1…35; an undo to 30 and new picks reached 37. The delta (after 35) brings 36–37, one of them a card
        // still held at 32: the merge notices and asks for a full fetch.
        var delta = picks(36...37)
        delta[0] = RotoPick(pickNo: 36, seat: delta[0].seat, slot: 132, how: "player", at: 0)
        let r = RotoMerge.apply(held: picks(1...35), delta: delta, picksMade: 37)
        XCTAssertTrue(r.needsFull)
    }

    func testGapAsksForAFullFetch() {
        let r = RotoMerge.apply(held: picks(1...10), delta: picks(13...14), picksMade: 14)
        XCTAssertTrue(r.needsFull)
    }

    func testFullFetchReplaces() {
        let fresh = picks(1...33, slotOffset: 500)
        let r = RotoMerge.apply(held: [], delta: fresh, picksMade: 33)
        XCTAssertEqual(r.picks, fresh)
        XCTAssertFalse(r.needsFull)
    }

    // MARK: wire

    func testDecodesRotoState() throws {
        let json = """
        {"event_id": "e1", "phase": "drafting",
         "draft": {"picks_per_player": 45, "pick_order": "snake", "players": 8, "pool_count": 360, "picks_made": 2,
                   "total_picks": 360, "source_list_id": null, "clock": [{"from_round": 1, "seconds": 14400}],
                   "clock_paused": false, "started_at": 1760000000, "finished_at": null},
         "on_clock": {"participant_id": "p3", "seat": 3, "pick_no": 3, "round": 1, "turn_started_at": 1760000100,
                      "turn_seconds": 14400, "remaining_seconds": null, "deadline": 1760014500, "overdue": false},
         "seats": [{"seat": 1, "participant_id": "p1", "display_name": "Ann", "account": true, "me": false},
                   {"seat": 3, "participant_id": "p3", "display_name": "Cy", "account": false, "me": true}],
         "picks": [[1, 1, 17, "player", 1760000050], [2, 2, 4, "auto", 1760000100]],
         "pool": [[1, "c-1", "nonfoil"], [2, "c-2", "foil"]],
         "me": {"participant_id": "p3", "seat": 3, "queue": [5, 9], "auto_pick": true, "deck_list_id": "d1"}}
        """
        let s = try wireDecoder.decode(RotoState.self, from: Data(json.utf8))
        XCTAssertEqual(s.phase, .drafting)
        XCTAssertEqual(s.draft.picksMade, 2)
        XCTAssertEqual(s.draft.clock?.first?.seconds, 14400)
        XCTAssertEqual(s.onClock?.seat, 3)
        XCTAssertEqual(s.picks.map(\.slot), [17, 4])
        XCTAssertTrue(s.picks[1].automatic)
        XCTAssertEqual(s.pool?.last?.finish, "foil")
        XCTAssertEqual(s.me?.queue, [5, 9])
        XCTAssertEqual(s.me?.deckListId, "d1")
    }

    func testDecodesSetupStateWithoutClockOrPool() throws {
        let json = """
        {"event_id": "e1", "phase": "setup", "draft": {"picks_per_player": 45, "pick_order": "snake", "players": 3,
         "pool_count": 0, "picks_made": 0, "total_picks": null, "source_list_id": null, "clock": null, "clock_paused": false,
         "started_at": null, "finished_at": null}, "on_clock": null,
         "seats": [{"seat": null, "participant_id": "p1", "display_name": "Ann", "account": true, "me": true}],
         "picks": [], "pool": null, "me": {"participant_id": "p1", "seat": null, "queue": [], "auto_pick": true, "deck_list_id": null}}
        """
        let s = try wireDecoder.decode(RotoState.self, from: Data(json.utf8))
        XCTAssertEqual(s.phase, .setup)
        XCTAssertNil(s.onClock)
        XCTAssertNil(s.pool)
        XCTAssertEqual(s.draft.total, 135)
    }

    func testDecodesPickConflict() throws {
        let json = """
        {"ok": false, "conflict": true, "state": {"event_id": "e1", "phase": "drafting", "draft": {"picks_made": 5},
         "on_clock": null, "seats": [], "picks": [[5, 5, 30, "player", 1]], "pool": null, "me": null}}
        """
        let r = try wireDecoder.decode(RotoPickResult.self, from: Data(json.utf8))
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.conflict, true)
        XCTAssertEqual(r.state.picks.first?.pickNo, 5)
    }

    // MARK: round robin schedule

    func testScheduleMeetsEveryoneOnce() {
        for n in 2...10 {
            let ids = (1...n).map { "p\($0)" }
            let rounds = RotoMath.roundRobinRounds(players: n)
            for id in ids {
                var met: [String] = []
                var byes = 0
                for r in 1...rounds {
                    if let o = RotoScheduleView.opponent(of: id, round: r, roster: ids) { met.append(o) } else { byes += 1 }
                }
                XCTAssertEqual(Set(met).count, n - 1, "n=\(n) \(id)")
                XCTAssertEqual(met.count, n - 1)
                XCTAssertEqual(byes, n % 2)
            }
        }
    }

    func testManaValue() {
        XCTAssertEqual(RotoCard.manaValue("{2}{U}{U}"), 4)
        XCTAssertEqual(RotoCard.manaValue("{X}{R}"), 1)
        XCTAssertEqual(RotoCard.manaValue("{W/U}{W/U}"), 2)
        XCTAssertEqual(RotoCard.manaValue(""), 0)
        XCTAssertEqual(RotoCard.manaValue("{1}{G} // {3}{G}{G}"), 2)
    }

    // MARK: live answers (captured 2026-10-16 from the server in a rolled-back transaction)

    func testDecodesLiveServerAnswers() throws {
        let state = """
        {"me": {"seat": 2, "queue": [5], "auto_pick": true, "deck_list_id": "43f9c6b8-2101-4edb-a8f6-30bf269d24ab", "participant_id": "0cdf712c-07e0-439c-acc8-501045522595"}, "pool": [[1, "5aa90ab6-2686-4462-8725-5d4370c05437", "nonfoil"], [2, "97957307-f8ec-412f-a720-9b03b93fac56", "nonfoil"], [4, "5819e3f3-da49-4003-88ce-f3b7bb495787", "nonfoil"]], "draft": {"clock": [{"seconds": 3600, "from_round": 1}, {"seconds": 600, "from_round": 3}], "players": 3, "pick_order": "snake", "picks_made": 2, "pool_count": 30, "started_at": 1792183778, "finished_at": null, "total_picks": 15, "clock_paused": false, "source_list_id": "a36e9381-3425-42ba-b381-c7602d629447", "picks_per_player": 5}, "phase": "drafting", "picks": [[1, 1, 1, "organizer", 1792183778], [2, 2, 4, "auto", 1792183778]], "seats": [{"me": false, "seat": 1, "account": false, "display_name": "Gus", "participant_id": "a15ad1de-cd61-4025-ac18-0d2f58377b5b"}, {"me": true, "seat": 2, "account": true, "display_name": "Ben", "participant_id": "0cdf712c-07e0-439c-acc8-501045522595"}, {"me": false, "seat": 3, "account": true, "display_name": "Ana Org", "participant_id": "877be8fd-1eaa-4974-825c-ee33cdf7412d"}], "event_id": "1d455625-8c95-42b0-bb12-b8185c3f8dca", "on_clock": {"seat": 3, "round": 1, "overdue": false, "pick_no": 3, "deadline": 1792187378, "turn_seconds": 3600, "participant_id": "877be8fd-1eaa-4974-825c-ee33cdf7412d", "turn_started_at": 1792183778, "remaining_seconds": null}}
        """
        let s = try wireDecoder.decode(RotoState.self, from: Data(state.utf8))
        XCTAssertEqual(s.draft.total, 15)
        XCTAssertEqual(s.picks.map(\.how), ["organizer", "auto"])
        XCTAssertEqual(s.onClock?.seat, RotoMath.seat(players: 3, pickNo: 3, snake: true))
        XCTAssertEqual(s.onClock?.deadline, 1792187378)
        XCTAssertEqual(RotoMath.clockSeconds(s.draft.clock, round: 3), 600)

        let cube = """
        {"players": 3, "event_id": "1d455625-8c95-42b0-bb12-b8185c3f8dca", "cube_name": "Test Cube", "pool_count": 30, "source_list_id": "a36e9381-3425-42ba-b381-c7602d629447", "max_picks_per_player": 10}
        """
        XCTAssertEqual(try wireDecoder.decode(RotoCubeResult.self, from: Data(cube.utf8)).maxPicksPerPlayer, 10)

        let queue = #"{"queue": [5], "auto_pick": true, "picks_made": 2}"#
        XCTAssertEqual(try wireDecoder.decode(RotoQueueResult.self, from: Data(queue.utf8)).picksMade, 2)

        // lists_changes rows carry the event link: "From <event>", never Missing.
        let list = """
        {"id": "43f9c6b8-2101-4edb-a8f6-30bf269d24ab", "seq": 84, "kind": "deck", "name": "Test Cube roto · 16 Oct", "format": "cube", "deleted": false, "event_id": "1d455625-8c95-42b0-bb12-b8185c3f8dca", "versions": [{"at": 1792183777.781887, "note": "Roto picks", "entries": [["5819e3f3-da49-4003-88ce-f3b7bb495787", "main", 1]], "version": 1}], "event_name": "Roto · Test Cube · Fri 16 Oct", "current_version": 1}
        """
        let dto = try wireDecoder.decode(ListDTO.self, from: Data(list.utf8))
        let l = try XCTUnwrap(dto.list)
        XCTAssertEqual(l.eventName, "Roto · Test Cube · Fri 16 Oct")
        XCTAssertEqual(MainActor.assumeIsolated { missing(in: l, owned: [:]) }, 0)
    }
}
