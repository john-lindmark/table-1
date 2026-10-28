import SwiftUI

/* Group by (the View menu on every card list: your decks, cubes, binders and All cards, and anything shared with you
   on a profile). One rule everywhere, tested against testdata/card-grouping/cases.json:
   - Type: Creatures, Planeswalkers, Instants, Sorceries, Artifacts, Enchantments, Battles, Lands, Other (the front
     face's type line; a land creature is a creature).
   - Color: White, Blue, Black, Red, Green, Multicolor, Colorless, then Lands (from the card's colors; packs without
     colors fall back to the mana cost's symbols).
   - Color identity: each exact combination, mono first (White … Green), then the ten pairs, the ten three-color
     combinations, the five four-color ones, Five-color, then Colorless. From the pack's identity field; lands group by
     their identity like any card. Packs without it fall back to the card's colors and mana cost.
   - Mana value: 0 … 6, 7+, then Lands (lands have mana value 0 but read as their own pile).
   Decks start on Type, cubes on Color, collections and binders on None. */

enum CardGrouping: String, CaseIterable, Sendable {
    case none, type, color, identity, manaValue

    var title: String {
        switch self {
        case .none: "No groups"
        case .type: "Group by type"
        case .color: "Group by color"
        case .identity: "Group by color identity"
        case .manaValue: "Group by mana value"
        }
    }

    static let mvOrder = ["0", "1", "2", "3", "4", "5", "6", "7+", "Lands"]

    /// Every color identity in order, with its letters in WUBRG order.
    static let identities: [(key: String, letters: String)] = [
        ("White", "W"), ("Blue", "U"), ("Black", "B"), ("Red", "R"), ("Green", "G"),
        ("Azorius", "WU"), ("Dimir", "UB"), ("Rakdos", "BR"), ("Gruul", "RG"), ("Selesnya", "WG"),
        ("Orzhov", "WB"), ("Izzet", "UR"), ("Golgari", "BG"), ("Boros", "WR"), ("Simic", "UG"),
        ("Esper", "WUB"), ("Grixis", "UBR"), ("Jund", "BRG"), ("Naya", "WRG"), ("Bant", "WUG"),
        ("Abzan", "WBG"), ("Jeskai", "WUR"), ("Sultai", "UBG"), ("Mardu", "WBR"), ("Temur", "URG"),
        ("Not white", "UBRG"), ("Not blue", "WBRG"), ("Not black", "WURG"), ("Not red", "WUBG"), ("Not green", "WUBR"),
        ("Five-color", "WUBRG"), ("Colorless", ""),
    ]

    /// The identity group of a set of WUBRG letters (any order, other characters ignored).
    nonisolated static func identityGroup(_ letters: String) -> String {
        let s = String("WUBRG".filter { letters.contains($0) })
        return identities.first { $0.letters == s }?.key ?? "Colorless"
    }

    var order: [String] {
        switch self {
        case .none: []
        case .type: ListLine.typeOrder
        case .color: ListLine.colorOrder
        case .identity: Self.identities.map(\.key)
        case .manaValue: Self.mvOrder
        }
    }

    /// The group's heading: mana values read "Mana value 3", identities of two colors or more carry their letters
    /// ("Azorius · WU").
    func label(_ key: String) -> String {
        switch self {
        case .manaValue where key != "Lands": return "Mana value \(key)"
        case .identity:
            guard let letters = Self.identities.first(where: { $0.key == key })?.letters, letters.count > 1 else { return key }
            return "\(key) · \(letters)"
        default: return key
        }
    }

    /// Keys in this grouping's order (unknown ones last, by name).
    func sorted(_ keys: some Sequence<String>) -> [String] {
        let order = self.order
        return Array(Set(keys)).sorted {
            let a = order.firstIndex(of: $0) ?? 99, b = order.firstIndex(of: $1) ?? 99
            return a != b ? a < b : $0 < $1
        }
    }

    /// A deck's or cube's choices (they always group); collections and binders add None.
    static func options(list: Bool) -> [CardGrouping] { list ? [.type, .color, .identity, .manaValue] : allCases }
}

/// One card's group under each grouping, worked out once from its Oracle card.
struct GroupKeys: Hashable, Sendable {
    var type = "Other"
    var color = "Colorless"
    var identity = "Colorless"
    var manaValue = "0"
    /// The mana value itself, for Sort by mana value.
    var cmc: Double = 0

    init() {}

    /// `identity`: the pack's color identity letters; nil (older packs) falls back to the colors and mana cost.
    init(typeLine: String, manaCost: String, colors: String, identity: String? = nil, cmc: Double) {
        let front = typeLine.components(separatedBy: " // ").first ?? typeLine
        type = ListLine.typeGroup(front)
        self.cmc = cmc
        self.identity = CardGrouping.identityGroup(identity ?? colors + manaCost)
        let land = front.contains("Land") && !front.contains("Creature")
        if land {
            color = "Lands"
            manaValue = "Lands"
        } else {
            let letters = colors.isEmpty ? manaCost : colors
            color = ListLine.colorGroup(letters)
            let mv = Int(cmc.rounded(.down))
            manaValue = mv >= 7 ? "7+" : String(max(0, mv))
        }
    }

    init(_ o: CatalogOracle?) {
        guard let o else { self.init(); return }
        self.init(typeLine: o.typeLine, manaCost: o.manaCost, colors: o.colors, identity: o.identity, cmc: o.cmc)
    }

    subscript(_ g: CardGrouping) -> String {
        switch g {
        case .none: ""
        case .type: type
        case .color: color
        case .identity: identity
        case .manaValue: manaValue
        }
    }
}

extension CardGroup {
    /// Each card's group keys, by card group id, from the cards' cover printings.
    nonisolated static func keys(_ groups: [CardGroup], _ db: CatalogDB) -> [String: GroupKeys] {
        let oracles = db.oracles(idxs: Array(Set(groups.compactMap { $0.cover?.oracleIdx })))
        var out: [String: GroupKeys] = [:]
        for g in groups { out[g.id] = GroupKeys(g.cover.flatMap { oracles[$0.oracleIdx] }) }
        return out
    }

    /// The groups in sections under `by`: one untitled section for None.
    static func sections(_ groups: [CardGroup], by: CardGrouping, keys: [String: GroupKeys]) -> [(key: String, cards: [CardGroup])] {
        guard by != .none else { return [("", groups)] }
        let byKey = Dictionary(grouping: groups) { keys[$0.id]?[by] ?? "Other" }
        return by.sorted(byKey.keys).map { ($0, byKey[$0]!) }
    }
}

extension CardLayout {
    /// The View menu with Group by and Sort: the layouts, Expand all printings, the groupings, then the sorts, the
    /// current ones checked.
    @MainActor static func menu(_ current: Binding<String>, screen: String, printings: Binding<PrintingsDisclosure>? = nil,
                                grouping: Binding<String>, list: Bool, sort: Binding<String>, sorts: CardSort.Screen) {
        menu(current, screen: screen, printings: printings, extra: CardGrouping.options(list: list).map { g in
            T1MenuItem(title: g.title, checked: grouping.wrappedValue == g.rawValue) {
                guard grouping.wrappedValue != g.rawValue else { return }
                grouping.wrappedValue = g.rawValue
                Telemetry.capture("card_grouping_changed", ["grouping": g.rawValue, "screen": screen])
            }
        } + CardSort.menuItems(sort, sorts, screen: screen))
    }
}

/// The grid in sections (Group by): each group's heading, then its cards three across.
struct SectionedCardGrid<Cell: View>: View {
    let sections: [(key: String, title: String?, items: [StackCard])]
    @ViewBuilder let cell: (StackCard, CGFloat) -> Cell

    var body: some View {
        GeometryReader { geo in
            let width = ((geo.size.width - 2) / 3).rounded(.down)
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(sections, id: \.key) { s in
                        if let title = s.title { Section1(title).id("h|\(s.key)") }
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 1), count: 3), spacing: 1) {
                            ForEach(s.items) { cell($0, width) }
                        }
                        .id("g|\(s.key)")
                    }
                }
            }
        }
    }
}
