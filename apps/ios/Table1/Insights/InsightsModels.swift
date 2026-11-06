import Foundation
import Supabase

/// Insights packs and read RPCs (contract/insights-2026-10-24.md § Packs, § RPCs). Wire names as published.
enum Insights {
    /// What the viewer picked, kept on the account so every device opens the same way (user_settings.insights,
    /// contract/insights-2026-10-24.md § What the viewer picked). Every key is optional; ones this build doesn't know stay.
    struct Picks: Codable, Equatable {
        var section: String?, format: String?, tier: String?, days: Int?, set: String?, event: String?, group: String?
        var hidden_formats: [String]?, hidden_sets: [String]?

        init(section: String? = nil, format: String? = nil, tier: String? = nil, days: Int? = nil, set: String? = nil,
             event: String? = nil, group: String? = nil, hidden_formats: [String]? = nil, hidden_sets: [String]? = nil) {
            self.section = section; self.format = format; self.tier = tier; self.days = days; self.set = set
            self.event = event; self.group = group; self.hidden_formats = hidden_formats; self.hidden_sets = hidden_sets
        }

        /// A wrong type reads as missing rather than failing the rest.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            section = try? c.decodeIfPresent(String.self, forKey: .section)
            format = try? c.decodeIfPresent(String.self, forKey: .format)
            tier = try? c.decodeIfPresent(String.self, forKey: .tier)
            days = try? c.decodeIfPresent(Int.self, forKey: .days)
            set = try? c.decodeIfPresent(String.self, forKey: .set)
            event = try? c.decodeIfPresent(String.self, forKey: .event)
            group = try? c.decodeIfPresent(String.self, forKey: .group)
            hidden_formats = try? c.decodeIfPresent([String].self, forKey: .hidden_formats)
            hidden_sets = try? c.decodeIfPresent([String].self, forKey: .hidden_sets)
        }

        static func read(_ o: [String: AnyJSON]) -> Picks {
            (try? JSONEncoder().encode(o)).flatMap { try? JSONDecoder().decode(Picks.self, from: $0) } ?? Picks()
        }

        /// The object to store: these picks over what the account holds (keys from newer clients stay).
        static func write(_ p: Picks, held: [String: AnyJSON]?) -> [String: AnyJSON] {
            let mine = (try? JSONEncoder().encode(p)).flatMap { try? JSONDecoder().decode([String: AnyJSON].self, from: $0) } ?? [:]
            return (held ?? [:]).merging(mine.filter { $0.value != .null }) { _, new in new }
        }
    }

    struct IndexEntry: Decodable, Hashable {
        let kind: String
        let key: String
        let name: String
        let version: String
        let url: String
        let bytes: Int
        let through: String?
    }

    enum Tier: String, Codable, CaseIterable { case big, all }
    static let windows = [7, 14, 30, 90]
    /// A load in the last ten minutes is reused only when the pack on screen came with it: a load cut short after the
    /// index left Modern empty until something forced another (build 39).
    static func reuseLoad(loadedAt: Date?, now: Date, packOnScreen: Bool) -> Bool {
        guard let loadedAt, packOnScreen else { return false }
        return now.timeIntervalSince(loadedAt) < 600
    }
    static let formats: [(key: String, label: String)] = [("standard", "Standard"), ("pioneer", "Pioneer"), ("modern", "Modern"), ("legacy", "Legacy"),
                                                          ("vintage", "Vintage"), ("pauper", "Pauper"), ("canlander", "Canlander")]

    /// The credit under a constructed brief, from the pack's sources: TopDeck.gg asks for a visible credit and link
    /// whenever its data is shown; Canadian Highlander comes from TopDeck alone.
    /// The options a picker shows: every one not hidden, in order (all of them if every one is hidden).
    static func visibleKeys(_ all: [String], _ hidden: [String]) -> [String] {
        let shown = all.filter { !hidden.contains($0) }
        return shown.isEmpty ? all : shown
    }
    /// Whether an option may be hidden: at least one other has to stay shown.
    static func canHide(_ all: [String], _ hidden: [String], _ key: String) -> Bool {
        all.contains { $0 != key && !hidden.contains($0) }
    }

    /// The studies' heading: a points format's changes are points changes, not bans.
    static func bansTitle(_ kinds: [String]) -> String {
        !kinds.isEmpty && kinds.allSatisfy { $0 == "points" } ? "Points changes" : "Bans and unbans"
    }

    /// "A", "A and B", "A, B and C".
    static func andList(_ xs: [String]) -> String {
        xs.count < 2 ? xs.joined() : xs.dropLast().joined(separator: ", ") + " and " + xs.last!
    }

    private static let sourceNames = [("mtgo", "Magic Online", "https://www.mtgo.com/decklists"), ("topdeck", "TopDeck.gg", "https://topdeck.gg"),
                                      ("melee", "Melee", "https://melee.gg")]

    /// The credit under a constructed brief, from the pack's sources in a fixed order: TopDeck.gg asks for a visible
    /// credit and link whenever its data is shown, so the link is TopDeck's when it's a source; Canadian Highlander
    /// comes from TopDeck alone. Melee results come through the MTG_decklistcache.
    static func sourcesCredit(_ sources: [String]) -> (label: String, url: URL) {
        let named = sourceNames.filter { sources.contains($0.0) }
        guard let first = named.first else { return ("Results from Magic Online", URL(string: sourceNames[0].2)!) }
        let link = named.first { $0.0 == "topdeck" } ?? first
        return ("Results from \(andList(named.map(\.1)))", URL(string: link.2)!)
    }

    // MARK: constructed

    struct Archetype: Codable, Hashable, Identifiable { let id: Int; let name: String; let family: String; let colors: String }
    struct Change: Codable, Hashable, Identifiable {
        let id: Int; let on: String; let kind: String; let cards: [String]; let set_code: String?; let note: String?; let url: String?
        /// "Banned: Lotus Field" / "Released: Reality Fracture"
        var words: String {
            let c = cards.count > 3 ? cards.prefix(3).joined(separator: ", ") + " and others" : cards.joined(separator: " and ")
            switch kind {
            case "ban": return "Banned: \(c)"
            case "unban": return "Unbanned: \(c)"
            case "restrict": return "Restricted: \(c)"
            case "unrestrict": return "Unrestricted: \(c)"
            case "rotation": return "Rotation"
            case "points": return "Points: \(note ?? c)"
            default: return "Released: \(note ?? set_code?.uppercased() ?? "a new set")"
            }
        }
        /// Changes with a before/after study: bans and their kin, and Canadian Highlander's points changes.
        var isBan: Bool { ["ban", "unban", "restrict", "unrestrict", "points"].contains(kind) }
    }
    /// `wr`, `t8r`, `won` and the window's `won_of` are missing from packs built before 2026-10-28.
    struct ShareRow: Codable, Hashable {
        let a: Int; let share: Double; let prev: Double?; let decks: Int; let top8: Int; let conv: Double?
        var wr: Double? = nil; var t8r: Double? = nil; var won: Int? = nil
    }
    struct CardRow: Codable, Hashable { let c: String; let n: String; let rate: Double; let prev: Double?; let copies: Double? }
    struct Movers: Codable, Hashable { let up: [CardRow]; let down: [CardRow] }
    struct Window: Codable, Hashable {
        let decks: Int; let weighted: Double; let events: Int; let thin: Bool; let brief: String?
        var won_of: Int? = nil
        let share: [ShareRow]
        let cards: [String: Movers] // main, side
        /// this tier × window's matchup grid (packs from 20261030090000 on)
        var matchups: Matchups? = nil
    }
    struct Line: Codable, Hashable { let a: Int; let v: [Double?] }
    struct Series: Codable, Hashable { let from: String; let days: Int; let lines: [Line]; let other: [Double?] }
    struct NewSetCard: Codable, Hashable { let c: String; let n: String; let rate: Double; let copies: Double?; let `in`: [Int]? }
    struct NewSet: Codable, Hashable { let set_code: String; let name: String; let released: String; let cards: [NewSetCard] }
    struct View: Codable, Hashable { let windows: [String: Window]; let series: Series; let new_set: NewSet? }
    struct Move: Codable, Hashable { let a: Int; let before: Double; let after: Double }
    struct Replacement: Codable, Hashable { let c: String; let n: String; let before: Double; let after: Double; let `in`: Int }
    struct AShare: Codable, Hashable { let a: Int; let share: Double }
    struct BanStudy: Codable, Hashable {
        let change: Int; let on: String
        let before: [AShare]
        let after: [String: [AShare]]
        let losers: [Move]; let gainers: [Move]; let replacements: [Replacement]
        let settled_days: Int?; let brief: String?
        /// The longest "after" window that has ended (60 → 30 → 14 days).
        var afterWindow: (days: Int, shares: [AShare])? {
            for d in [60, 30, 14] { if let s = after[String(d)] { return (d, s) } }
            return nil
        }
    }
    struct Matchups: Codable, Hashable {
        /// the grid's columns (top 10)
        let archetypes: [Int]
        /// every discernible archetype, the columns first, Other last (missing before 20261030090000)
        var rows: [Int]? = nil
        /// [a, b, a_wins, b_wins, draws], a before b in `rows`
        let cells: [[Int]]
        /// The grid's rows: every discernible archetype, or the columns in an older pack.
        var rowIds: [Int] { (rows ?? []).isEmpty ? archetypes : rows! }
        func cell(_ a: Int, _ b: Int) -> (wins: Int, losses: Int, draws: Int)? {
            if let c = cells.first(where: { $0[0] == a && $0[1] == b }) { return (c[2], c[3], c[4]) }
            if let c = cells.first(where: { $0[0] == b && $0[1] == a }) { return (c[3], c[2], c[4]) }
            return nil
        }
    }
    /// What `insights_mine` says about the signed-in account in a format: its decks with their archetypes, and how
    /// much of each archetype's usual list its collection holds.
    struct Mine: Codable, Hashable {
        struct Deck: Codable, Hashable { let a: Int; let id: String; let name: String }
        struct Cover: Codable, Hashable { let a: Int; let have: Double }
        let decks: [Deck]
        let coverage: [Cover]
    }
    /// Collection coverage from which an archetype counts as nearly yours.
    static let close = 0.6
    /// The grid's rows with your decks first, then archetypes your collection nearly builds, each with its note
    /// (testdata/insights/yours-first.json).
    static func yoursFirst(_ rows: [Int], _ mine: Mine?) -> [(a: Int, note: String?)] {
        guard let mine else { return rows.map { ($0, nil) } }
        var decks: [Int: Int] = [:]
        for d in mine.decks where d.a != 0 { decks[d.a, default: 0] += 1 }
        var have: [Int: Double] = [:]
        for c in mine.coverage where c.a != 0 { have[c.a] = c.have }
        let own = rows.filter { decks[$0] != nil }
        let close = rows.filter { decks[$0] == nil && (have[$0] ?? 0) >= Self.close }
            .sorted { (have[$0]!, rows.firstIndex(of: $1)!) > (have[$1]!, rows.firstIndex(of: $0)!) }
        let rest = rows.filter { !own.contains($0) && !close.contains($0) }
        return own.map { ($0, decks[$0]! > 1 ? "Your \(decks[$0]!) decks" : "Your deck") }
            + close.map { ($0, "You have \(Int((have[$0]! * 100 + 1e-9).rounded(.down)))%") }
            + rest.map { ($0, nil) }
    }
    // MARK: a deck's archetype, on the deck's own screen (list_insight)

    struct Record3: Codable, Hashable { let wins: Int; let losses: Int; let draws: Int }
    struct DeckMatchup: Codable, Hashable { let vs: Int; let name: String; let wins: Int; let losses: Int; let draws: Int }
    struct DeckInsightAnswer: Codable, Hashable {
        let format: String; let a: Int?; var name: String? = nil; var reason: String? = nil
        /// The deck against its archetype's nearest list, 0–1; a brew (reason "brew") has no `a`.
        var similarity: Double? = nil
        var month: Record3? = nil; var week: Record3? = nil; var prev: Record3? = nil
        var matchups: [DeckMatchup]? = nil
    }
    struct DeckInsight: Equatable {
        let title: String?; let similar: String?; let win: String?; let change: String?; let good: [String]; let bad: [String]; let note: String?
    }
    /// Matches a rate needs before it's shown.
    static let deckMin = 20
    /// How a deck screen words its archetype's numbers (testdata/insights/deck-insight.json).
    static func deckInsight(_ r: DeckInsightAnswer) -> DeckInsight {
        if r.reason == "other" || r.a == 0 {
            return DeckInsight(title: nil, similar: nil, win: nil, change: nil, good: [], bad: [], note: "Doesn't match an archetype Insights knows")
        }
        guard r.a != nil, let name = r.name else { return DeckInsight(title: nil, similar: nil, win: nil, change: nil, good: [], bad: [], note: nil) }
        func rate(_ x: Record3?) -> Double? {
            guard let x else { return nil }
            let n = x.wins + x.losses + x.draws
            return n >= deckMin ? Double(x.wins) / Double(n) : nil
        }
        var change: String?
        if let w = rate(r.week), let p = rate(r.prev) {
            let d = (w - p) * 100
            change = abs(d) < 0.05 ? "Same as last week" : "\(d > 0 ? "▲" : "▼") \(String(format: "%.1f", abs(d))) pts on last week"
        }
        let rated = (r.matchups ?? []).filter { $0.wins + $0.losses >= deckMin }
            .map { (m: $0, wr: Double($0.wins) / Double($0.wins + $0.losses), n: $0.wins + $0.losses) }
        let good = rated.filter { $0.wr > 0.5 }.sorted { ($0.wr, $0.n) > ($1.wr, $1.n) }.prefix(3)
        let bad = rated.filter { $0.wr < 0.5 }.sorted { $0.wr != $1.wr ? $0.wr < $1.wr : $0.n > $1.n }.prefix(3)
        return DeckInsight(title: name, similar: r.similarity.map { "\(Int(($0 * 100).rounded()))% similar" }, win: rate(r.month).map { "Win \(InsightCharts.pct1($0))" }, change: change,
                           good: good.map { "\($0.m.name) \(InsightCharts.pct($0.wr))" }, bad: bad.map { "\($0.m.name) \(InsightCharts.pct($0.wr))" }, note: nil)
    }

    struct EventRow: Codable, Hashable {
        let name: String; let on: String; let players: Int?; let tier: String; let source: String; let url: String?
        let top8: [Int]?; let winner: Int?
    }
    struct ConstructedPack: Codable, Hashable {
        let format: String; let name: String; let through: String; let sources: [String]; let default_tier: Tier
        let archetypes: [Archetype]; let changes: [Change]; let events: [EventRow]
        let tiers: [String: View]; let bans: [BanStudy]; let matchups: Matchups
        func view(_ t: Tier) -> View? { tiers[t.rawValue] }
        /// The matchup grid for the picked tier and window, and what it covers; an older pack has only its 90-day,
        /// All events grid.
        func grid(_ t: Tier, days: Int) -> (m: Matchups, scope: String) {
            if let m = view(t)?.windows[String(days)]?.matchups { return (m, "\(t == .big ? "Big events" : "All events"), last \(days) days") }
            return (matchups, "All events, last 90 days")
        }
        func archetype(_ id: Int) -> Archetype? { archetypes.first { $0.id == id } }
        func name(_ id: Int) -> String { archetype(id)?.name ?? "Other" }
        func change(_ id: Int) -> Change? { changes.first { $0.id == id } }
    }

    /// The format page's parts behind a row each (contract/insights-2026-10-24.md § Format page): key, title and a
    /// one-line summary for the picked tier and window; parts with nothing to show are left out. Shared cases in
    /// testdata/insights/parts.json.
    struct Part: Hashable { let key: String; let title: String; let detail: String }
    static func formatParts(_ p: ConstructedPack, tier: Tier, days: Int) -> [Part] {
        let view = p.view(tier)
        let w = view?.windows[String(days)]
        var out: [Part] = []
        if let w, !w.share.isEmpty {
            let named = w.share.filter { $0.a != 0 }
            out.append(Part(key: "meta", title: "Meta now", detail: [named.first.map { "\(p.name($0.a)) \(InsightCharts.pct($0.share))" },
                                                                    "\(named.count) archetypes"].compactMap { $0 }.joined(separator: " · ")))
        }
        if let w {
            let up = w.cards["main"]?.up.first
            out.append(Part(key: "cards", title: "Cards rising and falling",
                            detail: up.map { "Rising most: \($0.n) ▲ \(InsightCharts.delta($0.rate - ($0.prev ?? 0)).dropFirst())" } ?? "No card moved much in this window"))
        }
        if let ns = view?.new_set, let top = ns.cards.first {
            out.append(Part(key: "new_set", title: "New set · \(ns.name)", detail: "\(ns.cards.count) cards played · \(top.n) in \(InsightCharts.pct(top.rate))"))
        }
        let studied = p.bans.compactMap { p.change($0.change) }
        if let first = studied.first {
            let latest = studied.reduce(first) { $1.on > $0.on ? $1 : $0 }
            out.append(Part(key: "changes", title: bansTitle(studied.map(\.kind)),
                            detail: "\(latest.words) · \(InsightCharts.shortDay(latest.on))" + (studied.count > 1 ? " · \(studied.count - 1) more" : "")))
        }
        let events = p.events.filter { tier == .all || ["major", "large"].contains($0.tier) }
        if let first = events.first {
            let latest = events.reduce(first) { $1.on > $0.on ? $1 : $0 }
            out.append(Part(key: "events", title: tier == .big ? "Big events" : "Events",
                            detail: "\(events.count) \(events.count == 1 ? "event" : "events") · latest \(latest.name)"))
        }
        return out
    }

    // MARK: read RPCs

    struct ArchetypePage: Decodable {
        struct Weekly: Decodable { let from: String; let weeks: Int; let v: [Double?] }
        struct Record: Decodable { let wins: Int; let losses: Int; let draws: Int; let basis: String }
        struct Matchup: Decodable, Hashable { let vs: Int; let wins: Int; let losses: Int; let draws: Int }
        struct Finish: Decodable, Hashable {
            let event: String; let on: String; let players: Int?; let tier: String; let rank: Int?; let url: String?
            let main: [Line]; let side: [Line]
        }
        /// [name, copies]
        struct Line: Decodable, Hashable {
            let name: String; let qty: Int
            init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                name = try c.decode(String.self)
                qty = try c.decode(Int.self)
            }
        }
        let archetype: Archetype
        let decks: Int
        let series: Weekly
        let record: Record?
        let conv: Double?
        let core: [CardRow]; let flex: [CardRow]; let side: [CardRow]
        let matchups: [Matchup]
        let finishes: [Finish]
        /// Other (archetype 0) only: its decks by colors, each with its most-played cards and its example in `finishes`.
        struct Group: Decodable, Hashable { let colors: String; let decks: Int; let share: Double; let cards: [String]; let example: Int? }
        let groups: [Group]?
        let brief: String?
    }
    /// The deck page's example list: from the biggest event (major, large, regular, small), the best finish there,
    /// then the newest; only whole lists (40+ main deck cards). Nil when there's none.
    static func exampleFinish(_ finishes: [ArchetypePage.Finish]) -> Int? {
        let order = ["major", "large", "regular", "small"]
        func tier(_ f: ArchetypePage.Finish) -> Int { order.firstIndex(of: f.tier) ?? order.count }
        func rank(_ f: ArchetypePage.Finish) -> Int { f.rank ?? .max }
        var best: Int?
        for (i, f) in finishes.enumerated() where f.main.reduce(0, { $0 + $1.qty }) >= 40 {
            guard let b = best.map({ finishes[$0] }) else { best = i; continue }
            if tier(f) < tier(b) || (tier(f) == tier(b) && (rank(f) < rank(b) || (rank(f) == rank(b) && f.on > b.on))) { best = i }
        }
        return best
    }
    /// "1st", "2nd", "3rd", "4th"…: a finish's place.
    static func place(_ rank: Int) -> String {
        let t = rank % 100, u = rank % 10
        return "\(rank)" + ((11...13).contains(t) ? "th" : u == 1 ? "st" : u == 2 ? "nd" : u == 3 ? "rd" : "th")
    }
    /// meta_card: a year of weeks, the picked window, every archetype playing the card and its best lists
    /// (contract § Card search and the card page). The window, decks, finishes and last_seen came 2026-11-06.
    struct CardPage: Decodable {
        struct Weekly: Decodable { let from: String; let weeks: Int; let main: [Double?]; let side: [Double?] }
        struct ByArchetype: Decodable, Hashable {
            let a: Int; let rate: Double; let copies: Double?
            var side_copies: Double? = nil; var decks: Int? = nil; var of: Int? = nil
        }
        struct Window: Decodable, Hashable {
            let days: Int; let decks: Int; let of: Int
            let main: Double?; let side: Double?; let copies: Double?; let side_copies: Double?
        }
        /// A list that played the card: an archetype page's finish, plus its archetype and the card's copies.
        struct Finish: Decodable, Hashable {
            let event: String; let on: String; let players: Int?; let tier: String; let rank: Int?; let url: String?
            let a: Int; let qty: [Int]
            let main: [ArchetypePage.Line]; let side: [ArchetypePage.Line]
            var asFinish: ArchetypePage.Finish { .init(event: event, on: on, players: players, tier: tier, rank: rank, url: url, main: main, side: side) }
        }
        let c: String
        let n: String?
        let series: Weekly
        var window: Window? = nil
        let copies: Double?
        let by_archetype: [ByArchetype]
        var finishes: [Finish]? = nil
        let first_seen: String?
        var last_seen: String? = nil
    }
    /// A meta_card_search hit: 90-day shares of lists playing it main / side, and lists with it this year.
    struct CardHit: Decodable, Hashable, Identifiable {
        let c: String; let n: String; let type: String?
        let main: Double; let side: Double; let year: Int
        var id: String { c }
    }
    /// "Main 67% · Side 33%", or "Not in the last 90 days · 6 lists this year" (testdata/insights/card-search.json).
    static func hitDetail(_ h: CardHit) -> String {
        let parts = [h.main > 0 ? "Main \(InsightCharts.pct(h.main))" : nil, h.side > 0 ? "Side \(InsightCharts.pct(h.side))" : nil].compactMap { $0 }
        if parts.isEmpty { return "Not in the last 90 days · \(h.year) list\(h.year == 1 ? "" : "s") this year" }
        return parts.joined(separator: " · ")
    }
    /// "4 of 6 lists · 3.3 main · 1.0 side": an archetype row on the card page.
    static func archetypeDetail(_ b: CardPage.ByArchetype) -> String {
        let of = b.of ?? b.decks ?? 0
        var parts = b.decks.map { ["\($0) of \(of) list\(of == 1 ? "" : "s")"] } ?? []
        if let c = b.copies { parts.append(String(format: "%.1f main", c)) }
        if let c = b.side_copies { parts.append(String(format: "%.1f side", c)) }
        return parts.joined(separator: " · ")
    }
    /// The archetype row's bar: its lists that play the card (old answers: the main-deck rate).
    static func archetypeBar(_ b: CardPage.ByArchetype) -> Double {
        guard let d = b.decks, let of = b.of, of > 0 else { return b.rate }
        return Double(d) / Double(of)
    }
    /// The format changes naming the card, at their week in the card's weekly series (ban markers on the chart).
    static func cardMarkers(_ changes: [Change], card: String, from: String, weeks: Int) -> [(index: Int, label: String, ban: Bool)] {
        guard let d0 = InsightCharts.day(from) else { return [] }
        var out: [(index: Int, label: String, ban: Bool)] = []
        for c in changes.sorted(by: { ($0.on, $0.id) < ($1.on, $1.id) }) where c.cards.contains(card) {
            guard let d = InsightCharts.day(c.on) else { continue }
            let days = Int((d.timeIntervalSince(d0) / 86400).rounded())
            guard days >= 0, days / 7 < weeks else { continue }
            let i = days / 7
            if let k = out.firstIndex(where: { $0.index == i }) {
                out[k] = (i, out[k].label + "/" + c.kind.uppercased(), out[k].ban || c.isBan)
            } else { out.append((i, c.kind.uppercased(), c.isBan)) }
        }
        return out
    }
    /// "1st · Modern Challenge 64", or the event with no place.
    static func finishTitle(_ f: CardPage.Finish) -> String {
        f.rank.map { "\(place($0)) · \(f.event)" } ?? f.event
    }
    /// "Burn · 4 main · 1 side · NOV 3".
    static func finishDetail(_ f: CardPage.Finish, archetype: String) -> String {
        let m = f.qty.first ?? 0, s = f.qty.count > 1 ? f.qty[1] : 0
        return [archetype, m > 0 ? "\(m) main" : nil, s > 0 ? "\(s) side" : nil, InsightCharts.shortDay(f.on)].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: limited

    struct LCard: Codable, Hashable, Identifiable {
        let c: String?; let n: String; let r: String?; let col: String?
        let gih: Double?; let gih_n: Int; let oh: Double?; let gd: Double?; let gns: Double?; let iwd: Double?
        let ata: Double?; let deck: Double
        let week_gih: [Double?]?; let pair_gih: [String: Double]?
        var id: String { n }
    }
    struct LPair: Codable, Hashable, Identifiable {
        let p: String; let games: Int; let wr: Double; let share: Double; let splash: Double
        let play_wr: Double?; let draw_wr: Double?; let week_wr: [Double?]; let week_share: [Double?]
        var id: String { p }
    }
    struct LFacts: Codable, Hashable {
        let play_wr: Double?; let draw_wr: Double?; let mull_rate: Double?; let mull_wr: Double?; let keep7_wr: Double?
        let mull_play: Double?; let turns: Double?
    }
    /// One exact color combination: main colors (WUBRG order, as 17Lands writes them) and the splash ("" for none).
    struct LColors: Codable, Hashable { let m: String; let s: String; let games: Int; let wr: Double; let share: Double }
    struct LView: Codable, Hashable {
        let games: Int; let wr: Double; let weeks: Int; let brief: String?
        let pairs: [LPair]; let cards: [LCard]; let facts: LFacts
        let colors: [LColors]?
    }
    static let shards = ["WUB": "Esper", "UBR": "Grixis", "BRG": "Jund", "WRG": "Naya", "WUG": "Bant", "WBG": "Abzan", "WUR": "Jeskai",
                         "UBG": "Sultai", "WBR": "Mardu", "URG": "Temur"]
    /// "Dimir UB + r", "Esper WUB", "Four-color WUBR": a deck's colors as 17Lands' deck color table names them.
    static func colorsName(_ m: String, _ s: String) -> String {
        let base = m.count <= 2 ? (pairNames[m] ?? m) : m.count == 3 ? (shards[m] ?? "Three-color") : m.count == 4 ? "Four-color" : "Five-color"
        return "\(base) \(m)" + (s.isEmpty ? "" : " + \(s.lowercased())")
    }
    struct LEvent: Codable, Hashable { let updated: String; let groups: [String: LView] }
    struct LimitedPack: Codable, Hashable {
        struct Credit: Codable, Hashable { let name: String; let url: String }
        /// An Arena cube version's family (contract/insights-2026-10-24.md § Arena cubes); nil for a set.
        struct Cube: Codable, Hashable { let family: String; let name: String }
        let set_code: String; let name: String?; let released: String?; let credit: Credit
        var cube: Cube? = nil
        let events: [String: LEvent]
    }
    static let eventOrder = ["PremierDraft", "TradDraft", "PickTwoDraft", "Sealed", "TradSealed"]
    static let eventLabels = ["PremierDraft": "Premier", "TradDraft": "Traditional", "PickTwoDraft": "Pick Two", "Sealed": "Sealed", "TradSealed": "Trad Sealed"]
    static let pairNames = ["WU": "Azorius", "WB": "Orzhov", "WR": "Boros", "WG": "Selesnya", "UB": "Dimir", "UR": "Izzet", "UG": "Simic",
                            "BR": "Rakdos", "BG": "Golgari", "RG": "Gruul", "W": "Mono-White", "U": "Mono-Blue", "B": "Mono-Black",
                            "R": "Mono-Red", "G": "Mono-Green", "3C": "Three or more", "C": "Colorless"]
}
