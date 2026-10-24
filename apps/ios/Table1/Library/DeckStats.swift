import Foundation

/* Deck and cube stats (contract/lists-2026-10-15.md, "Stats"). Pure functions over a list's cards, no UI and no
   catalog access, so the same inputs give the same numbers here, on the web (src/lib/deckStats.ts) and on Android
   (DeckStats.kt). testdata/deck-stats/cases.json holds the shared cases; make_cases.py there is the reference. */

/// A token card a card makes (the pack's O-line tokens field). `key` tells apart token cards with the same name.
struct StatToken: Hashable, Sendable {
    let key: String
    let name: String
    let type: String
}

/// One list line as the stats read it. `type`, `cost`, `cmc`, `colors`, `produced` and `tokens` come from the catalog
/// pack's O line.
struct StatCard: Hashable, Sendable {
    var name: String
    var qty: Int
    var board: String
    let type: String
    var cost: String
    var cmc: Double
    var colors: String
    var legal: String = ""
    var rarity: String = ""
    /// One copy's USD market price; nil when there's none.
    var usd: Double?
    /// Mana it makes, letters from WUBRGCF; nil when the pack doesn't say (then lands read by basic land type).
    var produced: String?
    var tokens: [StatToken]
    /// The front face's card types as bits in `DeckStats.types` order, read once (stats ask many times).
    let typeBits: Int

    init(name: String, qty: Int, board: String, type: String, cost: String, cmc: Double, colors: String,
         legal: String = "", rarity: String = "", usd: Double? = nil, produced: String? = nil, tokens: [StatToken] = []) {
        self.name = name; self.qty = qty; self.board = board; self.type = type; self.cost = cost; self.cmc = cmc
        self.colors = colors; self.legal = legal; self.rarity = rarity; self.usd = usd; self.produced = produced
        self.tokens = tokens
        typeBits = DeckStats.cardTypes(type).reduce(0) { $0 | 1 << DeckStats.types.firstIndex(of: $1)! }
    }
}

enum DeckStats {
    static let colors: [Character] = ["W", "U", "B", "R", "G"]
    static let types = ["Creature", "Planeswalker", "Instant", "Sorcery", "Artifact", "Enchantment", "Battle", "Land"]
    private static let permanents: Set<String> = ["Creature", "Planeswalker", "Artifact", "Enchantment", "Battle", "Land"]
    static let colorGroups = ["White", "Blue", "Black", "Red", "Green", "Multicolor", "Colorless", "Lands"]
    /// Mana value columns: 0 … 6, then 7 and more.
    static let buckets = ["0", "1", "2", "3", "4", "5", "6", "7+"]
    private static let basicTypes: [(String, Character)] = [("Plains", "W"), ("Island", "U"), ("Swamp", "B"), ("Mountain", "R"), ("Forest", "G")]
    private static let fourOf: Set<String> = ["standard", "pioneer", "modern", "legacy", "vintage", "pauper", "premodern"]
    private static let singleton: Set<String> = ["commander", "canlander"]
    /// Cards whose text lets a deck hold any number of copies, and the few with their own cap.
    private static let anyNumber: Set<String> = [
        "Relentless Rats", "Rat Colony", "Shadowborn Apostle", "Persistent Petitioners", "Dragon's Approach",
        "Slime Against Humanity", "Hare Apparent", "Templar Knight", "Cid, Timeless Artificer",
    ]
    private static let upTo: [String: Int] = ["Seven Dwarves": 7, "Nazgûl": 9]

    // MARK: one card

    static func front(_ type: String) -> String { type.components(separatedBy: " // ").first ?? "" }

    private static func words(_ s: String) -> [String] {
        s.split { !$0.isLetter || !$0.isASCII }.map(String.init)
    }

    /// The card types on the front face ("Artifact Creature" → Artifact, Creature).
    static func cardTypes(_ type: String) -> [String] {
        let w = Set(words(front(type).components(separatedBy: " — ").first ?? ""))
        return types.filter { w.contains($0) }
    }

    static func isLand(_ c: StatCard) -> Bool { c.typeBits & 1 << 7 != 0 }
    static func isCreature(_ c: StatCard) -> Bool { c.typeBits & 1 != 0 }

    static func bucket(_ cmc: Double) -> Int { min(7, max(0, Int(cmc.rounded(.down)))) }

    /// Colored mana symbols in a cost, every face counted, as [W, U, B, R, G]. A hybrid symbol counts once for
    /// each of its colors; Phyrexian and {2/W} count for their color.
    static func pips(_ cost: String) -> [Int] {
        var out = [0, 0, 0, 0, 0]
        var sym = ""
        var inside = false
        for ch in cost {
            if ch == "{" { inside = true; sym = "" } else if ch == "}" {
                inside = false
                let parts = sym.split(separator: "/")
                for (i, col) in colors.enumerated() where parts.contains(where: { $0.count == 1 && $0.first == col }) { out[i] += 1 }
            } else if inside { sym.append(ch) }
        }
        return out
    }

    /// Colors of the basic land types on any face (Steam Vents → UR).
    static func basicTypeColors(_ c: StatCard) -> String {
        var sub = Set<String>()
        for face in c.type.components(separatedBy: " // ") {
            let parts = face.components(separatedBy: " — ")
            if parts.count > 1 { sub.formUnion(words(parts[1])) }
        }
        return String(basicTypes.filter { sub.contains($0.0) }.map(\.1))
    }

    /// Any face is a permanent (a spell // land card counts through its land).
    static func isPermanent(_ c: StatCard) -> Bool {
        c.type.components(separatedBy: " // ").contains { face in
            !permanents.isDisjoint(with: words(face.components(separatedBy: " — ").first ?? ""))
        }
    }

    static func isBasic(_ c: StatCard) -> Bool { words(c.type).contains("Basic") }

    /// Mana a card makes as WUBRGC letters. With the pack's produced field: permanents only (rituals aren't
    /// sources), and F (searches for any basic land) makes the colors of the deck's basic lands (`basics`). Without
    /// it (an older pack): lands by their basic land types.
    static func produces(_ c: StatCard, basics: String) -> String {
        guard let p = c.produced else { return isLand(c) ? basicTypeColors(c) : "" }
        guard isPermanent(c) else { return "" }
        let got = Set(p.filter { $0 != "F" } + (p.contains("F") ? basics : ""))
        return String("WUBRGC".filter { got.contains($0) })
    }

    /// The cube's color group: the card's colors (not its mana cost), lands on their own.
    static func colorGroup(_ c: StatCard) -> String {
        if isLand(c) { return "Lands" }
        if c.colors.isEmpty { return "Colorless" }
        if c.colors.count > 1 { return "Multicolor" }
        return colorGroups[colors.firstIndex(of: c.colors.first!) ?? 6]
    }

    // MARK: decks

    /// The deck the stats describe: main deck and commander (sideboard and Considering left out).
    static func deck(_ cards: [StatCard]) -> [StatCard] { cards.filter { $0.board == "main" || $0.board == "commander" } }

    /// Spells by mana value, split into creatures and everything else; lands left out.
    static func curve(_ cards: [StatCard]) -> (creatures: [Int], other: [Int]) {
        var creatures = Array(repeating: 0, count: 8), other = creatures
        for c in deck(cards) where !isLand(c) {
            if isCreature(c) { creatures[bucket(c.cmc)] += c.qty } else { other[bucket(c.cmc)] += c.qty }
        }
        return (creatures, other)
    }

    /// Copies of each card type, in `types` order. A card counts once for every type it has.
    static func typeCounts(_ cards: [StatCard]) -> [Int] {
        var out = Array(repeating: 0, count: types.count)
        for c in cards { for i in types.indices where c.typeBits & 1 << i != 0 { out[i] += c.qty } }
        return out
    }

    static func averageMV(_ cards: [StatCard], withLands: Bool) -> Double {
        var n = 0, sum = 0.0
        for c in deck(cards) where withLands || !isLand(c) {
            n += c.qty
            sum += c.cmc * Double(c.qty)
        }
        return n == 0 ? 0 : sum / Double(n)
    }

    static func pipTotals(_ cards: [StatCard]) -> [Int] {
        var out = [0, 0, 0, 0, 0]
        for c in deck(cards) { for (i, p) in pips(c.cost).enumerated() { out[i] += p * c.qty } }
        return out
    }

    struct Sources: Equatable {
        /// Copies that make each of W U B R G.
        var colors = [0, 0, 0, 0, 0]
        var colorless = 0
        /// Copies that make any mana, and the non-land ones among them (dorks, rocks, a spell // land card).
        var total = 0
        var nonLand = 0
        /// Lands (not basics) that make no mana the stats can read.
        var unread = 0
    }

    /// Mana sources in the deck: lands and permanents that make mana.
    static func sources(_ cards: [StatCard]) -> Sources {
        let d = deck(cards)
        var basicSet = Set<Character>()
        for c in d where isBasic(c) && isLand(c) { basicSet.formUnion(basicTypeColors(c)) }
        let basics = String(basicSet)
        var s = Sources()
        for c in d {
            let p = produces(c, basics: basics)
            if !p.isEmpty {
                s.total += c.qty
                if !isLand(c) { s.nonLand += c.qty }
                for (i, col) in colors.enumerated() where p.contains(col) { s.colors[i] += c.qty }
                if p.contains("C") { s.colorless += c.qty }
            } else if isLand(c) && !isBasic(c) {
                s.unread += c.qty
            }
        }
        return s
    }

    struct TokenUse: Equatable {
        let token: StatToken
        /// Cards that make it, by name, with their copies.
        let makers: [(name: String, qty: Int)]
        static func == (a: TokenUse, b: TokenUse) -> Bool {
            a.token == b.token && a.makers.map(\.name) == b.makers.map(\.name) && a.makers.map(\.qty) == b.makers.map(\.qty)
        }
    }

    /// Tokens the main deck, commander and sideboard make, by token card in name order.
    static func tokens(_ cards: [StatCard]) -> [TokenUse] {
        var found: [String: (token: StatToken, makers: [String: Int])] = [:]
        for c in cards where c.board != "maybe" {
            for t in c.tokens {
                found[t.key, default: (t, [:])].makers[c.name, default: 0] += c.qty
            }
        }
        let byName = { (a: String, b: String) in Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8)) }
        return found.values
            .sorted { $0.token.name != $1.token.name ? byName($0.token.name, $1.token.name) : byName($0.token.key, $1.token.key) }
            .map { TokenUse(token: $0.token, makers: $0.makers.sorted { byName($0.key, $1.key) }.map { ($0.key, $0.value) }) }
    }

    /// Main deck, sideboard and commander at market price; copies without a price are counted. Basics never count
    /// (contract/basics-2026-10-24.md).
    static func price(_ cards: [StatCard]) -> (total: Double, unpriced: Int) {
        var total = 0.0, unpriced = 0
        for c in cards where c.board != "maybe" && !isBasic(c) {
            if let usd = c.usd { total += usd * Double(c.qty) } else { unpriced += c.qty }
        }
        return ((total * 100).rounded() / 100, unpriced)
    }

    /// Cards in the main deck (the library a game starts from).
    static func librarySize(_ cards: [StatCard]) -> Int { cards.filter { $0.board == "main" }.reduce(0) { $0 + $1.qty } }

    /// Most copies a deck may hold over main deck and sideboard, nil for no limit.
    static func copyLimit(_ name: String, format: String, basic: Bool) -> Int? {
        if basic || anyNumber.contains(name) { return nil }
        if let n = upTo[name] { return n }
        if singleton.contains(format) { return 1 }
        if fourOf.contains(format) { return 4 }
        return nil
    }

    /// Why each card can't be played in a format, by name: Banned, Not legal, Restricted to 1, Singleton, or
    /// More than N copies. Main deck, sideboard and commander count; Considering doesn't. Sorted by name.
    static func legality(_ cards: [StatCard], format: String) -> [(name: String, reason: String)] {
        var copies: [String: Int] = [:], first: [String: StatCard] = [:]
        for c in cards where c.board != "maybe" {
            copies[c.name, default: 0] += c.qty
            if first[c.name] == nil { first[c.name] = c }
        }
        var out: [(name: String, reason: String)] = []
        for name in copies.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
            let c = first[name]!, n = copies[name]!
            let basic = words(c.type).contains("Basic")
            var reason: String?
            switch CatalogPack.legality(c.legal, format) {
            case "banned": reason = "Banned"
            case "not_legal": reason = "Not legal"
            case "restricted" where n > 1: reason = "Restricted to 1"
            case "restricted": break
            default:
                if let limit = copyLimit(name, format: format, basic: basic), n > limit {
                    reason = limit == 1 ? "Singleton" : "More than \(limit) copies"
                }
            }
            if let reason { out.append((name, reason)) }
        }
        return out
    }

    // MARK: odds

    private static func lnChoose(_ n: Int, _ k: Int) -> Double {
        guard k > 0 && k < n else { return 0 }
        let k = min(k, n - k)
        var s = 0.0
        for i in 1...k { s += log(Double(n - k + i)) - log(Double(i)) }
        return s
    }

    /// P(at least `k` of the `K` cards in a group are among `n` cards drawn from `N`).
    static func hypergeometric(population N: Int, successes K: Int, draws n: Int, atLeast k: Int) -> Double {
        let n = min(n, N)
        if k <= 0 { return 1 }
        if k > min(K, n) { return 0 }
        let total = lnChoose(N, n)
        var p = 0.0
        for i in k...min(K, n) where n - i <= N - K {
            p += exp(lnChoose(K, i) + lnChoose(N - K, n - i) - total)
        }
        return min(1, p)
    }

    /// Cards seen by your turn `turn`: the opening seven plus a draw each turn, except the first turn on the play.
    static func drawsByTurn(_ turn: Int, onPlay: Bool) -> Int { 7 + turn - (onPlay ? 1 : 0) }

    // MARK: cubes

    static func colorBalance(_ cards: [StatCard]) -> [Int] {
        var out = Array(repeating: 0, count: colorGroups.count)
        for c in cards { out[colorGroups.firstIndex(of: colorGroup(c))!] += c.qty }
        return out
    }

    /// Mana value columns for each color group but Lands.
    static func curveByColor(_ cards: [StatCard]) -> [[Int]] {
        var out = Array(repeating: Array(repeating: 0, count: 8), count: colorGroups.count - 1)
        for c in cards {
            let g = colorGroups.firstIndex(of: colorGroup(c))!
            if g < out.count { out[g][bucket(c.cmc)] += c.qty }
        }
        return out
    }

    enum AsfanBy: String, CaseIterable, Sendable { case color, type, mv }

    /// Labels for `asfan`'s values.
    static func asfanLabels(_ by: AsfanBy) -> [String] {
        switch by {
        case .color: colorGroups
        case .type: types
        case .mv: buckets + ["Lands"]
        }
    }

    /// Expected copies of each characteristic in a pack of `pack` cards drawn from the cube.
    static func asfan(_ cards: [StatCard], pack: Int, by: AsfanBy) -> [Double] {
        let total = cards.reduce(0) { $0 + $1.qty }
        let counts: [Int]
        switch by {
        case .color: counts = colorBalance(cards)
        case .type: counts = typeCounts(cards)
        case .mv:
            var c9 = Array(repeating: 0, count: 9)
            for c in cards { c9[isLand(c) ? 8 : bucket(c.cmc)] += c.qty }
            counts = c9
        }
        return counts.map { total == 0 ? 0 : Double(pack) * Double($0) / Double(total) }
    }

    /// One copy per element: the order sample hands and packs shuffle.
    static func expand(_ cards: [StatCard]) -> [Int] {
        cards.enumerated().flatMap { i, c in Array(repeating: i, count: max(0, c.qty)) }
    }
}

// MARK: random numbers (same sequence on every platform)

/// mulberry32: a small 32-bit generator, seeded, so tests can replay a hand.
struct StatsRNG: Sendable {
    private var a: UInt32
    init(seed: UInt32) { a = seed }

    mutating func next() -> UInt32 {
        a = a &+ 0x6D2B_79F5
        var t = a
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return t ^ (t >> 14)
    }

    /// 0 ..< bound (multiply-shift).
    mutating func int(_ bound: Int) -> Int { Int((UInt64(next()) * UInt64(bound)) >> 32) }

    /// A Fisher-Yates permutation of 0 ..< n.
    mutating func shuffle(_ n: Int) -> [Int] {
        var a = Array(0..<n)
        if n > 1 { for i in stride(from: n - 1, to: 0, by: -1) { a.swapAt(i, int(i + 1)) } }
        return a
    }

    static func randomSeed() -> UInt32 { UInt32.random(in: .min ... .max) }
}

/// A sample opening hand with the London mulligan: every mulligan shuffles and draws seven again, then puts one
/// card on the bottom for each mulligan taken. Values are positions in the expanded library (`DeckStats.expand`).
struct SampleHand: Sendable {
    let size: Int
    private var rng: StatsRNG
    private(set) var hand: [Int] = []
    private(set) var library: [Int] = []
    private(set) var mulligans = 0
    /// Cards still to put on the bottom before the hand is kept.
    private(set) var toBottom = 0
    /// Cards drawn after keeping.
    private(set) var drawn = 0

    init(size: Int, seed: UInt32) {
        self.size = size
        rng = StatsRNG(seed: seed)
        deal()
    }

    private mutating func deal() {
        let order = rng.shuffle(size)
        hand = Array(order.prefix(7))
        library = Array(order.dropFirst(7))
        toBottom = min(mulligans, hand.count)
        drawn = 0
    }

    /// Down to one card at most.
    var canMulligan: Bool { 7 - mulligans > 1 && size > 0 }
    var canDraw: Bool { toBottom == 0 && !library.isEmpty }

    mutating func mulligan() {
        guard canMulligan else { return }
        mulligans += 1
        deal()
    }

    mutating func bottom(_ index: Int) {
        guard toBottom > 0, hand.indices.contains(index) else { return }
        library.append(hand.remove(at: index))
        toBottom -= 1
    }

    mutating func draw() {
        guard canDraw else { return }
        hand.append(library.removeFirst())
        drawn += 1
    }
}
