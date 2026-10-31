import Foundation

/* Owning a card in any printing (contract/owned-by-card-2026-10-31.md): a deck or cube line is covered by copies of
   the same card in any printing, finish or language, the printing and finish it names first. Also card detail's Match
   collection. Cases in testdata/owned-by-card/cases.json (OwnedByCardTests). */

/// What the collection holds, per printing and finish and per card, built once for a screen.
struct Holdings: Sendable {
    /// "card_id|finish" → copies, over every condition and language.
    let byPrinting: [String: Int]
    /// Card (Oracle) key → copies in any printing, finish or language.
    let byCard: [String: Int]
    private let cardOf: [String: String]

    /// `owned` keyed "card_id|finish" or "card_id|finish|lang"; `cardOf` maps a printing to its card (a printing
    /// missing from it is its own card, as before the catalog loads).
    init(owned: [String: Int], cardOf: [String: String]) {
        var p: [String: Int] = [:], c: [String: Int] = [:]
        for (k, n) in owned {
            let parts = k.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let id = parts[0], finish = parts.count > 1 ? parts[1] : "nonfoil"
            p["\(id)|\(finish)", default: 0] += n
            c[cardOf[id] ?? id, default: 0] += n
        }
        byPrinting = p
        byCard = c
        self.cardOf = cardOf
    }

    func card(_ cardId: String) -> String { cardOf[cardId] ?? cardId }
    /// Copies of this printing's card in any printing.
    func owned(card cardId: String) -> Int { byCard[card(cardId)] ?? 0 }
    func owned(printing cardId: String, finish: String) -> Int { byPrinting["\(cardId)|\(finish)"] ?? 0 }

    /// The collection now, with every printing it holds or `listing` names mapped to its card.
    @MainActor
    static func current(listing: some Sequence<String> = [String]()) -> Holdings {
        let owned = ownedByPrinting()
        return Holdings(owned: owned, cardOf: cardKeys(owned: owned, listing: listing))
    }

    /// Each printing in `owned` (keyed "card_id|…") or `listing` mapped to its card.
    @MainActor
    static func cardKeys(owned: [String: Int], listing: some Sequence<String>) -> [String: String] {
        var ids = Set(owned.keys.map { String($0.split(separator: "|")[0]) })
        ids.formUnion(listing)
        return CatalogStore.shared.cardKeys(ids)
    }
}

enum OwnedByCard {
    /// One deck or cube line, in list order.
    struct Need: Hashable, Sendable {
        let cardId: String
        let board: String
        var finish = "nonfoil"
        let qty: Int
        var lang = "en"
    }

    /// Copies each line still needs. The printing and finish a line names cover it first, then the card's other
    /// copies cover what's left, lines in order; a copy covers one line. Considering and basics never need any and
    /// never use copies.
    static func shorts(_ lines: [Need], _ h: Holdings, basics: Set<String>) -> [Int] {
        let counted = lines.map { $0.board != "maybe" && !basics.contains($0.cardId) }
        var exact = h.byPrinting, spare = h.byCard
        var covered = Array(repeating: 0, count: lines.count)
        for (i, l) in lines.enumerated() where counted[i] {
            let k = "\(l.cardId)|\(l.finish)"
            let c = min(l.qty, exact[k] ?? 0)
            exact[k, default: 0] -= c
            spare[h.card(l.cardId), default: 0] -= c
            covered[i] = c
        }
        for (i, l) in lines.enumerated() where counted[i] {
            let o = h.card(l.cardId)
            let c = min(l.qty - covered[i], spare[o] ?? 0)
            spare[o, default: 0] -= c
            covered[i] += c
        }
        return lines.indices.map { counted[$0] ? lines[$0].qty - covered[$0] : 0 }
    }

    static func needs(_ list: CardList) -> [Need] {
        list.entries.map { Need(cardId: $0.cardId, board: $0.board, finish: $0.finish, qty: $0.qty, lang: $0.lang) }
    }

    /// Copies a list still needs (a roto deck's cards come from the cube, never from your collection).
    static func missing(_ list: CardList, _ h: Holdings, basics: Set<String>) -> Int {
        list.eventId != nil ? 0 : shorts(needs(list), h, basics: basics).reduce(0, +)
    }

    /// Wants → Missing: one line per card, the largest shortfall across lists (lists don't reserve copies), shown as
    /// the first short line of the list that needs most (the earliest list on a tie).
    static func lines(_ lists: [CardList], _ h: Holdings, basics: Set<String>) -> [MissingLine] {
        var need: [String: (short: Int, lists: [String], line: Need?)] = [:]
        for l in lists where l.eventId == nil {
            let ls = needs(l)
            var per: [String: Int] = [:], first: [String: Need] = [:], order: [String] = []
            for (e, s) in zip(ls, shorts(ls, h, basics: basics)) where e.board != "maybe" && !basics.contains(e.cardId) {
                let o = h.card(e.cardId)
                if per[o] == nil { order.append(o) }
                per[o, default: 0] += e.qty
                if s > 0, first[o] == nil { first[o] = e }
            }
            for o in order {
                let short = per[o]! - (h.byCard[o] ?? 0)
                guard short > 0 else { continue }
                var v = need[o] ?? (0, [], nil)
                if short > v.short { v.short = short; v.line = first[o] }
                v.lists.append(l.name)
                need[o] = v
            }
        }
        return need.compactMap { o, v in
            v.line.map { MissingLine(cardId: $0.cardId, finish: $0.finish, card: o, short: v.short, lists: v.lists.sorted()) }
        }
        .sorted { $0.short != $1.short ? $0.short > $1.short : $0.id < $1.id }
    }

    // MARK: Match collection (card detail)

    /// A version you own: printing × finish, every condition and language together.
    struct Version: Hashable, Sendable {
        let cardId: String
        let finish: String
        let owned: Int
    }

    struct Pick: Hashable, Sendable {
        let cardId: String
        let finish: String
        var qty: Int
        var key: String { "\(cardId)|\(finish)" }
    }

    /// A `list_edit` move op: `qty` copies of a line to another printing and/or finish, keeping its language.
    struct Move: Hashable, Sendable {
        let cardId: String
        let finish: String
        var lang = "en"
        let toCardId: String
        let toFinish: String
        let qty: Int
    }

    /// Versions the section already lists first, then the ones you hold most of, then by card id and finish, up to the
    /// section's copies.
    static func autoMatch(_ lines: [Need], _ versions: [Version]) -> [Pick] {
        var left = lines.reduce(0) { $0 + $1.qty }
        let listed = Set(lines.map { "\($0.cardId)|\($0.finish)" })
        let order = versions.sorted {
            let a = listed.contains("\($0.cardId)|\($0.finish)"), b = listed.contains("\($1.cardId)|\($1.finish)")
            if a != b { return a }
            if $0.owned != $1.owned { return $0.owned > $1.owned }
            return ($0.cardId, $0.finish) < ($1.cardId, $1.finish)
        }
        var picks: [Pick] = []
        for v in order {
            let n = min(v.owned, left)
            if n > 0 { picks.append(Pick(cardId: v.cardId, finish: v.finish, qty: n)); left -= n }
        }
        return picks
    }

    /// A tap on a version's tile: one more of it while you own more and copies are left to pick; otherwise back to none.
    static func tap(_ picks: [Pick], versions: [Version], total: Int, cardId: String, finish: String) -> [Pick] {
        let have = versions.first { $0.cardId == cardId && $0.finish == finish }?.owned ?? 0
        var out = picks
        let used = out.reduce(0) { $0 + $1.qty }
        guard let i = out.firstIndex(where: { $0.cardId == cardId && $0.finish == finish }) else {
            if used < total && have > 0 { out.append(Pick(cardId: cardId, finish: finish, qty: 1)) }
            return out
        }
        if out[i].qty < have && used < total { out[i].qty += 1 } else { out.remove(at: i) }
        return out
    }

    /// Move ops that give the section the picked printings; copies not picked stay as they are. Lines that already are
    /// a picked version keep those copies; the rest move in list order to the picks in pick order.
    static func matchOps(_ lines: [Need], _ picks: [Pick]) -> [Move] {
        var want: [String: Int] = [:]
        for p in picks { want[p.key, default: 0] += p.qty }
        var keep: [Int] = []
        for l in lines {
            let k = "\(l.cardId)|\(l.finish)"
            let c = min(l.qty, want[k] ?? 0)
            want[k, default: 0] -= c
            keep.append(c)
        }
        var targets = picks.map { ($0, want[$0.key] ?? 0) }
        var ops: [Move] = []
        for (l, c) in zip(lines, keep) {
            var movable = l.qty - c
            for t in targets.indices where movable > 0 {
                let n = min(movable, targets[t].1)
                guard n > 0 else { continue }
                ops.append(Move(cardId: l.cardId, finish: l.finish, lang: l.lang, toCardId: targets[t].0.cardId,
                                toFinish: targets[t].0.finish, qty: n))
                targets[t].1 -= n
                movable -= n
            }
        }
        return ops
    }
}
