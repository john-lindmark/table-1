import XCTest
@testable import Table1

/* The widgets batch (contract/widgets-2026-10-22.md): the next-event pick and time text, the value history, the
   organizer activity's lines, and the server's organizer state decoding. */

final class WidgetLogicTests: XCTestCase {
    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let now = ISO8601DateFormatter().date(from: "2026-10-22T12:00:00Z")!

    private func event(_ id: String, bucket: String = "upcoming", status: String = "open", startsIn: TimeInterval? = nil,
                       round: Int = 0) -> NextEventItem {
        NextEventItem(id: id, name: id, status: status, bucket: bucket, organizing: false, playing: true, venueName: nil,
                      startsAt: startsIn.map { ISO8601DateFormatter().string(from: now.addingTimeInterval($0)) },
                      numberOfRounds: 4, currentRound: round, players: 8, formatLabel: nil, format: "modern")
    }

    // MARK: next event

    func testPickPutsLiveFirstThenSoonestThenUndatedAndHidesCancelledAndPast() {
        let picked = NextEvent.pick([
            event("undated"), event("later", startsIn: 86400), event("cancelled", status: "cancelled", startsIn: 60),
            event("past", bucket: "past"), event("soon", startsIn: 3600), event("live", bucket: "live", round: 2),
        ])
        XCTAssertEqual(picked.map(\.id), ["live", "soon", "later", "undated"])
    }

    func testTimeText() {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(NextEvent.timeText(event("l", bucket: "live", round: 2), now: now), "Live · R2/4")
        XCTAssertEqual(NextEvent.timeText(event("u"), now: now), "Not scheduled")
        XCTAssertEqual(NextEvent.timeText(event("p", startsIn: -600), now: now), "Starting now")
        XCTAssertEqual(NextEvent.timeText(event("m", startsIn: 45 * 60), now: now), "In 45m")
        XCTAssertEqual(NextEvent.timeText(event("h", startsIn: 2 * 3600 + 10 * 60), now: now), "In 2h 10m")
        // Day and time come from the system's localized template, whose spacing and joining word vary ("Oct 30 at …").
        let plain = { (s: String) in s.replacingOccurrences(of: "\u{202F}", with: " ") }
        let days = plain(NextEvent.timeText(event("d", startsIn: 2 * 86400 + 6.5 * 3600), now: now, calendar: utc, locale: en))
        XCTAssertTrue(days.hasPrefix("Sat") && days.hasSuffix("6:30 PM"), days)
        let weeks = plain(NextEvent.timeText(event("w", startsIn: 8 * 86400), now: now, calendar: utc, locale: en))
        XCTAssertTrue(weeks.hasPrefix("Oct 30") && weeks.hasSuffix("12:00 PM"), weeks)
    }

    func testParsesPostgresTimestamps() {
        XCTAssertNotNil(NextEvent.parseDate("2026-10-22T18:00:00+00:00"))
        XCTAssertNotNil(NextEvent.parseDate("2026-10-22T18:00:00.123456+00:00") ?? NextEvent.parseDate("2026-10-22T18:00:00.123+00:00"))
        XCTAssertNil(NextEvent.parseDate("tomorrow"))
    }

    func testReloadsJustAfterTheNextStartWithinTwelveHours() {
        let soon = event("s", startsIn: 10 * 60)
        XCTAssertEqual(NextEvent.nextReload([soon], now: now), now.addingTimeInterval(11 * 60))
        XCTAssertEqual(NextEvent.nextReload([event("x", startsIn: 5 * 3600)], now: now), now.addingTimeInterval(30 * 60))
        XCTAssertEqual(NextEvent.nextReload([event("y", startsIn: 3 * 86400)], now: now), now.addingTimeInterval(3 * 3600))
    }

    func testDecodesEventsHomeRowsWithTheSnakeCaseDecoder() throws {
        let json = #"{"id":"e1","name":"Friday","short_code":"ABCD","status":"open","bucket":"upcoming","organizing":true,"playing":false,"venue_name":"Mox","starts_at":"2026-10-23T01:00:00+00:00","number_of_rounds":4,"current_round":0,"is_demo":false,"players":6,"format_label":"Modern","format":"modern","my_status":null}"#
        let e = try T1Shared.snakeDecoder.decode(NextEventItem.self, from: Data(json.utf8))
        XCTAssertEqual(e.venueName, "Mox")
        XCTAssertTrue(e.organizing)
        XCTAssertNotNil(e.startDate)
    }

    // MARK: value history

    private func day(_ offset: Int) -> Date { utc.date(byAdding: .day, value: offset, to: now)! }

    func testOnePointPerDayLastValueWins() {
        var r: ValueRecord?
        XCTAssertTrue(ValueHistory.record(&r, userId: "u", usd: 100, cards: 1, copies: 1, now: now, calendar: utc))
        XCTAssertTrue(ValueHistory.record(&r, userId: "u", usd: 105.004, cards: 1, copies: 1, now: now, calendar: utc))
        XCTAssertFalse(ValueHistory.record(&r, userId: "u", usd: 105, cards: 1, copies: 1, now: now, calendar: utc), "same value, nothing to redraw")
        XCTAssertEqual(r?.points, [ValuePoint(day: "2026-10-22", usd: 105)])
        XCTAssertNil(r?.change(now: now, calendar: utc), "one day: no change yet")
    }

    func testChangeOverSevenDaysOrShorterHistory() {
        var r: ValueRecord?
        for (i, v) in [100.0, 90, 120, 130, 125, 140, 150, 160, 170].enumerated() {
            ValueHistory.record(&r, userId: "u", usd: v, cards: 1, copies: 1, now: day(i - 8), calendar: utc)
        }
        let week = r!.change(now: now, calendar: utc)!
        XCTAssertEqual(week.usd, 170 - 90, accuracy: 0.001)
        XCTAssertEqual(week.days, 7)

        var short: ValueRecord?
        ValueHistory.record(&short, userId: "u", usd: 50, cards: 1, copies: 1, now: day(-2), calendar: utc)
        ValueHistory.record(&short, userId: "u", usd: 45, cards: 1, copies: 1, now: now, calendar: utc)
        let c = short!.change(now: now, calendar: utc)!
        XCTAssertEqual(c.usd, -5, accuracy: 0.001)
        XCTAssertEqual(c.days, 2)
    }

    func testKeepsThirtyDaysAndStartsFreshForAnotherAccount() {
        var r: ValueRecord?
        for i in 0..<40 { ValueHistory.record(&r, userId: "u", usd: Double(i), cards: 1, copies: 1, now: day(i - 39), calendar: utc) }
        XCTAssertEqual(r?.points.count, ValueHistory.keepDays)
        XCTAssertEqual(r?.points.first?.day, ValueHistory.day(day(-29), utc))
        ValueHistory.record(&r, userId: "other", usd: 7, cards: 1, copies: 1, now: now, calendar: utc)
        XCTAssertEqual(r?.userId, "other")
        XCTAssertEqual(r?.points.count, 1)
    }

    // MARK: organizer activity

    private func org(_ phase: String = "live", round: Int = 2, matches: Int = 8, done: Int = 5, disputes: Int = 0,
                     guests: Int = 0) -> OrgState {
        OrgState(phase: phase, round: round, rounds: 4, roundSeconds: 3000, endsAt: nil, pausedRemaining: nil,
                 matches: matches, done: done, waiting: matches - done, disputes: disputes, guestWaiting: guests,
                 players: 16, updatedAt: 0)
    }

    func testOrganizerNextStep() {
        XCTAssertEqual(org().nextStep, "Waiting on 3 results")
        XCTAssertEqual(org(done: 7).nextStep, "Waiting on 1 result")
        XCTAssertEqual(org(done: 8).nextStep, "Ready: Pair round 3")
        XCTAssertTrue(org(done: 8).isReady)
        XCTAssertEqual(org(round: 4, done: 8).nextStep, "Ready: Finish event")
        XCTAssertEqual(org("between", round: 2, matches: 0, done: 0).nextStep, "Round 2 recorded · Pair round 3")
        XCTAssertEqual(org("between", round: 0, matches: 0, done: 0).nextStep, "Pair round 1")
        XCTAssertEqual(org("complete").nextStep, "Event complete")
        XCTAssertEqual(org(disputes: 1, guests: 2).flags, ["1 dispute to decide", "2 to enter yourself"])
        XCTAssertEqual(org("between", disputes: 1).flags, [])
    }

    func testDecodesTheServersOrganizerState() throws {
        // Shape of live-activity's organizer.ts (no endsAt while paused).
        let json = #"{"snapshots":[],"organizer":[{"eventId":"e","eventName":"Friday","state":{"phase":"live","round":2,"rounds":4,"roundSeconds":3000,"pausedRemaining":1200,"matches":8,"done":5,"waiting":3,"disputes":1,"guestWaiting":1,"players":16,"updatedAt":1761134400}}]}"#
        let r = try JSONDecoder().decode(LiveAPI.StateResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.organizer.first?.state.pausedText, "20:00")
        XCTAssertEqual(r.organizer.first?.state.resultsText, "5/8 in")
        let old = try JSONDecoder().decode(LiveAPI.StateResponse.self, from: Data(#"{"snapshots":[]}"#.utf8))
        XCTAssertEqual(old.organizer, [], "older servers send no organizer key")
    }
}
