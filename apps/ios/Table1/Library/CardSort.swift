import SwiftUI

/* Sort (the View menu on every card list, after Group by; contract/card-sort-2026-10-25.md). One rule everywhere,
   tested against testdata/card-sort/cases.json:
   - Name: A–Z, ignoring case.
   - Mana value: spells low to high, then lands (Group by's Lands), then by name.
   - Set: newest set first, then set code, then collector number (digits as a number, then the text), then name; a
     card newer than the local card data goes last.
   Screens that had their own order keep it first: All cards' Recent and Price, binders' Most copies. Group by makes
   the sections; Sort orders the cards inside each. */

enum CardSort: String, CaseIterable, Sendable {
    case recent, price, count, name, manaValue, set

    var title: String {
        switch self {
        case .recent: "Most recent first"
        case .price: "Highest price first"
        case .count: "Most copies first"
        case .name: "Sort by name"
        case .manaValue: "Sort by mana value"
        case .set: "Sort by set"
        }
    }

    /// The screen family's choices, its own order first (that's also where it starts).
    enum Screen { case list, shared, binder, allCards }

    static func options(_ s: Screen) -> [CardSort] {
        switch s {
        case .list, .shared: [.name, .manaValue, .set]
        case .binder: [.count, .name, .manaValue, .set]
        case .allCards: [.recent, .price, .name, .manaValue, .set]
        }
    }

    /// Whether this rule orders the cards (name, mana value, set); the others are the screen's own.
    var shared: Bool { self == .name || self == .manaValue || self == .set }
}

/// What a card sorts on: its name, its mana value (and whether it's a land) and the printing shown.
struct SortKey: Hashable, Sendable {
    var name: String
    var cmc: Double = 0
    var land = false
    var released = ""
    var set = ""
    var cn = ""

    init(name: String, cmc: Double = 0, land: Bool = false, released: String = "", set: String = "", cn: String = "") {
        self.name = name.lowercased()
        self.cmc = cmc
        self.land = land
        self.released = released
        self.set = set
        self.cn = cn
    }

    init(name: String, keys: GroupKeys?, printing: CatalogPrinting?) {
        self.init(name: name, cmc: keys?.cmc ?? 0, land: keys?.manaValue == "Lands",
                  released: printing?.releasedAt ?? "", set: printing?.set ?? "", cn: printing?.cn ?? "")
    }

    private var number: Int { Int(cn.filter(\.isNumber)) ?? .max }

    /// Whether `a` goes before `b` under `by` (name, mana value or set; any other sort reads as name).
    static func before(_ a: SortKey, _ b: SortKey, by: CardSort) -> Bool {
        switch by {
        case .manaValue:
            if a.land != b.land { return !a.land }
            if a.cmc != b.cmc { return a.cmc < b.cmc }
        case .set:
            if a.set.isEmpty != b.set.isEmpty { return !a.set.isEmpty }
            if a.released != b.released { return a.released > b.released }
            if a.set != b.set { return a.set < b.set }
            if a.number != b.number { return a.number < b.number }
            if a.cn != b.cn { return a.cn < b.cn }
        default: break
        }
        return a.name < b.name
    }
}

extension CardSort {
    /// `items` in this sort, each item's key worked out once. Recent, price and count leave the order as it is.
    func apply<T>(_ items: [T], key: (T) -> SortKey) -> [T] {
        guard shared else { return items }
        return items.map { (key($0), $0) }.sorted { SortKey.before($0.0, $1.0, by: self) }.map(\.1)
    }

    /// The View menu's Sort items, the current one checked.
    @MainActor static func menuItems(_ current: Binding<String>, _ s: Screen, screen: String) -> [T1MenuItem] {
        options(s).map { o in
            T1MenuItem(title: o.title, checked: current.wrappedValue == o.rawValue) {
                guard current.wrappedValue != o.rawValue else { return }
                current.wrappedValue = o.rawValue
                Telemetry.capture("card_sort_changed", ["sort": o.rawValue, "screen": screen])
            }
        }
    }

    /// The saved sort, or the screen's first option when it's missing or not one of its own.
    static func of(_ raw: String, _ s: Screen) -> CardSort {
        let o = options(s)
        return CardSort(rawValue: raw).flatMap { o.contains($0) ? $0 : nil } ?? o[0]
    }
}
