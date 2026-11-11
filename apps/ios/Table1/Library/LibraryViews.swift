import SwiftUI
import Supabase

/* Library (Collection tab). Progressive disclosure: the home screen is a summary; the list, a card's
   printings and its history are each one tap deeper. Built ahead of the Figma Library screens on the
   existing kit (same as the web client); restyle once those land. */

enum LibraryRoute: Hashable {
    case allCards
    case add
    case addScan // Add cards with the scanner already up (the Scan cards control)
    case search // every card, from the Collection home's magnifier
    case card(String) // oracle id
    case cardIn(String, CardContext) // oracle id, opened from a deck/cube or a binder
    case lists(CardList.Kind)
    case list(String) // list id
    case versions(String) // list id
    case version(String, Int) // list id, version number
    case listAdd(String) // list id
    case findDeck(String?) // a deck finder job id (a tapped deck.found push), or nil for a new search
    case linePrinting(String, String, String, String, String, String) // list id, card id, board, finish, language, condition
    case importList(CardList.Kind)
    case trades
    case trade(String?) // trade id, nil for a new one
    case collectionImport
    case listStats(String) // list id
    case cubeSync(String) // list id: Sync with Cube Cobra
    case sideboardGuide(String) // list id
    case sideboardMatchup(String, String) // list id, matchup id
    case sideboardPick(String, String, String) // list id, matchup id, in | out
    case sideboardPool(String) // list id: the sideboard and Considering
    case sampleHand(String) // list id
    case drawOdds(String) // list id
    case samplePack(String) // list id
    case spice(String, String?, CardList.Kind, String, String) // a shared deck or cube's Spice: list id, link token, kind, format, title
    case binders
    case binder(String) // binder id, or BinderRoute.unsorted
    case wants
    case buy(BuySource) // the Buy screen for a deck, a cube, Wants or Missing (BuyViews.swift)
    case social(SocialRoute) // friends, profiles, sharing, trade matches (FriendsViews.swift)
    case rankings(String?) // a cube's rankings (list id), or every ranking of yours (RankingsViews.swift)
    case ranking(String) // ranking id
    case rankingPick(String, String) // ranking id, job (W U B R G M C L F)
    case rankingLists(String, String) // ranking id, job
    case rankingCard(String, String, String) // ranking id, oracle id, job
    case rankingCompare(String, String, String) // ranking id, the other ranking's id, job
    case rankingPack(String) // ranking id: P1P1 packs and pick history
    case rankingChanges(String) // ranking id: the change log
    case myDeckPhotos // Account → Deck photos: every photo of your decks (MyDeckPhotos.swift)
    case eventDeckPhotos(String) // event id: that event's Deck photos, opened from Account → Deck photos
    case support // Account → Support: questions and the guide (UI/Support.swift)
    case supportGuides // the guide's sections
    case supportTopic(String) // an FAQ topic key
    case supportFaq(String, String) // FAQ id, how it was reached (search | topic)
    case supportGuide(String, String?, String) // guide section id, the entry to scroll to, how it was reached
    /// An Insights screen pushed from the Library (a deck's archetype), so Back returns to the deck.
    indirect case insights(InsightsRoute)

    /// The Insights routes on top of a Library path (InsightsRoute.library the other way round): an Insights screen's
    /// own Library pushes (an example list's cards) stay plain Library routes.
    static func insights(_ path: Binding<[LibraryRoute]>) -> Binding<[InsightsRoute]> {
        Binding(
            get: {
                let routes = path.wrappedValue.drop { if case .insights = $0 { false } else { true } }
                return routes.map { if case .insights(let r) = $0 { r } else { .library($0) } }
            },
            set: { routes in
                let base = path.wrappedValue.prefix { if case .insights = $0 { false } else { true } }
                path.wrappedValue = Array(base) + routes.map { if case .library(let r) = $0 { r } else { .insights($0) } }
            })
    }
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
        case .search: "card_search"
        case .card, .cardIn: "card_detail"
        case .insights: "insights"
        case .lists(let kind): kind == .deck ? "decks" : "cubes"
        case .list(let id): ListsStore.shared.list(id: id)?.kind == .cube ? "cube" : "deck"
        case .versions, .version: "list_versions"
        case .listAdd: "list_add"
        case .findDeck: "deck_finder"
        case .linePrinting: "list_printing"
        case .importList: "list_import"
        case .cubeSync: "cube_sync"
        case .sideboardGuide: "sideboard_guide"
        case .sideboardMatchup: "sideboard_matchup"
        case .sideboardPick(_, _, let side): side == "in" ? "sideboard_in" : "sideboard_out"
        case .sideboardPool: "sideboard_pool"
        case .trades: "trades"
        case .trade: "trade"
        case .collectionImport: "collection_import"
        case .listStats(let id): ListsStore.shared.list(id: id)?.kind == .cube ? "cube_stats" : "deck_stats"
        case .sampleHand: "sample_hand"
        case .drawOdds: "draw_odds"
        case .samplePack: "sample_pack"
        case .spice(_, _, let kind, _, _): kind == .cube ? "cube_spice" : "deck_spice"
        case .binders: "binders"
        case .binder: "binder"
        case .wants: "wants"
        case .buy: "buy"
        case .social(let r): r.screenName
        case .rankings: "rankings"
        case .ranking: "ranking"
        case .rankingPick: "ranking_screen"
        case .rankingLists: "ranking_lists"
        case .rankingCard: "ranking_card"
        case .rankingCompare: "ranking_compare"
        case .rankingPack: "ranking_pack"
        case .rankingChanges: "ranking_changes"
        case .myDeckPhotos: "my_deck_photos"
        case .eventDeckPhotos: "deck_photos"
        case .support: "support"
        case .supportGuides: "support_guides"
        case .supportTopic: "support_topic"
        case .supportFaq: "support_faq"
        case .supportGuide: "support_guide"
        }
    }

    @ViewBuilder private var screen: some View {
        switch route {
        case .allCards: AllCardsView(path: $path)
        case .add: AddCardsView(path: $path)
        case .addScan: AddCardsView(path: $path, scanOnOpen: true)
        case .search: AddCardsView(path: $path, search: true)
        case .card(let id): CardDetailView(oracleId: id, path: $path)
        case .cardIn(let id, let context): CardDetailView(oracleId: id, path: $path, context: context)
        case .lists(let kind): ListsView(kind: kind, path: $path)
        case .list(let id): ListDetailView(listId: id, path: $path)
        case .versions(let id): ListVersionsView(listId: id, path: $path)
        case .version(let id, let n): ListVersionView(listId: id, number: n, path: $path)
        case .listAdd(let id): ListAddCardsView(listId: id, path: $path)
        case .findDeck(let job): DeckFinderView(path: $path, jobId: job)
        case .linePrinting(let l, let c, let b, let f, let lang, let cond):
            ChangePrintingView(target: .listLine(listId: l, cardId: c, board: b, finish: f, lang: lang, cond: cond))
        case .importList(let kind): ListImportView(kind: kind, path: $path)
        case .trades: TradesView(path: $path)
        case .trade(let id): TradeView(tradeId: id, path: $path)
        case .collectionImport: CollectionImportView(path: $path)
        case .listStats(let id): ListStatsView(listId: id, path: $path)
        case .cubeSync(let id): CubeSyncView(listId: id, path: $path)
        case .sideboardGuide(let id): SideboardGuideView(listId: id, path: $path)
        case .sideboardMatchup(let id, let m): SideboardMatchupView(listId: id, matchupId: m, path: $path)
        case .sideboardPick(let id, let m, let side): SideboardPickView(listId: id, matchupId: m, side: side == "in" ? .in : .out)
        case .sideboardPool(let id): SideboardPoolView(listId: id)
        case .sampleHand(let id): SampleHandView(listId: id)
        case .drawOdds(let id): DrawOddsView(listId: id)
        case .samplePack(let id): SamplePackView(listId: id)
        case .spice(let id, let token, let kind, let format, let title):
            SpiceView(listId: id, token: token, kind: kind, format: format, title: title, path: $path)
        case .binders: BindersView(path: $path)
        case .binder(let id): BinderView(binderId: id, path: $path)
        case .wants: WantsView(path: $path)
        case .buy(let source): BuyView(source: source, path: $path)
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
        case .myDeckPhotos: MyDeckPhotosView(path: $path)
        case .eventDeckPhotos(let id): DeckPhotosView(eventId: id)
        case .support: SupportView(path: $path)
        case .supportGuides: SupportGuidesView(path: $path)
        case .supportTopic(let key): SupportTopicView(topic: key, path: $path)
        case .supportFaq(let id, let from): SupportFaqView(id: id, from: from, path: $path)
        case .supportGuide(let section, let entry, let from): SupportGuideView(section: section, entry: entry, from: from)
        case .insights(let r): InsightsDestination(route: r, path: LibraryRoute.insights($path))
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

/// The Collection tab (Figma 325:10820): the collection as a shelf of its hero art, then a shelf each of decks,
/// binders and cubes (yours, then the ones you follow), with Trade · Wants · Import along the bottom. + adds cards
/// or makes a deck, binder or cube; the magnifier searches every card; the camera (Figma 327:8076) scans a pile of
/// cards and adds them all to the collection, a deck, cube, binder, wants or a trade.
struct LibraryHomeView: View {
    @Binding var path: [LibraryRoute]
    private var col: CollectionStore { CollectionStore.shared }
    private var lists: ListsStore { ListsStore.shared }
    private var binders: BindersStore { BindersStore.shared }
    /// Shelf art by scope key (`HeroScope.key`): heroes first, else the card the place holds most.
    @State private var art: [String: [CatalogPrinting]] = [:]
    /// What the last scan added, with its Undo when it has one.
    @State private var scanAdded: (label: String, undo: CardUndo?)?
    @State private var undoing = false
    @State private var scanError: String?

    var body: some View {
        T1Screen {
            HStack(spacing: 1) {
                Text("COLLECTION").font(T1.mono(12)).tracking(2).lineLimit(1)
                    .padding(.leading, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                T1IconButton(icon: .plus, label: "Add") { add() }
                T1IconButton(icon: .search, label: "Search cards") { tap("search"); path.append(.search) }
                T1IconButton(icon: .photoCamera, label: "Scan cards") { scan() }
            }
            .background(T1.bg)
            if let error = col.error { Notice(error, error: true) }
            if let scanError { Notice(scanError, error: true) }
            if let scanAdded {
                HStack(spacing: 12) {
                    LabelText(scanAdded.label)
                    Spacer(minLength: 0)
                    if scanAdded.undo != nil { BarButton(undoing ? "Undoing…" : "Undo") { undoScan() } }
                }
                .padding(.horizontal, 16).padding(.vertical, 12).background(T1.surface)
            }
            if let waiting = col.outboxNotice { Notice(waiting) }
            ScrollView {
                VStack(spacing: 0) {
                    collectionShelf
                    shelf(icon: .decks, title: "Decks", open: .lists(.deck)) {
                        ForEach(lists.lists(.deck)) { l in
                            ShelfTile(art: art[HeroScope.list(l.id).key]?.first, title: l.name,
                                      subtitle: l.eventName ?? formatName(l.format)) { path.append(.list(l.id)) }
                        }
                        followed("deck")
                        if lists.lists(.deck).isEmpty { ShelfTile(art: nil, title: "New deck", subtitle: "Build or import") { newList(.deck) } }
                    }
                    shelf(icon: .binders, title: "Binders", open: .binders) {
                        ForEach(binders.binders) { b in
                            ShelfTile(art: art[HeroScope.binder(b.id).key]?.first, title: b.name, subtitle: nil) { path.append(.binder(b.id)) }
                        }
                        followed("binder")
                        if binders.binders.isEmpty { ShelfTile(art: nil, title: "New binder", subtitle: "Where your copies are") { newBinder() } }
                    }
                    shelf(icon: .cubes, title: "Cubes", open: .lists(.cube)) {
                        ForEach(lists.lists(.cube)) { l in
                            ShelfTile(art: art[HeroScope.list(l.id).key]?.first, title: l.name, subtitle: nil) { path.append(.list(l.id)) }
                        }
                        followed("cube")
                        if lists.lists(.cube).isEmpty { ShelfTile(art: nil, title: "New cube", subtitle: "Build or import") { newList(.cube) } }
                    }
                }
                .padding(.bottom, 64)
            }
            .refreshable { await col.sync(); await FollowsStore.shared.load() }
            HStack(spacing: 1) {
                action("Trade") { path.append(.trades) }
                action("Wants") { path.append(.wants) }
                action("Import") { path.append(.collectionImport) }
            }
        }
        .task { if FollowsStore.shared.items == nil { await FollowsStore.shared.load() } }
        .task(id: col.version) { await PriceBook.shared.load(col.items.values.map(\.cardId)) }
        #if DEBUG
        // Design QA: `-T1ScanDemo [addto]` opens the scanner with the demo collection's first cards already scanned
        // (the Simulator has no camera), and with `addto` Add to over it.
        .task(id: CatalogStore.shared.generation) { scanDemo() }
        #endif
        .task(id: artKey) { await loadArt() }
    }

    // MARK: pieces

    /// The whole collection: up to two hero arts side by side, cards and value along the bottom. Opens All cards.
    private var collectionShelf: some View {
        let s = col.summary
        let heroes = Array((art[HeroScope.collection.key] ?? []).prefix(2))
        return Button { path.append(.allCards) } label: {
            ZStack(alignment: .bottom) {
                HStack(spacing: 0) {
                    if heroes.isEmpty { T1.surface } else { ForEach(heroes, id: \.cardId) { CardArtCrop(printing: $0) } }
                }
                T1.bg.opacity(0.6)
                HStack(spacing: 0) {
                    ShelfText(s.map { $0.totalQty.formatted() } ?? (col.ready ? "0" : "…"), size: 9, color: T1.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let s { ShelfText(money(s.valueUsd, "USD"), size: 9, color: T1.muted) }
                }
                .padding(16)
            }
            .frame(height: 179)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("All cards, \(s?.totalQty ?? 0) cards")
    }

    private func shelf<Tiles: View>(icon: T1Icon, title: String, open: LibraryRoute, @ViewBuilder tiles: () -> Tiles) -> some View {
        VStack(spacing: 0) {
            Button { path.append(open) } label: {
                HStack(spacing: 8) {
                    icon.fill(T1.text).frame(width: 18, height: 18)
                    Text(title.uppercased()).font(T1.mono(12)).tracking(2).lineLimit(1)
                    Spacer(minLength: 0)
                    T1.arrowRightGlyph
                }
                .padding(.leading, 16)
                .frame(height: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 1) { tiles() }
            }
            .frame(height: ShelfTile.height)
        }
        .padding(.top, 32)
    }

    /// Items of this kind you follow, after your own: the owner's name under the title.
    @ViewBuilder private func followed(_ kind: String) -> some View {
        ForEach((FollowsStore.shared.items ?? []).filter { $0.kind == kind && $0.available }) { f in
            ShelfTile(art: art["follow:\(f.id)"]?.first, title: f.title, subtitle: f.owner?.displayName, note: f.unseen > 0 ? "\(f.unseen) new" : nil) {
                if let r = FollowsStore.route(f) { path.append(.social(r)) }
            }
        }
    }

    private func action(_ title: String, _ go: @escaping () -> Void) -> some View {
        Button { tap(title.lowercased()); go() } label: {
            ShelfText(title, size: 11, color: T1.text)
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(T1.bg)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: actions

    private func add() {
        tap("add")
        T1Overlays.shared.showMenu(nil, [
            T1MenuItem(title: "Add cards", detail: "Search, Scryfall syntax or scan") { path.append(.add) },
            T1MenuItem(title: "New deck") { newList(.deck) },
            T1MenuItem(title: "New binder") { newBinder() },
            T1MenuItem(title: "New cube") { newList(.cube) },
        ])
    }

    private func newList(_ kind: CardList.Kind) {
        T1Overlays.shared.present {
            NewListPanel(kind: kind, created: { id in path.append(.list(id)) }, find: { path.append(.findDeck(nil)) },
                         importList: { path.append(.importList(kind)) })
        }
    }

    private func newBinder() {
        T1Overlays.shared.present { BinderEditPanel(binder: nil) { id in path.append(.binder(id)) } }
    }

    private func tap(_ target: String) { Telemetry.capture("collection_home_tap", ["target": target]) }

    // MARK: scan

    /// The camera: scan as many cards as you like, then Add opens Add to over the scanner (the camera held meanwhile).
    /// Closing Add to goes back to the scanner with the cards kept; picking a place adds them all and closes both.
    private func scan() {
        tap("scan")
        scanError = nil
        let hold = ScanHold()
        T1Overlays.shared.present(full: true, swipeBack: false) {
            CardScanView(title: "Scan cards", doneLabel: "Add", hold: hold, onDone: { cards in
                guard !cards.isEmpty else { return }
                hold.on = true
                addScanned(cards, hold: hold)
            }, onCancel: {
                Telemetry.capture("scan_session_ended", ["context": "collection", "cards": 0, "exact": 0, "cancelled": true])
                T1Overlays.shared.dismissPanel()
            })
            .screen("card_scanner")
        }
    }

    private func addScanned(_ cards: [ScannedCard], hold: ScanHold) {
        let lines = ScanBatch.lines(cards)
        var printings: [String: CatalogPrinting] = [:], oracleIds: [String: String] = [:]
        for c in cards { printings[c.printing.cardId] = c.printing; oracleIds[c.printing.cardId] = c.oracle.oracleId }
        guard let first = cards.last else { return }
        T1Overlays.shared.present {
            AddToPanel(oracle: first.oracle, printings: printings, lines: lines, scope: "scan",
                       scanned: (cards.count == 1 ? "scanned card" : "scanned cards", oracleIds)) { label, undo in
                Telemetry.capture("scan_session_ended", ["context": "collection", "cards": cards.count,
                                                         "exact": cards.filter(\.exact).count, "cancelled": false])
                T1Overlays.shared.dismissPanel() // the scanner (Add to closed itself)
                scanAdded = (label, undo)
            }
            .onDisappear { hold.on = false }
            .screen("scan_add_to")
        }
    }

    #if DEBUG
    private func scanDemo() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-T1ScanDemo"), let db = CatalogStore.shared.db, T1Overlays.shared.panels.isEmpty else { return }
        let items = col.items.values.sorted { $0.cardId < $1.cardId }.prefix(4)
        let printings = db.printings(ids: items.map(\.cardId))
        let oracles = db.oracles(idxs: printings.values.map(\.oracleIdx))
        let cards = items.compactMap { it -> ScannedCard? in
            guard let p = printings[it.cardId], let o = oracles[p.oracleIdx] else { return nil }
            return ScannedCard(oracle: o, printing: p, finish: it.finish, condition: it.condition, exact: true)
        }
        guard !cards.isEmpty else { return }
        let hold = ScanHold()
        T1Overlays.shared.present(full: true, swipeBack: false) {
            CardScanView(title: "Scan cards", doneLabel: "Add", scanned: cards, hold: hold, onDone: { cards in
                hold.on = true
                addScanned(cards, hold: hold)
            }, onCancel: { T1Overlays.shared.dismissPanel() })
        }
        if i + 1 < args.count, args[i + 1] == "addto" { hold.on = true; addScanned(cards, hold: hold) }
    }
    #endif

    private func undoScan() {
        guard let undo = scanAdded?.undo, !undoing else { return }
        undoing = true
        Task {
            defer { undoing = false }
            do {
                try await undo.run()
                scanAdded = nil
            } catch {
                scanError = error.localizedDescription
            }
        }
    }

    // MARK: art

    private var artKey: String {
        "\(HeroesStore.shared.heroes)-\(CatalogStore.shared.generation)-\(col.version)-\(binders.version)-\(PriceBook.shared.version)-"
            + lists.lists.map { "\($0.id)\($0.current?.number ?? 0)" }.joined(separator: ",")
            + (FollowsStore.shared.items ?? []).map { "\($0.id)\($0.art ?? "")" }.joined(separator: ",")
    }

    private func loadArt() async {
        guard let db = CatalogStore.shared.db else { art = [:]; return }
        let basics = CatalogStore.shared.basics
        var places: [(key: String, heroes: [String], held: [String])] = []
        // The collection falls back to its most valuable cards.
        let prices = PriceBook.shared
        let items = col.items.values.filter { $0.qty > 0 && !basics.contains($0.cardId) }
        let byValue = items.sorted { (prices.usd($0.cardId, $0.finish) ?? 0) > (prices.usd($1.cardId, $1.finish) ?? 0) }.map(\.cardId)
        places.append((HeroScope.collection.key, HeroesStore.shared.heroes(.collection), byValue))
        for l in lists.lists {
            places.append((HeroScope.list(l.id).key, HeroesStore.shared.heroes(.list(l.id)),
                           l.entries.filter { $0.board != "side" && $0.board != "maybe" }.sorted { $0.qty > $1.qty }.map(\.cardId)))
        }
        for b in binders.binders {
            places.append((HeroScope.binder(b.id).key, HeroesStore.shared.heroes(.binder(b.id)),
                           binders.items(in: b.id, col.items).sorted { $0.qty > $1.qty }.map(\.item.cardId)))
        }
        // Followed items: the printing the server picked the same way (contract/follows-2026-10-25.md § Follow art).
        let followed = (FollowsStore.shared.items ?? []).compactMap { f in f.available ? f.art.map { (f.id, $0) } : nil }
        art = await Task.detached(priority: .userInitiated) {
            var m = Dictionary(places.map { p in (p.key, ShelfArt.printings(heroes: p.heroes, held: p.held, basics: basics, count: 2, db)) },
                               uniquingKeysWith: { a, _ in a })
            let found = db.printings(ids: followed.map(\.1))
            for (id, card) in followed { if let p = found[card] { m["follow:\(id)"] = [p] } }
            return m
        }.value
    }
}

enum ShelfArt {
    /// A shelf tile's art: the place's heroes (in the printing it holds), topped up with the first cards it holds
    /// that aren't basic lands, up to `count`, one per card.
    nonisolated static func printings(heroes: [String], held: [String], basics: Set<String>, count: Int, _ db: CatalogDB) -> [CatalogPrinting] {
        var out = HeroArt.printings(heroes, held: held, db)
        guard out.count < count else { return Array(out.prefix(count)) }
        var seen = Set(out.map(\.oracleIdx))
        let candidates = Array(held.filter { !basics.contains($0) }.prefix(60))
        let found = db.printings(ids: candidates)
        for id in candidates where out.count < count {
            if let p = found[id], seen.insert(p.oracleIdx).inserted { out.append(p) }
        }
        return out
    }
}

/// Uppercase mono with the shelves' tracking.
private struct ShelfText: View {
    let text: String
    let size: CGFloat
    let color: Color
    init(_ text: String, size: CGFloat, color: Color) { self.text = text; self.size = size; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(T1.mono(size)).tracking(1.5).foregroundStyle(color).lineLimit(1)
    }
}

/// One deck, binder or cube on a shelf: its art under a scrim, name and a detail line at the bottom.
struct ShelfTile: View {
    static let width: CGFloat = 258
    static let height: CGFloat = 135
    let art: CatalogPrinting?
    let title: String
    let subtitle: String?
    var note: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                CardArtCrop(printing: art)
                T1.bg.opacity(0.6)
                HStack(alignment: .bottom, spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        ShelfText(title, size: 11, color: T1.text)
                        if let subtitle, !subtitle.isEmpty { ShelfText(subtitle, size: 9, color: T1.muted) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let note { ShelfText(note, size: 9, color: T1.accent) }
                }
                .padding(16)
            }
            .frame(width: Self.width, height: Self.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension T1 {
    /// The shelf header's arrow in its 50 × 50 tap area.
    static var arrowRightGlyph: some View {
        T1Icon.arrowRight.fill(T1.text).frame(width: 18, height: 18).frame(width: 50, height: 50)
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
    /// Search (the Collection home's magnifier): no scanner, and each card says how many you own.
    var search = false
    @Environment(\.dismiss) private var dismiss
    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var query = ""
    @State private var hits: [CatalogOracle] = []
    /// Copies owned per oracle idx (search only).
    @State private var owned: [Int: Int] = [:]
    @State private var covers: [Int: CatalogPrinting] = [:]
    @State private var result: CardSearchEngine.Result?
    @State private var scanned: (batchId: String, label: String)?
    @State private var error: String?
    @State private var busy = false
    @State private var autoScanned = false
    @State private var opened = false
    @FocusState private var focused: Bool

    var body: some View {
        T1Screen {
            Bar(title: search ? "Search" : "Add cards", back: { dismiss() })
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
            CardSearchBar(query: $query, prompt: search ? "A card, deck, cube or binder" : "Lightning Bolt, or t:dragon c:r",
                          scan: search ? nil : { scan() }, focused: $focused)
            CardSearchStatus(query: query, result: result)
            HairlineList {
                if search { ListHitsSections(query: query, path: $path) }
                if catalog.phase == .ready && CardName.norm(query).count >= 2 && hits.isEmpty && !CardQuery.hasSyntax(query) {
                    LoadingRow(text: "No card by that name")
                }
                ForEach(hits, id: \.idx) { o in
                    Button { path.append(.card(o.oracleId)) } label: {
                        CardRow(printing: covers[o.idx], title: o.name, detail: o.manaCost.isEmpty ? o.typeLine : "\(o.typeLine) · \(o.manaCost)") {
                            if !search {
                                Text("\(o.printings)").font(T1.mono(15)).monospacedDigit().foregroundStyle(T1.muted)
                            } else if let n = owned[o.idx], n > 0 {
                                Text("\(n)").font(T1.mono(17)).monospacedDigit()
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
        .onAppear {
            catalog.load(userInitiated: true)
            #if DEBUG
            // Design QA: `-T1LibraryDemo search -T1SearchQuery tr` opens Search with a query typed.
            if search, query.isEmpty, let q = UserDefaults.standard.string(forKey: "T1SearchQuery") { query = q }
            #endif
            // Only as the screen opens: coming back from a card's page leaves the keyboard down.
            guard !opened else { return }
            opened = true
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
        .task(id: "\(search)-\(CollectionStore.shared.version)-\(catalog.generation)") {
            guard search, let db = catalog.db else { return }
            let items = CollectionStore.shared.items.values.map { ($0.cardId, $0.qty) }
            owned = await Task.detached(priority: .userInitiated) {
                let printings = db.printings(ids: Array(Set(items.map(\.0))))
                var out: [Int: Int] = [:]
                for (id, qty) in items { if let p = printings[id] { out[p.oracleIdx, default: 0] += qty } }
                return out
            }.value
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
