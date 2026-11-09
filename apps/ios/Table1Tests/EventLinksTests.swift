import XCTest
@testable import Table1

/* Event links in the app and following events (contract/event-links-2026-11-09.md, contract/event-follows-2026-11-09.md),
   on testdata/event-links/cases.json, the file Android EventLinksTest and web eventFollows.test.ts read. */
private let casesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../testdata/event-links/cases.json").standardized

private struct Cases: Decodable {
    struct R: Decodable { let name: String; let signUp: String; let me: String?; let currentRound: Int; let want: Bool }
    struct T: Decodable { let status: String; let round: EventPage.Head?; let currentRound: Int; let numberOfRounds: Int; let want: String }
    struct RT: Decodable { let number: Int; let stage: String; let status: String; let want: String }
    struct S: Decodable { let status: String; let sides: [[Int]]; let gameDraws: Int; let want: String }
    struct F: Decodable {
        let status: String; let currentRound: Int; let numberOfRounds: Int; let stage: String?
        let formatLabel: String?; let startsAt: String?; let venueName: String?; let want: String
    }
    let results: [R]
    let title: [T]
    let roundTitle: [RT]
    let score: [S]
    let followed: [F]
}

final class EventLinksTests: XCTestCase {
    private func cases() throws -> Cases {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Cases.self, from: Data(contentsOf: casesURL))
    }

    func testResultsAndTitle() throws {
        let c = try cases()
        for r in c.results {
            var p = EventPage(eventId: "e")
            p.signUp = r.signUp; p.me = r.me; p.currentRound = r.currentRound
            XCTAssertEqual(p.showsResults, r.want, r.name)
        }
        for t in c.title {
            var p = EventPage(eventId: "e")
            p.status = t.status; p.round = t.round; p.currentRound = t.currentRound; p.numberOfRounds = t.numberOfRounds
            XCTAssertEqual(p.resultsTitle, t.want)
        }
    }

    func testMatchups() throws {
        let c = try cases()
        for r in c.roundTitle { XCTAssertEqual(PublicRound(number: r.number, stage: r.stage, status: r.status).title, r.want) }
        for s in c.score {
            let m = PublicMatch(matchId: "m", status: s.status, gameDraws: s.gameDraws,
                                sides: s.sides.map { PublicMatch.Side(side: $0[0], gameWins: $0[1]) })
            XCTAssertEqual(m.score, s.want)
        }
        // An older server's current pairings stand in for its round.
        var p = EventPage(eventId: "e")
        p.round = .init(number: 2, stage: "swiss")
        p.pairings = [PublicMatch(matchId: "m", tableNumber: 3)]
        XCTAssertEqual(p.matchupRounds.map(\.title), ["Round 2 · now"])
        XCTAssertEqual(PublicMatch(matchId: "b", isBye: true).tableLabel, "Bye")
    }

    func testFollowedDetail() throws {
        for f in try cases().followed {
            let e = FollowedEvent(eventId: "e", name: "N", formatLabel: f.formatLabel, status: f.status, currentRound: f.currentRound,
                                  numberOfRounds: f.numberOfRounds, startsAt: f.startsAt, venueName: f.venueName, stage: f.stage)
            XCTAssertEqual(e.detail, f.want)
        }
    }

    func testFollowDecodes() throws {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let f = try d.decode(EventFollow.self, from: Data(#"{"following": true, "notify": false, "can_follow": true}"#.utf8))
        XCTAssertEqual(f, EventFollow(following: true, notify: false, canFollow: true))
        let p = try d.decode(EventPage.self, from: Data(#"{"event_id": "e", "sign_up": "closed", "current_round": 2, "round": {"number": 2, "stage": "swiss", "status": "active"}, "rounds": [{"number": 2, "stage": "swiss", "status": "active", "matches": [{"match_id": "m", "table_number": 1, "is_bye": false, "status": "pending", "game_draws": 0, "sides": [{"side": 0, "display_name": "Ana", "game_wins": 0}, {"side": 1, "display_name": "Bo", "game_wins": 0}]}]}]}"#.utf8))
        XCTAssertTrue(p.showsResults)
        XCTAssertEqual(p.matchupRounds.first?.matches?.first?.name(1), "Bo")
    }
}
