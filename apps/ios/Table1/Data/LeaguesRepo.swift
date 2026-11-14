import Foundation
import Supabase

/* Server calls for finding events, leagues and format boards (contract/public-events-leagues-2026-11-13.md §§ 1, 3, 4).
   The server part may not be live where a build runs: a missing function sets `LeaguesServer.missing`, so the screens
   hide their sections (or show the plain error row with Try again) and nothing is reported. In Debug the signed-out
   design demos answer from LeaguesDemo instead. */

enum LeaguesServer {
    /// A call found no such function on the server: the new choices in Create and Setup → Details stay hidden.
    static var missing = false
}

extension Repo {
    private static func json(_ v: Any) -> AnyJSON { AnyJSON.from(v) }

    private static func text(_ s: String?) -> AnyJSON {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return .null }
        return .string(t)
    }

    /// One RPC, decoded; a function the server doesn't have is noted and rethrown.
    private static func leagues<T: Decodable>(_ fn: String, _ params: [String: AnyJSON] = [:]) async throws -> T {
        do {
            let data = try await supabase.rpc(fn, params: params).execute().data
            LeaguesServer.missing = false
            return try wireDecoder.decode(T.self, from: data)
        } catch {
            if Leagues.isMissing(error) { LeaguesServer.missing = true }
            throw error
        }
    }

    // MARK: finding events

    /// The events you can find, soonest first. `here` only with a distance picked (never stored).
    static func findEvents(_ filters: Leagues.Filters, q: String = "", here: Fix? = nil, limit: Int = 50) async throws -> [FoundEvent] {
        #if DEBUG
        if LeaguesDemo.on { return LeaguesDemo.find(filters, q: q) }
        #endif
        let f = filters.json(here: here.map { (lat: $0.lat, lng: $0.lng) }, q: q)
        return try await leagues("find_events", ["p_filters": json(f), "p_limit": .integer(limit)])
    }

    /// What the event page adds: description, address, league.
    static func eventAbout(_ eventId: String) async throws -> EventAbout {
        #if DEBUG
        if LeaguesDemo.on { return LeaguesDemo.about(eventId) }
        #endif
        return try await leagues("event_about", ["p_event_id": .string(eventId)])
    }

    /// Who can find it (`find`: public | friends | private), the description and the address; nil leaves a key alone,
    /// an empty string clears it. `here` is the event's place, for distance.
    @discardableResult
    static func setEventListing(_ eventId: String, find: String? = nil, description: String? = nil, address: String? = nil,
                                here: Fix? = nil) async throws -> EventListing {
        var patch: [String: AnyJSON] = [:]
        if let find { patch["find"] = .string(find) }
        if let description { patch["description"] = text(description) }
        if let address { patch["venue_address"] = text(address) }
        if let here { patch["lat"] = .double(here.lat); patch["lng"] = .double(here.lng) }
        let r: EventListing = try await leagues("event_listing_set", ["p_event_id": .string(eventId), "p_patch": .object(patch)])
        Telemetry.capture("event_listing_saved", ["find": find ?? "kept", "description": !(r.description ?? "").isEmpty])
        return r
    }

    // MARK: leagues

    static func leaguesHome(query: String = "") async throws -> LeaguesHome {
        #if DEBUG
        if LeaguesDemo.on { return LeaguesDemo.home(query) }
        #endif
        return try await leagues("leagues_home", ["p_query": text(query)])
    }

    /// `league`: the id or the slug.
    static func leagueView(_ league: String, seasonId: String? = nil) async throws -> LeaguePage {
        #if DEBUG
        if LeaguesDemo.on { return LeaguesDemo.page(seasonId) }
        #endif
        return try await leagues("league_view", ["p_league": .string(league), "p_season_id": seasonId.map { .string($0) } ?? .null])
    }

    static func leagueStandings(_ seasonId: String, after: Int = 0, limit: Int = 100) async throws -> [LeagueRow] {
        #if DEBUG
        if LeaguesDemo.on { return Array(LeaguesDemo.table.dropFirst(after).prefix(limit)) }
        #endif
        return try await leagues("league_standings", ["p_season_id": .string(seasonId), "p_after": .integer(after), "p_limit": .integer(limit)])
    }

    static func leaguePlayer(_ seasonId: String, key: String) async throws -> LeaguePlayer {
        #if DEBUG
        if LeaguesDemo.on { return LeaguesDemo.player(key) }
        #endif
        return try await leagues("league_player", ["p_season_id": .string(seasonId), "p_key": .string(key)])
    }

    static func setLeagueFollow(_ leagueId: String, follow: Bool, notify: Bool? = nil) async throws -> LeagueMe {
        let r: LeagueMe = try await leagues("league_follow_set", [
            "p_league_id": .string(leagueId), "p_follow": .bool(follow), "p_notify": notify.map { .bool($0) } ?? .null,
        ])
        if notify == nil { Telemetry.capture("league_followed", ["following": r.following]) }
        return r
    }

    static func createLeague(name: String, description: String, region: String, link: String) async throws -> LeagueInfo {
        let l: LeagueInfo = try await leagues("league_create", [
            "p_name": .string(name), "p_description": text(description), "p_region": text(region), "p_link": text(link),
        ])
        Telemetry.capture("league_created")
        return l
    }

    /// `patch`: name, description, region, link (empty clears), archived.
    static func updateLeague(_ leagueId: String, patch: [String: Any]) async throws -> LeagueInfo {
        #if DEBUG
        if LeaguesDemo.on {
            if patch["archived"] as? Bool == true { LeaguesDemo.archived = true }
            return LeaguesDemo.page(nil).league
        }
        #endif
        return try await leagues("league_update", ["p_league_id": .string(leagueId), "p_patch": json(patch)])
    }

    /// `role`: owner | organizer, or nil to remove (the league's owner only).
    static func setLeagueMember(_ leagueId: String, userId: String, role: String?) async throws {
        #if DEBUG
        if LeaguesDemo.on { try LeaguesDemo.setMember(userId, role: role); return }
        #endif
        struct Answer: Decodable { let role: String? }
        let _: Answer = try await leagues("league_member_set", [
            "p_league_id": .string(leagueId), "p_user_id": .string(userId), "p_role": role.map { .string($0) } ?? .null,
        ])
    }

    /// A new season (`seasonId` nil: needs name, dates and points) or a change to one. `closed: true` closes it.
    static func setLeagueSeason(_ leagueId: String, seasonId: String?, name: String? = nil, startsOn: String? = nil,
                                endsOn: String? = nil, points: Leagues.Rule? = nil, bestN: Int?? = nil,
                                qualify: Leagues.Qualify? = nil, closed: Bool? = nil) async throws -> LeagueSeason {
        var patch: [String: Any] = [:]
        if let name { patch["name"] = name }
        if let startsOn { patch["starts_on"] = startsOn }
        if let endsOn { patch["ends_on"] = endsOn }
        if let points {
            patch["points"] = ["places": points.places.map { ["through": $0.through, "points": $0.points] },
                               "participation": points.participation, "match_win": points.matchWin] as [String: Any]
        }
        var out = json(patch)
        if case .object(var o) = out {
            if let bestN { o["best_n"] = bestN.map { AnyJSON.integer($0) } ?? AnyJSON.null }
            if let qualify { o["qualify"] = .object(["winners": .bool(qualify.winners), "pass_down": .bool(qualify.passDown), "top": .integer(qualify.top)]) }
            if let closed { o["closed"] = .bool(closed) }
            out = .object(o)
        }
        let s: LeagueSeason = try await leagues("league_season_set", [
            "p_league_id": .string(leagueId), "p_season_id": seasonId.map { .string($0) } ?? .null, "p_patch": out,
        ])
        if let points { Telemetry.capture("league_season_saved", ["preset": Leagues.preset(points)]) }
        return s
    }

    /// Puts an event in a season, or takes it out (`seasonId` nil). Returns the event's league.
    @discardableResult
    static func setLeagueEvent(_ eventId: String, seasonId: String?, multiplier: Double = 1, final: Bool = false) async throws -> EventLeague? {
        struct Answer: Decodable { let league: EventLeague? }
        let a: Answer = try await leagues("league_event_set", [
            "p_event_id": .string(eventId), "p_season_id": seasonId.map { .string($0) } ?? .null,
            "p_multiplier": .double(multiplier), "p_final": .bool(final),
        ])
        if seasonId != nil { Telemetry.capture("league_event_set", ["final": final, "multiplier": multiplier]) }
        return a.league
    }

    // MARK: achievements on profiles (contract § 7)

    /// A profile's achievements; on your own also who sees them. Throws on a server without it: no section then.
    static func profileAchievements(_ userId: String) async throws -> ProfileAchievements {
        try await leagues("profile_achievements", ["p_user_id": .string(userId)])
    }

    /// Who sees your achievements: private | friends | public.
    static func setAchievementsVisibility(_ visibility: String) async throws -> String {
        struct Answer: Decodable { let visibility: String }
        let a: Answer = try await leagues("achievements_visibility_set", ["p_visibility": .string(visibility)])
        Telemetry.capture("achievements_visibility", ["visibility": a.visibility])
        return a.visibility
    }

    // MARK: format boards

    static func formatBoards() async throws -> FormatBoards {
        #if DEBUG
        if LeaguesDemo.on { return LeaguesDemo.boards }
        #endif
        return try await leagues("format_boards")
    }

    static func formatLeaderboard(_ board: String, after: Int = 0, limit: Int = 100) async throws -> Leaderboard {
        #if DEBUG
        if LeaguesDemo.on { return LeaguesDemo.board(board) }
        #endif
        return try await leagues("format_leaderboard", ["p_board": .string(board), "p_after": .integer(after), "p_limit": .integer(limit)])
    }

    /// Show or hide yourself on every board.
    static func setLeaderboardsListed(_ listed: Bool) async throws -> Bool {
        struct Answer: Decodable { let listed: Bool }
        let a: Answer = try await leagues("leaderboards_listed_set", ["p_listed": .bool(listed)])
        Telemetry.capture("leaderboards_listed", ["listed": a.listed])
        return a.listed
    }
}
