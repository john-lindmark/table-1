import Foundation

/// Insights packs and read RPCs (contract/insights-2026-10-24.md § Packs, § RPCs). Wire names as published.
enum Insights {
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
    static let formats: [(key: String, label: String)] = [("standard", "Standard"), ("pioneer", "Pioneer"), ("modern", "Modern"), ("pauper", "Pauper")]

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
            default: return "Released: \(note ?? set_code?.uppercased() ?? "a new set")"
            }
        }
        var isBan: Bool { ["ban", "unban", "restrict", "unrestrict"].contains(kind) }
    }
    struct ShareRow: Codable, Hashable { let a: Int; let share: Double; let prev: Double?; let decks: Int; let top8: Int; let conv: Double? }
    struct CardRow: Codable, Hashable { let c: String; let n: String; let rate: Double; let prev: Double?; let copies: Double? }
    struct Movers: Codable, Hashable { let up: [CardRow]; let down: [CardRow] }
    struct Window: Codable, Hashable {
        let decks: Int; let weighted: Double; let events: Int; let thin: Bool; let brief: String?
        let share: [ShareRow]
        let cards: [String: Movers] // main, side
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
        let archetypes: [Int]
        /// [a, b, a_wins, b_wins, draws], a before b in `archetypes`
        let cells: [[Int]]
        func cell(_ a: Int, _ b: Int) -> (wins: Int, losses: Int, draws: Int)? {
            if let c = cells.first(where: { $0[0] == a && $0[1] == b }) { return (c[2], c[3], c[4]) }
            if let c = cells.first(where: { $0[0] == b && $0[1] == a }) { return (c[3], c[2], c[4]) }
            return nil
        }
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
        func archetype(_ id: Int) -> Archetype? { archetypes.first { $0.id == id } }
        func name(_ id: Int) -> String { archetype(id)?.name ?? "Other" }
        func change(_ id: Int) -> Change? { changes.first { $0.id == id } }
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
        let brief: String?
    }
    struct CardPage: Decodable {
        struct Weekly: Decodable { let from: String; let weeks: Int; let main: [Double?]; let side: [Double?] }
        struct ByArchetype: Decodable, Hashable { let a: Int; let rate: Double; let copies: Double? }
        let c: String
        let n: String?
        let series: Weekly
        let copies: Double?
        let by_archetype: [ByArchetype]
        let first_seen: String?
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
    /// One exact colour combination: main colours (WUBRG order, as 17Lands writes them) and the splash ("" for none).
    struct LColors: Codable, Hashable { let m: String; let s: String; let games: Int; let wr: Double; let share: Double }
    struct LView: Codable, Hashable {
        let games: Int; let wr: Double; let weeks: Int; let brief: String?
        let pairs: [LPair]; let cards: [LCard]; let facts: LFacts
        let colors: [LColors]?
    }
    static let shards = ["WUB": "Esper", "UBR": "Grixis", "BRG": "Jund", "WRG": "Naya", "WUG": "Bant", "WBG": "Abzan", "WUR": "Jeskai",
                         "UBG": "Sultai", "WBR": "Mardu", "URG": "Temur"]
    /// "Dimir UB + r", "Esper WUB", "Four-colour WUBR": a deck's colours as 17Lands' deck colour table names them.
    static func colorsName(_ m: String, _ s: String) -> String {
        let base = m.count <= 2 ? (pairNames[m] ?? m) : m.count == 3 ? (shards[m] ?? "Three-colour") : m.count == 4 ? "Four-colour" : "Five-colour"
        return "\(base) \(m)" + (s.isEmpty ? "" : " + \(s.lowercased())")
    }
    struct LEvent: Codable, Hashable { let updated: String; let groups: [String: LView] }
    struct LimitedPack: Codable, Hashable {
        struct Credit: Codable, Hashable { let name: String; let url: String }
        let set_code: String; let name: String?; let released: String?; let credit: Credit
        let events: [String: LEvent]
    }
    static let eventOrder = ["PremierDraft", "TradDraft", "PickTwoDraft", "Sealed", "TradSealed"]
    static let eventLabels = ["PremierDraft": "Premier", "TradDraft": "Traditional", "PickTwoDraft": "Pick Two", "Sealed": "Sealed", "TradSealed": "Trad Sealed"]
    static let pairNames = ["WU": "Azorius", "WB": "Orzhov", "WR": "Boros", "WG": "Selesnya", "UB": "Dimir", "UR": "Izzet", "UG": "Simic",
                            "BR": "Rakdos", "BG": "Golgari", "RG": "Gruul", "W": "Mono-White", "U": "Mono-Blue", "B": "Mono-Black",
                            "R": "Mono-Red", "G": "Mono-Green", "3C": "Three or more", "C": "Colourless"]
}
