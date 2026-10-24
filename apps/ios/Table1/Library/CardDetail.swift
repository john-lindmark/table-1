import Foundation

/* Card detail's rules (contract/card-detail-2026-10-23.md): the screen is opened in a scope (the collection, a deck
   or cube, a binder, or search), shows that scope's versions of the card, and a pick in the attribute row changes the
   copies in view. Kept apart from the views so the tests (and testdata/card-detail/cases.json) can reach it. */

/// One thing the scope counts: owned copies are printing × finish × condition × language; a deck or cube line is
/// printing × section × finish (its condition and language are unused).
struct CardVersion: Hashable, Identifiable, Sendable {
    var cardId: String
    var finish: String
    var condition = "NM"
    var lang = "en"
    /// List scope: the line's section.
    var board: String?
    var qty = 0

    var id: String { board.map { "\(cardId)|\($0)|\(finish)" } ?? itemKey }
    var itemKey: String { CollectionStore.key(cardId, finish, condition, lang) }

    init(cardId: String, finish: String, condition: String = "NM", lang: String = "en", board: String? = nil, qty: Int = 0) {
        self.cardId = cardId
        self.finish = finish
        self.condition = condition
        self.lang = lang
        self.board = board
        self.qty = qty
    }

    init(_ item: CollectionItem, qty: Int? = nil) {
        self.init(cardId: item.cardId, finish: item.finish, condition: item.condition, lang: item.lang, qty: qty ?? item.qty)
    }

    init(_ entry: CardList.Entry) {
        self.init(cardId: entry.cardId, finish: entry.finish, board: entry.board, qty: entry.qty)
    }
}

enum CardAttribute: String, CaseIterable, Sendable {
    case set, language, condition, finish, section
}

enum CardDetailRules {
    /// The value every version shares, nil when they differ (shown as MIX). Empty → nil.
    static func shared<T: Equatable>(_ versions: [CardVersion], _ value: (CardVersion) -> T) -> T? {
        guard let first = versions.first.map(value) else { return nil }
        return versions.allSatisfy { value($0) == first } ? first : nil
    }

    /// The version the stepper and the bar's price act on when none is selected: the one held most of, the first
    /// listed on a tie.
    static func main(_ versions: [CardVersion]) -> CardVersion? {
        versions.reduce(nil) { best, v in best.map { v.qty > $0.qty ? v : $0 } ?? v }
    }

    /// Versions in the order the grid shows them: printings earliest first, then finish, section, condition, language.
    static func ordered(_ versions: [CardVersion], printings: [CatalogPrinting]) -> [CardVersion] {
        let rank = Dictionary(printings.sorted(by: CatalogPrinting.oldestFirst).enumerated().map { ($1.cardId, $0) },
                              uniquingKeysWith: { a, _ in a })
        let finishes = Finish.allCases.map(\.rawValue), boards = CardList.boardOrder, conditions = Conditions.all
        func key(_ v: CardVersion) -> [Int] {
            [rank[v.cardId] ?? Int.max, finishes.firstIndex(of: v.finish) ?? 9, v.board.flatMap { boards.firstIndex(of: $0) } ?? 0,
             conditions.firstIndex(of: v.condition) ?? 9]
        }
        return versions.filter { $0.qty > 0 }.sorted { a, b in key(a) != key(b) ? key(a).lexicographicallyPrecedes(key(b)) : a.lang < b.lang }
    }

    /// The version a pick turns `v` into. Set: the new printing, in the same finish if it has it (else its first), in
    /// its own language when it isn't English (else the copy keeps its language). The others change just that field.
    static func repoint(_ v: CardVersion, _ attribute: CardAttribute, to value: String, printing: CatalogPrinting?) -> CardVersion {
        var out = v
        switch attribute {
        case .set:
            guard let p = printing else { return v }
            out.cardId = p.cardId
            let finishes = p.finishList.map(\.rawValue)
            if !finishes.contains(v.finish), let f = finishes.first { out.finish = f }
            if p.lang != "en" { out.lang = p.lang }
        case .language: out.lang = value
        case .condition: out.condition = value
        case .finish: out.finish = value
        case .section: out.board = value
        }
        return out
    }

    /// The version a new copy starts as: the card's original printing (else the earliest), its first finish, and the
    /// condition and language picked for adds.
    static func fresh(_ printings: [CatalogPrinting], condition: String, lang: String, board: String? = nil) -> CardVersion? {
        guard let p = printings.first(where: \.original) ?? printings.sorted(by: CatalogPrinting.oldestFirst).first else { return nil }
        return CardVersion(cardId: p.cardId, finish: p.finishList.first?.rawValue ?? Finish.nonfoil.rawValue, condition: condition,
                           lang: Languages.forNew(p, picked: lang), board: board)
    }

    /// Moves `qty` of an item's copies to another version, each copy staying where it is: from `from` only when given
    /// (a binder id or `BinderRoute.unsorted`), else Unsorted first, then the binders in the order given. Nil when
    /// nothing would change or there aren't that many copies in those places.
    static func ops(_ item: CollectionItem, places: [(place: String, qty: Int)], to: CardVersion, qty: Int,
                    from: String? = nil) -> [CollectionOp]? {
        guard qty > 0, qty <= item.qty, to.itemKey != item.key else { return nil }
        let order = from.map { f in places.filter { $0.place == f } }
            ?? (places.filter { $0.place == BinderRoute.unsorted } + places.filter { $0.place != BinderRoute.unsorted })
        var left = qty
        var out: [CollectionOp] = []
        for p in order where left > 0 {
            let n = min(left, p.qty)
            guard n > 0 else { continue }
            let binderId = p.place == BinderRoute.unsorted ? nil : p.place
            out.append(CollectionOp(cardId: item.cardId, finish: item.finish, condition: item.condition, lang: item.lang, delta: -n, binderId: binderId))
            out.append(CollectionOp(cardId: to.cardId, finish: to.finish, condition: to.condition, lang: to.lang, delta: n, binderId: binderId))
            left -= n
        }
        return left == 0 ? out : nil
    }

    /// One copy more or less of a version, into or out of a binder (nil: the collection's own rule, Unsorted first).
    static func step(_ v: CardVersion, delta: Int, binderId: String?) -> CollectionOp {
        CollectionOp(cardId: v.cardId, finish: v.finish, condition: v.condition, lang: v.lang, delta: delta,
                     binderId: binderId == BinderRoute.unsorted ? nil : binderId)
    }

    /// Whether the Finish cell shows: some printing in view comes in more than one finish, or the versions differ.
    static func showsFinish(_ versions: [CardVersion], printings: [String: CatalogPrinting]) -> Bool {
        if shared(versions, \.finish) == nil { return true }
        return versions.contains { (printings[$0.cardId]?.finishList.count ?? 1) > 1 }
    }
}
