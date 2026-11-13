import Foundation

/* Cube rankings engine (contract/cube-rankings-2026-10-21.md). Pure: everything comes from a ranking's screen log, so
   undo, redo and watching never need repair. Same rules as the reference testdata/cube-ranking/make_cases.py, checked
   against its cases.json by CubeRankingTests:
   - A screen is 2-4 cards put in order, best first; every pair on it is known. Knowledge is the transitive closure,
     applied final screens newest first, then the colors' screens, then picks (applyOrder); a pair that contradicts
     what's known is skipped. It covers the cube's cards and every card in
     the log, so a card that left the cube still carries what it settled; jobs and lists only hold the cube's cards.
   - Cards added since the ranking last caught up with its cube ("fresh") wait outside the lists until they're placed
     (in a list with nothing placed yet they're simply part of what's left to sort).
   - A job (a color, or the final over every card) places from the top: the next place goes to the card known to beat
     every other card still in; a card with `target` or more known above it is out.
   - The next screen: the cards nothing still in is known to beat (fewest known below, then a seeded hash), filled to
     four with cards unordered against the screen, nearest the top first; in the final, new colors first. When only two
     qualify it's a placement screen: one free card against up to three locked cards in known order.
   - The final places a card only once its order against the rest is checked (RankSupport): against each other color's
     best card not yet placed, asked on a screen or backed by two chains of screens that share no card (2026-11-13).
     Until then the next screen is that check, and its answer wins over what the colors or a detour had settled. */

/// A ranking job: a color of the cube (Group by color) or the final.
/// `pick` isn't a job: its screens are P1P1 picks (the first card picked over the rest of its pack).
enum RankJob: String, CaseIterable, Hashable, Sendable {
    case w = "W", u = "U", b = "B", r = "R", g = "G", m = "M", c = "C", l = "L", final = "F", pick = "P"

    static let colors: [RankJob] = [.w, .u, .b, .r, .g, .m, .c, .l]

    var title: String {
        switch self {
        case .w: "White"
        case .u: "Blue"
        case .b: "Black"
        case .r: "Red"
        case .g: "Green"
        case .m: "Multicolor"
        case .c: "Colorless"
        case .l: "Lands"
        case .final: "Final"
        case .pick: "P1P1"
        }
    }

    /// From CardGrouping's color group ("White" … "Lands").
    init?(colorGroup: String) {
        guard let j = Self.colors.first(where: { $0.title == colorGroup }) else { return nil }
        self = j
    }
}

/// How much of each color a ranking sorts: the top quarter, third or half, or every card (2026-10-23: quarter and third
/// added). The final top N comes out exact at any depth; it just asks about a card itself when a color has more cards in
/// the top N than it sorted.
enum RankDepth {
    static let all = ["quarter", "third", "half", "full"]
    static func divisor(_ depth: String) -> Int? { ["half": 2, "third": 3, "quarter": 4][depth] ?? (depth == "full" ? nil : 2) }
    static func target(_ n: Int, _ depth: String) -> Int { divisor(depth).map { (n + $0 - 1) / $0 } ?? n }
    /// "top half" / "top third" / "top quarter" / "every card".
    static func phrase(_ depth: String) -> String { ["half": "top half", "third": "top third", "quarter": "top quarter"][depth] ?? "every card" }
    /// The depth a new ranking starts with: a quarter of each color for a top 50, a third for a top 100.
    static func suggested(top: Int) -> String { top <= 50 ? "quarter" : "third" }
}

/// A set of card indexes.
struct RankBits: Equatable, Sendable {
    var words: [UInt64]

    init(count: Int) { words = Array(repeating: 0, count: (count + 63) / 64) }

    func contains(_ i: Int) -> Bool { words[i >> 6] & (1 << UInt64(i & 63)) != 0 }
    mutating func insert(_ i: Int) { words[i >> 6] |= 1 << UInt64(i & 63) }
    mutating func remove(_ i: Int) { words[i >> 6] &= ~(1 << UInt64(i & 63)) }
    mutating func formUnion(_ o: RankBits) { for k in words.indices { words[k] |= o.words[k] } }
    var count: Int { words.reduce(0) { $0 + $1.nonzeroBitCount } }
    var isEmpty: Bool { words.allSatisfy { $0 == 0 } }

    func intersectionCount(_ o: RankBits) -> Int {
        var n = 0
        for k in words.indices { n += (words[k] & o.words[k]).nonzeroBitCount }
        return n
    }

    func intersects(_ o: RankBits) -> Bool {
        for k in words.indices where words[k] & o.words[k] != 0 { return true }
        return false
    }

    /// Indexes in ascending order.
    var members: [Int] {
        var out: [Int] = []
        for (k, w) in words.enumerated() where w != 0 {
            var v = w
            while v != 0 {
                out.append(k * 64 + v.trailingZeroBitCount)
                v &= v - 1
            }
        }
        return out
    }
}

/// One screen of the log: the cards in the order they were locked in (best first), its job, and when (epoch ms).
struct RankScreen: Codable, Hashable, Sendable {
    var s: String
    var o: [String]
    var t: Double?

    var job: RankJob? { RankJob(rawValue: s) }
}

/// The log as a transitive "beats" relation over the cube's cards, indexed by sorted Oracle id.
struct RankKnowledge: Sendable {
    let ids: [String]
    let index: [String: Int]
    private(set) var beats: [RankBits]
    private(set) var below: [RankBits]
    private(set) var screens = 0
    private(set) var perJob: [String: Int] = [:]
    /// Screen index → pairs it said that were skipped because the opposite was already known.
    private(set) var contradicted: [Int: [(Int, Int)]] = [:]
    /// The screens this knowledge was built from.
    private(set) var log: [RankScreen] = []
    /// The final's support, kept up to date one screen at a time (built again when a check overturns an order). A class
    /// so `supportFor` can fill it on a `let`; `apply` swaps in a new one, so copies never share changes.
    private var cache = RankSupportCache()

    init(cards: [String], log: [RankScreen] = []) {
        ids = Array(Set((cards + log.flatMap(\.o)).map { $0.lowercased() })).sorted()
        index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        beats = Array(repeating: RankBits(count: ids.count), count: ids.count)
        below = beats
        self.log = log
        build()
    }

    /// The same cards, nothing known (RankSupport's own orders).
    init(sameCardsAs K: RankKnowledge) {
        ids = K.ids
        index = K.index
        beats = Array(repeating: RankBits(count: K.ids.count), count: K.ids.count)
        below = beats
    }

    var count: Int { ids.count }

    /// The order screens are applied in (2026-11-07): final screens newest first, then the colors' screens, then picks,
    /// each in log order. Without a contradiction the order changes nothing (the closure is the same). With one, a newer
    /// final screen wins over an older one and over a color's sort, so the final's checks can correct an order the colors
    /// or a detour through another color settled. Picks stay last, so "Keep my ranking" still skips a pick's
    /// disagreeing pairs.
    static func applyOrder(_ log: [RankScreen]) -> [Int] {
        let f = RankJob.final.rawValue, p = RankJob.pick.rawValue
        return log.indices.reversed().filter { log[$0].s == f } + log.indices.filter { log[$0].s != f && log[$0].s != p }
            + log.indices.filter { log[$0].s == p }
    }

    private mutating func build() {
        beats = Array(repeating: RankBits(count: ids.count), count: ids.count)
        below = beats
        contradicted = [:]
        perJob = [:]
        cache = RankSupportCache()
        for s in log { perJob[s.s, default: 0] += 1 }
        for k in Self.applyOrder(log) {
            let skipped = pairs(log[k]).filter { !add($0.0, $0.1) }
            if !skipped.isEmpty { contradicted[k] = skipped }
        }
        screens = log.count
    }

    /// One more screen. A final screen that contradicts what's known wins (final screens apply newest first), so the
    /// whole log is applied again; anything else gives the same answer added on its own.
    mutating func apply(_ screen: RankScreen) {
        log.append(screen)
        let prs = pairs(screen)
        if screen.s == RankJob.final.rawValue && prs.contains(where: { known($0.1, $0.0) }) { build(); return }
        perJob[screen.s, default: 0] += 1
        let skipped = prs.filter { !add($0.0, $0.1) }
        if !skipped.isEmpty { contradicted[screens] = skipped }
        screens += 1
        if var support = cache.value {
            support.addScreen(self, screen)
            cache = RankSupportCache(support)
        } else {
            cache = RankSupportCache()
        }
    }

    /// The final's support for these colors (built once, then kept up to date by `apply`).
    func supportFor(_ groups: [Int]) -> RankSupport {
        if let s = cache.value, s.groups == groups { return s }
        let s = RankSupport(self, groups: groups)
        cache.value = s
        return s
    }

    /// What a screen says, as (winner, loser) pairs: every pair in order, or for a pick the picked card over each
    /// other card of its pack.
    func pairs(_ screen: RankScreen) -> [(Int, Int)] {
        let xs = indexes(screen.o)
        if screen.s == RankJob.pick.rawValue {
            guard let first = xs.first else { return [] }
            return xs.dropFirst().map { (first, $0) }
        }
        var out: [(Int, Int)] = []
        for i in xs.indices { for j in (i + 1)..<xs.count { out.append((xs[i], xs[j])) } }
        return out
    }

    /// The screen's cards that are in the cube, in order, once each.
    func indexes(_ cards: [String]) -> [Int] {
        var xs: [Int] = []
        for c in cards { if let i = index[c.lowercased()], !xs.contains(i) { xs.append(i) } }
        return xs
    }

    /// Learns a beats b; false when the opposite was already known (the pair is skipped).
    @discardableResult
    mutating func add(_ a: Int, _ b: Int) -> Bool {
        if beats[b].contains(a) { return false }
        if beats[a].contains(b) { return true }
        var ups = below[a]; ups.insert(a)
        var downs = beats[b]; downs.insert(b)
        for x in ups.members { beats[x].formUnion(downs) }
        for y in downs.members { below[y].formUnion(ups) }
        return true
    }

    func known(_ a: Int, _ b: Int) -> Bool { beats[a].contains(b) }
    func beatsSet(_ x: Int) -> RankBits { beats[x] }
    func belowSet(_ x: Int) -> RankBits { below[x] }

    /// Same relation (redo: "Removing it changes nothing").
    func sameKnowledge(_ o: RankKnowledge) -> Bool { ids == o.ids && beats == o.beats }
}

/// One job's state: who is placed, whether it's done, and the next screen.
struct RankSession: Sendable {
    let top: [Int]
    let done: Bool
    let target: Int
    let size: Int
    /// The next screen's cards in shown order; nil when done.
    let question: [Int]?
    /// Placement screens: the locked cards, in known order (a subset of `question`).
    let pinned: [Int]
    /// Cards still in and not yet placed.
    let open: RankBits
    /// New cards that can still make the list and aren't placed yet: `top` leaves them out.
    var waiting: [Int] = []
    /// The final's check: the next card to place against cards its order with hasn't been asked about directly.
    var check = false
    /// Places checked from the top (the final; a color's list counts every place). `done` once it reaches the target;
    /// `top` shows every place the log settles, checked or not.
    var checked = 0
}

final class RankSupportCache: @unchecked Sendable {
    var value: RankSupport?
    init(_ value: RankSupport? = nil) { self.value = value }
}

/// Pairs RankSupport found backed by two chains. Screens only add wins (a final screen that overturns an order builds
/// the knowledge and its support again), so a backed pair stays backed; each new screen gets its own copy.
final class RankBacked: @unchecked Sendable {
    var pairs: Set<Int>
    init(_ pairs: Set<Int> = []) { self.pairs = pairs }
}

/// What the final needs before it places a card (2026-11-07): which orders a screen asked about directly. `met[x]` the
/// cards x was ordered against on any screen (a pick: the picked card and the rest), `metFinal[x]` on a final screen,
/// `won[x]` the cards x beat on a screen (and still beats); `sorted` the same-color order the color's own screens set.
struct RankSupport {
    let groups: [Int]
    private var met: [RankBits]
    private var metFinal: [RankBits]
    private var won: [RankBits]
    private var sorted: RankKnowledge
    private var backed = RankBacked()

    init(_ K: RankKnowledge, groups: [Int]) {
        self.groups = groups
        met = Array(repeating: RankBits(count: K.count), count: K.count)
        metFinal = met
        won = met
        sorted = RankKnowledge(sameCardsAs: K)
        for sc in K.log { addScreen(K, sc) }
    }

    /// One more screen of K's log (K already knows it).
    mutating func addScreen(_ K: RankKnowledge, _ sc: RankScreen) {
        let f = RankJob.final.rawValue, p = RankJob.pick.rawValue
        backed = RankBacked(backed.pairs)
        for (w, l) in K.pairs(sc) {
            met[w].insert(l); met[l].insert(w)
            if sc.s == f { metFinal[w].insert(l); metFinal[l].insert(w) }
            if K.known(w, l) {
                won[w].insert(l)
                if groups[w] == groups[l] && sc.s != f && sc.s != p { sorted.add(w, l) }
            }
        }
    }

    /// x is known to beat every other card still in the running; P is the final's cards not placed yet, in the running
    /// or not (2026-11-13: in Daniel Shea's Lindmark Cube top 50 every white, red and green card had been pushed out of
    /// the running by answers nothing checked, so places 35-46 were twelve black cards checked only against each other).
    /// The cards x still needs a screen with, one per color at most: each other color's best card in P (fewest known
    /// above it in P, then index) unless x met it on a screen or two chains of screens that share no card put x above it
    /// (one chain is one answer away from wrong: Duress over Wheel of Fortune carried those twelve, all through Urza's
    /// Saga over Path to Exile); and x's own color's best card when only the color's own screens put x above it (a color
    /// sorted wrong holds its better cards back, then lets them out in a run).
    func unchecked(_ K: RankKnowledge, _ x: Int, _ P: RankBits) -> RankBits {
        var best: [Int: (Int, Int)] = [:]
        for y in P.members where y != x {
            let g = groups[y], k = K.belowSet(y).intersectionCount(P)
            if let cur = best[g], cur.0 < k || (cur.0 == k && cur.1 < y) { continue }
            best[g] = (k, y)
        }
        var miss = RankBits(count: K.count)
        for (g, (_, y)) in best {
            if g == groups[x] {
                if sorted.known(x, y) && !metFinal[x].contains(y) { miss.insert(y) }
                continue
            }
            if met[x].contains(y) { continue }
            let key = x * K.count + y
            if backed.pairs.contains(key) { continue }
            if RankSupport.chains(won, x, y) >= 2 { backed.pairs.insert(key) } else { miss.insert(y) }
        }
        return miss
    }

    /// How many chains of screens that share no card lead from x down to y, at most `limit` (2026-11-13): vertex-disjoint
    /// paths in the graph of screen wins (`won[a]`: the cards a beat on a screen and still beats), found by augmenting
    /// paths over split vertices (in(v) = 2v, out(v) = 2v + 1). Only the count matters, so the search order doesn't.
    static func chains(_ won: [RankBits], _ x: Int, _ y: Int, limit: Int = 2) -> Int {
        let n = won.count
        var usedV = [Bool](repeating: false, count: n)   // vertices carrying a chain (x and y never count)
        var usedIn: [Int: Set<Int>] = [:]                // b -> the a's whose edge a -> b carries a chain
        var usedOut: [Int: Set<Int>] = [:]               // a -> the b's of those edges
        var flow = 0
        while flow < limit {
            let start = 2 * x + 1, goal = 2 * y
            var from = [Int](repeating: -1, count: 2 * n)
            from[start] = start
            var queue = [start], h = 0, found = false
            func go(_ t: Int, _ st: Int) {
                if from[t] < 0 { from[t] = st; queue.append(t); if t == goal { found = true } }
            }
            while h < queue.count && !found {
                let st = queue[h], v = st >> 1
                h += 1
                if st & 1 == 1 {
                    let out = usedOut[v]
                    outer: for (k, word) in won[v].words.enumerated() where word != 0 {
                        var m = word
                        while m != 0 {
                            let b = k * 64 + m.trailingZeroBitCount
                            m &= m - 1
                            if out?.contains(b) != true { go(2 * b, st); if found { break outer } }
                        }
                    }
                    if usedV[v] && v != x { go(2 * v, st) }
                } else {
                    if v != y && !usedV[v] { go(2 * v + 1, st) }
                    for a in usedIn[v] ?? [] { go(2 * a + 1, st) }
                }
            }
            if !found { break }
            var t = goal
            while t != start {
                let f = from[t], fv = f >> 1, tv = t >> 1
                if f & 1 == 1 && t & 1 == 0 {        // out(fv) -> in(tv): along an edge, or back across a used vertex
                    if fv == tv { usedV[fv] = false } else { usedIn[tv, default: []].insert(fv); usedOut[fv, default: []].insert(tv) }
                } else if f & 1 == 0 && t & 1 == 1 { // in(fv) -> out(tv): across a vertex, or back along a used edge
                    if fv == tv { usedV[fv] = true } else { usedIn[fv]?.remove(tv); usedOut[tv]?.remove(fv) }
                }
                t = f
            }
            flow += 1
        }
        return flow
    }
}

enum CubeRanking {
    /// The rules this engine implements, by the date they changed; the same in every engine and in cases.json (`rules`).
    /// RankEngine runs the server's engine file instead when its manifest names newer rules.
    static let rules = "2026-11-13"

    static func fnv1a(_ s: String) -> UInt32 {
        var h: UInt32 = 0x811C_9DC5
        for b in s.utf8 {
            h ^= UInt32(b)
            h = h &* 0x0100_0193
        }
        return h
    }

    /// Places from the top: the next place goes to the card in U known to beat every other card in U (U loses them).
    private static func ranked(_ K: RankKnowledge, _ U: inout RankBits, _ T: Int) -> [Int] {
        var top: [Int] = []
        while top.count < T {
            var found: Int?
            for x in U.members {
                let bx = K.beatsSet(x)
                var ok = true
                for k in U.words.indices {
                    var rest = U.words[k] & ~bx.words[k]
                    if k == x >> 6 { rest &= ~(1 << UInt64(x & 63)) }
                    if rest != 0 { ok = false; break }
                }
                if ok { found = x; break }
            }
            guard let f = found else { break }
            top.append(f)
            U.remove(f)
        }
        return top
    }

    /// One job: `scope` is the cards in it; `groups` maps a card index to its color (final only); `fresh` the cube's new
    /// cards. The list (`top`) leaves out new cards still waiting to be placed (`waiting`); screens and `done` count all.
    static func session(_ K: RankKnowledge, scope: RankBits, target: Int, seed: String, groups: [Int]? = nil,
                        fresh: RankBits? = nil) -> RankSession {
        let members = scope.members
        let n = members.count
        let T = min(target, n)
        var live = RankBits(count: K.count)
        for x in members where K.belowSet(x).intersectionCount(scope) < T { live.insert(x) }
        var U = live
        let full = ranked(K, &U, T)
        var sure = full.count
        var stuck: (Int, RankBits)?
        var unplaced = scope
        if let groups {
            var left = live
            let (good, why) = checked(K, &left, &unplaced, T, K.supportFor(groups))
            sure = good.count
            stuck = why
        }
        let done = sure >= T
        let placed = Set(full)
        var waiting = fresh.map { f in live.members.filter { f.contains($0) && !placed.contains($0) } } ?? []
        var top = full
        if !waiting.isEmpty {
            var shown = live
            for x in waiting { shown.remove(x) }
            top = ranked(K, &shown, T)
            // A list with nothing placed yet: new cards are simply part of what's left to sort.
            if top.isEmpty { top = full; waiting = [] }
        }
        guard !done else {
            return RankSession(top: top, done: true, target: T, size: n, question: nil, pinned: [], open: U, waiting: waiting, checked: sure)
        }

        var hashes: [Int: UInt32] = [:]
        func h(_ x: Int) -> UInt32 {
            if let v = hashes[x] { return v }
            let v = fnv1a(seed + ":" + K.ids[x]); hashes[x] = v; return v
        }
        if let (x, miss) = stuck, let groups {
            return RankSession(top: top, done: false, target: T, size: n, question: checkScreen(K, unplaced, x, miss, groups, h), pinned: [],
                               open: U, waiting: waiting, check: true, checked: sure)
        }
        let openCards = U.members
        let cands = openCards.filter { !K.belowSet($0).intersects(U) }
        let candKeys = Dictionary(uniqueKeysWithValues: cands.map { ($0, (K.beatsSet($0).intersectionCount(U), h($0))) })
        let sortedCands = cands.sorted { a, b in
            let ka = candKeys[a]!, kb = candKeys[b]!
            if ka.0 != kb.0 { return ka.0 < kb.0 }
            if ka.1 != kb.1 { return ka.1 < kb.1 }
            return a < b
        }
        var picked = choose(K, sortedCands, groups, [])
        if picked.count < 4 {
            let candSet = Set(cands)
            let others = openCards.filter { !candSet.contains($0) }
            let keys = Dictionary(uniqueKeysWithValues: others.map {
                ($0, (K.belowSet($0).intersectionCount(U), K.beatsSet($0).intersectionCount(U), h($0)))
            })
            let sortedOthers = others.sorted { a, b in
                let ka = keys[a]!, kb = keys[b]!
                if ka.0 != kb.0 { return ka.0 < kb.0 }
                if ka.1 != kb.1 { return ka.1 < kb.1 }
                if ka.2 != kb.2 { return ka.2 < kb.2 }
                return a < b
            }
            picked = choose(K, sortedOthers, groups, picked)
        }
        var pinned: [Int] = []
        if picked.count == 2 { (picked, pinned) = placement(K, U, picked[0], picked[1], h) }
        return RankSession(top: top, done: false, target: T, size: n, question: picked, pinned: pinned, open: U, waiting: waiting, checked: sure)
    }

    /// ranked() for the final: a card known to beat every other card still in is placed only once its order against
    /// them is checked (RankSupport.unchecked). Returns the places and, when it stops at one, the card and its unchecked
    /// cards.
    /// ranked() for the final: a card known to beat every other card still in (U) is placed only once its order against
    /// the cards not placed yet (P) is checked (RankSupport.unchecked). U and P lose the placed cards.
    private static func checked(_ K: RankKnowledge, _ U: inout RankBits, _ P: inout RankBits, _ T: Int, _ support: RankSupport) -> ([Int], (Int, RankBits)?) {
        var top: [Int] = []
        while top.count < T {
            var probe = U
            guard let x = ranked(K, &probe, 1).first else { break }
            let miss = support.unchecked(K, x, P)
            if !miss.members.isEmpty { return (top, (x, miss)) }
            top.append(x)
            U.remove(x)
            P.remove(x)
        }
        return (top, nil)
    }

    /// The check: x with up to three of the cards it hasn't been checked against: its own color's next card first, then
    /// other colors' cards nearest the top (fewest known above them among the cards not placed yet, P), one per color
    /// first. Nothing is locked: the answer is new and wins.
    private static func checkScreen(_ K: RankKnowledge, _ P: RankBits, _ x: Int, _ miss: RankBits, _ groups: [Int],
                                    _ h: (Int) -> UInt32) -> [Int] {
        let keys = Dictionary(uniqueKeysWithValues: miss.members.map { ($0, (K.belowSet($0).intersectionCount(P), h($0))) })
        let ys = miss.members.sorted { a, b in
            let ka = keys[a]!, kb = keys[b]!
            if ka.0 != kb.0 { return ka.0 < kb.0 }
            if ka.1 != kb.1 { return ka.1 < kb.1 }
            return a < b
        }
        var picked = [x] + ys.filter { groups[$0] == groups[x] }.prefix(1)
        for y in ys where picked.count < 4 && !picked.contains(y) && !picked.contains(where: { groups[$0] == groups[y] }) { picked.append(y) }
        for y in ys where picked.count < 4 && !picked.contains(y) { picked.append(y) }
        return picked
    }

    private static func choose(_ K: RankKnowledge, _ order: [Int], _ groups: [Int]?, _ start: [Int]) -> [Int] {
        var picked = start
        func ok(_ x: Int) -> Bool {
            !picked.contains(x) && picked.allSatisfy { !K.known(x, $0) && !K.known($0, x) }
        }
        if let groups {
            for x in order {
                if picked.count == 4 { break }
                if ok(x) && !picked.contains(where: { groups[$0] == groups[x] }) { picked.append(x) }
            }
        }
        for x in order {
            if picked.count == 4 { break }
            if ok(x) { picked.append(x) }
        }
        return picked
    }

    /// Only two cards qualify: the free card against the leader and up to two cards of the run below it (its middle
    /// and its end), locked in known order. Returns (cards in shown order, pinned cards).
    private static func placement(_ K: RankKnowledge, _ U: RankBits, _ a: Int, _ b: Int, _ h: (Int) -> UInt32) -> ([Int], [Int]) {
        var best: (chain: [Int], free: Int)?
        for (lead, free) in [(a, b), (b, a)] {
            let run: [Int] = U.members.filter { K.known(lead, $0) && !K.known(free, $0) && !K.known($0, free) }
            let keys: [Int: (Int, UInt32)] = Dictionary(uniqueKeysWithValues: run.map { ($0, (K.belowSet($0).intersectionCount(U), h($0))) })
            let below = run.sorted { x, y in
                let kx = keys[x]!, ky = keys[y]!
                if kx.0 != ky.0 { return kx.0 < ky.0 }
                if kx.1 != ky.1 { return kx.1 < ky.1 }
                return x < y
            }
            var chain = [lead]
            for c in below where K.known(chain[chain.count - 1], c) { chain.append(c) }
            if best == nil || chain.count > best!.chain.count { best = (chain, free) }
        }
        var (chain, free) = best!
        if chain.count == 1 { return ([a, b], []) }
        if chain.count > 3 {
            let rest = Array(chain.dropFirst())
            chain = [chain[0], rest[(rest.count - 1) / 2], rest[rest.count - 1]]
        }
        return (chain + [free], chain)
    }

    /// A redone screen's cards come back first while each is still open and their order is unknown.
    static func reaskOpen(_ K: RankKnowledge, _ st: RankSession, _ cards: [String]) -> Bool {
        var xs: [Int] = []
        for c in cards {
            guard let i = K.index[c.lowercased()] else { return false }
            xs.append(i)
        }
        guard xs.count >= 2, xs.allSatisfy({ st.open.contains($0) }) else { return false }
        for i in xs.indices {
            for j in (i + 1)..<xs.count where K.known(xs[i], xs[j]) || K.known(xs[j], xs[i]) { return false }
        }
        return true
    }

    // MARK: estimates

    /// About how many screens a job takes: ordering the top k of n cards.
    static func expectedSort(_ n: Int, _ k: Int) -> Int {
        let k = min(k, n)
        guard n > 1, k > 0 else { return 0 }
        var bits = 0.0
        for i in (n - k + 1)...n { bits += log2(Double(i)) }
        let f = k >= n - 1 ? 1.55 : 1.66
        return Int((f * bits / log2(24.0)).rounded(.up))
    }

    /// About how many screens the final takes once every color is sorted: placing the top `top` across colors.
    static func expectedMerge(_ sizes: [Int], _ top: Int) -> Int {
        let T = min(top, sizes.reduce(0, +))
        guard T > 0, sizes.filter({ $0 > 0 }).count > 1 else { return 0 }
        var C: [[Double]] = [[1]]
        for t in stride(from: 1, through: T, by: 1) {
            var row = Array(repeating: 1.0, count: t + 1)
            for k in stride(from: 1, to: t, by: 1) { row[k] = C[t - 1][k - 1] + C[t - 1][k] }
            C.append(row)
        }
        var f = [1.0] + Array(repeating: 0.0, count: T)
        for s in sizes {
            var g = Array(repeating: 0.0, count: T + 1)
            for t in 0...T {
                for k in 0...min(s, t) { g[t] += f[t - k] * C[t][k] }
            }
            f = g
        }
        return Int((6.0 * log2(f[T]) / log2(24.0)).rounded(.up)) // 1.78 before the final's checks, 4.9 before 2026-11-13
    }

    // MARK: why

    /// One link of a "why" chain: this screen (from 1) put the winner above the loser.
    struct Link: Hashable { let winner: String; let loser: String; let screen: Int }

    /// The shortest chain of screens that puts `hi` above `lo`, or nil when nothing has settled it.
    static func why(_ K: RankKnowledge, _ log: [RankScreen], hi: String, lo: String) -> [Link]? {
        guard let a = K.index[hi.lowercased()], let b = K.index[lo.lowercased()], a != b, K.known(a, b) else { return nil }
        var first: [Int: Int] = [:] // w * n + l → screen index
        let n = K.count
        for (k, sc) in log.enumerated() {
            for (w, l) in K.pairs(sc) where K.known(w, l) {
                let key = w * n + l
                if first[key] == nil { first[key] = k }
            }
        }
        var adj: [Int: [(Int, Int)]] = [:]
        for (key, k) in first { adj[key / n, default: []].append((k, key % n)) }
        for w in adj.keys { adj[w]!.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 } }
        var prev: [Int: (Int, Int)?] = [a: nil]
        var queue = [a]
        while !queue.isEmpty {
            var next: [Int] = []
            for x in queue {
                for (k, y) in adj[x] ?? [] where prev[y] == nil {
                    prev[y] = .some((x, k))
                    next.append(y)
                }
            }
            if prev[b] != nil { break }
            queue = next
        }
        guard prev[b] != nil else { return nil }
        var chain: [Link] = []
        var y = b
        while let p = prev[y], let step = p {
            let (x, k) = step
            chain.append(Link(winner: K.ids[x], loser: K.ids[y], screen: k + 1))
            y = x
        }
        return chain.reversed()
    }

    // MARK: P1P1 picks

    static let packSize = 15

    /// The next pack: up to 15 of the cube's cards, by a hash of the ranking, the picks so far and the card.
    static func pack(rankingId: String, _ K: RankKnowledge) -> [String] {
        let n = K.perJob[RankJob.pick.rawValue] ?? 0
        let rid = rankingId.lowercased()
        let keyed = K.ids.enumerated().map { (fnv1a("\(rid):P:\(n):\($0.element)"), $0.offset) }
        return keyed.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.prefix(packSize).map { K.ids[$0.1] }
    }

    /// Cards of the pack the ranking already puts above the picked card, in pack order.
    static func disagreements(_ K: RankKnowledge, picked: String, pack: [String]) -> [String] {
        guard let p = K.index[picked.lowercased()] else { return [] }
        return pack.filter { $0.lowercased() != picked.lowercased() && K.index[$0.lowercased()].map { K.known($0, p) } == true }
    }

    /// "Let the pick win": while the ranking puts a pack card above the picked one, take out the newest screen of the
    /// shortest chain that says so (at most 30). Returns the log indexes to remove, ascending.
    static func pickWins(cards: [String], log: [RankScreen], picked: String, pack: [String]) -> [Int] {
        var alive = Array(log.indices)
        var removed: [Int] = []
        for _ in 0..<30 {
            let cur = alive.map { log[$0] }
            let K = RankKnowledge(cards: cards, log: cur)
            guard let d = disagreements(K, picked: picked, pack: pack).first,
                  let chain = why(K, cur, hi: d, lo: picked), let k = chain.map(\.screen).max() else { break }
            removed.append(alive.remove(at: k - 1))
        }
        return removed.sorted()
    }

    // MARK: compare

    struct Gap: Hashable {
        let card: String
        let a: Int, aOut: Bool
        let b: Int, bOut: Bool
        let gap: Int
        let atLeast: Bool
    }

    struct Comparison: Hashable {
        let compared: Int
        /// Average gap in tenths, half up.
        let avgTenths: Int
        let atLeast: Bool
        let biggest: [Gap]
        let oneSide: [Gap]
    }

    /// Two rankings' orders of one list (the same cube's knowledge indexes).
    static func compare(_ K: RankKnowledge, _ a: RankSession, _ b: RankSession, scope: RankBits) -> Comparison {
        func place(_ st: RankSession, _ x: Int) -> (Int, Bool)? {
            if let i = st.top.firstIndex(of: x) { return (i + 1, false) }
            if st.done && st.top.count < st.size { return (st.top.count + 1, true) }
            return nil
        }
        var rows: [(gap: Gap, best: Int, x: Int)] = []
        for x in scope.members {
            guard let pa = place(a, x), let pb = place(b, x), !(pa.1 && pb.1) else { continue }
            let best = [pa, pb].filter { !$0.1 }.map(\.0).min()!
            rows.append((Gap(card: K.ids[x], a: pa.0, aOut: pa.1, b: pb.0, bOut: pb.1, gap: abs(pa.0 - pb.0),
                             atLeast: pa.1 || pb.1), best, x))
        }
        let n = rows.count
        let total = rows.reduce(0) { $0 + $1.gap.gap }
        let biggest = rows.sorted { $0.gap.gap != $1.gap.gap ? $0.gap.gap > $1.gap.gap : $0.best != $1.best ? $0.best < $1.best : $0.x < $1.x }
        let oneSide = rows.filter { $0.gap.aOut != $0.gap.bOut }.sorted { $0.best != $1.best ? $0.best < $1.best : $0.x < $1.x }
        return Comparison(compared: n, avgTenths: n == 0 ? 0 : (20 * total + n) / (2 * n), atLeast: rows.contains { $0.gap.atLeast },
                          biggest: biggest.prefix(10).map(\.gap), oneSide: oneSide.map(\.gap))
    }
}

/// A whole ranking worked out from its log: the cube's cards and colors, depth and final size.
struct RankingState: Sendable {
    let rankingId: String
    let knowledge: RankKnowledge
    let category: [String: RankJob] // oracle id → color
    let depth: String
    let top: Int
    /// The cube's cards added since the ranking last caught up: they wait outside the lists until they're placed.
    let fresh: Set<String>
    /// The same ranking in the server's engine file when it has newer rules than this build (RankEngine); nil = ours.
    let js: RankEngineState?

    /// `cards` are the cube's cards now (a card in the log but not here has left the cube); `fresh` its new cards.
    init(rankingId: String, cards: [String: RankJob], log: [RankScreen], depth: String, top: Int, fresh: Set<String> = []) {
        self.rankingId = rankingId.lowercased()
        category = Dictionary(cards.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        knowledge = RankKnowledge(cards: Array(category.keys), log: log)
        self.depth = depth
        self.top = top
        let cube = category
        self.fresh = Set(fresh.map { $0.lowercased() }.filter { cube[$0] != nil })
        js = RankEngine.shared.open(rankingId: self.rankingId, category: category, log: log, depth: depth, top: top, fresh: self.fresh)
    }

    private init(_ s: RankingState, knowledge: RankKnowledge, js: RankEngineState?) {
        rankingId = s.rankingId; category = s.category; depth = s.depth; top = s.top; fresh = s.fresh; self.knowledge = knowledge; self.js = js
    }

    /// New cards not placed yet in any list: a re-rank is due.
    var waiting: [String] {
        var out = Set<String>()
        for job in jobs + [.final] { for x in session(job).waiting { out.insert(id(x)) } }
        return out.sorted()
    }

    /// The same ranking with one more screen.
    func appending(_ screen: RankScreen) -> RankingState {
        var k = knowledge
        k.apply(screen)
        return RankingState(self, knowledge: k, js: js?.appending(screen))
    }

    func scope(_ job: RankJob) -> RankBits {
        var m = RankBits(count: knowledge.count)
        for (i, id) in knowledge.ids.enumerated() {
            if let c = category[id], job == .final || c == job { m.insert(i) }
        }
        return m
    }

    func size(_ job: RankJob) -> Int { job == .final ? category.count : category.values.filter { $0 == job }.count }

    func target(_ job: RankJob) -> Int {
        if job == .final { return top }
        return RankDepth.target(size(job), depth)
    }

    /// Colors with at least one card, in order.
    var jobs: [RankJob] { RankJob.colors.filter { size($0) > 0 } }

    func session(_ job: RankJob) -> RankSession {
        if let js, let s = js.session(job, knowledge) { return s }
        let groups: [Int]? = job == .final
            ? knowledge.ids.map { RankJob.colors.firstIndex(of: category[$0] ?? .c) ?? 0 } : nil
        var freshBits: RankBits?
        if !fresh.isEmpty {
            var b = RankBits(count: knowledge.count)
            for c in fresh { if let i = knowledge.index[c] { b.insert(i) } }
            freshBits = b
        }
        return CubeRanking.session(knowledge, scope: scope(job), target: target(job),
                                   seed: "\(rankingId):\(job.rawValue):\(knowledge.screens)", groups: groups, fresh: freshBits)
    }

    func expected(_ job: RankJob) -> Int {
        if let js, let n = js.expected(job) { return n }
        return job == .final ? CubeRanking.expectedMerge(jobs.map(size), top) : CubeRanking.expectedSort(size(job), target(job))
    }

    /// Colors sorted, colors with cards, places ranked in the final: what list rows show.
    var progress: (sorted: Int, categories: Int, ranked: Int) {
        let js = jobs
        return (js.filter { session($0).done }.count, js.count, session(.final).top.count)
    }

    func id(_ x: Int) -> String { knowledge.ids[x] }

    /// Every list's places: job → oracle id → place (from 1).
    var places: [RankJob: [String: Int]] { places(nil) }

    /// The places of some lists (a color's screen can only move that color and the final).
    func places(_ only: [RankJob]?) -> [RankJob: [String: Int]] {
        var out: [RankJob: [String: Int]] = [:]
        for job in only ?? (jobs + [.final]) {
            out[job] = Dictionary(uniqueKeysWithValues: session(job).top.enumerated().map { (id($0.element), $0.offset + 1) })
        }
        return out
    }
}

/// One line of a ranking's change log: a card's place in a list went from → to (nil = not placed).
struct RankChange: Codable, Hashable, Sendable {
    var s: String
    var c: String
    var f: Int?
    var to: Int?
    /// When (epoch ms), what did it (screen / undo / redo / pick / pick_win) and the screen number, once saved.
    var t: Double?
    var by: String?
    var n: Int?

    /// What moved between two states' places: colors then the final, each by the better place, then card id.
    static func diff(_ before: [RankJob: [String: Int]], _ after: [RankJob: [String: Int]]) -> [RankChange] {
        var out: [RankChange] = []
        for job in RankJob.colors + [.final] {
            let a = before[job] ?? [:], b = after[job] ?? [:]
            let rows = Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }
                .map { (c: $0, f: a[$0], to: b[$0]) }
                .sorted { x, y in
                    let bx = [x.f, x.to].compactMap { $0 }.min()!, by = [y.f, y.to].compactMap { $0 }.min()!
                    return bx != by ? bx < by : x.c < y.c
                }
            out += rows.map { RankChange(s: job.rawValue, c: $0.c, f: $0.f, to: $0.to) }
        }
        return out
    }
}
