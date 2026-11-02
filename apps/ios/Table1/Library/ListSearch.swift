import SwiftUI
import Supabase

/* Collection Search finds decks, cubes and binders (contract/library-search-2026-10-18.md § Collection search).
   Your own are matched on the device (CardSearch.matches(_:list:format:)); everyone else's you can see come from
   library_search: what you follow, friends', and anyone's set to Anyone. A section per kind above the cards. */

/// One of library_search's items: someone else's binder, deck or cube.
struct ListHit: Decodable, Hashable, Sendable {
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
}

enum ListSearch {
    /// How many of each kind show before "Show all N".
    static let shown = 3

    @MainActor
    static func search(_ query: String) async throws -> [ListHit] {
        #if DEBUG
        if let demo = FollowsStore.shared.demo {
            // The demo's followed items stand in for other people's.
            return demo.list().filter { $0.available && CardSearch.matches(query, list: "\($0.name ?? "") \($0.owner?.displayName ?? "")", format: $0.format ?? "") }
                .map { ListHit(kind: $0.kind, id: $0.id, name: $0.name ?? "", format: $0.format, forTrade: $0.forTrade, cards: $0.cards,
                               owner: $0.owner, userId: $0.userId, token: $0.token, following: true) }
        }
        #endif
        struct Items: Decodable { let items: [ListHit] }
        let r: Items = try await supabase.rpc("library_search", params: ["p_query": AnyJSON.string(query.trimmingCharacters(in: .whitespaces))])
            .execute().value
        return r.items
    }

    /// Where someone else's item opens: its profile section, or the link it was followed through.
    static func route(_ h: ListHit) -> SocialRoute? {
        if let token = h.token { return .sharedLink(token) }
        guard let userId = h.userId else { return nil }
        return .profileCards(userId, h.kind, h.id, h.name, h.kind == "binder" ? nil : SharedList(format: h.format ?? "", owner: h.owner?.displayName))
    }
}

/// The Decks, Cubes and Binders sections of Collection Search, then a Cards heading when any showed.
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
    }

    private static let kinds: [(kind: String, title: String, label: String)] = [("deck", "Decks", "Deck"), ("cube", "Cubes", "Cube"), ("binder", "Binders", "Binder")]

    var body: some View {
        let sections = self.sections
        ForEach(sections, id: \.kind) { s in
            let all = open.contains(s.kind) || s.hits.count <= ListSearch.shown + 1
            Section1("\(s.title) · \(s.hits.count)")
            ForEach(all ? s.hits : Array(s.hits.prefix(ListSearch.shown))) { h in
                Button {
                    Telemetry.capture("search_list_opened", ["kind": s.kind, "whose": h.whose])
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
        let theirs = others?.query == query ? others?.items ?? [] : []
        return Self.kinds.compactMap { k in
            var hits: [Hit]
            if k.kind == "binder" {
                let mine = BindersStore.shared.binders.filter { CardSearch.matches(query, list: $0.name, format: "") }
                hits = CardSearch.order(query, mine) { $0.name }.map { b in
                    Hit(id: b.id, title: b.name, detail: [k.label, b.forTrade ? "For trade" : nil].compactMap { $0 }.joined(separator: " · "),
                        value: totals[b.id], route: .binder(b.id), whose: "mine")
                }
            } else {
                let mine = ListsStore.shared.lists(k.kind == "deck" ? .deck : .cube).filter { CardSearch.matches(query, list: $0.name, format: $0.format) }
                hits = CardSearch.order(query, mine) { $0.name }.map { l in
                    Hit(id: l.id, title: l.name, detail: [k.label, k.kind == "deck" && !l.format.isEmpty ? formatName(l.format) : nil].compactMap { $0 }.joined(separator: " · "),
                        value: l.count("main"), route: .list(l.id), whose: "mine")
                }
            }
            hits += theirs.filter { $0.kind == k.kind }.compactMap { h in
                guard let r = ListSearch.route(h) else { return nil }
                let detail = [k.label, k.kind == "deck" ? h.format.flatMap { $0.isEmpty ? nil : formatName($0) } : nil,
                              k.kind == "binder" && h.forTrade == true ? "For trade" : nil, h.owner?.displayName]
                return Hit(id: "\(h.kind)|\(h.id)", title: h.name, detail: detail.compactMap { $0 }.joined(separator: " · "),
                           value: h.cards, route: .social(r), whose: h.following == true ? "following" : "shared")
            }
            return hits.isEmpty ? nil : (k.kind, k.title, hits)
        }
    }
}
