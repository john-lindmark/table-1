import XCTest
@testable import Table1

/* Teams, Team Trios, top 4, a season's final and alerts (contract/teams-finals-alerts-2026-11-13.md), entry fees
   (contract/entry-fees-2026-11-13.md) and the room tools (contract/room-tools-2026-11-13.md) against
   testdata/leagues/cases.json (reference make_cases.py): every wording and small rule, then the wire shapes of the
   contracts' RPCs and the engine's team bracket, the team link, and the push taps. */

private let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../testdata/leagues").standardized

private struct Cases: Decodable {
    struct MoneyCase: Decodable { let cents: Int; let want: String }
    struct Cut: Decodable { let formatName: String; let pairing: String; let want: [Int] }
    struct Key: Decodable { let key: String; let label: String }
    struct Seat: Decodable { let slot: Int; let seatFormats: [String]?; let want: String }
    struct TeamLine: Decodable {
        struct T: Decodable { let members: Int; let complete: Bool }
        let team: T; let teamSize: Int; let want: String
    }
    struct Alert: Decodable { let alert: EventAlerts; let want: String }
    struct Fee: Decodable {
        struct F: Decodable { let amountCents: Int; let payMode: String }
        let fee: F?; let want: String
    }
    struct Tag: Decodable {
        struct P: Decodable { let status: String; let method: String? }
        let payment: P; let want: String
    }
    struct Presets: Decodable { let winner, top2, top4, top8: [PayoutBracket] }
    struct Words: Decodable { let payout: [PayoutBracket]; let want: String; let total: Double }
    struct PrizeAt: Decodable { let payout: [PayoutBracket]; let poolCents: Int; let place: Int; let share: Int; let want: Int }
    struct Pool: Decodable {
        struct Want: Decodable { let grossCents, leagueCutCents, hostKeepCents, poolCents: Int }
        let entries, amountCents, cutCents: Int; let keepKind: String; let keepValue: Double; let addedCents: Int; let want: Want
    }
    struct Ext: Decodable { let seconds: Int; let want: String }
    struct Judge: Decodable {
        struct Call: Decodable { let tableNumber: Int; let by: String?; let calledAt: String }
        let call: Call; let now: String; let want: String
    }
    struct Rules: Decodable { let rel: String?; let due: String?; let want: String }
    let money: [MoneyCase]
    let cutChoices: [Cut]
    let seatFormats: [Key]
    let seatLabel: [Seat]
    let teamLine: [TeamLine]
    let alertLine: [Alert]
    let feeLine: [Fee]
    let payTag: [Tag]
    let payoutPresets: Presets
    let payoutWords: [Words]
    let prizeAt: [PrizeAt]
    let pool: [Pool]
    let extensionText: [Ext]
    let judgeLine: [Judge]
    let rulesLine: [Rules]
}

final class EventToolsTests: XCTestCase {
    private func cases() throws -> Cases {
        try T1Shared.snakeDecoder.decode(Cases.self, from: Data(contentsOf: dir.appending(path: "cases.json")))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try T1Shared.snakeDecoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: shared cases

    func testMoneyFeeLineAndPayTag() throws {
        let c = try cases()
        XCTAssertFalse(c.money.isEmpty)
        for m in c.money { XCTAssertEqual(Money.text(m.cents), m.want, "\(m.cents)") }
        XCTAssertFalse(c.feeLine.isEmpty)
        for f in c.feeLine { XCTAssertEqual(Money.feeLine(amountCents: f.fee?.amountCents, payMode: f.fee?.payMode), f.want) }
        XCTAssertFalse(c.payTag.isEmpty)
        for t in c.payTag { XCTAssertEqual(Money.payTag(status: t.payment.status, method: t.payment.method), t.want) }
    }

    func testPayoutsPrizesAndThePool() throws {
        let c = try cases()
        let presets = Dictionary(uniqueKeysWithValues: Money.payoutPresets.map { ($0.key, $0.payout) })
        XCTAssertEqual(presets["winner"], c.payoutPresets.winner)
        XCTAssertEqual(presets["top2"], c.payoutPresets.top2)
        XCTAssertEqual(presets["top4"], c.payoutPresets.top4)
        XCTAssertEqual(presets["top8"], c.payoutPresets.top8)
        XCTAssertEqual(Money.payoutPresets.count, 4)
        XCTAssertFalse(c.payoutWords.isEmpty)
        for w in c.payoutWords {
            XCTAssertEqual(Money.payoutWords(w.payout), w.want)
            XCTAssertEqual(Money.payoutTotal(w.payout), w.total, accuracy: 0.0001, w.want)
            XCTAssertTrue(Money.payoutValid(w.payout), w.want)
        }
        XCTAssertFalse(c.prizeAt.isEmpty)
        for p in c.prizeAt {
            XCTAssertEqual(Money.prizeAt(p.payout, poolCents: p.poolCents, place: p.place, share: p.share), p.want, "place \(p.place) share \(p.share)")
        }
        XCTAssertFalse(c.pool.isEmpty)
        for p in c.pool {
            let got = Money.pool(entries: p.entries, amountCents: p.amountCents, cutCents: p.cutCents, keepKind: p.keepKind,
                                 keepValue: p.keepValue, addedCents: p.addedCents)
            XCTAssertEqual([got.grossCents, got.leagueCutCents, got.hostKeepCents, got.poolCents],
                           [p.want.grossCents, p.want.leagueCutCents, p.want.hostKeepCents, p.want.poolCents], "\(p.entries) × \(p.amountCents)")
        }
    }

    func testCutChoicesSeatsAndTeamLine() throws {
        let c = try cases()
        XCTAssertFalse(c.cutChoices.isEmpty)
        for k in c.cutChoices { XCTAssertEqual(TeamRules.cutChoices(formatName: k.formatName, pairing: k.pairing), k.want, "\(k.formatName) \(k.pairing)") }
        XCTAssertEqual(TeamRules.seatFormats.map(\.key), c.seatFormats.map(\.key))
        XCTAssertEqual(TeamRules.seatFormats.map(\.label), c.seatFormats.map(\.label))
        XCTAssertFalse(c.seatLabel.isEmpty)
        for s in c.seatLabel { XCTAssertEqual(TeamRules.seatLabel(slot: s.slot, seatFormats: s.seatFormats), s.want) }
        XCTAssertFalse(c.teamLine.isEmpty)
        for t in c.teamLine { XCTAssertEqual(TeamRules.teamLine(members: t.team.members, complete: t.team.complete, teamSize: t.teamSize), t.want) }
    }

    func testAlertExtensionJudgeAndRulesLines() throws {
        let c = try cases()
        XCTAssertFalse(c.alertLine.isEmpty)
        for a in c.alertLine { XCTAssertEqual(AlertRules.line(a.alert), a.want) }
        XCTAssertFalse(c.extensionText.isEmpty)
        for e in c.extensionText { XCTAssertEqual(RoomRules.extensionText(e.seconds), e.want, "\(e.seconds)") }
        XCTAssertFalse(c.judgeLine.isEmpty)
        for j in c.judgeLine {
            let now = try XCTUnwrap(Leagues.parseDate(j.now))
            XCTAssertEqual(RoomRules.judgeLine(table: j.call.tableNumber, by: j.call.by, calledAt: Leagues.parseDate(j.call.calledAt), now: now), j.want)
        }
        XCTAssertFalse(c.rulesLine.isEmpty)
        for r in c.rulesLine { XCTAssertEqual(RoomRules.rulesLine(rel: r.rel, due: r.due), r.want) }
    }

    // MARK: this client's own rules

    func testAmountsAsTyped() {
        XCTAssertEqual(Money.cents("25"), 2500)
        XCTAssertEqual(Money.cents("$7.50"), 750)
        XCTAssertEqual(Money.cents("1,400"), 140_000)
        XCTAssertEqual(Money.cents(""), 0)
        XCTAssertNil(Money.cents("seven"))
        XCTAssertNil(Money.cents("-5"))
        XCTAssertEqual(Money.typed(2500), "25")
        XCTAssertEqual(Money.typed(750), "7.50")
        XCTAssertEqual(Money.preset(Money.payoutPresets[2].payout), "top4")
        XCTAssertEqual(Money.preset([PayoutBracket(through: 1, percent: 50)]), "custom")
        XCTAssertFalse(Money.payoutValid([PayoutBracket(through: 2, percent: 60)]), "two places at 60% pass the pool")
        XCTAssertFalse(Money.payoutValid([PayoutBracket(through: 2, percent: 10), PayoutBracket(through: 1, percent: 10)]), "brackets go up")
        XCTAssertEqual(Money.paidText(method: "door"), "PAID AT THE DOOR")
        XCTAssertEqual(Money.paidText(method: "comp"), "COMP")
        XCTAssertEqual(Money.paidText(method: "app"), "PAID")
        XCTAssertEqual(Money.prizeTag(paidHow: "cash"), "PAID · CASH")
        XCTAssertEqual(Money.prizeTag(paidHow: "store credit"), "PAID · STORE CREDIT")
        XCTAssertEqual(Money.prizeTag(paidHow: "other"), "PAID")
        XCTAssertEqual(Money.paidHows.map(\.key), ["cash", "store credit", "other"], "event_prize_mark's p_how")
        XCTAssertEqual(Money.prizeTag(paidHow: nil), "PAID")
    }

    func testTeamLinkAndCode() throws {
        let link = TeamRules.link(eventId: "e1", code: "K7Q2M9XD")
        XCTAssertEqual(link.absoluteString, "https://table-1.site/s/e1?team=K7Q2M9XD")
        XCTAssertEqual(TeamRules.code(in: link), "K7Q2M9XD")
        XCTAssertNil(TeamRules.code(in: try XCTUnwrap(URL(string: "https://table-1.site/s/e1"))))
        XCTAssertEqual(TeamRules.clean(" k7q2-m9xd "), "K7Q2M9XD")
        XCTAssertEqual(TeamRules.clean("https://table-1.site/s/e1?team=k7q2m9xd"), "K7Q2M9XD", "a pasted link gives its code")
        XCTAssertNil(TeamRules.clean("  "))
        // The app keeps /s/<event> links as the event's page: the code rides beside it.
        XCTAssertEqual(WebLink.parse(link), .standings("e1"))
    }

    @MainActor
    func testATeamLinkWaitsForItsEventPage() throws {
        TeamLinkCode.pending = nil
        TeamLinkCode.note(try XCTUnwrap(URL(string: "https://table-1.site/s/E1?team=k7q2m9xd")))
        XCTAssertNil(TeamLinkCode.take("other"))
        XCTAssertEqual(TeamLinkCode.take("e1"), "K7Q2M9XD")
        XCTAssertNil(TeamLinkCode.take("e1"), "used once")
        TeamLinkCode.note(try XCTUnwrap(URL(string: "https://table-1.site/s/e1")))
        XCTAssertNil(TeamLinkCode.pending)
    }

    func testDueTextInTheDevicesZone() throws {
        let denver = try XCTUnwrap(TimeZone(identifier: "America/Denver"))
        let d = try XCTUnwrap(Leagues.parseDate("2026-11-14T16:30:00Z"))   // 09:30 in Denver
        XCTAssertEqual(RoomRules.dueText(d, zone: denver, locale: Locale(identifier: "en_GB")), "SAT 14 NOV 09:30")
        XCTAssertEqual(RoomRules.rulesLine(rel: "competitive", due: RoomRules.dueText(d, zone: denver, locale: Locale(identifier: "en_GB"))),
                       "COMPETITIVE · DECKLISTS DUE SAT 14 NOV 09:30")
        XCTAssertEqual(RoomRules.count("Lunch after round 2"), "19 / 140")
        XCTAssertEqual(RoomRules.displayURL("e1").absoluteString, "https://table-1.site/d/e1")
    }

    func testTeamEventsCutByTeams() throws {
        // Six teams of three after three Swiss rounds with a top 4: the cut counts teams, never players.
        func step(_ teams: Int, players: Int, cut: Int = 4) -> String {
            EventRules.nextStep(stages: ["swiss", "swiss", "swiss"], waiting: false, numberOfRounds: 3, topCut: cut, activePlayers: players, activeTeams: teams).rawValue
        }
        XCTAssertEqual(step(6, players: 18), "cut4")
        XCTAssertEqual(step(4, players: 16), "finish", "four teams: the event ends after Swiss")
        XCTAssertEqual(step(9, players: 27, cut: 8), "finish", "a team event has no top 8")
        XCTAssertEqual(EventRules.roundsLine(auto: false, rounds: 3, topCut: 4, open: false), "3 rounds · Top 4")
        XCTAssertEqual(TeamRules.cutLabel(0), "No top cut")
        XCTAssertEqual(TeamRules.cutLabel(4), "Top 4")
        XCTAssertTrue(FormatOption.teamTrios.isTeam)
        XCTAssertTrue(FormatOption.constructed.contains(.teamTrios), "Team Trios sits with the constructed formats")
        XCTAssertEqual(FormatOption(rawValue: "team_trios")?.label, "Team Trios")
    }

    // MARK: wire shapes

    func testEventRowCarriesTriosSignUpAndRules() throws {
        let e = try decode(EventRow.self, """
        {"id": "e1", "short_code": "T3R1", "name": "Team Trios Open", "format": "constructed", "format_name": "team_trios",
         "format_label": "Team Trios", "team_size": 3, "seat_formats": ["modern", "standard", "pioneer"], "team_signup": true,
         "top_cut": 4, "rel": "competitive", "decklist_due_at": "2026-11-14T16:30:00+00:00"}
        """)
        XCTAssertTrue(e.isTrios)
        XCTAssertTrue(e.isTeamEvent)
        XCTAssertTrue(e.teamSignup)
        XCTAssertEqual(e.topCut, 4)
        XCTAssertEqual(TeamRules.seatLabel(slot: 2, seatFormats: e.seatFormats), "B · STANDARD")
        XCTAssertEqual(e.rel, "competitive")
        // An event from before any of it.
        let old = try decode(EventRow.self, #"{"id": "e2", "short_code": "K7Q2", "name": "Draft"}"#)
        XCTAssertNil(old.seatFormats)
        XCTAssertFalse(old.teamSignup)
        let about = try decode(EventAbout.self, """
        {"event_id": "e1", "description": null, "venue_address": null, "visibility": "public", "rel": "casual",
         "decklist_due_at": null, "seat_formats": ["modern", "standard", "pioneer"], "team_signup": true, "format_key": "other", "league": null, "placed": false}
        """)
        XCTAssertTrue(about.hasAbout, "a rules level is something to say")
        XCTAssertEqual(EventAboutRows.rulesLine(about), "CASUAL")
        XCTAssertEqual(about.teamSignup, true)
    }

    func testTeamMineDecodes() throws {
        let mine = try decode(TeamMine.self, """
        {"team_signup": true, "team_size": 3, "seat_formats": ["modern", "standard", "pioneer"],
         "team": {"id": "t1", "name": "Ravens", "captain_id": "u1", "join_code": "K7Q2M9XD",
                  "members": [{"participant_id": "p2", "user_id": "u2", "name": "Bo", "slot": 2},
                              {"participant_id": "p1", "user_id": "u1", "name": "Ann", "slot": 1}], "complete": false},
         "captain": true, "can_create": false,
         "teams": [{"id": "t1", "name": "Ravens", "members": 2, "complete": false}, {"id": "t2", "name": "Owls", "members": 3, "complete": true}]}
        """)
        XCTAssertEqual(mine.team?.members.map(\.name), ["Ann", "Bo"], "by seat")
        XCTAssertEqual(mine.team?.count, 2)
        XCTAssertEqual(mine.teams.map { TeamRules.teamLine(members: $0.count, complete: $0.complete, teamSize: mine.teamSize ?? 3) }, ["2/3", "COMPLETE"])
        XCTAssertTrue(mine.teams[0].members.isEmpty, "others' teams come as a count")
        // Signed out, on an event whose organizer builds the teams.
        let off = try decode(TeamMine.self, #"{"team_signup": false, "team_size": 3, "seat_formats": null, "team": null, "captain": false, "can_create": false, "teams": []}"#)
        XCTAssertFalse(off.teamSignup)
        XCTAssertNil(off.team)
        // Organizers get every team in full with its code.
        let org = try decode(TeamMine.self, """
        {"team_signup": true, "team_size": 3, "seat_formats": null, "team": null, "captain": false, "can_create": false,
         "teams": [{"id": "t2", "name": "Owls", "captain_id": "u4", "join_code": "H4T8WQ2B",
                    "members": [{"participant_id": "p4", "user_id": null, "name": "Dee", "slot": 1}], "complete": false}]}
        """)
        XCTAssertEqual(org.teams[0].joinCode, "H4T8WQ2B")
        XCTAssertEqual(org.teams[0].count, 1)
    }

    func testStandingsWithATeamBracket() throws {
        let r = try decode(StandingsResponse.self, """
        {"standings": [], "top_cut": 4,
         "teams": [{"rank": 1, "team_id": "t1", "name": "Ravens", "points": 9, "wins": 3, "losses": 0, "draws": 0, "byes": 0, "match_wins": 7,
                    "gw": 0.7, "members": [], "swiss_rank": 2, "playoff": "winner"}],
         "team_bracket": [{"stage": "semifinal", "matches": [
            {"table_number": 1, "status": "confirmed", "winner": "t1",
             "sides": [{"seed": 1, "team_id": "t1", "name": "Ravens", "match_wins": 2}, {"seed": 4, "team_id": "t4", "name": "Hawks", "match_wins": 1}],
             "matches": [{"match_id": "m1", "table_number": 1, "is_bye": false, "status": "confirmed", "winner": "p1",
                          "sides": [{"participant_id": "p1", "display_name": "Ann", "slot": 1, "game_wins": 2},
                                    {"participant_id": "p10", "display_name": "Jo", "slot": 1, "game_wins": 0}]}]}]}]}
        """)
        XCTAssertEqual(r.teams?.first?.playoff, "winner")
        XCTAssertEqual(r.teams?.first?.swissRank, 2)
        XCTAssertEqual(r.teamBracket?.first?.stage, "semifinal")
        XCTAssertEqual(r.teamBracket?.first?.matches.first?.winner, "t1")
        XCTAssertEqual(r.teamBracket?.first?.matches.first?.matches?.first?.sides.first?.slot, 1)
        // Other events send null, and older servers nothing.
        XCTAssertNil(try decode(StandingsResponse.self, #"{"standings": [], "team_bracket": null}"#).teamBracket)
        XCTAssertNil(try decode(StandingsResponse.self, #"{"standings": []}"#).teamBracket)
    }

    func testEventMoneyDecodes() throws {
        XCTAssertNil(try decode(EventMoney.self, #"{"fee": null}"#).fee, "no fee: nothing else is sent")
        let m = try decode(EventMoney.self, """
        {"fee": {"amount_cents": 2500, "currency": "usd", "pay_mode": "either", "refund_hours": 24, "host_keep": {"kind": "percent", "value": 10},
                 "added_cents": 1000, "payout": [{"through": 1, "percent": 40}, {"through": 2, "percent": 25}, {"through": 4, "percent": 17.5}],
                 "league_cut_cents": 700},
         "app_ready": true,
         "pool": {"entries": 3, "gross_cents": 7500, "league_cut_cents": 2100, "host_keep_cents": 540, "added_cents": 1000, "pool_cents": 5860},
         "me": {"status": "paid", "method": "app", "amount_cents": 2500, "participant_id": "p1", "can_pay": false, "can_refund": true},
         "prizes": [{"participant_id": "p1", "user_id": "u1", "name": "Ann", "place": 1, "amount_cents": 2344, "custom": false, "paid": true, "paid_how": "cash"}],
         "organizer": {"stripe": {"connected": true, "ready": true},
                       "players": [{"status": "paid", "method": "app", "amount_cents": 2500, "participant_id": "p1", "user_id": "u1", "name": "Ann"},
                                   {"status": "unpaid", "method": null, "amount_cents": 0, "participant_id": "p2", "user_id": null, "name": "Bo"}],
                       "unpaid": 1}}
        """)
        XCTAssertEqual(Money.feeLine(m.fee), "$25 · APP OR DOOR")
        XCTAssertEqual(m.pool?.poolCents, 5860)
        XCTAssertEqual(Money.prizeAt(m.fee?.payout ?? [], poolCents: m.pool?.poolCents ?? 0, place: 1), 2344)
        XCTAssertEqual(m.me?.canRefund, true)
        XCTAssertEqual(m.organizer?.players?.map(\.tag), ["PAID · APP", "UNPAID"])
        XCTAssertEqual(m.payment("p2")?.isPaid, false)
        XCTAssertEqual(m.organizer?.unpaid, 1)
        XCTAssertEqual(m.prizes?.first.map { Money.prizeTag(paidHow: $0.paidHow) }, "PAID · CASH")
        // A player's read: no organizer part, no prizes yet.
        let mine = try decode(EventMoney.self, """
        {"fee": {"amount_cents": 750, "currency": "usd", "pay_mode": "door", "refund_hours": null, "host_keep": {"kind": "none", "value": 0},
                 "added_cents": 0, "payout": [], "league_cut_cents": 0},
         "app_ready": false, "pool": {"entries": 0, "gross_cents": 0, "league_cut_cents": 0, "host_keep_cents": 0, "added_cents": 0, "pool_cents": 0},
         "me": {"status": "unpaid", "method": null, "amount_cents": 0, "participant_id": "p9", "can_pay": false, "can_refund": false},
         "prizes": [], "organizer": null}
        """)
        XCTAssertNil(mine.organizer)
        XCTAssertEqual(Money.feeLine(mine.fee), "$7.50 · DOOR")
        let a = try decode(PaymentsAccount.self, #"{"connected": true, "ready": false, "payouts": false, "details_submitted": false, "disabled_reason": "requirements.past_due"}"#)
        XCTAssertEqual(a.state, "Finish setting up")
        XCTAssertEqual(try decode(PaymentsAccount.self, #"{"connected": false, "ready": false, "payouts": false, "details_submitted": false, "disabled_reason": null}"#).state, "Not connected")
        let l = try decode(LeagueMoney.self, """
        {"entry_cut_cents": 700, "pool_cents": 140000, "received_cents": 61600,
         "events": [{"event_id": "e1", "name": "Modern Open", "entries": 41, "owed_cents": 28700, "received_cents": 28700}]}
        """)
        XCTAssertEqual(Money.text(l.poolCents), "$1,400")
        XCTAssertEqual(l.events?.first?.owedCents, 28_700)
        // Everyone else gets the cut and the pool only.
        XCTAssertNil(try decode(LeagueMoney.self, #"{"entry_cut_cents": 700, "pool_cents": 140000, "received_cents": null, "events": null}"#).events)
    }

    func testEventRoomDecodes() throws {
        let r = try decode(EventRoom.self, """
        {"display": {"show": "pairings", "message": "Lunch after round 2"},
         "extensions": [{"match_id": "m3", "table_number": 3, "extra_seconds": 300}],
         "calls": [{"call_id": "c1", "match_id": "m3", "table_number": 3, "called_at": "2026-11-13T18:30:00+00:00", "by": "Bea"}],
         "my_match": {"match_id": "m3", "table_number": 3, "extra_seconds": 300, "call_open": true}}
        """)
        XCTAssertEqual(r.display?.show, "pairings")
        XCTAssertEqual(RoomRules.extensionText(r.extra("m3")), "+5:00")
        XCTAssertEqual(r.extra("m9"), 0)
        XCTAssertEqual(r.calls?.first?.by, "Bea")
        XCTAssertEqual(r.myMatch?.callOpen, true)
        // A spectator before round 1.
        let quiet = try decode(EventRoom.self, #"{"display": {"show": "auto", "message": null}, "extensions": [], "calls": null, "my_match": null}"#)
        XCTAssertNil(quiet.calls)
        XCTAssertNil(quiet.myMatch)
    }

    func testFinalStatusAndAlertsDecode() throws {
        let f = try decode(FinalStatus.self, """
        {"season_id": "s1",
         "qualified": [{"key": "u:1", "user_id": "u1", "name": "Bea", "rank": 1, "points": 47, "how": "winner", "state": "in"},
                       {"key": "u:2", "user_id": "u2", "name": "Cy", "rank": 2, "points": 41, "how": "points", "state": "none"},
                       {"key": "g:dee", "user_id": null, "name": "Dee", "rank": 3, "points": 38, "how": "points", "state": "guest"}],
         "next": [{"key": "u:4", "user_id": "u4", "name": "Eli", "rank": 4, "points": 36, "how": null, "state": "invited"}]}
        """)
        XCTAssertEqual(f.line, "1 of 3 in")
        XCTAssertEqual(f.toInvite, 1, "a guest has no account to invite")
        XCTAssertEqual(QualifiedPanel.detail(f.qualified[0]), "#1 · 47 pts · Winner")
        XCTAssertEqual(QualifiedPanel.detail(f.next[0]), "#4 · 36 pts")
        let a = try decode(EventAlerts.self, #"{"on": true, "formats": ["modern", "limited"], "km": 50, "lat": 39.7, "lng": -105.0}"#)
        XCTAssertEqual(AlertRules.line(a), "MODERN, LIMITED · 50 KM")
        XCTAssertTrue(a.hasArea)
        let none = try decode(EventAlerts.self, #"{"on": false, "formats": [], "km": null, "lat": null, "lng": null}"#)
        XCTAssertEqual(AlertRules.line(none), "OFF")
        XCTAssertFalse(none.hasArea)
    }

    // MARK: pushes and the server part

    func testJudgeAndNewEventPushesOpenTheEvent() {
        // Neither is a league, Library, Insights, deck photo or Account push: the tap falls through to the event itself
        // (the organizer's Live for a judge call; the event's page for a new public event you aren't in).
        for kind in ["judge.call", "event.public_new"] {
            let info: [AnyHashable: Any] = ["kind": kind, "event_id": "e1"]
            XCTAssertNil(PushRoutes.league(info), kind)
            XCTAssertNil(PushRoutes.library(info), kind)
            XCTAssertNil(PushRoutes.route(info), kind)
            XCTAssertNil(PushRoutes.insights(info), kind)
            XCTAssertNil(PushRoutes.deckPhoto(info), kind)
            XCTAssertEqual(info["event_id"] as? String, "e1")
        }
    }

    func testAMissingServerPartIsRememberedAndNeverReported() async {
        // A function the server answered "no such function" for is refused at once from then on: its rows stay hidden.
        ToolsServer.missing.insert("event_room_test_only")
        defer { ToolsServer.missing.remove("event_room_test_only") }
        do {
            let _: EventRoom = try await Repo.tools("event_room_test_only")
            XCTFail("a missing function throws")
        } catch {
            XCTAssertTrue(error is ToolsServer.Missing)
            XCTAssertFalse(Leagues.isMissing(URLError(.notConnectedToInternet)))
        }
        XCTAssertEqual(ToolsServer.PaymentsOff(message: "Payments aren't set up yet").localizedDescription, "Payments aren't set up yet")
    }
}
