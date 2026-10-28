import SwiftUI

/* The command zone of a Commander or Oathbreaker deck (contract/command-zone-2026-10-27.md): its cards live in the
   deck's "commander" section. Commander decks name a commander and may add a partner or background; Oathbreaker decks
   name an oathbreaker (a planeswalker) and its signature spell (an instant or sorcery). Picked when the deck is made
   and changed from the deck screen. Cases shared with web and Android in testdata/command-zone/cases.json. */

enum CommandZone {
    static let board = "commander"
    static let formats: Set<String> = ["commander", "oathbreaker"]

    enum Role: String, Sendable {
        case commander, partner, oathbreaker, signature

        var title: String {
            switch self {
            case .commander: "Commander"
            case .partner: "Partner or background"
            case .oathbreaker: "Oathbreaker"
            case .signature: "Signature spell"
            }
        }

        /// The slot's label above its card, short enough for half a phone's width.
        var label: String {
            switch self {
            case .partner: "Partner"
            default: title
            }
        }

        /// The empty slot's card.
        var choose: String {
            switch self {
            case .commander: "Choose a commander"
            case .partner: "Add a partner or background"
            case .oathbreaker: "Choose an oathbreaker"
            case .signature: "Choose a signature spell"
            }
        }

        var hint: String {
            switch self {
            case .commander: "A legendary creature"
            case .partner: "Optional: a second commander"
            case .oathbreaker: "A planeswalker"
            case .signature: "An instant or sorcery"
            }
        }

        /// Whether a card of this type line can fill the slot. Lenient: the deck's legality check has the last word.
        func fits(_ typeLine: String) -> Bool {
            let front = typeLine.components(separatedBy: " // ").first ?? typeLine
            switch self {
            case .commander, .partner:
                return front.contains("Background") || (front.contains("Legendary") && (front.contains("Creature") || front.contains("Planeswalker")))
            case .oathbreaker: return front.contains("Planeswalker")
            case .signature: return front.contains("Instant") || front.contains("Sorcery")
            }
        }
    }

    struct Slot: Hashable, Sendable {
        let role: Role
        /// The line filling it, nil when empty.
        var cardId: String?
        var finish = "nonfoil"
        var lang = "en"
    }

    /// A command-zone line: its card and type line.
    struct Line: Hashable, Sendable {
        let cardId: String
        let typeLine: String
        var finish = "nonfoil"
        var lang = "en"
    }

    /// The slots a deck of this format shows, filled from its command-zone lines in order. Commander: one slot per
    /// commander line (at most two), then an empty one while there are fewer than two. Oathbreaker: the first
    /// planeswalker is the oathbreaker, the first instant or sorcery the signature spell. Other formats: none.
    static func slots(format: String, lines: [Line]) -> [Slot] {
        switch format {
        case "commander":
            var out = lines.prefix(2).enumerated().map { i, l in
                Slot(role: i == 0 ? .commander : .partner, cardId: l.cardId, finish: l.finish, lang: l.lang)
            }
            if out.count < 2 { out.append(Slot(role: out.isEmpty ? .commander : .partner)) }
            return out
        case "oathbreaker":
            return [Role.oathbreaker, .signature].map { role in
                guard let l = lines.first(where: { role.fits($0.typeLine) }) else { return Slot(role: role) }
                return Slot(role: role, cardId: l.cardId, finish: l.finish, lang: l.lang)
            }
        default:
            return []
        }
    }

    /// The lines after filling a slot: its card replaced in place, or the new card added after the others.
    static func filling(_ lines: [Line], slot: Slot, with new: Line) -> [Line] {
        var out = lines.filter { $0.cardId != new.cardId || $0.cardId == slot.cardId }
        if let id = slot.cardId, let i = out.firstIndex(where: { $0.cardId == id }) { out[i] = new } else { out.append(new) }
        return out
    }

    /// A deck line outside the command zone that could be moved in.
    struct DeckLine: Hashable, Sendable {
        let cardId: String
        let board: String
        let typeLine: String
        var finish = "nonfoil"
        var lang = "en"
        var qty = 1
    }

    /// The deck's own cards a slot's picker offers first: main deck, then sideboard, those that fit. A deck made before
    /// the command zone has its commander in the main deck.
    static func inDeck(_ role: Role, _ lines: [DeckLine]) -> [DeckLine] {
        ["main", "side"].flatMap { b in lines.filter { $0.board == b && role.fits($0.typeLine) } }
    }

    /// A list_edit change that moves a deck card into a slot.
    enum Op: Equatable, Sendable {
        /// Every copy of a line to another section.
        case move(cardId: String, finish: String, lang: String, from: String, to: String)
        case delta(cardId: String, finish: String, lang: String, board: String, by: Int)
    }

    /// The changes that put one copy of `line` in `slot`: the slot's card (if any) goes to the main deck; a single copy
    /// moves, one of several moves by deltas.
    static func movingIn(_ line: DeckLine, slot: Slot) -> [Op] {
        var ops: [Op] = []
        if let id = slot.cardId { ops.append(.move(cardId: id, finish: slot.finish, lang: slot.lang, from: board, to: "main")) }
        if line.qty <= 1 {
            ops.append(.move(cardId: line.cardId, finish: line.finish, lang: line.lang, from: line.board, to: board))
        } else {
            ops.append(.delta(cardId: line.cardId, finish: line.finish, lang: line.lang, board: line.board, by: -1))
            ops.append(.delta(cardId: line.cardId, finish: line.finish, lang: line.lang, board: board, by: 1))
        }
        return ops
    }

    /// What a command-zone line is called on the deck screen.
    static func role(format: String, typeLine: String) -> String {
        format == "oathbreaker" ? (Role.oathbreaker.fits(typeLine) ? "Oathbreaker" : "Signature spell") : "Commander"
    }
}

/// Search for a card that fits one command-zone slot: the catalog by name (or Scryfall syntax), filtered to cards that
/// can fill it. A tap picks the card in its original paper printing. On a deck screen, the deck's own cards that fit come
/// first (a deck made before the command zone has its commander in the main deck): a tap moves that copy in.
struct CommandZonePicker: View {
    /// A card already in the deck, outside the command zone, with its name and art.
    struct DeckCard: Hashable {
        let line: CommandZone.DeckLine
        let name: String
        let printing: CatalogPrinting?
    }

    let role: CommandZone.Role
    var deck: [DeckCard] = []
    var pickedInDeck: ((DeckCard) -> Void)? = nil
    let picked: (CatalogOracle, CatalogPrinting) -> Void
    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var query: String

    init(role: CommandZone.Role, start: String = "", deck: [DeckCard] = [], pickedInDeck: ((DeckCard) -> Void)? = nil,
         picked: @escaping (CatalogOracle, CatalogPrinting) -> Void) {
        self.role = role
        self.deck = deck
        self.pickedInDeck = pickedInDeck
        self.picked = picked
        _query = State(initialValue: start)
    }

    private var fromDeck: [DeckCard] {
        let fit = Set(CommandZone.inDeck(role, deck.map(\.line)))
        return deck.filter { fit.contains($0.line) && (query.isEmpty || CardSearch.matches(query, name: $0.name, type: $0.line.typeLine)) }
    }
    @State private var hits: [CatalogOracle] = []
    @State private var covers: [Int: CatalogPrinting] = [:]
    @FocusState private var focused: Bool

    var body: some View {
        T1Screen {
            Bar(title: role.title, subtitle: role.hint) { BarButton("Cancel") { T1Overlays.shared.dismissPanel() } }
            CatalogStatusRow(catalog: catalog)
            CardSearchBar(query: $query, prompt: role == .signature ? "An instant or sorcery" : role == .oathbreaker ? "A planeswalker" : "A legendary creature",
                          focused: $focused) { if let o = hits.first, let p = covers[o.idx] { pick(o, p) } }
            HairlineList {
                if let pickedInDeck, !fromDeck.isEmpty {
                    Section1("In this deck")
                    ForEach(fromDeck, id: \.self) { c in
                        Button {
                            T1Overlays.shared.dismissPanel()
                            pickedInDeck(c)
                        } label: {
                            CardRow(printing: c.printing, title: c.name, detail: c.line.typeLine) { LabelText("Move in", color: T1.text) }
                        }.buttonStyle(.plain)
                    }
                    if !hits.isEmpty { Section1("All cards") }
                }
                if catalog.phase == .ready && CardName.norm(query).count >= 2 && hits.isEmpty {
                    ListRow(title: "No \(role.title.lowercased()) by that name")
                }
                ForEach(hits, id: \.idx) { o in
                    Button { if let p = covers[o.idx] { pick(o, p) } } label: {
                        CardRow(printing: covers[o.idx], title: o.name, detail: o.manaCost.isEmpty ? o.typeLine : "\(o.typeLine) · \(o.manaCost)") { EmptyView() }
                    }.buttonStyle(.plain)
                }
            }
        }
        .onAppear { catalog.load(userInitiated: true); focused = true }
        .task(id: "\(query)-\(catalog.generation)") {
            guard let db = catalog.db else { hits = []; return }
            let q = query, role = role
            try? await Task.sleep(for: CardSearchEngine.debounce(q))
            if Task.isCancelled { return }
            let found = await Task.detached(priority: .userInitiated) { await CardSearchEngine.run(q, db) }.value
            if !Task.isCancelled {
                hits = found.hits.filter { role.fits($0.typeLine) }
                covers = found.covers
            }
        }
    }

    private func pick(_ o: CatalogOracle, _ p: CatalogPrinting) {
        T1Overlays.shared.dismissPanel()
        picked(o, p)
    }
}

/// The command zone as cards side by side: commander | partner or background, oathbreaker | signature spell. The
/// content gets each card's width.
struct CommandZoneCards<Content: View>: View {
    @ViewBuilder let content: (CGFloat) -> Content
    @State private var width: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: 16) { content(min(220, max(0, (width - 48) / 2))) }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T1.bg)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// One slot as a card: tap a filled one for Open card / Change / Remove, an empty one to choose.
struct CommandZoneCard: View {
    let slot: CommandZone.Slot
    let printing: CatalogPrinting?
    let name: String?
    let width: CGFloat
    let choose: () -> Void
    var remove: (() -> Void)?
    var open: (() -> Void)?

    var body: some View {
        Button {
            guard slot.cardId != nil else { return choose() }
            var items = [T1MenuItem(title: "Change \(slot.role.title.lowercased())", action: choose)]
            if let open { items.insert(T1MenuItem(title: "Open card", action: open), at: 0) }
            if let remove { items.append(T1MenuItem(title: "Remove", destructive: true, action: remove)) }
            T1Overlays.shared.showMenu(name, items)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                LabelText(slot.role.label)
                if slot.cardId != nil, let printing {
                    printing.art(width: width, finish: slot.finish)
                } else {
                    RoundedRectangle(cornerRadius: width * 0.0432).fill(T1.surface).frame(width: width, height: width / CardArt.aspect)
                        .overlay {
                            VStack(spacing: 8) {
                                if slot.cardId == nil { Text("+").font(T1.mono(28)).foregroundStyle(T1.text) }
                                Text(slot.cardId == nil ? slot.role.choose : name ?? "…").font(T1.mono(13)).foregroundStyle(T1.text)
                                if slot.cardId == nil { Text(slot.role.hint).font(T1.mono(11)).foregroundStyle(T1.muted) }
                            }
                            .multilineTextAlignment(.center).padding(12)
                        }
                }
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(slot.cardId == nil ? slot.role.choose : "\(slot.role.title): \(name ?? "")")
    }
}
