#if DEBUG
import Foundation

/// Stand-in answers for finding events, leagues and boards while a signed-out design demo is up (`-T1EventsDemo
/// home|find|findleagues|boards|board|league|leaguedetails|leaguestandings|leagueplayer|leagueorg|leagueseason|about`):
/// a twelve-month regional series with placement points 12/10/8/6/3/1, winners qualify, top 10 on points. Debug only;
/// `Repo`'s league calls answer from here instead of the server, and nothing here asks for location.
enum LeaguesDemo {
    static var on = false
    /// owner | nil: `leagueorg` opens the league as its owner.
    static var role: String?

    /// Who runs the sample league, as its owner sees them (`leagueorg`): you own it; the menu's changes stick here.
    static var members: [LeagueMember] = [
        LeagueMember(userId: me, name: "Ann Ito", role: "owner"),
        LeagueMember(userId: "demo-0", name: "Bea Kowalski", role: "organizer"),
        LeagueMember(userId: "demo-5", name: "Gus Varga", role: "organizer"),
    ]
    static var archived = false

    /// league_member_set on the sample league, with the server's rule that a league keeps an owner.
    static func setMember(_ userId: String, role: String?) throws {
        let owners = members.filter(\.isOwner).count
        if let m = members.first(where: { $0.userId == userId }), m.isOwner, role != "owner", owners <= 1 {
            throw NSError(domain: "Table1", code: 1, userInfo: [NSLocalizedDescriptionKey: "A league keeps an owner. Make someone else the owner first."])
        }
        members.removeAll { $0.userId == userId && role == nil }
        if let role, let i = members.firstIndex(where: { $0.userId == userId }) { members[i].role = role }
        else if let role { members.append(LeagueMember(userId: userId, name: "New organizer", role: role)) }
    }

    static let leagueId = "11111111-1111-4111-8111-111111111111"
    static let slug = "the-mountain-magic-series"
    static let seasonId = "22222222-2222-4222-8222-222222222222"
    static let lastSeasonId = "33333333-3333-4333-8333-333333333333"
    static let league = "The Mountain Magic Series"
    static let me = "demo-me"

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        do { return try wireDecoder.decode(T.self, from: Data(json.utf8)) } catch { fatalError("Leagues demo \(T.self): \(error)") }
    }

    /// `days` from today at `hour`:00 local, as the server writes times.
    private static func at(_ days: Int, _ hour: Int = 10) -> String {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: Date())) ?? Date()
        return Leagues.iso(cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day)
    }

    private static let leagueJSON = #"{"id": "\#(leagueId)", "slug": "\#(slug)", "name": "\#(league)", "season_id": "\#(seasonId)", "season": "2026", "multiplier": 1, "final": false}"#

    private static func found(_ id: String, _ name: String, _ key: String, _ label: String, days: Int, hour: Int = 10, venue: String?,
                              players: Int, capacity: Int? = nil, km: Int? = nil, visibility: String = "public", inLeague: Bool = false,
                              me: String? = nil, status: String = "setup", round: Int = 0, team: Int? = nil) -> String {
        """
        {"event_id": "\(id)", "name": "\(name)", "format_key": "\(key)", "format_label": "\(label)", "set_name": null, "cube_name": null,
         "team_size": \(team.map(String.init) ?? "null"), "status": "\(status)", "current_round": \(round), "starts_at": "\(at(days, hour))",
         "venue_name": \(venue.map { "\"\($0)\"" } ?? "null"), "venue_address": null, "capacity": \(capacity.map(String.init) ?? "null"),
         "top_cut": 8, "visibility": "\(visibility)", "players": \(players), "organizer": "Bea Kowalski", "has_description": \(inLeague),
         "km": \(km.map(String.init) ?? "null"), "league": \(inLeague ? leagueJSON : "null"), "me": \(me.map { "\"\($0)\"" } ?? "null")}
        """
    }

    static let events: [FoundEvent] = decode([FoundEvent].self, "[" + [
        found("f0", "Legacy Open", "legacy", "Legacy", days: 0, hour: 9, venue: "Mythic Games", players: 30, capacity: 32, km: 4, status: "in_progress", round: 3),
        found("f1", "Modern Open", "modern", "Modern", days: 2, venue: "MeH Games", players: 12, km: 19, inLeague: true, me: "player"),
        found("f2", "Friday draft", "limited", "Draft", days: 4, hour: 18, venue: nil, players: 5, capacity: 8, visibility: "friends"),
        found("f3", "Pioneer Open", "pioneer", "Pioneer", days: 9, venue: "Level 7 Games", players: 21, capacity: 64, km: 6, inLeague: true),
        found("f4", "Vintage Cube night", "cube", "Draft · Vintage Cube", days: 11, hour: 18, venue: "Dragon's Lair", players: 6, capacity: 8, km: 2),
        found("f5", "Team Sealed", "limited", "Team sealed", days: 16, venue: "Mythic Games", players: 18, capacity: 36, km: 4, team: 3),
        found("f6", "Standard Open", "standard", "Standard", days: 23, venue: "MeH Games", players: 8, km: 19, inLeague: true),
        found("f7", "Pauper League night", "pauper", "Pauper", days: 30, hour: 18, venue: "Level 7 Games", players: 4, km: 6),
    ].joined(separator: ",") + "]")

    /// The picks cut the sample list the way the server would (formats, team, league, seats left, scope, words).
    static func find(_ f: Leagues.Filters, q: String) -> [FoundEvent] {
        let words = q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let window = Leagues.whenWindow(f.when, now: Date(), zone: .current)
        return events.filter { e in
            if !f.formats.isEmpty, !f.formats.contains(e.formatKey ?? "") { return false }
            if f.team, e.teamSize == nil { return false }
            if f.league, e.league == nil { return false }
            if f.open, !(e.status == "setup" && (e.capacity == nil || (e.players ?? 0) < (e.capacity ?? 0))) { return false }
            if f.scope != "all", e.visibility != f.scope { return false }
            if let window, let d = e.startDate, !(window.from <= d && d < window.to) { return false }
            if words.count >= 2, !"\(e.name) \(e.venueName ?? "") \(e.league?.name ?? "")".lowercased().contains(words) { return false }
            return true
        }
    }

    static func about(_ eventId: String) -> EventAbout {
        let e = events.first { $0.eventId == eventId }
        guard e?.league != nil || eventId == "about" else {
            return EventAbout(eventId: eventId, visibility: e?.visibility ?? "link_only", formatKey: e?.formatKey)
        }
        return decode(EventAbout.self, """
        {"event_id": "\(eventId)", "description": "Swiss rounds, then a cut to the top 8. Doors at 9:30, round 1 at 10:00 sharp.\\n\\nDecklists are due before round 1. Rules and the season's standings: https://example.com/series",
         "venue_address": "1234 Main Street, Denver, CO 80202", "visibility": "public", "format_key": "modern", "league": \(leagueJSON), "placed": false}
        """)
    }

    static let names = ["Bea Kowalski", "Cy Park", "Dee Okafor", "Eli Moreau", "Fen Zhou", "Gus Varga", "Ann Ito", "Hal Brandt", "Ivy Novak", "Jo Reyes",
                        "Kai Sato", "Lu Bianchi", "Max Weber", "Nia Adeyemi", "Oli Kerr", "Pia Holm", "Quin Abara", "Rae Lindgren", "Sol Mendez",
                        "Tess Aldana", "Uma Roy", "Vik Petrov", "Wes Tanaka", "Xan Doyle"]
    private static let points = [47, 41, 38, 36, 33, 30, 28, 27, 24, 22, 21, 19, 18, 16, 15, 13, 12, 10, 9, 7, 6, 4, 3, 1]

    /// 24 players; the first three won an event, the next ten are in on points; you are seventh.
    static let table: [LeagueRow] = names.enumerated().map { i, name in
        LeagueRow(rank: i + 1, key: i == 6 ? "u:\(me)" : "u:demo-\(i)", userId: i == 6 ? me : "demo-\(i)", name: name, points: points[i],
                  events: max(1, 6 - i / 5), wins: i < 3 ? 1 : 0, best: i < 3 ? 1 : min(16, i), qualified: i < 3 ? "winner" : i < 13 ? "points" : nil)
    }

    private static func leagueEvent(_ id: String, _ name: String, _ key: String, _ label: String, days: Int, venue: String, status: String,
                                    players: Int, winner: String? = nil, multiplier: Double = 1, final: Bool = false) -> String {
        """
        {"event_id": "\(id)", "name": "\(name)", "format_label": "\(label)", "format_key": "\(key)", "starts_at": "\(at(days))",
         "venue_name": "\(venue)", "status": "\(status)", "multiplier": \(multiplier), "final": \(final), "players": \(players),
         "winner": \(winner.map { "\"\($0)\"" } ?? "null")}
        """
    }

    static func page(_ season: String?) -> LeaguePage {
        let last = season == lastSeasonId
        let year = Calendar.current.component(.year, from: Date())
        return decode(LeaguePage.self, """
        {"league": {"id": "\(leagueId)", "slug": "\(slug)", "name": "\(league)",
                    "description": "A year of opens across the Front Range. Every event earns points, every winner is in the final, and the ten best on points join them.\\n\\nhttps://example.com/series",
                    "region": "Denver, Colorado", "link": "https://example.com/series", "archived": false,
                    "organizers": ["Bea Kowalski", "Gus Varga"]},
         "me": {"role": \(role.map { "\"\($0)\"" } ?? "null"), "following": \(role == nil), "notify": true},
         "members": null,
         "seasons": [{"id": "\(seasonId)", "name": "\(year)", "starts_on": "\(year)-01-01", "ends_on": "\(year)-12-31", "state": "active"},
                     {"id": "\(lastSeasonId)", "name": "\(year - 1)", "starts_on": "\(year - 1)-01-01", "ends_on": "\(year - 1)-12-31", "state": "over"}],
         "season": {"id": "\(last ? lastSeasonId : seasonId)", "name": "\(last ? year - 1 : year)", "starts_on": "\(last ? year - 1 : year)-01-01",
                    "ends_on": "\(last ? year - 1 : year)-12-31", "state": "\(last ? "over" : "active")",
                    "points": {"places": [{"through": 1, "points": 12}, {"through": 2, "points": 10}, {"through": 4, "points": 8},
                                          {"through": 8, "points": 6}, {"through": 16, "points": 3}], "participation": 1, "match_win": 0},
                    "best_n": null, "qualify": {"winners": true, "pass_down": true, "top": 10}, "closed": \(last)},
         "events": [\([
            leagueEvent("f1", "Modern Open", "modern", "Modern", days: 2, venue: "MeH Games", status: "setup", players: 12),
            leagueEvent("f3", "Pioneer Open", "pioneer", "Pioneer", days: 9, venue: "Level 7 Games", status: "setup", players: 21),
            leagueEvent("f6", "Standard Open", "standard", "Standard", days: 23, venue: "MeH Games", status: "setup", players: 8),
            leagueEvent("f9", "The Final", "modern", "Modern", days: 44, venue: "Mythic Games", status: "setup", players: 3, final: true),
            leagueEvent("p1", "Legacy Open", "legacy", "Legacy", days: -12, venue: "Mythic Games", status: "completed", players: 34, winner: "Dee Okafor", multiplier: 2),
            leagueEvent("p2", "Modern Open", "modern", "Modern", days: -40, venue: "MeH Games", status: "completed", players: 41, winner: "Cy Park"),
            leagueEvent("p3", "Pauper Open", "pauper", "Pauper", days: -68, venue: "Level 7 Games", status: "completed", players: 22, winner: "Bea Kowalski"),
         ].joined(separator: ","))],
         "standings": [], "standings_count": \(table.count), "my_row": null}
        """).with(table)
    }

    static func player(_ key: String) -> LeaguePlayer {
        let row = table.first { $0.key == key } ?? table[6]
        func event(_ id: String, _ name: String, _ label: String, days: Int, place: Int, players: Int, wins: Int, points: Int, counted: Bool = true) -> String {
            """
            {"event_id": "\(id)", "name": "\(name)", "format_label": "\(label)", "starts_at": "\(at(days))", "place": \(place),
             "players": \(players), "match_wins": \(wins), "points": \(points), "counted": \(counted)}
            """
        }
        let events: [LeaguePlayer.Event] = decode([LeaguePlayer.Event].self, "[" + [
            event("p1", "Legacy Open", "Legacy", days: -12, place: 3, players: 34, wins: 5, points: 16),
            event("p2", "Modern Open", "Modern", days: -40, place: 7, players: 41, wins: 4, points: 6),
            event("p3", "Pauper Open", "Pauper", days: -68, place: 12, players: 22, wins: 3, points: 3),
            event("p4", "Standard Open", "Standard", days: -96, place: 15, players: 28, wins: 2, points: 3),
            event("p5", "Pioneer Open", "Pioneer", days: -124, place: 21, players: 30, wins: 1, points: 1, counted: false),
        ].joined(separator: ",") + "]")
        return LeaguePlayer(player: row, events: events)
    }

    static func home(_ query: String) -> LeaguesHome {
        let card = #"{"id": "\#(leagueId)", "slug": "\#(slug)", "name": "\#(league)", "region": "Denver, Colorado", "season": "2026", "next_event": {"event_id": "f1", "name": "Modern Open", "starts_at": "\#(at(2))", "format_label": "Modern"}"#
        let other = #"{"id": "44444444-4444-4444-8444-444444444444", "slug": "front-range-cube-league", "name": "Front Range Cube League", "region": "Boulder, Colorado", "season": "Spring", "next_event": {"event_id": "f4", "name": "Week 6", "starts_at": "\#(at(11))", "format_label": "Draft"}}"#
        let found = query.count >= 2 ? #"[{"id": "55555555-5555-4555-8555-555555555555", "slug": "pikes-peak-pauper", "name": "Pikes Peak Pauper", "region": "Colorado Springs, Colorado", "season": "2026", "next_event": null}]"# : "[]"
        let mine = role != nil && !archived ? "[" + card + #", "role": "owner"}]"# : "[]"
        let following = "[" + (role == nil ? card + #", "notify": true},"# : "") + other + "]"
        return decode(LeaguesHome.self, #"{"mine": \#(mine), "following": \#(following), "found": \#(found)}"#)
    }

    /// A profile's achievements (`-T1LibraryDemo profile|myprofile`): a champion, a running season, a top 4 in another
    /// league, two boards; on your own profile also the board that doesn't list you yet.
    static func achievements(own: Bool) -> ProfileAchievements {
        let year = Calendar.current.component(.year, from: Date())
        func leagueItem(_ name: String, _ season: String, _ id: String, state: String, rank: Int?, wins: Int, qualified: String?, champion: Bool) -> String {
            """
            {"kind": "league", "league_id": "\(leagueId)", "league_slug": "\(slug)", "league_name": "\(name)", "season_id": "\(id)",
             "season_name": "\(season)", "state": "\(state)", "rank": \(rank.map(String.init) ?? "null"), "players": 96, "points": 41,
             "wins": \(wins), "qualified": \(qualified.map { "\"\($0)\"" } ?? "null"), "champion": \(champion)}
            """
        }
        func boardItem(_ key: String, rank: Int?, rating: Int, matches: Int) -> String {
            #"{"kind": "board", "board": "\#(key)", "label": "\#(Leagues.label(key))", "rank": \#(rank.map(String.init) ?? "null"), "rating": \#(rating), "matches": \#(matches), "to_go": \#(max(0, 10 - matches)), "players": 124}"#
        }
        let items = [
            leagueItem(league, "\(year - 1)", lastSeasonId, state: "over", rank: 5, wins: 1, qualified: "winner", champion: true),
            leagueItem(league, "\(year)", seasonId, state: "active", rank: 4, wins: 0, qualified: nil, champion: false),
            leagueItem("Front Range Cube League", "Spring", "66666666-6666-4666-8666-666666666666", state: "over", rank: 3, wins: 0, qualified: nil, champion: false),
            boardItem("cube", rank: 9, rating: 1571, matches: 18),
            boardItem("modern", rank: 14, rating: 1612, matches: 31),
        ] + (own ? [boardItem("limited", rank: nil, rating: 1540, matches: 6)] : [])
        return decode(ProfileAchievements.self, "{\"items\": [" + items.joined(separator: ",") + "]" + (own ? ", \"visibility\": \"public\", \"listed\": true" : "") + "}")
    }

    static let boards: FormatBoards = {
        let mine: [String: String] = [
            "modern": #"{"rating": 1612, "matches": 31, "wins": 19, "losses": 11, "draws": 1, "events": 6, "rank": 14, "to_go": 0}"#,
            "limited": #"{"rating": 1540, "matches": 6, "wins": 4, "losses": 2, "draws": 0, "events": 2, "rank": null, "to_go": 4}"#,
            "cube": #"{"rating": 1571, "matches": 18, "wins": 11, "losses": 7, "draws": 0, "events": 5, "rank": 9, "to_go": 0}"#,
        ]
        let counts = ["standard": 86, "pioneer": 61, "modern": 124, "legacy": 47, "vintage": 12, "pauper": 38, "premodern": 9,
                      "canadian_highlander": 0, "limited": 143, "cube": 52]
        let rows = Leagues.formatKeys.filter { $0.key != "other" }.map { k in
            #"{"board": "\#(k.key)", "label": "\#(k.label)", "players": \#(counts[k.key] ?? 0), "me": \#(mine[k.key] ?? "null")}"#
        }
        return decode(FormatBoards.self, #"{"listed": true, "boards": [\#(rows.joined(separator: ","))]}"#)
    }()

    static func board(_ key: String) -> Leaderboard {
        let card = boards.boards.first { $0.board == key }
        let rows = names.enumerated().map { i, name -> String in
            let wins = 24 - i, losses = 6 + i / 2
            return #"{"rank": \#(i + 1), "user_id": "\#(i == 13 ? me : "demo-\(i)")", "name": "\#(i == 13 ? "Ann Ito" : name == "Ann Ito" ? "Nia Adeyemi" : name)", "avatar_url": null, "rating": \#(i == 13 ? 1612 : 1794 - i * 14), "matches": \#(wins + losses), "wins": \#(wins), "losses": \#(losses), "draws": \#(i % 3 == 0 ? 1 : 0), "events": \#(9 - i / 4)}"#
        }
        let mine = card?.me.map { m in
            #"{"rating": \#(m.rating), "matches": \#(m.matches), "wins": \#(m.wins), "losses": \#(m.losses), "draws": \#(m.draws), "events": \#(m.events), "rank": \#(m.rank.map(String.init) ?? "null"), "to_go": \#(m.toGo)}"#
        } ?? "null"
        return decode(Leaderboard.self, #"{"board": "\#(key)", "label": "\#(Leagues.label(key))", "count": \#(card?.players ?? rows.count), "me": \#(mine), "rows": [\#(rows.joined(separator: ","))]}"#)
    }
}

private extension LeaguePage {
    /// The page with the sample table: the first 50 rows and your own.
    func with(_ table: [LeagueRow]) -> LeaguePage {
        var p = self
        if LeaguesDemo.role != nil {
            p.members = LeaguesDemo.members
            p.league.organizers = LeaguesDemo.members.map(\.name)
        }
        p.standings = Array(table.prefix(50))
        p.myRow = table.first { $0.userId == LeaguesDemo.me }
        return p
    }
}
#endif
