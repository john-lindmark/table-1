import SwiftUI
import Supabase

/* Library (Collection tab). Progressive disclosure: the home screen is a summary; the list, a card's
   printings and its history are each one tap deeper. Built ahead of the Figma Library screens on the
   existing kit (same as the web client); restyle once those land. */

enum LibraryRoute: Hashable {
    case allCards
    case add
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
        case .add: "add_cards"
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
        }
    }

    @ViewBuilder private var screen: some View {
        switch route {
        case .allCards: AllCardsView(path: $path)
        case .add: AddCardsView(path: $path)
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
                    LabelText(s.map { "\($0.uniqueCards.formatted()) distinct · \(money($0.valueUsd, "USD")) · \(money($0.valueEur, "EUR"))" } ?? " ")
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
        let missing = MissingView.lines(ListsStore.shared.lists, owned: ownedByPrinting()).reduce(0) { $0 + $1.short }
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
    /// Printing id → finishes owned, for prices.
    var owned: [String: Set<String>] = [:]
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
            g.owned[it.cardId, default: []].insert(it.finish)
            if let p = printings[it.cardId], it.qty > g.coverQty { g.cover = p; g.coverQty = it.qty; g.coverFinish = it.finish }
            if let i = g.parts.firstIndex(where: { $0.cardId == it.cardId && $0.finish == it.finish }) { g.parts[i].qty += it.qty }
            else { g.parts.append(Part(cardId: it.cardId, finish: it.finish, qty: it.qty, printing: printings[it.cardId])) }
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
    @State private var printings = PrintingsDisclosure()
    private var prices: PriceBook { PriceBook.shared }
    private var heroes: HeroesStore { HeroesStore.shared }

    /// The most a single owned copy is worth (market price, USD).
    private func price(_ g: CardGroup) -> Double? {
        g.owned.flatMap { id, finishes in finishes.compactMap { prices.usd(id, $0) } }.max()
    }

    private var shown: [CardGroup] {
        let n = CardName.norm(query)
        var list = n.isEmpty ? groups : groups.filter { $0.norm.contains(n) || CardName.norm($0.type).contains(n) }
        switch sort {
        case "price":
            // No price yet reads as the most valuable: those are the cards worth checking first.
            let p = Dictionary(list.map { ($0.id, price($0) ?? .infinity) }, uniquingKeysWith: { a, _ in a })
            list.sort { p[$0.id]! != p[$1.id]! ? p[$0.id]! > p[$1.id]! : $0.norm < $1.norm }
        case "set":
            // Newest set first; within a set, collector number order.
            func cn(_ g: CardGroup) -> Int { Int(g.cover?.cn.trimmingCharacters(in: .letters) ?? "") ?? Int.max }
            list.sort { a, b in
                let ra = a.cover?.releasedAt ?? "", rb = b.cover?.releasedAt ?? ""
                if ra != rb { return ra > rb }
                if a.cover?.set != b.cover?.set { return (a.cover?.set ?? "") < (b.cover?.set ?? "") }
                return cn(a) != cn(b) ? cn(a) < cn(b) : a.norm < b.norm
            }
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

    /// Stacks follow the sort: one per set when sorted by set, otherwise runs of ten in sort order.
    private func stacks(_ shown: [CardGroup]) -> [(id: String, title: String?, cards: [StackCard])] {
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
                    BarButton("View") { CardLayout.menu($layout, screen: "all_cards", printings: $printings) }
                }
            }
            if let error = col.error { Notice(error, error: true) }
            CatalogStatus(catalog: catalog)
            T1SearchField(text: $query, prompt: "Name or type")
            T1Segmented(options: [("recent", "Recent"), ("price", "Price"), ("set", "Set")], selection: $sort)
            if catalog.phase == .ready && built {
                if groups.isEmpty && col.ready {
                    Button { path.append(.add) } label: { ListRow(title: "No cards yet", detail: "Add your first card") }.buttonStyle(.plain)
                }
                let shown = shown
                if shown.isEmpty && !groups.isEmpty { ListRow(title: "No matches", detail: "Nothing in your collection by that name or type") }
                if layout == CardLayout.stacks.rawValue {
                    GeometryReader { geo in
                        ScrollView { StackRows(stacks: stacks(shown), width: ((geo.size.width - 1) / 2).rounded(.down)) }
                    }
                } else if layout == CardLayout.grid.rawValue {
                    CardGrid(items: tiles(shown)) { c, width in
                        Button(action: c.open) {
                            CardTile(printing: c.printing, name: c.name, qty: c.qty, width: width, finish: c.finish, hero: c.hero)
                        }.buttonStyle(.plain)
                    }
                } else {
                    HairlineList {
                        ForEach(shown) { g in
                            CardGroupRows(group: g, detail: detail(g), hero: heroes.isHero(g.id, .collection), open: printings.open(g.id),
                                          partDetail: { PriceBook.text(prices.usd($0.cardId, $0.finish)) },
                                          toggle: { printings.toggle(g.id) },
                                          tap: { _ in if g.known { path.append(.card(g.id)) } })
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
            groups = await Task.detached(priority: .userInitiated) { CardGroup.build(items, db) }.value
            built = true
            await prices.load(items.map(\.cardId))
        }
    }
}

// MARK: add (search)

struct AddCardsView: View {
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var query = ""
    @State private var hits: [CatalogOracle] = []
    @State private var covers: [Int: CatalogPrinting] = [:]
    @State private var result: CardSearchEngine.Result?
    @State private var scanned: (batchId: String, label: String)?
    @State private var error: String?
    @State private var busy = false
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
            focused = true
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

// MARK: card detail

private struct PrintingPrice: Decodable {
    let id: String
    let setName: String?
    let usd: Double?
    let usdFoil: Double?
    let eur: Double?
    let eurFoil: Double?

    func text(_ finish: String) -> String? {
        let nonfoil = finish == Finish.nonfoil.rawValue
        let parts = [(nonfoil ? usd : usdFoil).map { "$\($0.formatted())" }, (nonfoil ? eur : eurFoil).map { "€\($0.formatted())" }]
        let shown = parts.compactMap { $0 }
        return shown.isEmpty ? nil : shown.joined(separator: " · ")
    }
}

/// Where card detail was opened from: that deck/cube's lines or that binder's copies of the card come first, each
/// with Change printing.
enum CardContext: Hashable {
    case list(String) // list id
    case binder(String) // binder id, or BinderRoute.unsorted
}

struct CardDetailView: View {
    let oracleId: String
    var path: Binding<[LibraryRoute]>?
    var context: CardContext?
    @Environment(\.dismiss) private var dismiss
    private var col: CollectionStore { CollectionStore.shared }
    private var catalog: CatalogStore { CatalogStore.shared }

    @State private var oracle: CatalogOracle?
    @State private var printings: [CatalogPrinting] = []
    @State private var looked = false
    @State private var prices: [String: PrintingPrice] = [:]
    @State private var busy: String?
    @State private var error: String?
    @State private var last: (batchId: String, label: String)?
    @State private var showAll = false
    @State private var open: String?
    @State private var history: [HistoryEntry]?
    /// A printing tapped in the list, shown large in place of the owned one.
    @State private var preview: CatalogPrinting?
    @State private var added: String?
    /// Condition new copies go in as (shared with the scanner).
    @AppStorage("library.addCondition") private var addCondition = "NM"
    /// Language new English-printing copies go in as (shared with the scanner and binder adds).
    @AppStorage("library.addLang") private var addLang = "en"

    private var owned: [(item: CollectionItem, printing: CatalogPrinting)] {
        let byId = Dictionary(printings.map { ($0.cardId, $0) }, uniquingKeysWith: { a, _ in a })
        return col.items.values.compactMap { it in byId[it.cardId].map { (it, $0) } }
            .sorted { $0.printing.cardId != $1.printing.cardId ? CatalogPrinting.oldestFirst($0.printing, $1.printing) : $0.item.key < $1.item.key }
    }

    var body: some View {
        let owned = owned
        let total = owned.reduce(0) { $0 + $1.item.qty }
        T1Screen {
            Bar(title: oracle?.name ?? "Card", subtitle: oracle == nil ? nil : "\(total) in collection", back: { dismiss() })
            if let message = error ?? col.error { Notice(message, error: true) }
            CatalogStatus(catalog: catalog)
            if looked && oracle == nil && catalog.phase == .ready { Notice("That card isn't in the card data.", error: true) }
            if let added { Notice(added) }
            if let last {
                HStack(spacing: 12) {
                    LabelText(last.label)
                    Spacer(minLength: 0)
                    BarButton(busy == "undo" ? "Undoing…" : "Undo") { Task { await undo() } }
                }
                .padding(.horizontal, 16).padding(.vertical, 12).background(T1.surface)
            }
            if let oracle {
                HairlineList {
                    hero(oracle, preview ?? contextPrinting(owned) ?? owned.first?.printing ?? printings.first)
                    contextSection(owned)
                    Section1("In collection · \(owned.count)")
                    if owned.isEmpty { LoadingRow(text: "None yet. Pick a printing below.") }
                    ForEach(owned, id: \.item.key) { pair in ownedRow(pair.item, pair.printing) }
                    let uses = ListsStore.shared.uses(cardIds: Set(printings.map(\.cardId)))
                    if !uses.isEmpty {
                        let used = uses.reduce(0) { $0 + $1.qty }
                        // Lists don't reserve copies, so say when they ask for more than you own between them.
                        // Considering never counts against what you own.
                        Section1(used > total ? "In decks and cubes · \(used) used · own \(total)" : "In decks and cubes · \(used)")
                        ForEach(uses, id: \.list.id) { use in
                            let kind = use.list.kind == .deck ? "\(use.list.format.capitalized) deck" : "Cube"
                            Button { listPath(use.list.id) } label: {
                                ListRow(title: use.list.name, detail: use.considering > 0 ? "\(kind) · \(use.considering) considering" : kind) {
                                    Text("\(use.qty)").font(T1.mono(17)).monospacedDigit()
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                    if !ListsStore.shared.lists.isEmpty {
                        Button { addToList(preview ?? owned.first?.printing ?? printings.first) } label: {
                            ListRow(title: "Add to a deck or cube", detail: "Pick the list, then the section")
                        }.buttonStyle(.plain)
                    }
                    wantRow(oracle)
                    heroRow(oracle)
                    Section1("Add a printing · \(printings.count)")
                    T1Segmented(options: Conditions.all.map { ($0, $0) }, selection: $addCondition)
                    LanguageRow(lang: addLang, title: "New copies in") {
                        LanguagePicker.present(current: addLang, subtitle: "For new copies") { addLang = $0 }
                    }
                    ForEach(showAll ? printings : Array(printings.prefix(12)), id: \.cardId) { addRow($0) }
                    if !showAll && printings.count > 12 {
                        Button { showAll = true } label: { ListRow(title: "Show all \(printings.count) printings") }.buttonStyle(.plain)
                    }
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .task(id: catalog.generation) {
            catalog.load(userInitiated: true)
            guard let db = catalog.db else { return }
            let id = oracleId
            let found = await Task.detached(priority: .userInitiated) { () -> (CatalogOracle?, [CatalogPrinting]) in
                guard let o = db.oracle(id: id) else { return (nil, []) }
                return (o, db.printings(oracleIdx: o.idx))
            }.value
            oracle = found.0
            printings = found.1.sorted(by: CatalogPrinting.oldestFirst)
            looked = true
        }
        .task(id: oracleId) {
            let rows: [PrintingPrice]? = try? await supabase.rpc("card_printings", params: ["p_oracle_id": AnyJSON.string(oracleId)]).execute().value
            if let rows { prices = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
        }
        .task(id: "\(open ?? "")-\(col.version)") {
            guard let open else { history = nil; return }
            do { history = try await col.history(cardId: open) } catch { self.error = error.localizedDescription }
        }
    }

    private func listPath(_ id: String) { path?.wrappedValue.append(.list(id)) }

    // MARK: opened from a deck, cube or binder

    /// This card's lines in the list it was opened from: (entry, printing).
    private func contextLines(_ list: CardList) -> [(entry: CardList.Entry, printing: CatalogPrinting)] {
        let byId = Dictionary(printings.map { ($0.cardId, $0) }, uniquingKeysWith: { a, _ in a })
        return list.entries.compactMap { e in byId[e.cardId].map { (e, $0) } }
            .sorted { list.boards.firstIndex(of: $0.entry.board) ?? 0 < list.boards.firstIndex(of: $1.entry.board) ?? 0 }
    }

    /// This card's copies in the binder (or Unsorted) it was opened from.
    private func contextCopies(_ owned: [(item: CollectionItem, printing: CatalogPrinting)], binderId: String)
        -> [(item: CollectionItem, printing: CatalogPrinting, qty: Int)] {
        let _ = BindersStore.shared.version
        return owned.compactMap { pair in
            let here = PrintingChange.places(pair.item).first { $0.place == binderId }?.qty ?? 0
            return here > 0 ? (pair.item, pair.printing, here) : nil
        }
    }

    private func contextPrinting(_ owned: [(item: CollectionItem, printing: CatalogPrinting)]) -> CatalogPrinting? {
        switch context {
        case .list(let id): ListsStore.shared.list(id: id).flatMap { contextLines($0).first?.printing }
        case .binder(let id): contextCopies(owned, binderId: id).first?.printing
        case nil: nil
        }
    }

    @ViewBuilder private func contextSection(_ owned: [(item: CollectionItem, printing: CatalogPrinting)]) -> some View {
        switch context {
        case .list(let id):
            if let list = ListsStore.shared.list(id: id) {
                let lines = contextLines(list)
                Section1("In \(list.name) · \(lines.reduce(0) { $0 + $1.entry.qty })")
                if lines.isEmpty { LoadingRow(text: "Not in this \(list.kind == .deck ? "deck" : "cube") any more.") }
                ForEach(lines, id: \.entry) { l in
                    Button {
                        T1Overlays.shared.present(full: true) {
                            ChangePrintingView(target: .listLine(listId: list.id, cardId: l.entry.cardId, board: l.entry.board, finish: l.entry.finish),
                                               close: { T1Overlays.shared.dismissPanel() }).screen("list_printing")
                        }
                    } label: {
                        CardRow(printing: l.printing, title: "\(l.printing.setLabel) · \(Finish(rawValue: l.entry.finish)?.label ?? l.entry.finish)",
                                detail: list.boardTitle(l.entry.board), finish: l.entry.finish) {
                            changeLabel(l.entry.qty)
                        }
                    }.buttonStyle(.plain)
                }
            }
        case .binder(let id):
            let copies = contextCopies(owned, binderId: id)
            let name = id == BinderRoute.unsorted ? "Unsorted" : BindersStore.shared.binder(id)?.name ?? "Binder"
            Section1("In \(name) · \(copies.reduce(0) { $0 + $1.qty })")
            if copies.isEmpty { LoadingRow(text: "None here any more.") }
            // Ids apart from In collection's below: the lazy stack flattens both, and a shared id drops a row.
            ForEach(copies, id: \.item.key.inBinder) { c in
                Button { changePrinting(c.item, place: id) } label: {
                    CardRow(printing: c.printing, title: "\(c.printing.setLabel) · \(c.item.finishLabel)",
                            detail: [c.item.condition, c.item.lang == "en" ? nil : c.item.lang.uppercased()].compactMap { $0 }.joined(separator: " · "),
                            finish: c.item.finish) {
                        changeLabel(c.qty)
                    }
                }.buttonStyle(.plain)
            }
        case nil:
            EmptyView()
        }
    }

    /// The count, with "Change" so the row says what a tap does.
    private func changeLabel(_ qty: Int) -> some View {
        HStack(spacing: 12) {
            LabelText("Change", color: T1.text)
            Text("\(qty)").font(T1.mono(17)).monospacedDigit()
        }
    }

    /// Owned copies → another printing or finish, in the same place; Undo shows here.
    private func changePrinting(_ it: CollectionItem, place: String?) {
        T1Overlays.shared.present(full: true) {
            ChangePrintingView(target: .owned(it, place: place), close: { T1Overlays.shared.dismissPanel() },
                               changed: { batchId, label in last = (batchId, label); added = nil; error = nil })
                .screen("item_printing")
        }
    }

    /// Wanting this card: any printing, or the one shown on top. Shows how many are wanted already.
    private func wantRow(_ o: CatalogOracle) -> some View {
        let store = BindersStore.shared
        let mine = store.liveWants.filter { $0.oracleId == o.oracleId }
        let n = mine.reduce(0) { $0 + $1.qty }
        return Button {
            let shown = preview ?? owned.first?.printing ?? printings.first
            var items = [T1MenuItem(title: "Any printing") { want(o, nil) }]
            if let shown { items.append(T1MenuItem(title: "Only \(shown.setLabel)") { want(o, shown) }) }
            items.append(T1MenuItem(title: "Pick a printing…", detail: "One printing, or one finish") {
                T1Overlays.shared.present(full: true) {
                    WantPrintingPanel(oracleId: o.oracleId, from: "card") { added = $0; last = nil }.screen("want_printing")
                }
            })
            if !mine.isEmpty {
                items.append(T1MenuItem(title: "Open wants") { path?.wrappedValue.append(.wants) })
            }
            T1Overlays.shared.showMenu("Want \(o.name)", items)
        } label: {
            ListRow(title: n > 0 ? "Wanted · \(n)" : "Add to wants", detail: n > 0 ? "Want one more, or open your wants" : "Trades marks it when you get one")
        }.buttonStyle(.plain)
    }

    /// Makes the card a hero of where it was opened from: the deck or cube, the binder, or (from anywhere else)
    /// the collection.
    @ViewBuilder private func heroRow(_ o: CatalogOracle) -> some View {
        if let scope = HeroScope(context) {
            let store = HeroesStore.shared
            let on = store.isHero(o.oracleId, scope)
            let place: String = switch scope {
            case .collection: "your collection"
            case .list(let id): ListsStore.shared.list(id: id)?.name ?? "this list"
            case .binder(let id): BindersStore.shared.binder(id)?.name ?? "this binder"
            }
            Button {
                if !store.toggle(o.oracleId, scope) { error = "\(place.prefix(1).uppercased() + place.dropFirst()) has \(HeroesStore.limit) hero cards already." }
            } label: {
                ListRow(title: on ? "Hero of \(place)" : "Make it a hero",
                        detail: on ? "Tap to stop highlighting it" : "Highlighted in \(place) and where it's listed") {
                    if on { LabelText("Hero", color: T1.text) }
                }
            }.buttonStyle(.plain)
        }
    }

    private func want(_ o: CatalogOracle, _ p: CatalogPrinting?) {
        Task {
            do {
                try await BindersStore.shared.applyWants([WantOp(oracleId: o.oracleId, cardId: p?.cardId, delta: 1)], event: "want_added",
                                                         props: ["any_printing": p == nil, "finish": false, "has_max": false, "from": "card"])
                added = "Wanted 1 \(p?.setLabel ?? o.name)"
                last = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    /// Adds one copy of the shown printing to a list: pick the list, then the section.
    private func addToList(_ p: CatalogPrinting?) {
        guard let p else { return }
        let store = ListsStore.shared
        T1Overlays.shared.showMenu("Add \(p.setLabel) to", store.lists.map { l in
            T1MenuItem(title: l.name, detail: l.kind == .deck ? "\(l.format.capitalized) deck" : "Cube") {
                // The first menu closes before its action runs, so the section menu can open right after.
                let sections = l.kind == .deck ? ["main", "side", "maybe"] : ["main", "maybe"]
                T1Overlays.shared.showMenu(l.name, sections.map { board in
                    T1MenuItem(title: l.boardTitle(board)) {
                        store.add(listId: l.id, cardId: p.cardId, board: board, delta: 1)
                        last = nil
                        error = nil
                        added = "Added 1 \(p.setLabel) to \(l.name) · \(l.boardTitle(board))"
                    }
                })
            }
        })
    }

    private func hero(_ o: CatalogOracle, _ p: CatalogPrinting?) -> some View {
        HStack(alignment: .top, spacing: 16) {
            if let p { p.art(width: 146).id(p.cardId) } else { Rectangle().fill(T1.bg).frame(width: 146, height: 146 / CardArt.aspect) }
            VStack(alignment: .leading, spacing: 4) {
                Text(o.typeLine).font(T1.mono(13)).fixedSize(horizontal: false, vertical: true)
                if !o.manaCost.isEmpty { LabelText(o.manaCost) }
                LabelText("\(o.printings) printings")
            }
            Spacer(minLength: 0)
        }
        .padding(16).background(T1.surface)
    }

    private func ownedRow(_ it: CollectionItem, _ p: CatalogPrinting) -> some View {
        let price = prices[it.cardId]
        let _ = BindersStore.shared.version
        let detail = [price?.setName, it.condition, it.lang.uppercased(), price?.text(it.finish)].compactMap { $0 }.joined(separator: " · ")
        let place = BindersStore.shared.placementText(it)
        return VStack(spacing: 1) {
            HStack(spacing: 1) {
                Button { open = open == it.cardId ? nil : it.cardId; preview = p } label: {
                    HStack(spacing: 12) {
                        p.art(width: 36, finish: it.finish)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(p.setLabel) · \(it.finishLabel)").font(T1.mono(13)).lineLimit(1)
                            LabelText(detail)
                            if let place { LabelText(place, color: BindersStore.shared.forTrade(it.key).qty > 0 ? T1.accent : T1.muted) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                Text("\(it.qty)").font(T1.mono(17)).monospacedDigit().padding(.horizontal, 12)
                stepButton("−", enabled: busy != it.key) {
                    change(it.key, "Removed 1 \(p.setLabel)", CollectionOp(cardId: it.cardId, finish: it.finish, condition: it.condition, lang: it.lang, delta: -1))
                }
                stepButton("+", enabled: busy != it.key) {
                    change(it.key, "Added 1 \(p.setLabel)", CollectionOp(cardId: it.cardId, finish: it.finish, condition: it.condition, lang: it.lang, delta: 1))
                }
            }
            .background(T1.surface)
            if open == it.cardId {
                conditionRow(it, p)
                LanguageRow(lang: it.lang) {
                    LanguageChange.start(it, label: p.setLabel) { result in
                        switch result {
                        case .success(let r): last = r; added = nil; error = nil
                        case .failure(let e): error = e.localizedDescription
                        }
                    }
                }
                Button { changePrinting(it, place: nil) } label: {
                    ListRow(title: "Change printing", detail: "Or finish · keeps condition and binder") {
                        LabelText(p.setLabel, color: T1.text)
                    }
                }.buttonStyle(.plain)
                Button {
                    BinderMoveFlow.start(it, label: p.setLabel) { label in
                        if let label { added = label; last = nil }
                    }
                } label: {
                    ListRow(title: "Move", detail: BindersStore.shared.placementText(it) ?? "Unsorted \(it.qty)") {
                        LabelText("Binders", color: T1.text)
                    }
                }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 4) {
                    LabelText("History · \(p.setLabel)")
                    if let history {
                        if history.isEmpty { LabelText("No changes yet") }
                        ForEach(Array(history.enumerated()), id: \.offset) { _, h in
                            Text("\(h.at.prefix(10)) · \(h.delta > 0 ? "+\(h.delta)" : "\(h.delta)") \(Finish(rawValue: h.finish)?.label ?? h.finish) · \(h.source) → \(h.qtyAfter)")
                                .font(T1.mono(12)).monospacedDigit()
                                .foregroundStyle(h.undone ? T1.disabled : T1.text)
                                .strikethrough(h.undone)
                        }
                    } else {
                        LabelText("Loading…")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 12).background(T1.surface)
            }
        }
    }

    /// Condition of these copies: tap another to move one copy (or all of them) there.
    private func conditionRow(_ it: CollectionItem, _ p: CatalogPrinting) -> some View {
        HStack(spacing: 1) {
            ForEach(Conditions.all, id: \.self) { c in
                let on = c == it.condition
                Button { if !on { moveCondition(it, p, to: c) } } label: {
                    LabelText(c, color: on ? T1.ink : T1.text)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(on ? T1.text : T1.surface)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy == it.key)
                .accessibilityLabel(Conditions.name(c))
            }
        }
    }

    private func moveCondition(_ it: CollectionItem, _ p: CatalogPrinting, to c: String) {
        func move(_ n: Int) {
            change(it.key, "Moved \(n) \(p.setLabel) to \(c)", [
                CollectionOp(cardId: it.cardId, finish: it.finish, condition: it.condition, lang: it.lang, delta: -n),
                CollectionOp(cardId: it.cardId, finish: it.finish, condition: c, lang: it.lang, delta: n),
            ])
        }
        if it.qty == 1 { move(1); return }
        T1Overlays.shared.showMenu("Mark as \(Conditions.name(c).lowercased())", [
            T1MenuItem(title: "One copy") { move(1) },
            T1MenuItem(title: "All \(it.qty) copies") { move(it.qty) },
        ])
    }

    private func addRow(_ p: CatalogPrinting) -> some View {
        let price = prices[p.cardId]
        let detail = [price?.setName, CatalogPack.rarityName[p.rarity], p.releasedAt.isEmpty ? nil : String(p.releasedAt.prefix(4))]
            .compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 1) {
            // Tapping the art or name shows this printing large at the top.
            Button { preview = p } label: {
                HStack(spacing: 12) {
                    p.art(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.lang == "en" ? p.setLabel : "\(p.setLabel) · \(p.lang.uppercased())").font(T1.mono(13)).lineLimit(1)
                        LabelText(detail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            ForEach(p.finishList, id: \.self) { f in
                let k = "\(p.cardId)|\(f.rawValue)"
                Button {
                    let lang = Languages.forNew(p, picked: addLang)
                    change(k, "Added 1 \(p.setLabel) \(f.label) · \(addCondition)\(lang == "en" ? "" : " · \(lang.uppercased())")",
                           CollectionOp(cardId: p.cardId, finish: f.rawValue, condition: addCondition, lang: lang, delta: 1))
                } label: {
                    LabelText("+ \(f == .nonfoil ? "Card" : f.label)", color: busy == k ? T1.disabled : T1.text)
                        .padding(.horizontal, 12).frame(maxHeight: .infinity)
                        .background(T1.surfaceHover)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy == k)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(T1.surface)
    }

    private func stepButton(_ glyph: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph).font(T1.mono(22))
                .foregroundStyle(enabled ? T1.text : T1.disabled)
                .frame(width: 52, height: 52)
                .background(T1.surfaceHover)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func change(_ key: String, _ label: String, _ op: CollectionOp) { change(key, label, [op]) }

    private func change(_ key: String, _ label: String, _ ops: [CollectionOp]) {
        busy = key
        error = nil
        Task {
            defer { busy = nil }
            do {
                let res = try await col.apply(ops)
                last = (res.batchId, label)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func undo() async {
        guard let last else { return }
        busy = "undo"
        defer { busy = nil }
        do {
            try await col.undo(batchId: last.batchId)
            self.last = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
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
