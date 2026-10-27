import XCTest
@testable import Table1

/* Scheduled events, sign-up, top 8, automatic rounds and decklists (contract/scheduled-events-2026-10-27.md) against
   testdata/scheduled-events/cases.json, plus the new event_bundle / event_public fields from testdata/event-bundle. */

private let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../testdata").standardized

private struct Cases: Decodable {
    struct Rounds: Decodable { let players, want: Int }
    struct Next: Decodable { let stages: [String]; let waiting: Bool; let number_of_rounds, top_cut, active_players: Int; let want: String }
    struct RoundName: Decodable { let stage: String; let number, of: Int; let want: String }
    struct SignUp: Decodable { let players: Int; let capacity: Int?; let waitlist: Int; let want: String }
    struct Auto: Decodable { let players: Int; let want: String }
    struct RoundsLine: Decodable { let auto: Bool; let rounds, top_cut: Int; let open: Bool; let want: String }
    struct Button: Decodable { let signed_in: Bool; let sign_up: String; let me: String?; let want: String }
    struct Counts: Decodable { let main, side: Int }
    struct Deck: Decodable { let body: String; let want: Counts }
    struct DeckFormat: Decodable { let event: String; let want: String? }
    struct Line: Decodable { let sent, players: Int; let want: String }
    let rounds: [Rounds]
    let next: [Next]
    let round_name: [RoundName]
    let sign_up: [SignUp]
    let auto_label: [Auto]
    let rounds_line: [RoundsLine]
    let button: [Button]
    let decklist: [Deck]
    let deck_format: [DeckFormat]
    let decklists_line: [Line]
}

final class ScheduledEventsTests: XCTestCase {
    private func cases() throws -> Cases {
        try JSONDecoder().decode(Cases.self, from: Data(contentsOf: dir.appending(path: "scheduled-events/cases.json")))
    }

    func testRoundsAndNextStep() throws {
        let c = try cases()
        for r in c.rounds { XCTAssertEqual(EventRules.swissRounds(r.players), r.want, "\(r.players) players") }
        for n in c.next {
            XCTAssertEqual(EventRules.nextStep(stages: n.stages, waiting: n.waiting, numberOfRounds: n.number_of_rounds,
                                               topCut: n.top_cut, activePlayers: n.active_players).rawValue, n.want, "\(n)")
        }
        for r in c.round_name { XCTAssertEqual(EventRules.roundName(stage: r.stage, number: r.number, of: r.of), r.want) }
        for a in c.auto_label { XCTAssertEqual(EventRules.autoLabel(players: a.players), a.want) }
        for l in c.rounds_line {
            XCTAssertEqual(EventRules.roundsLine(auto: l.auto, rounds: l.rounds, topCut: l.top_cut, open: l.open), l.want)
        }
    }

    func testSignUpPage() throws {
        let c = try cases()
        for s in c.sign_up { XCTAssertEqual(EventRules.signUpLine(players: s.players, capacity: s.capacity, waitlist: s.waitlist), s.want) }
        for b in c.button { XCTAssertEqual(EventRules.button(signedIn: b.signed_in, signUp: b.sign_up, me: b.me).rawValue, b.want, "\(b)") }
    }

    func testDecklists() throws {
        let c = try cases()
        for d in c.decklist {
            XCTAssertEqual(EventRules.decklistCounts(d.body), EventRules.Counts(main: d.want.main, side: d.want.side), d.body)
        }
        for f in c.deck_format { XCTAssertEqual(EventRules.deckFormat(f.event), f.want, f.event) }
        for l in c.decklists_line { XCTAssertEqual(EventRules.decklistsLine(sent: l.sent, players: l.players), l.want) }
    }

    func testBundleCarriesWaitlistDecklistsAndCut() throws {
        let w = try wireDecoder.decode(Repo.BundleWire.self, from: Data(contentsOf: dir.appending(path: "event-bundle/bundle.json")))
        let b = Repo.bundle(w)
        XCTAssertEqual(b.event.topCut, 8)
        XCTAssertEqual(b.event.capacity, 8)
        XCTAssertEqual(b.event.decklists, "optional")
        XCTAssertEqual(b.waitlist.map(\.displayName), ["Dot Waiting"])
        XCTAssertEqual(b.decklists.map(\.mainCount), [60])
        XCTAssertEqual(b.rounds.map { $0.stage ?? "?" }, ["swiss", "swiss"])
        XCTAssertNotNil(b.decklist(b.participants[0].id))
        XCTAssertEqual(b.decklistsMissing, 2)
    }

    func testEventPageFromThePublicRead() throws {
        let p = try wireDecoder.decode(EventPage.self, from: Data(contentsOf: dir.appending(path: "event-bundle/public.json")))
        XCTAssertTrue(p.available)
        XCTAssertEqual(p.signUp, "closed")
        XCTAssertEqual(p.signUpLine, "3/8 players · 1 on the waitlist")
        XCTAssertEqual(p.roundsLine, "3 rounds · Top 8")
        XCTAssertEqual(EventRules.button(signedIn: false, signUp: p.signUp, me: p.me), .closed)
    }

    func testStandingsWithABracket() throws {
        let json = #"""
        {"standings":[{"rank":1,"participant_id":"a","display_name":"Ana","status":"active","match_points":9,"match_wins":3,
          "match_losses":0,"match_draws":0,"byes":0,"omw":0.5,"gw":0.7,"ogw":0.5,"swiss_rank":2,"playoff":"winner"}],
         "top_cut":8,"bracket":[{"stage":"final","matches":[{"match_id":"m","table_number":1,"status":"confirmed","winner":"a",
          "sides":[{"seed":2,"participant_id":"a","display_name":"Ana","game_wins":2},{"seed":1,"participant_id":"b","display_name":"Bo","game_wins":0}]}]}]}
        """#
        let r = try wireDecoder.decode(StandingsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.standings.first?.playoff, "winner")
        XCTAssertEqual(r.standings.first?.swissRank, 2)
        XCTAssertEqual(r.bracket?.first?.title, "Final")
        XCTAssertEqual(r.bracket?.first?.matches.first?.winner, "a")
    }
}
