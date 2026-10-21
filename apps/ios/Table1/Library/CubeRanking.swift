import Foundation

/* Cube rankings engine (contract/cube-rankings-2026-10-21.md). Pure: everything comes from a ranking's screen log, so
   undo, redo and watching never need repair. Same rules as the reference testdata/cube-ranking/make_cases.py, checked
   against its cases.json by CubeRankingTests:
   - A screen is 2-4 cards put in order, best first; every pair on it is known. Knowledge is the transitive closure,
     applied in log order; a pair that contradicts what's known is skipped and cards no longer in the cube are left out.
   - A job (a color, or the final over every card) places from the top: the next place goes to the card known to beat
     every other card still in; a card with `target` or more known above it is out.
   - The next screen: the cards nothing still in is known to beat (fewest known below, then a seeded hash), filled to
     four with cards unordered against the screen, nearest the top first; in the final, new colors first. When only two
     qualify it's a placement screen: one free card against up to three locked cards in known order. */

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

    init(cards: [String], log: [RankScreen] = []) {
        ids = Array(Set(cards.map { $0.lowercased() })).sorted()
        index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        beats = Array(repeating: RankBits(count: ids.count), count: ids.count)
        below = beats
        for s in log { apply(s) }
    }

    var count: Int { ids.count }

    mutating func apply(_ screen: RankScreen) {
        perJob[screen.s, default: 0] += 1
        let skipped = pairs(screen).filter { !add($0.0, $0.1) }
        if !skipped.isEmpty { contradicted[screens] = skipped }
        screens += 1
    }

    /// What a screen says, as (winner, loser) pairs: every pair in order, or for a pick the picked card over each
    /// other card of its pack (only while the picked card is in the cube).
    func pairs(_ screen: RankScreen) -> [(Int, Int)] {
        let xs = indexes(screen.o)
        if screen.s == RankJob.pick.rawValue {
            guard let first = screen.o.first, index[first.lowercased()] != nil else { return [] }
            return xs.dropFirst().map { (xs[0], $0) }
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
    private mutating func add(_ a: Int, _ b: Int) -> Bool {
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
}

enum CubeRanking {
    static func fnv1a(_ s: String) -> UInt32 {
        var h: UInt32 = 0x811C_9DC5
        for b in s.utf8 {
            h ^= UInt32(b)
            h = h &* 0x0100_0193
        }
        return h
    }

    /// One job: `scope` is the cards in it; `groups` maps a card index to its color (final only).
    static func session(_ K: RankKnowledge, scope: RankBits, target: Int, seed: String, groups: [Int]? = nil) -> RankSession {
        let members = scope.members
        let n = members.count
        let T = min(target, n)
        var live = RankBits(count: K.count)
        for x in members where K.belowSet(x).intersectionCount(scope) < T { live.insert(x) }
        var top: [Int] = []
        var U = live
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
        let done = top.count >= T
        guard !done else { return RankSession(top: top, done: true, target: T, size: n, question: nil, pinned: [], open: U) }

        var hashes: [Int: UInt32] = [:]
        func h(_ x: Int) -> UInt32 {
            if let v = hashes[x] { return v }
            let v = fnv1a(seed + ":" + K.ids[x]); hashes[x] = v; return v
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
        return RankSession(top: top, done: false, target: T, size: n, question: picked, pinned: pinned, open: U)
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
        return Int((1.78 * log2(f[T]) / log2(24.0)).rounded(.up))
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

    init(rankingId: String, cards: [String: RankJob], log: [RankScreen], depth: String, top: Int) {
        self.rankingId = rankingId.lowercased()
        category = Dictionary(cards.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        knowledge = RankKnowledge(cards: Array(category.keys), log: log)
        self.depth = depth
        self.top = top
    }

    private init(_ s: RankingState, knowledge: RankKnowledge) {
        rankingId = s.rankingId; category = s.category; depth = s.depth; top = s.top; self.knowledge = knowledge
    }

    /// The same ranking with one more screen.
    func appending(_ screen: RankScreen) -> RankingState {
        var k = knowledge
        k.apply(screen)
        return RankingState(self, knowledge: k)
    }

    func scope(_ job: RankJob) -> RankBits {
        var m = RankBits(count: knowledge.count)
        for (i, id) in knowledge.ids.enumerated() where job == .final || category[id] == job { m.insert(i) }
        return m
    }

    func size(_ job: RankJob) -> Int { job == .final ? knowledge.count : knowledge.ids.filter { category[$0] == job }.count }

    func target(_ job: RankJob) -> Int {
        if job == .final { return top }
        let n = size(job)
        return depth == "half" ? (n + 1) / 2 : n
    }

    /// Colors with at least one card, in order.
    var jobs: [RankJob] { RankJob.colors.filter { size($0) > 0 } }

    func session(_ job: RankJob) -> RankSession {
        let groups: [Int]? = job == .final
            ? knowledge.ids.map { RankJob.colors.firstIndex(of: category[$0] ?? .c) ?? 0 } : nil
        return CubeRanking.session(knowledge, scope: scope(job), target: target(job),
                                   seed: "\(rankingId):\(job.rawValue):\(knowledge.screens)", groups: groups)
    }

    func expected(_ job: RankJob) -> Int {
        job == .final ? CubeRanking.expectedMerge(jobs.map(size), top) : CubeRanking.expectedSort(size(job), target(job))
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
