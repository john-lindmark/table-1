import SwiftUI
import Supabase

/* Library (Collection tab). Progressive disclosure: the home screen is a summary; the list, a card's
   printings and its history are each one tap deeper. Built ahead of the Figma Library screens on the
   existing kit (same as the web client); restyle once those land. */

enum LibraryRoute: Hashable {
    case allCards
    case add
    case card(String) // oracle id
    case lists(CardList.Kind)
    case list(String) // list id
    case versions(String) // list id
    case version(String, Int) // list id, version number
    case listAdd(String) // list id
    case findDeck
    case linePrinting(String, String, String, String) // list id, card id, board, finish
    case importList(CardList.Kind)
}

/// Every Library screen behind a route, shared by the Collection tab and the Debug demo.
struct LibraryDestination: View {
    let route: LibraryRoute
    @Binding var path: [LibraryRoute]
    var body: some View {
        switch route {
        case .allCards: AllCardsView(path: $path)
        case .add: AddCardsView(path: $path)
        case .card(let id): CardDetailView(oracleId: id, path: $path)
        case .lists(let kind): ListsView(kind: kind, path: $path)
        case .list(let id): ListDetailView(listId: id, path: $path)
        case .versions(let id): ListVersionsView(listId: id, path: $path)
        case .version(let id, let n): ListVersionView(listId: id, number: n, path: $path)
        case .listAdd(let id): ListAddCardsView(listId: id, path: $path)
        case .findDeck: DeckFinderView(path: $path)
        case .linePrinting(let l, let c, let b, let f): LinePrintingView(listId: l, cardId: c, board: b, finish: f)
        case .importList(let kind): ListImportView(kind: kind, path: $path)
        }
    }
}

private func money(_ n: Double?, _ code: String) -> String {
    guard let n else { return "—" }
    return n.formatted(.currency(code: code).precision(.fractionLength(0)))
}

/// A Table 1 row that reads as unavailable (flat disabled color, no dimming).
private struct SoonRow: View {
    let title: String
    var body: some View {
        HStack {
            Text(title).font(T1.mono(14)).foregroundStyle(T1.disabled)
            Spacer(minLength: 0)
            LabelText("Soon", color: T1.disabled)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(T1.surface)
    }
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

    var body: some View {
        let s = col.summary
        T1Screen {
            Bar(title: "Library", subtitle: col.isDemo ? "Demo data" : col.syncing ? "Syncing…" : nil)
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
                    ListRow(title: "All cards", detail: s.map { "\($0.uniquePrintings.formatted()) printings" }) {
                        if let s { Text(s.uniqueCards.formatted()).font(T1.mono(17)).monospacedDigit() }
                    }
                }.buttonStyle(.plain)
                Button { path.append(.add) } label: { ListRow(title: "Add cards", detail: "Search by name") }.buttonStyle(.plain)
                listsRow(.deck, "Decks")
                listsRow(.cube, "Cubes")
                SoonRow(title: "Trades")
            }
        }
        .refreshable { await col.sync() }
    }

    /// Decks and cubes open once there are any (only the Debug demo until L3 ships them).
    @ViewBuilder private func listsRow(_ kind: CardList.Kind, _ title: String) -> some View {
        let lists = ListsStore.shared.lists(kind)
        if lists.isEmpty {
            SoonRow(title: title)
        } else {
            Button { path.append(.lists(kind)) } label: {
                ListRow(title: title, detail: lists.prefix(3).map(\.name).joined(separator: " · ")) {
                    Text(lists.count.formatted()).font(T1.mono(17)).monospacedDigit()
                }
            }.buttonStyle(.plain)
        }
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
            if let p = printings[it.cardId], it.qty > g.coverQty { g.cover = p; g.coverQty = it.qty }
            by[key] = g
        }
        return Array(by.values)
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
    @State private var sort = "name"
    @AppStorage("library.allCards.grid") private var grid = false

    private var shown: [CardGroup] {
        let n = CardName.norm(query)
        var list = n.isEmpty ? groups : groups.filter { $0.norm.contains(n) || CardName.norm($0.type).contains(n) }
        switch sort {
        case "recent": list.sort { $0.lastSeq > $1.lastSeq }
        case "qty": list.sort { $0.qty != $1.qty ? $0.qty > $1.qty : $0.norm < $1.norm }
        default: list.sort { $0.norm < $1.norm }
        }
        return list
    }

    var body: some View {
        T1Screen {
            Bar(title: "All cards", subtitle: col.summary.map { "\($0.totalQty.formatted()) cards" }) {
                HStack(spacing: 20) {
                    BarButton(grid ? "List" : "Grid") { grid.toggle() }
                    BarButton("Back") { dismiss() }
                }
            }
            if let error = col.error { Notice(error, error: true) }
            CatalogStatus(catalog: catalog)
            T1SearchField(text: $query, prompt: "Name or type")
            T1Segmented(options: [("name", "A–Z"), ("recent", "Recent"), ("qty", "Most")], selection: $sort)
            if catalog.phase == .ready && built {
                if groups.isEmpty && col.ready {
                    Button { path.append(.add) } label: { ListRow(title: "No cards yet", detail: "Add your first card") }.buttonStyle(.plain)
                }
                let shown = shown
                if shown.isEmpty && !groups.isEmpty { ListRow(title: "No matches", detail: "Nothing in your collection by that name or type") }
                if grid {
                    CardGrid(items: shown) { g, width in
                        Button { if g.known { path.append(.card(g.id)) } } label: {
                            CardTile(printing: g.cover, name: g.name, qty: g.qty, width: width)
                        }.buttonStyle(.plain)
                    }
                } else {
                    HairlineList {
                        ForEach(shown) { g in
                            Button { if g.known { path.append(.card(g.id)) } } label: {
                                CardRow(printing: g.cover, title: g.name, detail: "\(g.printings) printing\(g.printings == 1 ? "" : "s") · \(g.type)") {
                                    Text("\(g.qty)").font(T1.mono(17)).monospacedDigit()
                                }
                            }.buttonStyle(.plain)
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
    @FocusState private var focused: Bool

    var body: some View {
        T1Screen {
            Bar(title: "Add cards") { BarButton("Back") { dismiss() } }
            CatalogStatus(catalog: catalog)
            T1SearchField(text: $query, prompt: "Lightning Bolt").focused($focused)
            HairlineList {
                if catalog.phase == .ready && CardName.norm(query).count >= 2 && hits.isEmpty {
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
            try? await Task.sleep(for: .milliseconds(120)) // let typing settle
            if Task.isCancelled { return }
            let found = await Task.detached(priority: .userInitiated) { () -> ([CatalogOracle], [Int: CatalogPrinting]) in
                let hits = db.search(q)
                return (hits, db.covers(oracleIdxs: hits.map(\.idx)))
            }.value
            if !Task.isCancelled { hits = found.0; covers = found.1 }
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

struct CardDetailView: View {
    let oracleId: String
    var path: Binding<[LibraryRoute]>?
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

    private var owned: [(item: CollectionItem, printing: CatalogPrinting)] {
        let byId = Dictionary(printings.map { ($0.cardId, $0) }, uniquingKeysWith: { a, _ in a })
        return col.items.values.compactMap { it in byId[it.cardId].map { (it, $0) } }
            .sorted { $0.printing.ord != $1.printing.ord ? $0.printing.ord < $1.printing.ord : $0.item.key < $1.item.key }
    }

    var body: some View {
        let owned = owned
        let total = owned.reduce(0) { $0 + $1.item.qty }
        T1Screen {
            Bar(title: oracle?.name ?? "Card", subtitle: oracle == nil ? nil : "\(total) in collection") {
                BarButton("Back") { dismiss() }
            }
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
                    hero(oracle, preview ?? owned.first?.printing ?? printings.first)
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
                    Section1("Add a printing · \(printings.count)")
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
            printings = found.1
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
        let detail = [price?.setName, it.condition, it.lang.uppercased(), price?.text(it.finish)].compactMap { $0 }.joined(separator: " · ")
        return VStack(spacing: 1) {
            HStack(spacing: 1) {
                Button { open = open == it.cardId ? nil : it.cardId; preview = p } label: {
                    HStack(spacing: 12) {
                        p.art(width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(p.setLabel) · \(it.finishLabel)").font(T1.mono(13)).lineLimit(1)
                            LabelText(detail)
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
                    change(k, "Added 1 \(p.setLabel) \(f.label)", CollectionOp(cardId: p.cardId, finish: f.rawValue, delta: 1))
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

    private func change(_ key: String, _ label: String, _ op: CollectionOp) {
        busy = key
        error = nil
        Task {
            defer { busy = nil }
            do {
                let res = try await col.apply([op])
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
