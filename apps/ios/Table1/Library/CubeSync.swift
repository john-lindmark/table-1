import Foundation

// Sync a cube with Cube Cobra (contract/cube-sync-2026-10-30.md): what's in, out and in a new printing or finish
// between the cube and Cube Cobra's answer, and the entries to save. Shared cases: testdata/cube-sync/cases.json.

enum CubeSync {
    struct Line: Hashable, Sendable {
        let board: String
        let cardId: String
        let finish: String
        let lang: String
        /// The line's condition: Cube Cobra records none, so a kept or changed copy keeps it and an In copy is NM.
        var cond = "NM"
        let qty: Int
    }
    struct Changed: Hashable, Sendable {
        let board: String
        let fromCard: String
        let fromFinish: String
        let fromLang: String
        let toCard: String
        let toFinish: String
        let toLang: String
        let qty: Int
    }
    struct Result: Sendable {
        var into: [Line] = []
        var out: [Line] = []
        var changed: [Changed] = []
        var same = 0
        var entries: [CardList.Entry] = []

        var inCount: Int { into.reduce(0) { $0 + $1.qty } }
        var outCount: Int { out.reduce(0) { $0 + $1.qty } }
        var changedCount: Int { changed.reduce(0) { $0 + $1.qty } }
        var isEmpty: Bool { into.isEmpty && out.isEmpty && changed.isEmpty }

        /// "3 in · 2 out · 5 new printings", or "Up to date".
        var summary: String {
            var parts: [String] = []
            if inCount > 0 { parts.append("\(inCount) in") }
            if outCount > 0 { parts.append("\(outCount) out") }
            if changedCount > 0 { parts.append("\(changedCount) new printing\(changedCount == 1 ? "" : "s")") }
            return parts.isEmpty ? "Up to date" : parts.joined(separator: " · ")
        }
    }
    /// A printing's card (oracle) and language, from the catalog.
    struct Printing: Sendable {
        let oracle: String
        let lang: String
    }

    private struct Key: Hashable, Comparable {
        let board: String, card: String, finish: String, lang: String, cond: String
        static func < (a: Key, b: Key) -> Bool {
            (a.board, a.card, a.finish, a.lang, a.cond) < (b.board, b.card, b.finish, b.lang, b.cond)
        }
    }
    private struct InKey: Hashable, Comparable {
        let board: String, card: String, finish: String
        static func < (a: InKey, b: InKey) -> Bool { (a.board, a.card, a.finish) < (b.board, b.card, b.finish) }
    }

    /// English first, then by code.
    private static func langBefore(_ a: String, _ b: String) -> Bool {
        (a != "en" ? 1 : 0, a) < (b != "en" ? 1 : 0, b)
    }

    /// English first, then by code; then the best condition first.
    private static func lineBefore(_ a: Key, _ b: Key) -> Bool {
        a.lang != b.lang ? langBefore(a.lang, b.lang) : rank(a.cond) < rank(b.cond)
    }
    private static func rank(_ cond: String) -> Int { ListToCollection.conditions.firstIndex(of: cond) ?? 9 }

    static func diff(current: [CardList.Entry], incoming: [CardList.Entry], printings: [String: Printing]) -> Result {
        let plang = { (c: String) in printings[c]?.lang ?? "en" }
        let oracle = { (c: String) in printings[c]?.oracle ?? c }
        var cur: [Key: Int] = [:]
        for e in current { cur[Key(board: e.board, card: e.cardId, finish: e.finish, lang: e.lang, cond: e.cond), default: 0] += e.qty }
        var inc: [InKey: Int] = [:]
        for e in incoming { inc[InKey(board: e.board, card: e.cardId, finish: e.finish), default: 0] += e.qty }
        var final: [Key: Int] = [:]
        var changed: [[String]: Int] = [:]
        var r = Result()

        // 1. Same printing and finish.
        for k in inc.keys.sorted() {
            let matches = cur.keys.filter { $0.board == k.board && $0.card == k.card && $0.finish == k.finish }
                .sorted(by: lineBefore)
            for m in matches {
                let n = min(inc[k]!, cur[m]!)
                guard n > 0 else { continue }
                cur[m]! -= n
                inc[k]! -= n
                final[m, default: 0] += n
                r.same += n
            }
        }

        // 2. Same printing, other finish. 3. Same card, other printing.
        func pair(_ match: (Key, String) -> Bool) {
            for k in inc.keys.sorted() {
                let order = cur.keys.sorted { a, b in
                    (a.board, a.card, a.finish) != (b.board, b.card, b.finish)
                        ? (a.board, a.card, a.finish) < (b.board, b.card, b.finish) : lineBefore(a, b)
                }
                for m in order {
                    if inc[k]! <= 0 { break }
                    guard cur[m]! > 0, m.board == k.board, match(m, k.card) else { continue }
                    let n = min(inc[k]!, cur[m]!)
                    cur[m]! -= n
                    inc[k]! -= n
                    let toLang = changedLang(fromCard: m.card, fromLang: m.lang, toCard: k.card, plang)
                    final[Key(board: k.board, card: k.card, finish: k.finish, lang: toLang, cond: m.cond), default: 0] += n
                    changed[[k.board, m.card, m.finish, m.lang, k.card, k.finish, toLang], default: 0] += n
                }
            }
        }
        pair { m, c in m.card == c }
        pair { m, c in oracle(m.card) == oracle(c) }

        var into: [Key: Int] = [:]
        for (k, n) in inc where n > 0 {
            let key = Key(board: k.board, card: k.card, finish: k.finish, lang: plang(k.card), cond: "NM")
            into[key, default: 0] += n
            final[key, default: 0] += n
        }
        let line = { (k: Key, n: Int) in Line(board: k.board, cardId: k.card, finish: k.finish, lang: k.lang, cond: k.cond, qty: n) }
        r.into = into.keys.sorted().map { line($0, into[$0]!) }
        r.out = cur.filter { $0.value > 0 }.keys.sorted().map { line($0, cur[$0]!) }
        r.changed = changed.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { k in
            Changed(board: k[0], fromCard: k[1], fromFinish: k[2], fromLang: k[3], toCard: k[4], toFinish: k[5], toLang: k[6], qty: changed[k]!)
        }
        r.entries = final.filter { $0.value > 0 }.keys.sorted().map {
            CardList.Entry(cardId: $0.card, board: $0.board, qty: final[$0]!, finish: $0.finish, lang: $0.lang, cond: $0.cond)
        }
        return r
    }

    /// The new printing's own language when it isn't English; else the old line's when it wasn't its printing's own;
    /// else English.
    static func changedLang(fromCard: String, fromLang: String, toCard: String, _ plang: (String) -> String) -> String {
        let to = plang(toCard)
        if to != "en" { return to }
        if fromLang != plang(fromCard) { return fromLang }
        return "en"
    }

    /// The Cube Cobra id in a link ("cubecobra.com/cube/list/<id>", "/c/<id>"), for the row's detail.
    static func cubeId(_ link: String?) -> String? {
        guard let link, let u = URL(string: link), u.host()?.hasSuffix("cubecobra.com") == true else { return nil }
        let parts = u.path().split(separator: "/").map(String.init)
        if parts.first == "c", parts.count > 1 { return parts[1] }
        if parts.first == "cube" { return parts.count >= 3 ? parts[2] : parts.count == 2 ? parts[1] : nil }
        return nil
    }
}
