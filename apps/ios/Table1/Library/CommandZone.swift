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

        /// The empty slot's row.
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

    /// What a command-zone line is called on the deck screen.
    static func role(format: String, typeLine: String) -> String {
        format == "oathbreaker" ? (Role.oathbreaker.fits(typeLine) ? "Oathbreaker" : "Signature spell") : "Commander"
    }
}

/// Search for a card that fits one command-zone slot: the catalog by name (or Scryfall syntax), filtered to cards that
/// can fill it. A tap picks the card in its original paper printing.
struct CommandZonePicker: View {
    let role: CommandZone.Role
    let picked: (CatalogOracle, CatalogPrinting) -> Void
    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var query: String

    init(role: CommandZone.Role, start: String = "", picked: @escaping (CatalogOracle, CatalogPrinting) -> Void) {
        self.role = role
        self.picked = picked
        _query = State(initialValue: start)
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

/// One slot as a row: the card (tap for Change / Remove) or the empty slot (tap to choose).
struct CommandZoneRow: View {
    let slot: CommandZone.Slot
    let printing: CatalogPrinting?
    let name: String?
    let choose: () -> Void
    var remove: (() -> Void)?
    var open: (() -> Void)?

    var body: some View {
        if slot.cardId != nil {
            Button {
                var items = [T1MenuItem(title: "Change \(slot.role.title.lowercased())", action: choose)]
                if let open { items.insert(T1MenuItem(title: "Open card", action: open), at: 0) }
                if let remove { items.append(T1MenuItem(title: "Remove", destructive: true, action: remove)) }
                T1Overlays.shared.showMenu(name, items)
            } label: {
                CardRow(printing: printing, title: name ?? "…", detail: slot.role.title) { LabelText("Change", color: T1.text) }
            }.buttonStyle(.plain)
        } else {
            Button(action: choose) {
                ListRow(title: slot.role.choose, detail: slot.role.hint) { LabelText("Choose", color: T1.text) }
            }.buttonStyle(.plain)
        }
    }
}
