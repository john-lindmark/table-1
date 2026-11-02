import SwiftUI
import Supabase

/* Collection Search finds decks, cubes and binders, Insights archetypes and rankings
   (contract/library-search-2026-10-18.md § Collection search). Your own lists are matched on the device by name
   (CardSearch.matches(_:list:format:)); everything else comes from library_search with p_all: other people's lists
   you can see, lists (yours too) holding a card the query names, archetypes and rankings. A section per kind above
   the cards. */

/// One of library_search's items.
struct ListHit: Decodable, Hashable, Sendable {
    struct Has: Decodable, Hashable, Sendable { let name: String; let qty: Int }
    let kind: String
    let id: String
    let name: String
    var format: String?
    var forTrade: Bool?
    var cards: Int?
    var owner: Follow.Owner?
    /// Seen on their profile: open it there.
    var userId: String?
    /// Seen through the link you followed with: open the link.
    var token: String?
    var following: Bool?
    /// Your own, found by a card it holds.
    var mine: Bool?
    /// Found by a card it holds, not its name.
    var has: Has?
    /// Archetypes: lists in the last 90 days.
    var decks: Int?
    /// Rankings: the cube's id or "set:<KEY>", and the name its maker gave it.
    var subject: String?
    var label: String?
}

enum ListSearch {
    /// How many of each kind show before "Show all N".
    static let shown = 3

    @MainActor
    static func search(_ query: String) async throws -> [ListHit] {
        #if DEBUG
        if let demo = FollowsStore.shared.demo {
            // The demo's followed items stand in for other people's lists, and one archetype from the demo pack.
            let lists = demo.list().filter { $0.available && CardSearch.matches(query, list: "\($0.name ?? "") \($0.owner?.displayName ?? "")", format: $0.format ?? "") }
                .map { ListHit(kind: $0.kind, id: $0.id, name: $0.name ?? "", format: $0.format, forTrade: $0.forTrade, cards: $0.cards,
                               owner: $0.owner, userId: $0.userId, token: $0.token, following: true) }
            let archetype = ListHit(kind: "archetype", id: "19", name: "Izzet Murktide", format: "modern", decks: 37)
            return CardSearch.matches(query, list: archetype.name, format: "modern") ? lists + [archetype] : lists
        }
        #endif
        struct Items: Decodable { let items: [ListHit] }
        let r: Items = try await supabase.rpc("library_search", params: [
            "p_query": AnyJSON.string(query.trimmingCharacters(in: .whitespaces)), "p_all": AnyJSON.bool(true),
        ]).execute().value
        return r.items
    }

    /// Where an item opens: your own screen, their profile section, the link it was followed through, an Insights
    /// archetype or a ranking.
    static func route(_ h: ListHit) -> LibraryRoute? {
        switch h.kind {
        case "archetype":
            guard let format = h.format, let id = Int(h.id) else { return nil }
            return .insights(.archetype(format, id))
        case "ranking":
            return .ranking(h.id)
        default:
            if h.mine == true { return h.kind == "binder" ? .binder(h.id) : .list(h.id) }
            if let token = h.token { return .social(.sharedLink(token)) }
            guard let userId = h.userId else { return nil }
            return .social(.profileCards(userId, h.kind, h.id, h.name,
                                         h.kind == "binder" ? nil : SharedList(format: h.format ?? "", owner: h.owner?.displayName)))
        }
    }
}

/// The Decks, Cubes, Binders, Archetypes and Rankings sections of Collection Search, then a Cards heading when any showed.
struct ListHitsSections: View {
    let query: String
    @Binding var path: [LibraryRoute]
    @State private var others: (query: String, items: [ListHit])?
    @State private var open: Set<String> = []

    private struct Hit: Identifiable {
        let id: String
        let title: String
        let detail: String
        let value: Int?
        let route: LibraryRoute
        let whose: String
        let by: String
    }

    private static let kinds: [(kind: String, title: String)] = [
        ("deck", "Decks"), ("cube", "Cubes"), ("binder", "Binders"), ("archetype", "Archetypes"), ("ranking", "Rankings"),
    ]

    var body: some View {
        let sections = self.sections
        ForEach(sections, id: \.kind) { s in
            let all = open.contains(s.kind) || s.hits.count <= ListSearch.shown + 1
            Section1("\(s.title) · \(s.hits.count)")
            ForEach(all ? s.hits : Array(s.hits.prefix(ListSearch.shown))) { h in
                Button {
                    Telemetry.capture("search_list_opened", ["kind": s.kind, "whose": h.whose, "by": h.by])
                    path.append(h.route)
                } label: {
                    ListRow(title: h.title, detail: h.detail) {
                        if let v = h.value { Text(v.formatted()).font(T1.mono(17)).monospacedDigit() }
                    }
                }.buttonStyle(.plain)
            }
            if !all {
                Button { open.insert(s.kind) } label: { ListRow(title: "Show all \(s.hits.count)") }.buttonStyle(.plain)
            }
        }
        if !sections.isEmpty { Section1("Cards") }
        Color.clear.frame(height: 0)
            .task(id: query) {
                open = []
                guard CardName.norm(query).count >= 2 else { return }
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
                // Offline or refused: yours still show.
                let items = (try? await ListSearch.search(query)) ?? []
                if !Task.isCancelled { others = (query, items) }
            }
    }

    private var sections: [(kind: String, title: String, hits: [Hit])] {
        guard CardName.norm(query).count >= 2 else { return [] }
        let totals = BindersStore.shared.totals(CollectionStore.shared.items).byBinder
        let found = others?.query == query ? others?.items ?? [] : []
        return Self.kinds.compactMap { k in
            var hits: [Hit] = []
            if k.kind == "binder" {
                let mine = BindersStore.shared.binders.filter { CardSearch.matches(query, list: $0.name, format: "") }
                hits = CardSearch.order(query, mine) { $0.name }.map { b in
                    Hit(id: b.id, title: b.name, detail: CardSearch.hitDetail(.init(kind: "binder", forTrade: b.forTrade)),
                        value: totals[b.id], route: .binder(b.id), whose: "mine", by: "name")
                }
            } else if k.kind == "deck" || k.kind == "cube" {
                let mine = ListsStore.shared.lists(k.kind == "deck" ? .deck : .cube).filter { CardSearch.matches(query, list: $0.name, format: $0.format) }
                hits = CardSearch.order(query, mine) { $0.name }.map { l in
                    Hit(id: l.id, title: l.name, detail: CardSearch.hitDetail(.init(kind: k.kind, format: l.format)),
                        value: l.count("main"), route: .list(l.id), whose: "mine", by: "name")
                }
            }
            let seen = Set(hits.map(\.id))
            hits += found.filter { $0.kind == k.kind && !seen.contains($0.id) }.compactMap { h in
                guard let r = ListSearch.route(h) else { return nil }
                let line = CardSearch.HitLine(kind: h.kind, format: h.format, forTrade: h.forTrade,
                                              owner: h.mine == true ? nil : h.owner?.displayName, has: h.has, decks: h.decks, label: h.label)
                return Hit(id: "\(h.kind)|\(h.id)", title: h.name, detail: CardSearch.hitDetail(line),
                           value: h.kind == "archetype" || h.kind == "ranking" ? nil : h.cards, route: r,
                           whose: h.mine == true ? "mine" : h.following == true ? "following" : "shared", by: h.has == nil ? "name" : "card")
            }
            return hits.isEmpty ? nil : (k.kind, k.title, hits)
        }
    }
}
