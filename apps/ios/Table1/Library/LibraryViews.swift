import SwiftUI
import Supabase

/* Library (Collection tab). Progressive disclosure: the home screen is a summary; the list, a card's
   printings and its history are each one tap deeper. Built ahead of the Figma Library screens on the
   existing kit (same as the web client); restyle once those land. */

enum LibraryRoute: Hashable {
    case allCards
    case add
    case addScan // Add cards with the scanner already up (the Scan cards control)
    case card(String) // oracle id
    case cardIn(String, CardContext) // oracle id, opened from a deck/cube or a binder
    case lists(CardList.Kind)
    case list(String) // list id
    case versions(String) // list id
    case version(String, Int) // list id, version number
    case listAdd(String) // list id
    case findDeck
    case linePrinting(String, String, String, String) // list id, card id, board, finish
    case importList(CardList.Kind)
    case trades
    case trade(String?) // trade id, nil for a new one
    case collectionImport
    case listStats(String) // list id
    case sampleHand(String) // list id
    case drawOdds(String) // list id
    case samplePack(String) // list id
    case binders
    case binder(String) // binder id, or BinderRoute.unsorted
    case wants
    case social(SocialRoute) // friends, profiles, sharing, trade matches (FriendsViews.swift)
    case rankings(String?) // a cube's rankings (list id), or every ranking of yours (RankingsViews.swift)
    case ranking(String) // ranking id
    case rankingPick(String, String) // ranking id, job (W U B R G M C L F)
    case rankingLists(String, String) // ranking id, job
    case rankingCard(String, String, String) // ranking id, oracle id, job
    case rankingCompare(String, String, String) // ranking id, the other ranking's id, job
    case rankingPack(String) // ranking id: P1P1 packs and pick history
    case rankingChanges(String) // ranking id: the change log
}

/// Every Library screen behind a route, shared by the Collection tab and the Debug demo.
struct LibraryDestination: View {
    let route: LibraryRoute
    @Binding var path: [LibraryRoute]
    var body: some View {
        Group { screen }.screen(screenName)
    }

    /// contract/telemetry-2026-10-15.md; never carries the route's ids.
    private var screenName: String {
        switch route {
        case .allCards: "all_cards"
        case .add, .addScan: "add_cards"
        case .card, .cardIn: "card_detail"
        case .lists(let kind): kind == .deck ? "decks" : "cubes"
        case .list(let id): ListsStore.shared.list(id: id)?.kind == .cube ? "cube" : "deck"
        case .versions, .version: "list_versions"
        case .listAdd: "list_add"
        case .findDeck: "deck_finder"
        case .linePrinting: "list_printing"
        case .importList: "list_import"
        case .trades: "trades"
        case .trade: "trade"
        case .collectionImport: "collection_import"
        case .listStats(let id): ListsStore.shared.list(id: id)?.kind == .cube ? "cube_stats" : "deck_stats"
        case .sampleHand: "sample_hand"
        case .drawOdds: "draw_odds"
        case .samplePack: "sample_pack"
        case .binders: "binders"
        case .binder: "binder"
        case .wants: "wants"
        case .social(let r): r.screenName
        case .rankings: "rankings"
        case .ranking: "ranking"
        case .rankingPick: "ranking_screen"
        case .rankingLists: "ranking_lists"
        case .rankingCard: "ranking_card"
        case .rankingCompare: "ranking_compare"
        case .rankingPack: "ranking_pack"
        case .rankingChanges: "ranking_changes"
        }
    }

    @ViewBuilder private var screen: some View {
        switch route {
        case .allCards: AllCardsView(path: $path)
        case .add: AddCardsView(path: $path)
        case .addScan: AddCardsView(path: $path, scanOnOpen: true)
        case .card(let id): CardDetailView(oracleId: id, path: $path)
        case .cardIn(let id, let context): CardDetailView(oracleId: id, path: $path, context: context)
        case .lists(let kind): ListsView(kind: kind, path: $path)
        case .list(let id): ListDetailView(listId: id, path: $path)
        case .versions(let id): ListVersionsView(listId: id, path: $path)
        case .version(let id, let n): ListVersionView(listId: id, number: n, path: $path)
        case .listAdd(let id): ListAddCardsView(listId: id, path: $path)
        case .findDeck: DeckFinderView(path: $path)
        case .linePrinting(let l, let c, let b, let f): ChangePrintingView(target: .listLine(listId: l, cardId: c, board: b, finish: f))
        case .importList(let kind): ListImportView(kind: kind, path: $path)
        case .trades: TradesView(path: $path)
        case .trade(let id): TradeView(tradeId: id, path: $path)
        case .collectionImport: CollectionImportView(path: $path)
        case .listStats(let id): ListStatsView(listId: id, path: $path)
        case .sampleHand(let id): SampleHandView(listId: id)
        case .drawOdds(let id): DrawOddsView(listId: id)
        case .samplePack(let id): SamplePackView(listId: id)
        case .binders: BindersView(path: $path)
        case .binder(let id): BinderView(binderId: id, path: $path)
        case .wants: WantsView(path: $path)
        case .social(let r): SocialDestination(route: r, path: $path)
        case .rankings(let list): RankingsView(listId: list, path: $path)
        case .ranking(let id): RankingView(rankingId: id, path: $path)
        case .rankingPick(let id, let job): RankingPickView(rankingId: id, job: RankJob(rawValue: job) ?? .final, path: $path)
        case .rankingLists(let id, let job): RankingListsView(rankingId: id, job: RankJob(rawValue: job) ?? .final, path: $path)
        case .rankingCard(let id, let card, let job): RankingCardView(rankingId: id, oracleId: card, job: RankJob(rawValue: job) ?? .final, path: $path)
        case .rankingCompare(let id, let other, let job):
            RankingCompareView(rankingId: id, otherId: other, job: RankJob(rawValue: job) ?? .final, path: $path)
        case .rankingPack(let id): RankingPackView(rankingId: id, path: $path)
        case .rankingChanges(let id): RankingChangesView(rankingId: id, path: $path)
        }
    }
}

private func money(_ n: Double?, _ code: String) -> String {
    guard let n else { return "—" }
    return n.formatted(.currency(code: code).precision(.fractionLength(0)))
}

private struct LoadingRow: View {
    let text: String
    var body: some View {
        LabelText(text).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 16).background(T1.surface)
    }
}

/// The catalog's state as a row, or nothing once it's ready.
private struct CatalogStatus: View {
    let catalog: CatalogStore
    var body: some View {
        switch catalog.phase {
        case .ready: EmptyView()
        case .failed(let message): Notice(message, error: true)
        case .idle, .loading: LoadingRow(text: "Loading card data…")
        }
    }
}

// MARK: home

struct LibraryHomeView: View {
    @Binding var path: [LibraryRoute]
    private var col: CollectionStore { CollectionStore.shared }
    /// The collection's hero cards, shown on the All cards row.
    @State private var heroArt: [CatalogPrinting] = []

    var body: some View {
        let s = col.summary
        T1Screen {
            Bar(title: "Collection", subtitle: col.isDemo ? "Demo data" : col.syncing ? "Syncing…" : nil)
            if let error = col.error { Notice(error, error: true) }
            HairlineList {
                VStack(spacing: 4) {
                    LabelText("Cards")
                    Text(s.map { $0.totalQty.formatted() } ?? (col.ready ? "0" : "…"))
                        .font(T1.mono(48)).tracking(4).monospacedDigit()
                    LabelText(s.map { "\($0.uniqueCards.formatted()) distinct · \(money($0.valueUsd, "USD"))" } ?? " ")
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24).background(T1.surface)

                Button { path.append(.allCards) } label: {
                    HeroListRow(heroes: heroArt, title: "All cards", detail: s.map { "\($0.uniquePrintings.formatted()) printings" }) {
                        if let s { Text(s.uniqueCards.formatted()).font(T1.mono(17)).monospacedDigit() }
                    }
                }.buttonStyle(.plain)
                Button { path.append(.add) } label: { ListRow(title: "Add cards", detail: "Search, Scryfall syntax or scan") }.buttonStyle(.plain)
                Button { path.append(.collectionImport) } label: {
                    ListRow(title: "Import and export", detail: "CSV from ManaBox, Moxfield and others")
                }.buttonStyle(.plain)
                bindersRow
                wantsRow
                listsRow(.deck, "Decks")
                listsRow(.cube, "Cubes")
                TradeMatchesRow(path: $path)
                Button { path.append(.trades) } label: {
                    let open = TradesStore.shared.trades.filter { !$0.confirmed }.count
                    ListRow(title: "Trades", detail: open > 0 ? "\(open) open" : "Give and get, then confirm") {
                        if TradesStore.shared.loaded { Text(TradesStore.shared.trades.count.formatted()).font(T1.mono(17)).monospacedDigit() }
                    }
                }.buttonStyle(.plain)
            }
        }
        .refreshable { await col.sync() }
        .task { await TradesStore.shared.load() }
        .task(id: "\(HeroesStore.shared.heroes(.collection))-\(CatalogStore.shared.generation)-\(col.version)") {
            guard let db = CatalogStore.shared.db else { heroArt = []; return }
            let heroes = HeroesStore.shared.heroes(.collection)
            let held = col.items.values.sorted { $0.qty > $1.qty }.map(\.cardId)
            heroArt = await Task.detached(priority: .userInitiated) { HeroArt.printings(heroes, held: held, db) }.value
        }
    }

    private var bindersRow: some View {
        let b = BindersStore.shared
        let trade = b.binders.filter(\.forTrade).map(\.id)
        let totals = b.totals(col.items)
        let forTrade = trade.reduce(0) { $0 + (totals.byBinder[$1] ?? 0) }
        return Button { path.append(.binders) } label: {
            ListRow(title: "Binders", detail: b.binders.isEmpty ? "Where your copies are, and what's for trade"
                                                                : "\(forTrade.formatted()) cards for trade · \(totals.unsorted.formatted()) unsorted") {
                Text(b.binders.count.formatted()).font(T1.mono(17)).monospacedDigit()
            }
        }.buttonStyle(.plain)
    }

    private var wantsRow: some View {
        let wanted = BindersStore.shared.liveWants.reduce(0) { $0 + $1.qty }
        let missing = MissingView.lines(ListsStore.shared.lists, owned: ownedByPrinting(), basics: CatalogStore.shared.basics).reduce(0) { $0 + $1.short }
        return Button { path.append(.wants) } label: {
            ListRow(title: "Wants", detail: "\(wanted.formatted()) wanted · \(missing.formatted()) missing") {
                Text(wanted.formatted()).font(T1.mono(17)).monospacedDigit()
            }
        }.buttonStyle(.plain)
    }

    /// Decks and cubes always open (an empty one shows 0; new ones are created inside).
    private func listsRow(_ kind: CardList.Kind, _ title: String) -> some View {
        let lists = ListsStore.shared.lists(kind)
        return Button { path.append(.lists(kind)) } label: {
            ListRow(title: title, detail: lists.isEmpty ? (kind == .deck ? "Build or import a deck" : "Build or import a cube")
                                                        : lists.prefix(3).map(\.name).joined(separator: " · ")) {
                Text(lists.count.formatted()).font(T1.mono(17)).monospacedDigit()
            }
        }.buttonStyle(.plain)
    }
}

// MARK: all cards

/// One Oracle card in the collection, summed over its printings and copies.
struct CardGroup: Identifiable, Hashable, Sendable {
    let id: String // oracle id, or the printing id when the card is newer than the local catalog
    let known: Bool
    let name: String
    let norm: String
    let type: String
    var qty = 0
    var printings = 0
    var lastSeq = 0
    /// The printing shown as this card's picture: the one owned most.
    var cover: CatalogPrinting?
    var coverQty = 0
    /// The finish of the copies shown as the picture.
    var coverFinish = "nonfoil"
    /// Copies per printing and finish (over conditions and languages), oldest printing first: the rows a card
    /// opens into.
    var parts: [Part] = []

    struct Part: Hashable, Sendable, Identifiable {
        let cardId: String
        let finish: String
        var qty: Int
        let printing: CatalogPrinting?
        /// The best condition among these copies, which prices the row.
        var condition = "NM"
        var id: String { "\(cardId)|\(finish)" }
        var finishLabel: String { Finish(rawValue: finish)?.label ?? finish }
    }

    static func build(_ items: [CollectionItem], _ db: CatalogDB) -> [CardGroup] {
        let printings = db.printings(ids: Array(Set(items.map(\.cardId))))
        let oracles = db.oracles(idxs: Array(Set(printings.values.map(\.oracleIdx))))
        var by: [String: CardGroup] = [:]
        var seen: [String: Set<String>] = [:]
        for it in items {
            let o = printings[it.cardId].flatMap { oracles[$0.oracleIdx] }
            let key = o?.oracleId ?? it.cardId
            var g = by[key] ?? CardGroup(id: key, known: o != nil, name: o?.name ?? "Card not in local data yet",
                                         norm: o?.norm ?? "", type: o?.typeLine ?? it.cardId)
            g.qty += it.qty
            g.lastSeq = max(g.lastSeq, it.seq)
            if seen[key, default: []].insert(it.cardId).inserted { g.printings += 1 }
            if let p = printings[it.cardId], it.qty > g.coverQty { g.cover = p; g.coverQty = it.qty; g.coverFinish = it.finish }
            if let i = g.parts.firstIndex(where: { $0.cardId == it.cardId && $0.finish == it.finish }) {
                g.parts[i].qty += it.qty
                if Conditions.better(it.condition, g.parts[i].condition) { g.parts[i].condition = it.condition }
            } else {
                g.parts.append(Part(cardId: it.cardId, finish: it.finish, qty: it.qty, printing: printings[it.cardId], condition: it.condition))
            }
            by[key] = g
        }
        return by.values.map { g in
            var g = g
            g.parts.sort { a, b in
                guard let pa = a.printing, let pb = b.printing else { return a.printing != nil }
                if pa.cardId != pb.cardId { return CatalogPrinting.oldestFirst(pa, pb) }
                return (Finish(rawValue: a.finish).flatMap { Finish.allCases.firstIndex(of: $0) } ?? 9)
                    < (Finish(rawValue: b.finish).flatMap { Finish.allCases.firstIndex(of: $0) } ?? 9)
            }
            return g
        }
    }
}

/// A card's collapsed row (and, open, one row per printing and finish under it) in All cards and binders.
struct CardGroupRows: View {
    let group: CardGroup
    let detail: String
    var hero = false
    var open = false
    var partDetail: (CardGroup.Part) -> String? = { _ in nil }
    let toggle: () -> Void
    let tap: (CardGroup.Part?) -> Void

    var body: some View {
        HStack(spacing: 1) {
            Button { tap(nil) } label: {
                CardRow(printing: group.cover, title: group.name, detail: detail, finish: group.coverFinish, hero: hero) {
                    Text("\(group.qty)").font(T1.mono(17)).monospacedDigit()
                }
            }.buttonStyle(.plain)
            if group.parts.count > 1 { PrintingsChevron(open: open, hero: hero, action: toggle) }
        }
        .fixedSize(horizontal: false, vertical: true)
        if open && group.parts.count > 1 {
            ForEach(group.parts) { part in
                Button { tap(part) } label: {
                    CardRow(printing: part.printing, title: [part.printing?.setLabel, part.finish == "nonfoil" ? nil : part.finishLabel]
                                .compactMap { $0 }.joined(separator: " · "),
                            detail: partDetail(part), finish: part.finish) {
                        Text("\(part.qty)").font(T1.mono(15)).monospacedDigit().foregroundStyle(T1.muted)
                    }
                    .padding(.leading, 24).background(T1.surface)
                }
                .buttonStyle(.plain)
                .id("\(group.id)|\(part.id)")
            }
        }
    }
}

struct AllCardsView: View {
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var col: CollectionStore { CollectionStore.shared }
    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var groups: [CardGroup] = []
    @State private var built = false
    @State private var query = ""
    @AppStorage("library.allCards.sort") private var sort = "recent"
    @AppStorage("library.allCards.layout") private var layout = CardLayout.list.rawValue
    @AppStorage("library.allCards.grouping") private var groupingRaw = CardGrouping.none.rawValue
    @State private var keys: [String: GroupKeys] = [:]
    @State private var printings = PrintingsDisclosure()
    private var prices: PriceBook { PriceBook.shared }
    private var grouping: CardGrouping { CardGrouping(rawValue: groupingRaw) ?? .none }
    private var heroes: HeroesStore { HeroesStore.shared }

    /// The most a single owned copy is worth (market price in its condition, USD).
    private func price(_ g: CardGroup) -> Double? {
        g.parts.compactMap { prices.usd($0.cardId, $0.finish, $0.condition) }.max()
    }

    private var shown: [CardGroup] {
        let n = CardName.norm(query)
        var list = n.isEmpty ? groups : groups.filter { $0.norm.contains(n) || CardName.norm($0.type).contains(n) }
        switch sort {
        case "price":
            // No price yet reads as the most valuable: those are the cards worth checking first.
            let p = Dictionary(list.map { ($0.id, price($0) ?? .infinity) }, uniquingKeysWith: { a, _ in a })
            list.sort { p[$0.id]! != p[$1.id]! ? p[$0.id]! > p[$1.id]! : $0.norm < $1.norm }
        case "name", "manaValue", "set":
            // Newest set first, then collector number; spells by mana value, then lands; or by name.
            list = CardSort.of(sort, .allCards).apply(list) { SortKey(name: $0.name, keys: keys[$0.id], printing: $0.cover) }
        default: list.sort { $0.lastSeq != $1.lastSeq ? $0.lastSeq > $1.lastSeq : $0.norm < $1.norm }
        }
        return list
    }

    private func detail(_ g: CardGroup) -> String {
        let p = PriceBook.text(price(g))
        if sort == "set", let c = g.cover { return [c.setLabel, p].compactMap { $0 }.joined(separator: " · ") }
        return [p, "\(g.printings) printing\(g.printings == 1 ? "" : "s")", g.type].compactMap { $0 }.joined(separator: " · ")
    }

    /// Grid and stacks: one card per Oracle card, or with every printing expanded, one per printing and finish.
    private func tiles(_ shown: [CardGroup]) -> [StackCard] {
        shown.flatMap { g -> [StackCard] in
            let hero = heroes.isHero(g.id, .collection)
            let open = { if g.known { path.append(.card(g.id)) } }
            guard printings.all, g.parts.count > 1 else {
                return [StackCard(id: g.id, printing: g.cover, name: g.name, qty: g.qty, finish: g.coverFinish, hero: hero, open: open)]
            }
            return g.parts.map { StackCard(id: "\(g.id)|\($0.id)", printing: $0.printing, name: g.name, qty: $0.qty, finish: $0.finish, hero: hero, open: open) }
        }
    }

    /// Stacks follow Group by (one per group), else the sort: one per set when sorted by set, otherwise runs of ten
    /// in sort order.
    private func stacks(_ shown: [CardGroup]) -> [(id: String, title: String?, cards: [StackCard])] {
        if grouping != .none {
            return CardGroup.sections(shown, by: grouping, keys: keys).map { s in
                ("\(grouping.rawValue)|\(s.key)|\(sort)|\(printings.all)", "\(grouping.label(s.key)) · \(s.cards.reduce(0) { $0 + $1.qty })", tiles(s.cards))
            }
        }
        let cards = tiles(shown)
        if sort == "set" {
            var out: [(id: String, title: String?, cards: [StackCard])] = []
            for c in cards {
                let key = c.printing?.set ?? ""
                if out.last?.id == key { out[out.count - 1].cards.append(c) }
                else { out.append((key, c.printing.map { $0.set.uppercased() } ?? "Unknown set", [c])) }
            }
            return out
        }
        return stride(from: 0, to: cards.count, by: 10).map { i in
            ("\(sort)|\(printings.all)|\(i)", nil, Array(cards[i..<min(i + 10, cards.count)]))
        }
    }

    var body: some View {
        T1Screen {
            Bar(title: "All cards", subtitle: col.summary.map { "\($0.totalQty.formatted()) cards" }, back: { dismiss() }) {
                HStack(spacing: 20) {
                    BarButton("Share") {
                        Telemetry.capture("share_opened", ["part": "all_cards", "from": "all_cards"])
                        path.append(.social(.share(.allCards)))
                    }
                    BarButton("View") {
                        CardLayout.menu($layout, screen: "all_cards", printings: $printings, grouping: $groupingRaw, list: false, sort: $sort, sorts: .allCards)
                    }
                }
            }
            if let error = col.error { Notice(error, error: true) }
            CatalogStatus(catalog: catalog)
            T1SearchField(text: $query, prompt: "Name or type")
            T1Segmented(options: [("recent", "Recent"), ("price", "Price"), ("name", "Name"), ("manaValue", "MV"), ("set", "Set")], selection: $sort, scroll: true)
            if catalog.phase == .ready && built {
                if groups.isEmpty && col.ready {
                    Button { path.append(.add) } label: { ListRow(title: "No cards yet", detail: "Add your first card") }.buttonStyle(.plain)
                }
                let shown = shown
                if shown.isEmpty && !groups.isEmpty { ListRow(title: "No matches", detail: "Nothing in your collection by that name or type") }
                if layout == CardLayout.stacks.rawValue {
                    GeometryReader { geo in
                        ScrollView { LazyVStack(spacing: 1) { StackRows(stacks: stacks(shown), width: ((geo.size.width - 1) / 2).rounded(.down)) } }
                    }
                } else if layout == CardLayout.grid.rawValue {
                    SectionedCardGrid(sections: CardGroup.sections(shown, by: grouping, keys: keys).map { s in
                        (key: "\(s.key)|\(sort)|\(printings.all)", title: grouping == .none ? nil : "\(grouping.label(s.key)) · \(s.cards.reduce(0) { $0 + $1.qty })",
                         items: tiles(s.cards))
                    }) { c, width in
                        Button(action: c.open) {
                            CardTile(printing: c.printing, name: c.name, qty: c.qty, width: width, finish: c.finish, hero: c.hero)
                        }.buttonStyle(.plain)
                    }
                } else {
                    HairlineList {
                        ForEach(CardGroup.sections(shown, by: grouping, keys: keys), id: \.key) { s in
                            if grouping != .none { Section1("\(grouping.label(s.key)) · \(s.cards.reduce(0) { $0 + $1.qty })").id("h|\(s.key)") }
                            ForEach(s.cards) { g in
                                CardGroupRows(group: g, detail: detail(g), hero: heroes.isHero(g.id, .collection), open: printings.open(g.id),
                                              partDetail: { PriceBook.text(prices.usd($0.cardId, $0.finish, $0.condition)) },
                                              toggle: { printings.toggle(g.id) },
                                              tap: { _ in if g.known { path.append(.card(g.id)) } })
                            }
                        }
                    }
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .task(id: "\(col.version)-\(catalog.generation)") {
            catalog.load(userInitiated: true)
            guard let db = catalog.db else { return }
            let items = Array(col.items.values)
            (groups, keys) = await Task.detached(priority: .userInitiated) { () -> ([CardGroup], [String: GroupKeys]) in
                let g = CardGroup.build(items, db)
                return (g, CardGroup.keys(g, db))
            }.value
            built = true
            await prices.load(items.map(\.cardId))
        }
    }
}

// MARK: add (search)

struct AddCardsView: View {
    @Binding var path: [LibraryRoute]
    var scanOnOpen = false
    @Environment(\.dismiss) private var dismiss
    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var query = ""
    @State private var hits: [CatalogOracle] = []
    @State private var covers: [Int: CatalogPrinting] = [:]
    @State private var result: CardSearchEngine.Result?
    @State private var scanned: (batchId: String, label: String)?
    @State private var error: String?
    @State private var busy = false
    @State private var autoScanned = false
    @FocusState private var focused: Bool

    var body: some View {
        T1Screen {
            Bar(title: "Add cards", back: { dismiss() })
            CatalogStatus(catalog: catalog)
            if let error { Notice(error, error: true) }
            if let scanned {
                HStack(spacing: 12) {
                    LabelText(scanned.label)
                    Spacer(minLength: 0)
                    BarButton(busy ? "Undoing…" : "Undo") { undoScan() }
                }
                .padding(.horizontal, 16).padding(.vertical, 12).background(T1.surface)
            }
            CardSearchBar(query: $query, prompt: "Lightning Bolt, or t:dragon c:r", scan: { scan() }, focused: $focused)
            CardSearchStatus(query: query, result: result)
            HairlineList {
                if catalog.phase == .ready && CardName.norm(query).count >= 2 && hits.isEmpty && !CardQuery.hasSyntax(query) {
                    LoadingRow(text: "No card by that name")
                }
                ForEach(hits, id: \.idx) { o in
                    Button { path.append(.card(o.oracleId)) } label: {
                        CardRow(printing: covers[o.idx], title: o.name, detail: o.manaCost.isEmpty ? o.typeLine : "\(o.typeLine) · \(o.manaCost)") {
                            Text("\(o.printings)").font(T1.mono(15)).monospacedDigit().foregroundStyle(T1.muted)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
        .onAppear {
            catalog.load(userInitiated: true)
            if scanOnOpen && !autoScanned {
                autoScanned = true
                scan()
            } else {
                focused = true
            }
        }
        .task(id: "\(query)-\(catalog.generation)") {
            guard let db = catalog.db else { hits = []; return }
            let q = query
            try? await Task.sleep(for: CardSearchEngine.debounce(q)) // let typing settle
            if Task.isCancelled { return }
            let found = await Task.detached(priority: .userInitiated) { await CardSearchEngine.run(q, db) }.value
            if !Task.isCancelled { hits = found.hits; covers = found.covers; result = found }
        }
    }

    /// Scan session: every card goes in as one batch (source "scan") when it's done, so one Undo takes it back.
    private func scan() {
        focused = false
        T1Overlays.shared.present(full: true, swipeBack: false) {
            CardScanView(title: "Scan cards", doneLabel: "Add", onDone: { cards in
                Telemetry.capture("scan_session_ended", ["context": "add", "cards": cards.count,
                                                         "exact": cards.filter(\.exact).count, "cancelled": false])
                T1Overlays.shared.dismissPanel()
                let ops = cards.map { CollectionOp(cardId: $0.printing.cardId, finish: $0.finish, condition: $0.condition, lang: $0.lang, delta: 1) }
                Task {
                    do {
                        let res = try await CollectionStore.shared.apply(ops, source: "scan")
                        scanned = (res.batchId, "Added \(cards.count) scanned card\(cards.count == 1 ? "" : "s")")
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }, onCancel: {
                Telemetry.capture("scan_session_ended", ["context": "add", "cards": 0, "exact": 0, "cancelled": true])
                T1Overlays.shared.dismissPanel()
            })
            .screen("card_scanner")
        }
    }

    private func undoScan() {
        guard let scanned, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await CollectionStore.shared.undo(batchId: scanned.batchId)
                self.scanned = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: card detail (CardDetailViews.swift)

/// The scope card detail was opened in (contract/card-detail-2026-10-23.md); nil is the collection.
enum CardContext: Hashable {
    case list(String) // list id
    case binder(String) // binder id, or BinderRoute.unsorted
    /// Nothing of yours in view (wants, Missing, a friend's or shared card): the bottom bar is Add to.
    case search
}

// MARK: images

/// Card art from the Scryfall CDN, cached on disk. The URL carries image_ts, so a cached image is never stale.
/// Cards in a three-column grid that fills the width, built lazily as it scrolls.
struct CardGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    @ViewBuilder let cell: (Item, CGFloat) -> Cell

    var body: some View {
        GeometryReader { geo in
            let width = ((geo.size.width - 2) / 3).rounded(.down)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 1), count: 3), spacing: 1) {
                    ForEach(items) { cell($0, width) }
                }
            }
        }
    }
}

private extension String {
    /// A binder-context row's id, apart from the same item's In collection row.
    var inBinder: String { "in|" + self }
}
