import XCTest
@testable import Table1

/* Finding events, leagues and boards (contract/public-events-leagues-2026-11-13.md) against
   testdata/leagues/cases.json (reference make_cases.py): every wording and small rule, then the wire shapes of the
   contract's RPCs, the filters sent to find_events, the widget's rows and the push taps. */

private let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../testdata/leagues").standardized

private struct Cases: Decodable {
    struct Key: Decodable { let key: String; let label: String }
    struct Presets: Decodable { let places: Leagues.Rule; let matchWins: Leagues.Rule }
    struct Words: Decodable { let rule: Leagues.Rule; let want: String }
    struct Place: Decodable { let rule: Leagues.Rule; let place: Int; let want: Int }
    struct Qualify: Decodable { let qualify: Leagues.Qualify; let want: String }
    struct Event: Decodable {
        struct League: Decodable { let name: String }
        let name: String; let status: String; let currentRound: Int; let formatLabel: String; let venueName: String?
        let capacity: Int?; let players: Int; let km: Int?; let visibility: String?; let league: League?
    }
    struct RowLabel: Decodable { let event: Event; let want: String? }
    struct EventLine: Decodable { let event: Event; let when: String?; let want: String }
    struct Window: Decodable { let pick: String; let now: String; let zone: String; let want: [String]? }
    struct Filter: Decodable {
        struct F: Decodable {
            let formats: [String]?; let km: Int?; let when: String?; let scope: String?
            let team: Bool?; let league: Bool?; let open: Bool?
        }
        struct Want: Decodable { let format: String; let `where`: String; let when: String; let more: String }
        let filters: F; let want: Want
    }
    struct Board: Decodable {
        struct Me: Decodable { let rating: Int; let rank: Int?; let toGo: Int }
        struct B: Decodable { let players: Int; let me: Me? }
        let board: B; let want: String
    }
    struct Card: Decodable {
        struct Next: Decodable { let name: String }
        struct C: Decodable { let season: String?; let region: String?; let nextEvent: Next? }
        let card: C; let want: String
    }
    struct Tile: Decodable {
        struct Want: Decodable { let code: String; let label: String; let accent: Bool }
        let item: Achievement; let want: Want
    }
    let achievementText: [Tile]
    let formatKeys: [Key]
    let presets: Presets
    let pointsWords: [Words]
    let placePoints: [Place]
    let qualifyWords: [Qualify]
    let rowLabel: [RowLabel]
    let eventLine: [EventLine]
    let whenWindow: [Window]
    let filterLabels: [Filter]
    let boardLine: [Board]
    let leagueLine: [Card]
}

final class LeaguesTests: XCTestCase {
    private func cases() throws -> Cases {
        try T1Shared.snakeDecoder.decode(Cases.self, from: Data(contentsOf: dir.appending(path: "cases.json")))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try T1Shared.snakeDecoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: shared cases

    func testFormatKeysAndPresets() throws {
        let c = try cases()
        XCTAssertEqual(Leagues.formatKeys.map(\.key), c.formatKeys.map(\.key))
        XCTAssertEqual(Leagues.formatKeys.map(\.label), c.formatKeys.map(\.label))
        for k in c.formatKeys { XCTAssertEqual(Leagues.label(k.key), k.label) }
        XCTAssertEqual(Leagues.places, c.presets.places)
        XCTAssertEqual(Leagues.matchWins, c.presets.matchWins)
        XCTAssertEqual(Leagues.preset(c.presets.places), "places")
        XCTAssertEqual(Leagues.preset(c.presets.matchWins), "match_wins")
    }

    func testPointsWordsAndPlacePoints() throws {
        let c = try cases()
        XCTAssertFalse(c.pointsWords.isEmpty)
        for w in c.pointsWords { XCTAssertEqual(Leagues.pointsWords(w.rule), w.want) }
        XCTAssertFalse(c.placePoints.isEmpty)
        for p in c.placePoints { XCTAssertEqual(Leagues.placePoints(p.rule, place: p.place), p.want, "place \(p.place)") }
    }

    func testQualifyWords() throws {
        let c = try cases()
        XCTAssertFalse(c.qualifyWords.isEmpty)
        for q in c.qualifyWords { XCTAssertEqual(Leagues.qualifyWords(q.qualify), q.want) }
    }

    func testRowLabelAndEventLine() throws {
        let c = try cases()
        XCTAssertFalse(c.rowLabel.isEmpty)
        for r in c.rowLabel {
            XCTAssertEqual(Leagues.rowLabel(league: r.event.league?.name, visibility: r.event.visibility), r.want, r.event.name)
        }
        XCTAssertFalse(c.eventLine.isEmpty)
        for l in c.eventLine {
            let e = l.event
            XCTAssertEqual(Leagues.eventLine(status: e.status, currentRound: e.currentRound, formatLabel: e.formatLabel, venueName: e.venueName,
                                             capacity: e.capacity, players: e.players, km: e.km, when: l.when), l.want, e.name)
        }
    }

    func testWhenWindow() throws {
        let c = try cases()
        XCTAssertFalse(c.whenWindow.isEmpty)
        for w in c.whenWindow {
            let now = try XCTUnwrap(Leagues.parseDate(w.now), w.now)
            let zone = try XCTUnwrap(TimeZone(identifier: w.zone))
            let got = Leagues.whenWindow(w.pick, now: now, zone: zone).map { [Leagues.iso($0.from), Leagues.iso($0.to)] }
            XCTAssertEqual(got, w.want, "\(w.pick) at \(w.now) in \(w.zone)")
        }
    }

    func testFilterLabels() throws {
        let c = try cases()
        XCTAssertFalse(c.filterLabels.isEmpty)
        for f in c.filterLabels {
            var picks = Leagues.Filters()
            picks.formats = f.filters.formats ?? []
            picks.km = f.filters.km
            picks.when = f.filters.when ?? "any"
            picks.scope = f.filters.scope ?? "all"
            picks.team = f.filters.team ?? false
            picks.league = f.filters.league ?? false
            picks.open = f.filters.open ?? false
            let got = Leagues.filterLabels(picks)
            XCTAssertEqual([got.format, got.where, got.when, got.more], [f.want.format, f.want.where, f.want.when, f.want.more])
        }
    }

    func testBoardAndLeagueLines() throws {
        let c = try cases()
        XCTAssertFalse(c.boardLine.isEmpty)
        for b in c.boardLine {
            XCTAssertEqual(Leagues.boardLine(players: b.board.players, rating: b.board.me?.rating, rank: b.board.me?.rank, toGo: b.board.me?.toGo ?? 0), b.want)
        }
        XCTAssertFalse(c.leagueLine.isEmpty)
        for l in c.leagueLine {
            XCTAssertEqual(Leagues.leagueLine(season: l.card.season, region: l.card.region, next: l.card.nextEvent?.name), l.want)
        }
    }

    func testAchievementText() throws {
        let c = try cases()
        XCTAssertFalse(c.achievementText.isEmpty)
        for t in c.achievementText {
            let got = Leagues.achievementText(t.item)
            XCTAssertEqual(got.code, t.want.code, "\(t.item)")
            XCTAssertEqual(got.label, t.want.label)
            XCTAssertEqual(got.accent, t.want.accent, "\(t.item)")
        }
    }

    func testProfileAchievementsDecodeAndViewAs() throws {
        let mine = try decode(ProfileAchievements.self, """
        {"items": [
          {"kind": "league", "league_id": "l1", "league_slug": "mms", "league_name": "The Mountain Magic Series", "season_id": "s1",
           "season_name": "2025", "state": "over", "rank": null, "players": 96, "points": 0, "wins": 0, "qualified": null, "champion": true},
          {"kind": "league", "league_id": "l1", "league_slug": "mms", "league_name": "The Mountain Magic Series", "season_id": "s2",
           "season_name": "2026", "state": "active", "rank": 4, "players": 80, "points": 33, "wins": 0, "qualified": "points", "champion": false},
          {"kind": "board", "board": "modern", "label": "Modern", "rank": 14, "rating": 1612, "matches": 31, "to_go": 0, "players": 124},
          {"kind": "board", "board": "cube", "label": "Cube", "rank": null, "rating": 1540, "matches": 6, "to_go": 4, "players": 9}],
         "visibility": "friends", "listed": true}
        """)
        XCTAssertEqual(mine.items.map { Leagues.achievementText($0).code }, ["CHAMPION", "QUALIFIED", "#14", "1540"])
        XCTAssertEqual(Set(mine.items.map(\.id)).count, 4, "each tile has its own id")
        // You see all of it; a friend sees what the part reaches, never the board that doesn't list you; anyone nothing.
        XCTAssertEqual(AchievementsRow.shown(mine, viewAs: nil, profile: .public).count, 4)
        XCTAssertEqual(AchievementsRow.shown(mine, viewAs: 1, profile: .public).map { Leagues.achievementText($0).code }, ["CHAMPION", "QUALIFIED", "#14"])
        XCTAssertTrue(AchievementsRow.shown(mine, viewAs: 0, profile: .public).isEmpty)
        // A private profile caps it; hiding from the boards takes the board tiles off for everyone else.
        XCTAssertTrue(AchievementsRow.shown(mine, viewAs: 1, profile: .private).isEmpty)
        var hidden = mine
        hidden.listed = false
        XCTAssertEqual(AchievementsRow.shown(hidden, viewAs: 1, profile: .friends).count, 2)
        XCTAssertTrue(AchievementsRow.shown(nil, viewAs: nil, profile: .public).isEmpty, "a failed call draws nothing")
        // Someone else's: items only.
        let theirs = try decode(ProfileAchievements.self, #"{"items": []}"#)
        XCTAssertNil(theirs.visibility)
        XCTAssertTrue(theirs.items.isEmpty)
    }

    // MARK: this client's own rules

    func testDatesInTheDevicesZone() throws {
        let denver = try XCTUnwrap(TimeZone(identifier: "America/Denver"))
        let us = Locale(identifier: "en_US_POSIX")
        let gb = Locale(identifier: "en_GB")
        let d = try XCTUnwrap(Leagues.parseDate("2026-03-29T16:00:00Z"))   // 10:00 in Denver
        XCTAssertEqual(Leagues.whenText(d, zone: denver, locale: gb), "SUN 29 MAR · 10:00")
        XCTAssertEqual(Leagues.dayText(d, zone: denver, locale: gb), "SUN 29 · 10:00")
        XCTAssertEqual(Leagues.dateText(d, zone: denver, locale: gb), "29 MAR 2026")
        XCTAssertTrue(Leagues.whenText(d, zone: denver, locale: us).hasPrefix("SUN 29 MAR · 10:00"))
        // A season's days never slip a day, whatever the zone.
        for id in ["America/Denver", "Pacific/Auckland", "Pacific/Honolulu", "Europe/Stockholm"] {
            let zone = try XCTUnwrap(TimeZone(identifier: id))
            let day = try XCTUnwrap(Leagues.parseDay("2026-12-31", zone: zone))
            XCTAssertEqual(Leagues.dayString(day, zone: zone), "2026-12-31", id)
        }
        XCTAssertEqual(Leagues.multiplierText(1), "1×")
        XCTAssertEqual(Leagues.multiplierText(1.5), "1.5×")
        XCTAssertEqual(Leagues.finishLine(place: 2, players: 24, formatLabel: "Modern", when: "29 MAR 2026"), "2ND OF 24 · MODERN · 29 MAR 2026")
        XCTAssertEqual(Leagues.finishLine(place: 11, players: nil, formatLabel: nil, when: nil), "11TH")
    }

    func testFiltersSentToTheServer() throws {
        let denver = try XCTUnwrap(TimeZone(identifier: "America/Denver"))
        let now = try XCTUnwrap(Leagues.parseDate("2026-11-13T18:30:00-07:00"))
        XCTAssertTrue(Leagues.Filters().json(now: now, zone: denver).isEmpty, "nothing picked sends nothing")
        var f = Leagues.Filters()
        f.toggle(format: "cube"); f.toggle(format: "modern")
        XCTAssertEqual(f.formats, ["modern", "cube"], "the pickers' order")
        f.km = 50; f.when = "today"; f.scope = "friends"; f.team = true; f.open = true
        var sent = f.json(now: now, zone: denver, here: nil, q: " m ")
        XCTAssertNil(sent["km"], "a distance without a place isn't sent")
        XCTAssertNil(sent["lat"])
        XCTAssertNil(sent["q"], "one character isn't a search")
        XCTAssertEqual(sent["from"] as? String, "2026-11-13T07:00:00Z")
        XCTAssertEqual(sent["to"] as? String, "2026-11-14T07:00:00Z")
        XCTAssertEqual(sent["scope"] as? String, "friends")
        XCTAssertEqual(sent["team"] as? Bool, true)
        XCTAssertEqual(sent["open"] as? Bool, true)
        XCTAssertNil(sent["league"])
        sent = f.json(now: now, zone: denver, here: (39.7, -105.0), q: "meh games")
        XCTAssertEqual(sent["km"] as? Int, 50)
        XCTAssertEqual(sent["lat"] as? Double, 39.7)
        XCTAssertEqual(sent["q"] as? String, "meh games")
        f.toggle(format: "modern")
        XCTAssertEqual(f.formats, ["cube"])
        XCTAssertEqual(f.moreCount, 3)
    }

    func testPicksAreKeptOnTheDevice() throws {
        let name = "leagues-tests-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        XCTAssertEqual(Leagues.Picks.load(d), Leagues.Filters())
        var f = Leagues.Filters()
        f.formats = ["modern", "limited"]; f.km = 100; f.when = "weekend"; f.scope = "public"; f.league = true
        Leagues.Picks.save(f, d)
        XCTAssertEqual(Leagues.Picks.load(d), f)
        XCTAssertEqual(d.stringArray(forKey: "find.formats"), ["modern", "limited"])
        XCTAssertEqual(d.integer(forKey: "find.km"), 100)
        XCTAssertEqual(d.string(forKey: "find.when"), "weekend")
        XCTAssertEqual(d.stringArray(forKey: "find.more"), ["league", "public"])
        // Values this build doesn't know are dropped, not kept.
        d.set(["modern", "typo"], forKey: "find.formats"); d.set(33, forKey: "find.km"); d.set("someday", forKey: "find.when")
        let read = Leagues.Picks.load(d)
        XCTAssertEqual(read.formats, ["modern"])
        XCTAssertNil(read.km)
        XCTAssertEqual(read.when, "any")
    }

    func testRuleValidity() {
        XCTAssertTrue(Leagues.places.valid)
        XCTAssertTrue(Leagues.matchWins.valid)
        XCTAssertFalse(Leagues.Rule().valid, "a rule that gives nothing")
        XCTAssertFalse(Leagues.Rule(places: [.init(through: 4, points: 8), .init(through: 2, points: 10)]).valid, "brackets go up")
        XCTAssertFalse(Leagues.Rule(places: [.init(through: 1, points: 1001)]).valid)
        XCTAssertEqual(Leagues.preset(Leagues.Rule(places: [.init(through: 1, points: 5)])), "custom")
    }

    func testMissingServerPart() {
        struct Fake: Error, CustomStringConvertible { let description: String }
        XCTAssertTrue(Leagues.isMissing(Fake(description: #"PostgrestError(detail: nil, hint: nil, code: Optional("PGRST202"), message: "Could not find the function public.find_events(p_filters, p_limit) in the schema cache")"#)))
        XCTAssertFalse(Leagues.isMissing(Fake(description: #"PostgrestError(code: Optional("42501"), message: "That event isn't available")"#)))
        XCTAssertFalse(Leagues.isMissing(URLError(.notConnectedToInternet)))
    }

    // MARK: wire shapes (the contract's RPCs)

    func testFindEventsDecodes() throws {
        let events = try decode([FoundEvent].self, """
        [{"event_id": "e1", "name": "Modern Open", "format_key": "modern", "format_label": "Modern", "set_name": null, "cube_name": null,
          "team_size": null, "status": "setup", "current_round": 0, "starts_at": "2026-03-29T16:00:00+00:00", "venue_name": "MeH Games",
          "venue_address": "1 Main St", "capacity": null, "top_cut": 8, "visibility": "public", "players": 12, "organizer": "Bea",
          "has_description": true, "km": 19,
          "league": {"id": "l1", "slug": "mms", "name": "The Mountain Magic Series", "season_id": "s1", "season": "2026", "multiplier": 1.5, "final": false},
          "me": "player"},
         {"event_id": "e2", "name": "Friday draft", "format_key": "limited", "format_label": "Draft", "set_name": "Duskmourn", "cube_name": null,
          "team_size": null, "status": "in_progress", "current_round": 2, "starts_at": null, "venue_name": null, "venue_address": null,
          "capacity": 8, "top_cut": 0, "visibility": "friends", "players": 8, "organizer": null, "has_description": false, "km": null,
          "league": null, "me": null}]
        """)
        let denver = try XCTUnwrap(TimeZone(identifier: "America/Denver"))
        XCTAssertEqual(events[0].line(zone: denver, locale: Locale(identifier: "en_GB")), "SUN 29 MAR · 10:00 · MODERN · MEH GAMES · 19 KM")
        XCTAssertEqual(events[0].rowLabel, "THE MOUNTAIN MAGIC SERIES")
        XCTAssertEqual(events[0].league?.multiplier, 1.5)
        XCTAssertTrue(events[0].isIn)
        XCTAssertEqual(events[0].route, .event("e1"), "your own event opens itself")
        XCTAssertEqual(events[1].line(), "NOW · ROUND 2 · DRAFT · 8/8")
        XCTAssertEqual(events[1].rowLabel, "FRIENDS")
        XCTAssertEqual(events[1].route, .eventPage("e2", signUp: false))
        // The widget keeps them in the App Group as JSON: a round trip keeps every field.
        let again = try JSONDecoder().decode([FoundEvent].self, from: JSONEncoder().encode(events))
        XCTAssertEqual(again, events)
    }

    func testEventAboutAndListingDecode() throws {
        let a = try decode(EventAbout.self, """
        {"event_id": "e1", "description": "Doors at 9:30.", "venue_address": null, "visibility": "link_only", "format_key": "modern",
         "league": {"id": "l1", "slug": "mms", "name": "MMS", "season_id": "s1", "season": "2026", "multiplier": 2, "final": true}, "placed": false}
        """)
        XCTAssertTrue(a.hasAbout)
        XCTAssertTrue(a.resultsPublic, "a league event's results are public whatever its listing")
        XCTAssertEqual(a.league?.final, true)
        let plain = try decode(EventAbout.self, #"{"event_id": "e2", "description": null, "venue_address": null, "visibility": "link_only", "format_key": "cube", "league": null, "placed": false}"#)
        XCTAssertFalse(plain.hasAbout)
        XCTAssertFalse(plain.resultsPublic)
        let l = try decode(EventListing.self, #"{"description": null, "venue_address": "1 Main St", "visibility": "public"}"#)
        XCTAssertEqual(l.visibility, "public")
    }

    func testLeagueViewDecodes() throws {
        let p = try decode(LeaguePage.self, """
        {"league": {"id": "l1", "slug": "mms", "name": "The Mountain Magic Series", "description": null, "region": "Denver, Colorado",
                    "link": "https://example.com", "archived": false, "organizers": ["Bea", "Gus"]},
         "me": {"role": null, "following": true, "notify": false},
         "seasons": [{"id": "s1", "name": "2026", "starts_on": "2026-01-01", "ends_on": "2026-12-31", "state": "active"}],
         "season": {"id": "s1", "name": "2026", "starts_on": "2026-01-01", "ends_on": "2026-12-31", "state": "active",
                    "points": {"places": [{"through": 1, "points": 12}, {"through": 2, "points": 10}, {"through": 4, "points": 8},
                                          {"through": 8, "points": 6}, {"through": 16, "points": 3}], "participation": 1, "match_win": 0},
                    "best_n": null, "qualify": {"winners": true, "pass_down": true, "top": 10}, "closed": false},
         "events": [{"event_id": "e1", "name": "Modern Open", "format_label": "Modern", "format_key": "modern",
                     "starts_at": "2026-03-29T16:00:00+00:00", "venue_name": "MeH Games", "status": "completed", "multiplier": 1,
                     "final": false, "players": 41, "winner": "Bea"},
                    {"event_id": "e2", "name": "Legacy Open", "format_label": "Legacy", "format_key": "legacy",
                     "starts_at": "2026-12-05T17:00:00+00:00", "venue_name": null, "status": "setup", "multiplier": 2,
                     "final": false, "players": 3, "winner": null}],
         "standings": [{"rank": 1, "key": "u:1", "user_id": "u1", "name": "Bea", "points": 12, "events": 1, "wins": 1, "best": 1, "qualified": "winner"},
                       {"rank": 2, "key": "g:cy", "user_id": null, "name": "Cy", "points": 10, "events": 1, "wins": 0, "best": 2, "qualified": null}],
         "standings_count": 2,
         "my_row": {"rank": 2, "key": "u:9", "name": "Me", "points": 10, "events": 1, "wins": 0, "best": 2, "qualified": "points"}}
        """)
        XCTAssertEqual(p.season?.points, Leagues.places)
        XCTAssertEqual(Leagues.pointsWords(p.season!.points), "1st 12 · 2nd 10 · Top 4 8 · Top 8 6 · Top 16 3 · Others 1")
        XCTAssertEqual(Leagues.qualifyWords(p.season!.qualify), "Event winners and the top 10 on points")
        XCTAssertFalse(p.me.runs)
        XCTAssertNil(p.standings[1].userId, "a guest")
        XCTAssertEqual(p.myRow?.qualified, "points")
        XCTAssertEqual(LeagueView.ordered(p.events).map(\.eventId), ["e2", "e1"], "upcoming first, then finished")
        let gb = Locale(identifier: "en_GB")
        _ = gb
        XCTAssertTrue(LeagueView.eventLine(p.events[0]).hasSuffix("MODERN · Won by Bea") || LeagueView.eventLine(p.events[0]).contains("Won by Bea"))
        // `members` is for the league's own organizers: null (or absent, from an older server) for everyone else.
        XCTAssertNil(p.members)
        let mine = try decode(LeaguePage.self, """
        {"league": {"id": "l1", "slug": "mms", "name": "MMS", "description": null, "region": null, "link": null, "archived": false, "organizers": ["Ann", "Bea"]},
         "me": {"role": "owner", "following": false, "notify": false},
         "members": [{"user_id": "u9", "name": "Ann", "role": "owner"}, {"user_id": "u1", "name": "Bea", "role": "organizer"}],
         "seasons": [], "season": null, "events": [], "standings": [], "standings_count": 0, "my_row": null}
        """)
        XCTAssertEqual(mine.members?.map(\.userId), ["u9", "u1"])
        XCTAssertEqual(mine.members?.map(\.roleLabel), ["Owner", "Organizer"])
        XCTAssertTrue(mine.me.runs)
        let nulled = try decode(LeaguePage.self, """
        {"league": {"id": "l1", "slug": "mms", "name": "MMS", "description": null, "region": null, "link": null, "archived": false, "organizers": []},
         "me": {"role": null, "following": false, "notify": false}, "members": null,
         "seasons": [], "season": null, "events": [], "standings": [], "standings_count": 0, "my_row": null}
        """)
        XCTAssertNil(nulled.members)
        // An archived league's screens come off the stack and leave Find → Leagues.
        XCTAssertEqual(LeagueToolsView.afterArchive([.find("leagues"), .league("mms"), .leagueTools("l1")]), [.find("leagues")])
        XCTAssertEqual(LeagueToolsView.afterArchive([.find("events"), .league("mms"), .leagueTools("l1")]), [.find("leagues")])
        XCTAssertEqual(LeagueToolsView.afterArchive([.eventPage("e1", signUp: false), .leagueOn("mms", "s1"), .leagueTools("l1")]),
                       [.eventPage("e1", signUp: false), .find("leagues")])
        XCTAssertEqual(LeagueToolsView.afterArchive([.league("mms"), .leagueTools("l1"), .leagueSeason("l1", nil)]), [.find("leagues")])
        let rows = try decode([LeagueRow].self, #"[{"rank": 3, "key": "u:3", "user_id": null, "name": "Dee", "points": 8, "events": 2, "wins": 0, "best": 3, "qualified": null}]"#)
        XCTAssertEqual(rows[0].rank, 3)
        let season = try decode(LeagueSeason.self, #"{"id": "s2", "name": "Spring", "starts_on": "2027-01-01", "ends_on": "2027-06-30", "state": "upcoming", "points": {"places": [], "participation": 1, "match_win": 1}, "best_n": 6, "qualify": {"winners": false, "pass_down": true, "top": 8}, "closed": false}"#)
        XCTAssertEqual(Leagues.preset(season.points), "match_wins")
        XCTAssertEqual(season.bestN, 6)
    }

    func testLeaguePlayerAndHomeDecode() throws {
        let p = try decode(LeaguePlayer.self, """
        {"player": {"rank": 7, "key": "u:9", "user_id": "u9", "name": "Ann Ito", "points": 28, "events": 5, "wins": 0, "best": 3, "qualified": "points"},
         "events": [{"event_id": "e1", "name": "Legacy Open", "format_label": "Legacy", "starts_at": "2026-11-01T17:00:00+00:00", "place": 3,
                     "players": 34, "match_wins": 5, "points": 16, "counted": true},
                    {"event_id": "e2", "name": "Pioneer Open", "format_label": "Pioneer", "starts_at": null, "place": 21, "players": 30,
                     "match_wins": 1, "points": 1, "counted": false}]}
        """)
        XCTAssertEqual(LeaguePlayerView.summary(p.player), "#7 · 5 events · Qualified")
        XCTAssertFalse(p.events[1].counted)
        let h = try decode(LeaguesHome.self, """
        {"mine": [{"id": "l1", "slug": "mms", "name": "MMS", "region": "Denver, Colorado", "season": "2026",
                   "next_event": {"event_id": "e1", "name": "Modern Open", "starts_at": "2026-03-29T16:00:00+00:00", "format_label": "Modern"}, "role": "owner"}],
         "following": [{"id": "l2", "slug": "cube", "name": "Cube League", "region": null, "season": null, "next_event": null, "notify": true}],
         "found": []}
        """)
        XCTAssertEqual(h.mine[0].line, "2026 · DENVER, COLORADO · NEXT MODERN OPEN")
        XCTAssertEqual(h.mine[0].role, "owner")
        XCTAssertEqual(h.following[0].line, "")
    }

    func testBoardsDecode() throws {
        let b = try decode(FormatBoards.self, """
        {"listed": true, "boards": [
          {"board": "modern", "label": "Modern", "players": 124, "me": {"rating": 1612, "matches": 31, "wins": 19, "losses": 11, "draws": 1, "events": 6, "rank": 14, "to_go": 0}},
          {"board": "limited", "label": "Limited", "players": 143, "me": {"rating": 1540, "matches": 6, "wins": 4, "losses": 2, "draws": 0, "events": 2, "rank": null, "to_go": 4}},
          {"board": "cube", "label": "Cube", "players": 0, "me": null}]}
        """)
        XCTAssertEqual(b.boards.map(\.line), ["124 LISTED · YOU 1612 · #14", "143 LISTED · YOU 1540 · 4 TO GO", "0 LISTED"])
        XCTAssertEqual(BoardView.mine(b.boards[0].me!), "#14 · 19-11-1 · 31 matches")
        XCTAssertEqual(BoardView.mine(b.boards[1].me!), "4 to go · 4-2-0 · 6 matches")
        let signedOut = try decode(FormatBoards.self, #"{"listed": false, "boards": []}"#)
        XCTAssertFalse(signedOut.listed)
        let l = try decode(Leaderboard.self, """
        {"board": "modern", "label": "Modern", "count": 2, "me": null,
         "rows": [{"rank": 1, "user_id": "u1", "name": "Bea", "avatar_url": null, "rating": 1794, "matches": 30, "wins": 24, "losses": 6, "draws": 0, "events": 9},
                  {"rank": 2, "user_id": null, "name": "Cy", "avatar_url": null, "rating": 1780, "matches": 30, "wins": 23, "losses": 6, "draws": 1, "events": 9}]}
        """)
        XCTAssertEqual(l.rows[1].record, "23-6-1")
        XCTAssertNil(l.rows[1].userId, "signed out: names only")
    }

    // MARK: the widget and pushes

    func testUpcomingWidget() throws {
        let picks = UpcomingPicks(formats: ["modern", "cube"], nearMe: true)
        XCTAssertEqual(picks.key, "modern,cube|near")
        XCTAssertEqual(UpcomingPicks().key, "all|near")
        XCTAssertNil(UpcomingPicks().formatsLabel)
        XCTAssertEqual(picks.formatsLabel, "Modern · Cube")
        XCTAssertEqual(UpcomingPicks(formats: ["modern", "cube", "legacy"]).formatsLabel, "3 formats")
        // Near me reads Everywhere until the app has kept a place; Everywhere never sends one.
        XCTAssertNil(UpcomingWidgets.filters(picks, place: nil)["lat"])
        let near = UpcomingWidgets.filters(picks, place: (39.7, -105.0))
        XCTAssertEqual(near["km"] as? Int, 100)
        XCTAssertEqual(near["formats"] as? [String], ["modern", "cube"])
        XCTAssertNil(UpcomingWidgets.filters(UpcomingPicks(nearMe: false), place: (39.7, -105.0))["lat"])
        XCTAssertTrue(UpcomingWidgets.filters(UpcomingPicks(nearMe: false), place: nil).isEmpty)
        // The place is rough: a tenth of a degree.
        XCTAssertEqual(Leagues.rough(39.7392), 39.7)
        XCTAssertEqual(Leagues.rough(-104.9903), -105.0)
        let denver = try XCTUnwrap(TimeZone(identifier: "America/Denver"))
        var e = FoundEvent(eventId: "e1", name: "Modern Open", formatKey: "modern", formatLabel: "Modern", startsAt: "2026-03-29T16:00:00Z", venueName: "MeH Games")
        XCTAssertEqual(UpcomingWidgets.whenText(e, zone: denver, locale: Locale(identifier: "en_GB")), "SUN 29 · 10:00")
        XCTAssertEqual(UpcomingWidgets.detail(e), "MODERN · MEH GAMES")
        XCTAssertEqual(UpcomingWidgets.eventLink(e).absoluteString, "table1://event/e1?src=widget_upcoming")
        e.status = "in_progress"; e.currentRound = 3
        XCTAssertEqual(UpcomingWidgets.whenText(e, zone: denver), "NOW · R3")
    }

    func testPushTaps() {
        for kind in ["league.results", "league.qualified", "league.season"] {
            XCTAssertEqual(PushRoutes.league(["kind": kind, "league_id": "l1", "league_slug": "mms", "event_id": "e1"]), "l1", kind)
        }
        XCTAssertEqual(PushRoutes.league(["kind": "league.season", "league_slug": "mms"]), "mms", "the slug when there's no id")
        XCTAssertNil(PushRoutes.league(["kind": "league.results"]))
        // A new league event opens the event, like any event push.
        XCTAssertNil(PushRoutes.league(["kind": "league.event", "league_id": "l1", "event_id": "e1"]))
        XCTAssertNil(PushRoutes.league(["kind": "event.follow_round", "event_id": "e1"]))
        for kind in ["league.results", "league.event"] {
            let info: [AnyHashable: Any] = ["kind": kind, "league_id": "l1", "event_id": "e1"]
            XCTAssertNil(PushRoutes.library(info)); XCTAssertNil(PushRoutes.route(info)); XCTAssertNil(PushRoutes.insights(info))
            XCTAssertNil(PushRoutes.deckPhoto(info))
        }
    }

    func testLinkedTextMarksOnlyHttpsLinks() {
        let a = LinkedText.attributed("Rules: https://example.com/series and http://old.example.com, mail me@example.com")
        let links = a.runs.compactMap(\.link)
        XCTAssertEqual(links.map(\.absoluteString), ["https://example.com/series"])
        XCTAssertEqual(TextCount.text(1240, of: 2000), "1,240 / 2,000")
    }
}
