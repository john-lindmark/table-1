import Foundation

/* Finding events, leagues and format boards (contract/public-events-leagues-2026-11-13.md): the wire models and every
   small rule and wording the three clients share. Change a rule in testdata/leagues/make_cases.py first, then make this
   pass testdata/leagues/cases.json (LeaguesTests). Foundation only: the Upcoming events widget compiles it too. */

// MARK: wire (decoded with T1Shared.snakeDecoder)

/// The league an event is in, as find_events and event_about send it.
struct EventLeague: Codable, Hashable {
    var id: String?
    var slug: String?
    var name: String
    var seasonId: String?
    var season: String?
    var multiplier: Double?
    var `final`: Bool?
}

/// One of find_events' rows.
struct FoundEvent: Codable, Identifiable, Hashable {
    let eventId: String
    var name: String
    var formatKey: String?
    var formatLabel: String?
    var setName: String?
    var cubeName: String?
    var teamSize: Int?
    var status: String = "setup"
    var currentRound: Int?
    var startsAt: String?
    var venueName: String?
    var venueAddress: String?
    var capacity: Int?
    var topCut: Int?
    var visibility: String?
    var players: Int?
    var organizer: String?
    var hasDescription: Bool?
    var km: Int?
    var league: EventLeague?
    /// organizer | player | waitlisted | nil
    var me: String?

    var id: String { eventId }
    var startDate: Date? { startsAt.flatMap(Leagues.parseDate) }
    var isIn: Bool { me != nil }

    /// The small label above the name: the league's name, else FRIENDS for a friends event.
    var rowLabel: String? { Leagues.rowLabel(league: league?.name, visibility: visibility) }

    /// `SUN 29 MAR · 10:00 · MODERN · MEH GAMES · 19 KM` in the device's zone.
    func line(zone: TimeZone = .current, locale: Locale = .current) -> String {
        Leagues.eventLine(status: status, currentRound: currentRound ?? 0, formatLabel: formatLabel ?? Leagues.label(formatKey ?? "other"),
                          venueName: venueName, capacity: capacity, players: players ?? 0, km: km,
                          when: startDate.map { Leagues.whenText($0, zone: zone, locale: locale) })
    }
}

/// event_about: what the event page adds.
struct EventAbout: Codable, Hashable {
    var eventId: String?
    var description: String?
    var venueAddress: String?
    var visibility: String?
    var formatKey: String?
    var league: EventLeague?
    var placed: Bool?

    var hasAbout: Bool { !(description ?? "").isEmpty || !(venueAddress ?? "").isEmpty }
    /// Results here are public: a public event, or one in a league.
    var resultsPublic: Bool { visibility == "public" || league != nil }
}

/// event_listing_set's answer.
struct EventListing: Codable, Hashable {
    var description: String?
    var venueAddress: String?
    var visibility: String?
}

struct LeagueInfo: Codable, Hashable {
    let id: String
    var slug: String
    var name: String
    var description: String?
    var region: String?
    var link: String?
    var archived: Bool?
    var organizers: [String]?
}

struct LeagueMe: Codable, Hashable {
    var role: String?
    var following: Bool = false
    var notify: Bool = false
    var runs: Bool { role != nil }
}

struct LeagueSeasonHead: Codable, Hashable, Identifiable {
    let id: String
    var name: String
    var startsOn: String
    var endsOn: String
    /// upcoming | active | over
    var state: String
}

struct LeagueSeason: Codable, Hashable, Identifiable {
    let id: String
    var name: String
    var startsOn: String
    var endsOn: String
    var state: String
    var points: Leagues.Rule
    var bestN: Int?
    var qualify: Leagues.Qualify
    var closed: Bool = false
}

struct LeagueEvent: Codable, Hashable, Identifiable {
    let eventId: String
    var name: String
    var formatLabel: String?
    var formatKey: String?
    var startsAt: String?
    var venueName: String?
    var status: String
    var multiplier: Double?
    var `final`: Bool?
    var players: Int?
    var winner: String?
    var id: String { eventId }
    var startDate: Date? { startsAt.flatMap(Leagues.parseDate) }
    var isOver: Bool { status == "completed" || status == "archived" }
}

/// A standings row. `qualified`: winner | points | nil. `userId` is nil for guests and signed-out readers.
struct LeagueRow: Codable, Hashable, Identifiable {
    var rank: Int
    var key: String
    var userId: String?
    var name: String
    var points: Int
    var events: Int
    var wins: Int
    var best: Int?
    var qualified: String?
    var id: String { key }
}

/// Someone who runs a league, with their account: sent to the league's own organizers only.
struct LeagueMember: Codable, Hashable, Identifiable {
    let userId: String
    var name: String
    /// owner | organizer
    var role: String
    var id: String { userId }
    var isOwner: Bool { role == "owner" }
    var roleLabel: String { isOwner ? "Owner" : "Organizer" }
}

struct LeaguePage: Codable, Hashable {
    var league: LeagueInfo
    var me: LeagueMe
    /// Who runs it, with accounts; nil for anyone who doesn't (and from a server before it).
    var members: [LeagueMember]?
    var seasons: [LeagueSeasonHead]
    var season: LeagueSeason?
    var events: [LeagueEvent]
    var standings: [LeagueRow]
    var standingsCount: Int
    var myRow: LeagueRow?
}

struct LeaguePlayer: Codable, Hashable {
    struct Event: Codable, Hashable, Identifiable {
        let eventId: String
        var name: String
        var formatLabel: String?
        var startsAt: String?
        var place: Int
        var players: Int?
        var matchWins: Int?
        var points: Int
        var counted: Bool
        var id: String { eventId }
    }
    var player: LeagueRow
    var events: [Event]
}

struct LeagueCard: Codable, Hashable, Identifiable {
    struct Next: Codable, Hashable {
        var eventId: String?
        var name: String
        var startsAt: String?
        var formatLabel: String?
    }
    let id: String
    var slug: String
    var name: String
    var region: String?
    var season: String?
    var nextEvent: Next?
    var role: String?
    var notify: Bool?

    var line: String { Leagues.leagueLine(season: season, region: region, next: nextEvent?.name) }
}

struct LeaguesHome: Codable, Hashable {
    var mine: [LeagueCard] = []
    var following: [LeagueCard] = []
    var found: [LeagueCard] = []
}

struct BoardMe: Codable, Hashable {
    var rating: Int
    var matches: Int = 0
    var wins: Int = 0
    var losses: Int = 0
    var draws: Int = 0
    var events: Int = 0
    var rank: Int?
    var toGo: Int = 0
    var record: String { "\(wins)-\(losses)-\(draws)" }
}

struct BoardCard: Codable, Hashable, Identifiable {
    let board: String
    var label: String
    var players: Int
    var me: BoardMe?
    var id: String { board }
    var line: String { Leagues.boardLine(players: players, rating: me?.rating, rank: me?.rank, toGo: me?.toGo ?? 0) }
}

struct FormatBoards: Codable, Hashable {
    var listed: Bool = false
    var boards: [BoardCard] = []
}

struct Leaderboard: Codable, Hashable {
    struct Row: Codable, Hashable {
        var rank: Int
        var userId: String?
        var name: String
        var avatarUrl: String?
        var rating: Int
        var matches: Int = 0
        var wins: Int = 0
        var losses: Int = 0
        var draws: Int = 0
        var events: Int = 0
        var record: String { "\(wins)-\(losses)-\(draws)" }
    }
    var board: String
    var label: String
    var count: Int
    var me: BoardMe?
    var rows: [Row]
}

/// A profile achievement (contract § 7): a league season (`kind` league) or a format board (`kind` board). Nothing is
/// stored: the server reads them from the standings and the boards each time.
struct Achievement: Codable, Hashable, Identifiable {
    var kind: String
    var leagueId: String?
    var leagueSlug: String?
    var leagueName: String?
    var seasonId: String?
    var seasonName: String?
    /// upcoming | active | over
    var state: String?
    /// nil when they only played the final (league), or when the board doesn't list them yet (own profile only).
    var rank: Int?
    var players: Int?
    var points: Int?
    var wins: Int?
    /// winner | points | nil
    var qualified: String?
    var champion: Bool?
    var board: String?
    var label: String?
    var rating: Int?
    var matches: Int?
    var toGo: Int?

    var id: String { kind == "board" ? "board:\(board ?? label ?? "")" : "league:\(seasonId ?? "\(leagueName ?? "") \(seasonName ?? "")")" }
    var isBoard: Bool { kind == "board" }
}

/// profile_achievements: the tiles, and on your own profile who sees them and whether the boards list you.
struct ProfileAchievements: Codable, Hashable {
    var items: [Achievement] = []
    var visibility: String?
    var listed: Bool?
}

// MARK: rules and wording

enum Leagues {
    /// What an event is filtered and rated under, in the pickers' order.
    static let formatKeys: [(key: String, label: String)] = [
        ("standard", "Standard"), ("pioneer", "Pioneer"), ("modern", "Modern"), ("legacy", "Legacy"), ("vintage", "Vintage"),
        ("pauper", "Pauper"), ("premodern", "Premodern"), ("canadian_highlander", "Canadian Highlander"),
        ("limited", "Limited"), ("cube", "Cube"), ("other", "Other"),
    ]

    static func label(_ key: String) -> String { formatKeys.first { $0.key == key }?.label ?? "Other" }

    /// Where choices (km); nil = Everywhere.
    static let distances = [25, 50, 100, 250]
    /// When choices: key and label.
    static let whens: [(key: String, label: String)] = [
        ("any", "Any time"), ("today", "Today"), ("weekend", "This weekend"), ("week", "This week"), ("month", "This month"),
    ]
    /// An event's league multipliers.
    static let multipliers: [Double] = [1, 1.5, 2, 3]

    static func multiplierText(_ m: Double) -> String {
        (m == m.rounded() ? String(Int(m)) : String(format: "%.1f", m)) + "×"
    }

    // MARK: points

    /// A season's points rule: a finish earns the first bracket whose `through` reaches its place, else
    /// `participation`; plus `matchWin` per match won.
    struct Rule: Codable, Hashable {
        struct Bracket: Codable, Hashable {
            var through: Int
            var points: Int
        }
        var places: [Bracket] = []
        var participation: Int = 0
        var matchWin: Int = 0

        init(places: [Bracket] = [], participation: Int = 0, matchWin: Int = 0) {
            self.places = places; self.participation = participation; self.matchWin = matchWin
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            places = try c.decodeIfPresent([Bracket].self, forKey: .places) ?? []
            participation = try c.decodeIfPresent(Int.self, forKey: .participation) ?? 0
            matchWin = try c.decodeIfPresent(Int.self, forKey: .matchWin) ?? 0
        }

        /// Brackets rise, 0 to 1,000 points each, up to 16; and the rule gives something (the server's checks).
        var valid: Bool {
            var last = 0
            for b in places {
                if b.through <= last || b.through > 512 || !(0...1000).contains(b.points) { return false }
                last = b.through
            }
            return places.count <= 16 && (0...100).contains(participation) && (0...20).contains(matchWin)
                && !(places.isEmpty && participation == 0 && matchWin == 0)
        }
    }

    struct Qualify: Codable, Hashable {
        var winners: Bool = false
        var passDown: Bool = true
        var top: Int = 0

        init(winners: Bool = false, passDown: Bool = true, top: Int = 0) {
            self.winners = winners; self.passDown = passDown; self.top = top
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            winners = try c.decodeIfPresent(Bool.self, forKey: .winners) ?? false
            passDown = try c.decodeIfPresent(Bool.self, forKey: .passDown) ?? true
            top = try c.decodeIfPresent(Int.self, forKey: .top) ?? 0
        }
    }

    /// The two presets: Places (the MMS table) and Match wins (1 a win + 1 to play).
    static let places = Rule(places: [.init(through: 1, points: 12), .init(through: 2, points: 10), .init(through: 4, points: 8),
                                      .init(through: 8, points: 6), .init(through: 16, points: 3)], participation: 1, matchWin: 0)
    static let matchWins = Rule(places: [], participation: 1, matchWin: 1)

    /// places | match_wins | custom: which preset a rule is.
    static func preset(_ rule: Rule) -> String {
        rule == places ? "places" : rule == matchWins ? "match_wins" : "custom"
    }

    static func ordinal(_ n: Int) -> String {
        if (10...20).contains(n % 100) { return "\(n)th" }
        switch n % 10 { case 1: return "\(n)st"; case 2: return "\(n)nd"; case 3: return "\(n)rd"; default: return "\(n)th" }
    }

    /// "1st 12 · 2nd 10 · Top 4 8 · Top 8 6 · Top 16 3 · Others 1". A bracket one past the last is a single place.
    static func pointsWords(_ rule: Rule) -> String {
        var parts: [String] = []
        var last = 0
        for b in rule.places {
            parts.append("\(b.through == last + 1 ? ordinal(b.through) : "Top \(b.through)") \(b.points)")
            last = b.through
        }
        if rule.participation > 0 { parts.append("\(parts.isEmpty ? "Playing" : "Others") \(rule.participation)") }
        if rule.matchWin > 0 { parts.append("Match win \(rule.matchWin)") }
        return parts.joined(separator: " · ")
    }

    static func placePoints(_ rule: Rule, place: Int) -> Int {
        rule.places.first { $0.through >= place }?.points ?? rule.participation
    }

    static func qualifyWords(_ q: Qualify) -> String {
        if q.winners && q.top > 0 { return "Event winners and the top \(q.top) on points" }
        if q.winners { return "Event winners" }
        return q.top > 0 ? "The top \(q.top) on points" : ""
    }

    // MARK: found events

    static func rowLabel(league: String?, visibility: String?) -> String? {
        if let league, !league.isEmpty { return league.uppercased() }
        return visibility == "friends" ? "FRIENDS" : nil
    }

    /// The data line under a found event. `when` is the date piece, already in the device's zone.
    static func eventLine(status: String, currentRound: Int, formatLabel: String, venueName: String?, capacity: Int?,
                          players: Int, km: Int?, when: String?) -> String {
        let running = (status == "seated" || status == "in_progress") && currentRound > 0
        var parts: [String?] = [running ? "NOW · ROUND \(currentRound)" : when, formatLabel.uppercased()]
        if let venueName, !venueName.isEmpty { parts.append(venueName.uppercased()) }
        if let capacity, capacity > 0 { parts.append("\(players)/\(capacity)") }
        if let km { parts.append("\(km) KM") }
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func formatter(_ format: String, zone: TimeZone, locale: Locale) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        f.dateFormat = format
        return f
    }

    /// The device's own clock: "10:00" or "10:00 AM".
    static func timeText(_ date: Date, zone: TimeZone = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f.string(from: date).uppercased()
    }

    /// "SUN 29 MAR · 10:00" in the zone.
    static func whenText(_ date: Date, zone: TimeZone = .current, locale: Locale = .current) -> String {
        formatter("EEE d MMM", zone: zone, locale: locale).string(from: date).uppercased().replacingOccurrences(of: ".", with: "")
            + " · " + timeText(date, zone: zone, locale: locale)
    }

    /// The widget's "SUN 29 · 10:00".
    static func dayText(_ date: Date, zone: TimeZone = .current, locale: Locale = .current) -> String {
        formatter("EEE d", zone: zone, locale: locale).string(from: date).uppercased().replacingOccurrences(of: ".", with: "")
            + " · " + timeText(date, zone: zone, locale: locale)
    }

    /// "29 MAR 2026" for a season's or a finished event's day.
    static func dateText(_ date: Date, zone: TimeZone = .current, locale: Locale = .current) -> String {
        formatter("d MMM yyyy", zone: zone, locale: locale).string(from: date).uppercased().replacingOccurrences(of: ".", with: "")
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// A season's `starts_on` / `ends_on` ("2026-01-01"), at local noon so the day never slips.
    static func parseDay(_ s: String, zone: TimeZone = .current) -> Date? {
        let p = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
    }

    static func dayString(_ d: Date, zone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// [from, to) for a When pick in the device's zone; nil for Any time. Weeks start on Monday. Local midnights, so a
    /// clock change inside the window lands on the right instant.
    static func whenWindow(_ pick: String, now: Date, zone: TimeZone) -> (from: Date, to: Date)? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let day = cal.startOfDay(for: now)
        func plus(_ days: Int) -> Date { cal.startOfDay(for: cal.date(byAdding: .day, value: days, to: day) ?? day) }
        // Monday = 0 … Sunday = 6
        let weekday = (cal.component(.weekday, from: day) + 5) % 7
        let nextMonday = plus(7 - weekday)
        switch pick {
        case "today": return (day, plus(1))
        case "weekend": return (weekday >= 5 ? day : plus(5 - weekday), nextMonday)
        case "week": return (day, nextMonday)
        case "month":
            let c = cal.dateComponents([.year, .month], from: day)
            let first = cal.date(from: DateComponents(year: c.year, month: (c.month ?? 1) + 1, day: 1)) ?? plus(31)
            return (day, first)
        default: return nil
        }
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    // MARK: filters

    /// The Find events picks (kept per device: `find.formats`, `find.km`, `find.when`, `find.more`).
    struct Filters: Codable, Hashable {
        var formats: [String] = []
        var km: Int?
        /// any | today | weekend | week | month
        var when = "any"
        /// all | public | friends
        var scope = "all"
        var team = false
        var league = false
        var open = false

        var isDefault: Bool { self == Filters() }
        var moreCount: Int { (team ? 1 : 0) + (league ? 1 : 0) + (open ? 1 : 0) + (scope != "all" ? 1 : 0) }

        /// A format in or out, kept in the pickers' order.
        mutating func toggle(format key: String) {
            let set = formats.contains(key) ? formats.filter { $0 != key } : formats + [key]
            formats = Leagues.formatKeys.map(\.key).filter(set.contains)
        }

        /// find_events' `p_filters` as JSON values: only what's picked. `here` is used only with a distance.
        func json(now: Date = .now, zone: TimeZone = .current, here: (lat: Double, lng: Double)? = nil, q: String = "") -> [String: Any] {
            var out: [String: Any] = [:]
            if !formats.isEmpty { out["formats"] = formats }
            if let here {
                out["lat"] = here.lat; out["lng"] = here.lng
                if let km { out["km"] = km }
            }
            if let w = Leagues.whenWindow(when, now: now, zone: zone) { out["from"] = Leagues.iso(w.from); out["to"] = Leagues.iso(w.to) }
            let words = q.trimmingCharacters(in: .whitespacesAndNewlines)
            if words.count >= 2 { out["q"] = words }
            if team { out["team"] = true }
            if league { out["league"] = true }
            if open { out["open"] = true }
            if scope != "all" { out["scope"] = scope }
            return out
        }
    }

    static func filterLabels(_ f: Filters) -> (format: String, where: String, when: String, more: String) {
        let format = f.formats.isEmpty ? "Any format" : f.formats.count == 1 ? label(f.formats[0]) : "\(f.formats.count) formats"
        let when = whens.first { $0.key == f.when && $0.key != "any" }?.label ?? "Any time"
        return (format, f.km.map { "\($0) km" } ?? "Everywhere", when, f.moreCount > 0 ? "More · \(f.moreCount)" : "More")
    }

    /// The picks on this device.
    enum Picks {
        static func load(_ d: UserDefaults = .standard) -> Filters {
            var f = Filters()
            f.formats = formatKeys.map(\.key).filter((d.stringArray(forKey: "find.formats") ?? []).contains)
            let km = d.integer(forKey: "find.km")
            f.km = distances.contains(km) ? km : nil
            let when = d.string(forKey: "find.when") ?? "any"
            f.when = whens.contains { $0.key == when } ? when : "any"
            let more = d.stringArray(forKey: "find.more") ?? []
            f.team = more.contains("team"); f.league = more.contains("league"); f.open = more.contains("open")
            f.scope = more.contains("public") ? "public" : more.contains("friends") ? "friends" : "all"
            return f
        }

        static func save(_ f: Filters, _ d: UserDefaults = .standard) {
            d.set(f.formats, forKey: "find.formats")
            d.set(f.km ?? 0, forKey: "find.km")
            d.set(f.when, forKey: "find.when")
            d.set([f.team ? "team" : nil, f.league ? "league" : nil, f.open ? "open" : nil, f.scope != "all" ? f.scope : nil].compactMap { $0 },
                  forKey: "find.more")
        }
    }

    // MARK: boards and league cards

    /// `124 LISTED · YOU 1612 · #14`; `YOU 1540 · 4 TO GO` before you're listed; nothing about you with no rated match.
    static func boardLine(players: Int, rating: Int?, rank: Int?, toGo: Int) -> String {
        var parts = ["\(players) LISTED"]
        if let rating {
            parts.append("YOU \(rating)")
            parts.append(rank.map { "#\($0)" } ?? (toGo > 0 ? "\(toGo) TO GO" : "NOT LISTED"))
        }
        return parts.joined(separator: " · ")
    }

    /// `2026 · DENVER, COLORADO · NEXT MODERN OPEN`.
    static func leagueLine(season: String?, region: String?, next: String?) -> String {
        [season?.uppercased(), region?.uppercased(), next.map { "NEXT \($0.uppercased())" }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// A player's season row for one event: `2ND OF 24 · MODERN · 29 MAR 2026`.
    static func finishLine(place: Int, players: Int?, formatLabel: String?, when: String?) -> String {
        [ordinal(place).uppercased() + (players.map { " OF \($0)" } ?? ""), formatLabel?.uppercased(), when]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// A profile achievement as a small tile: a code, a label under it, and whether it takes the accent (a champion
    /// and a first place, nothing else).
    static func achievementText(_ i: Achievement) -> (code: String, label: String, accent: Bool) {
        if i.isBoard {
            let label = i.label ?? Leagues.label(i.board ?? "other")
            if let rank = i.rank, rank > 0 { return ("#\(rank)", label, rank == 1) }
            return ("\(i.rating ?? 0)", label, false)
        }
        let label = "\(i.leagueName ?? "") · \(i.seasonName ?? "")"
        let over = i.state == "over"
        if i.champion == true { return ("CHAMPION", label, true) }
        if over, let rank = i.rank, rank > 0, rank <= 8 { return (rank == 1 ? "1ST" : rank <= 4 ? "TOP 4" : "TOP 8", label, rank == 1) }
        if let q = i.qualified, !q.isEmpty { return ("QUALIFIED", label, false) }
        if let rank = i.rank, rank > 0, rank <= 8 { return ("#\(rank)", label, false) }
        let wins = i.wins ?? 0
        return (wins == 1 ? "1 WIN" : "\(wins) WINS", label, false)
    }

    /// A rough place: rounded to 0.1° (about 11 km), the only precision the widget's Near me ever keeps.
    static func rough(_ degrees: Double) -> Double { (degrees * 10).rounded() / 10 }

    // MARK: the server part may not be live

    /// The function isn't on the server (PostgREST PGRST202, HTTP 404): the section hides, nothing is reported.
    static func isMissing(_ error: Error) -> Bool {
        let text = "\(error)"
        return text.contains("PGRST202") || text.contains("Could not find the function")
    }
}
