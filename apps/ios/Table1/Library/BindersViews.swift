import SwiftUI

/* Binders and wants screens (contract/binders-wants-2026-10-17.md). Library home → Binders: Unsorted and each
   binder; a binder lists its cards and can be renamed, flagged for trade or deleted. Library home → Wants: the
   wishlist, then everything a deck or cube is missing. Card detail moves copies between binders with
   `BinderMoveFlow`. */

private func money(_ n: Double?) -> String? {
    n.map { $0.formatted(.currency(code: "USD").precision(.fractionLength(0))) }
}

/// Market value (USD) of the given copies.
@MainActor
private func value(_ rows: [(item: CollectionItem, qty: Int)]) -> Double? {
    let priced = rows.compactMap { r in PriceBook.shared.usd(r.item.cardId, r.item.finish).map { $0 * Double(r.qty) } }
    return priced.isEmpty ? nil : priced.reduce(0, +)
}

// MARK: binders

struct BindersView: View {
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var store: BindersStore { BindersStore.shared }
    private var col: CollectionStore { CollectionStore.shared }
    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var query = ""
    /// Owned cards matching the search, with where their copies are.
    @State private var found: [(group: CardGroup, place: String)] = []
    /// Each binder's hero cards, as the printings it holds.
    @State private var heroArt: [String: [CatalogPrinting]] = [:]

    var body: some View {
        let totals = store.totals(col.items)
        let _ = store.version
        T1Screen {
            Bar(title: "Binders", subtitle: "\(store.binders.count) · \(store.binders.filter(\.forTrade).count) for trade", back: { dismiss() })
            if let error = store.error { Notice(error, error: true) }
            if !col.items.isEmpty { T1SearchField(text: $query, prompt: "Find a card in your binders") }
            HairlineList {
                if !query.isEmpty {
                    Section1("Cards · \(found.count)")
                    if found.isEmpty { ListRow(title: "No cards you own match") }
                    ForEach(found, id: \.group.id) { f in
                        Button { if f.group.known { path.append(.card(f.group.id)) } } label: {
                            CardRow(printing: f.group.cover, title: f.group.name, detail: f.place) {
                                Text("\(f.group.qty)").font(T1.mono(17)).monospacedDigit()
                            }
                        }.buttonStyle(.plain)
                    }
                } else {
                    Button { newBinder() } label: { ListRow(title: "New binder", detail: "A box, a deck box, a trade binder") }.buttonStyle(.plain)
                    Button { path.append(.binder(BinderRoute.unsorted)) } label: {
                        ListRow(title: "Unsorted", detail: "Copies not in a binder") {
                            Text(totals.unsorted.formatted()).font(T1.mono(17)).monospacedDigit()
                        }
                    }.buttonStyle(.plain)
                    if store.binders.contains(where: \.forTrade) { ShareRow(target: .forTrade, from: "binders", path: $path) }
                    ForEach(store.binders) { b in
                        let rows = store.items(in: b.id, col.items)
                        Button { path.append(.binder(b.id)) } label: {
                            HeroListRow(heroes: heroArt[b.id] ?? [], title: b.name, detail: [b.forTrade ? "For trade" : nil, money(value(rows))].compactMap { $0 }.joined(separator: " · ")) {
                                Text((totals.byBinder[b.id] ?? 0).formatted()).font(T1.mono(17)).monospacedDigit()
                                    .foregroundStyle(b.forTrade ? T1.accent : T1.text)
                            }
                        }.buttonStyle(.plain)
                    }
                    if store.binders.isEmpty {
                        Notice("Binders say where your copies are. Flag one for trade and Trades offers its cards first when you give.")
                    }
                }
            }
        }
        .refreshable { await col.sync() }
        .task(id: col.version) { await PriceBook.shared.load(col.items.values.map(\.cardId)) }
        .task(id: "\(query)-\(col.version)-\(store.version)-\(catalog.generation)") { await search() }
        .task(id: "\(HeroesStore.shared.heroes)-\(catalog.generation)-\(store.version)") {
            guard let db = catalog.db else { return }
            let wanted = store.binders.compactMap { b -> (String, [String], [String])? in
                let h = HeroesStore.shared.heroes(.binder(b.id))
                return h.isEmpty ? nil : (b.id, h, store.items(in: b.id, col.items).sorted { $0.qty > $1.qty }.map(\.item.cardId))
            }
            heroArt = await Task.detached(priority: .userInitiated) {
                Dictionary(wanted.map { ($0.0, HeroArt.printings($0.1, held: $0.2, db)) }, uniquingKeysWith: { a, _ in a })
            }.value
        }
        .searchUsed(query, screen: "binders")
    }

    /// Every owned card matching the search, most copies first, each saying where its copies are:
    /// "Trade binder 2 · Box 1 1 · Unsorted 1".
    private func search() async {
        let q = query
        guard !q.isEmpty else { found = []; return }
        catalog.load(userInitiated: true)
        guard let db = catalog.db else { return }
        try? await Task.sleep(for: .milliseconds(120))
        if Task.isCancelled { return }
        let items = Array(col.items.values)
        let (groups, keyOf) = await Task.detached(priority: .userInitiated) { () -> ([CardGroup], [String: String]) in
            let printings = db.printings(ids: Array(Set(items.map(\.cardId))))
            let oracles = db.oracles(idxs: Array(Set(printings.values.map(\.oracleIdx))))
            var keyOf: [String: String] = [:]
            for it in items { keyOf[it.cardId] = printings[it.cardId].flatMap { oracles[$0.oracleIdx]?.oracleId } ?? it.cardId }
            let groups = CardGroup.build(items, db).filter { CardSearch.matches(q, name: $0.name, type: $0.type) }
                .sorted { $0.qty != $1.qty ? $0.qty > $1.qty : $0.norm < $1.norm }
            return (groups, keyOf)
        }.value
        if Task.isCancelled { return }
        var byBinder: [String: [String: Int]] = [:], unsorted: [String: Int] = [:]
        for it in items {
            guard let k = keyOf[it.cardId] else { continue }
            let p = store.placement(it)
            for (b, n) in p.binders { byBinder[k, default: [:]][b.name, default: 0] += n }
            unsorted[k, default: 0] += p.unsorted
        }
        found = groups.map { g in
            let named = (byBinder[g.id] ?? [:]).sorted { $0.key.lowercased() < $1.key.lowercased() }.map { "\($0.key) \($0.value)" }
            let u = unsorted[g.id] ?? 0
            return (g, (named + (u > 0 ? ["Unsorted \(u)"] : [])).joined(separator: " · "))
        }
    }

    private func newBinder() {
        T1Overlays.shared.present { BinderEditPanel(binder: nil) { id in path.append(.binder(id)) } }
    }
}

enum BinderRoute {
    /// The pseudo-binder id for copies no binder holds.
    static let unsorted = "unsorted"
}

/// Name and "for trade" for a new binder or an existing one.
struct BinderEditPanel: View {
    let binder: Binder?
    var created: ((String) -> Void)?
    @State private var name: String
    @State private var forTrade: Bool
    @State private var busy = false
    @State private var error: String?

    init(binder: Binder?, created: ((String) -> Void)? = nil) {
        self.binder = binder
        self.created = created
        _name = State(initialValue: binder?.name ?? "")
        _forTrade = State(initialValue: binder?.forTrade ?? false)
    }

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: binder == nil ? "New binder" : "Edit binder") { BarButton("Cancel") { T1Overlays.shared.dismissPanel() } }
            if let error { Notice(error, error: true) }
            Field(label: "Name", text: $name)
            T1Switch(title: "For trade", detail: "Trades offers these copies first when you give", isOn: $forTrade)
            BigAction(text: binder == nil ? "Create binder" : "Save", enabled: !trimmed.isEmpty, busy: busy) { save() }
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private func save() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let b = try await BindersStore.shared.save(id: binder?.id, name: String(trimmed.prefix(60)), forTrade: forTrade)
                T1Overlays.shared.dismissPanel()
                if binder == nil { created?(b.id) }
                if forTrade && binder?.forTrade != true { await SharingOffer.afterForTrade() }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// One binder's cards (or Unsorted's), grouped by card, most copies first.
struct BinderView: View {
    let binderId: String
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var store: BindersStore { BindersStore.shared }
    private var col: CollectionStore { CollectionStore.shared }
    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var groups: [CardGroup] = []
    @State private var query = ""
    @State private var confirmDelete = false
    @State private var printings = PrintingsDisclosure()
    @AppStorage("library.binder.layout") private var layout = CardLayout.list.rawValue
    @AppStorage("library.binder.grouping") private var groupingRaw = CardGrouping.none.rawValue
    @State private var keys: [String: GroupKeys] = [:]
    private var grouping: CardGrouping { CardGrouping(rawValue: groupingRaw) ?? .none }

    private var binder: Binder? { store.binder(binderId) }
    private var unsorted: Bool { binderId == BinderRoute.unsorted }

    var body: some View {
        let rows = store.items(in: unsorted ? nil : binderId, col.items)
        let copies = rows.reduce(0) { $0 + $1.qty }
        T1Screen {
            Bar(title: unsorted ? "Unsorted" : binder?.name ?? "Binder",
                subtitle: ["\(copies.formatted()) cards", binder?.forTrade == true ? "For trade" : nil, money(value(rows))].compactMap { $0 }.joined(separator: " · "),
                back: { dismiss() }) {
                HStack(spacing: 20) {
                    if let binder { BarButton("Edit") { menu(binder) } }
                    BarButton("View") { CardLayout.menu($layout, screen: "binder", printings: $printings, grouping: $groupingRaw, list: false) }
                }
            }
            if !unsorted && binder == nil { Notice("This binder was deleted.") }
            CatalogStatusRow(catalog: catalog)
            T1SearchField(text: $query, prompt: "Name or type")
            GeometryReader { geo in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        if let binder {
                            WhoSeesRow(kind: "binder", id: binder.id, name: binder.name, forTrade: binder.forTrade)
                            ShareRow(target: .item(kind: "binder", id: binder.id, name: binder.name, forTrade: binder.forTrade), from: "binder", path: $path)
                        }
                        if unsorted || binder != nil {
                            Button {
                                T1Overlays.shared.present(full: true) { BinderAddPanel(binderId: unsorted ? nil : binderId).screen("binder_add") }
                            } label: {
                                ListRow(title: "Add cards", detail: unsorted ? "New copies, or copies out of a binder" : "Move in copies you own, or add new ones")
                            }.buttonStyle(.plain)
                        }
                        let shown = query.isEmpty ? groups : groups.filter { CardSearch.matches(query, name: $0.name, type: $0.type) }
                        if shown.isEmpty && !groups.isEmpty { ListRow(title: "No cards match") }
                        if groups.isEmpty && catalog.phase == .ready {
                            Notice(unsorted ? "Every copy is in a binder." : "No cards here yet. Add cards moves in copies you own or adds new ones; trades and imports can fill it too.")
                        }
                        let sections = CardGroup.sections(shown, by: grouping, keys: keys)
                        if layout == CardLayout.stacks.rawValue {
                            // Grouped: one stack per group; None: stacks of ten.
                            StackRows(stacks: sections.flatMap { sec -> [(id: String, title: String?, cards: [StackCard])] in
                                let cards = tiles(sec.cards)
                                if grouping != .none {
                                    return [("st|\(sec.key)|\(printings.all)", "\(grouping.label(sec.key)) · \(sec.cards.reduce(0) { $0 + $1.qty })", cards)]
                                }
                                return stride(from: 0, to: cards.count, by: 10).map { i in
                                    ("st|\(printings.all)|\(i)", nil, Array(cards[i..<min(i + 10, cards.count)]))
                                }
                            }, width: ((geo.size.width - 1) / 2).rounded(.down)).id("st|\(grouping.rawValue)")
                        } else {
                            ForEach(sections, id: \.key) { sec in
                                if grouping != .none { Section1("\(grouping.label(sec.key)) · \(sec.cards.reduce(0) { $0 + $1.qty })").id("h|\(sec.key)") }
                                if layout == CardLayout.grid.rawValue {
                                    let width = ((geo.size.width - 2) / 3).rounded(.down)
                                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 1), count: 3), spacing: 1) {
                                        ForEach(tiles(sec.cards)) { c in
                                            Button(action: c.open) {
                                                CardTile(printing: c.printing, name: c.name, qty: c.qty, width: width, finish: c.finish, hero: c.hero)
                                            }.buttonStyle(.plain)
                                        }
                                    }
                                    .id("grid|\(sec.key)|\(printings.all)")
                                } else {
                                    ForEach(sec.cards) { g in
                                        CardGroupRows(group: g, detail: "\(g.printings) printing\(g.printings == 1 ? "" : "s") · \(g.type)",
                                                      hero: isHero(g), open: printings.open(g.id),
                                                      partDetail: { PriceBook.text(PriceBook.shared.usd($0.cardId, $0.finish)) },
                                                      toggle: { printings.toggle(g.id) },
                                                      tap: { _ in open(g) })
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .alert("Delete \(binder?.name ?? "this binder")?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                guard let binder else { return }
                Task {
                    do { try await store.delete(binder); dismiss() } catch { store.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its \(copies.formatted()) cards stay in your collection, Unsorted. This can't be undone.")
        }
        .searchUsed(query, screen: "binder")
        .task(id: "\(col.version)-\(store.version)-\(catalog.generation)") {
            catalog.load(userInitiated: true)
            guard let db = catalog.db else { return }
            let items = rows.map { r in CollectionItem(cardId: r.item.cardId, finish: r.item.finish, condition: r.item.condition, lang: r.item.lang, qty: r.qty, seq: r.item.seq) }
            (groups, keys) = await Task.detached(priority: .userInitiated) { () -> ([CardGroup], [String: GroupKeys]) in
                let g = CardGroup.build(items, db).sorted { $0.qty != $1.qty ? $0.qty > $1.qty : $0.norm < $1.norm }
                return (g, CardGroup.keys(g, db))
            }.value
            await PriceBook.shared.load(items.map(\.cardId))
        }
    }

    private func isHero(_ g: CardGroup) -> Bool { !unsorted && HeroesStore.shared.isHero(g.id, .binder(binderId)) }

    private func open(_ g: CardGroup) { if g.known { path.append(.cardIn(g.id, .binder(binderId))) } }

    /// Grid and stacks: one card per Oracle card, or with every printing expanded, one per printing and finish.
    private func tiles(_ shown: [CardGroup]) -> [StackCard] {
        shown.flatMap { g -> [StackCard] in
            guard printings.all, g.parts.count > 1 else {
                return [StackCard(id: g.id, printing: g.cover, name: g.name, qty: g.qty, finish: g.coverFinish, hero: isHero(g)) { open(g) }]
            }
            return g.parts.map { p in
                StackCard(id: "\(g.id)|\(p.id)", printing: p.printing, name: g.name, qty: p.qty, finish: p.finish, hero: isHero(g)) { open(g) }
            }
        }
    }

    private func menu(_ b: Binder) {
        T1Overlays.shared.showMenu(b.name, [
            T1MenuItem(title: "Rename") { T1Overlays.shared.present { BinderEditPanel(binder: b) } },
            T1MenuItem(title: b.forTrade ? "Not for trade" : "For trade", detail: b.forTrade ? "Trades stops offering these first" : "Trades offers these first when you give") {
                Task {
                    do {
                        try await store.save(id: b.id, name: b.name, forTrade: !b.forTrade)
                        if !b.forTrade { await SharingOffer.afterForTrade() }
                    } catch { store.error = error.localizedDescription }
                }
            },
            T1MenuItem(title: "Delete binder", destructive: true) { confirmDelete = true },
        ])
    }
}

/// Binder → Add cards: search the catalog; Move in takes one copy you own from elsewhere (`BinderRules.moveInSource`),
/// + New adds a new copy of the card's original printing straight into the binder (`binderId` nil = Unsorted).
struct BinderAddPanel: View {
    let binderId: String?
    private var store: BindersStore { BindersStore.shared }
    private var col: CollectionStore { CollectionStore.shared }
    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var query = ""
    @State private var hits: [CatalogOracle] = []
    @State private var covers: [Int: CatalogPrinting] = [:]
    @State private var result: CardSearchEngine.Result?
    /// Owned items by card (oracle idx).
    @State private var owned: [Int: [CollectionItem]] = [:]
    @State private var last: (batchId: String, label: String)?
    @State private var busy = false
    @State private var error: String?
    @AppStorage("library.addCondition") private var addCondition = "NM"
    @AppStorage("library.addLang") private var addLang = "en"
    @FocusState private var focused: Bool

    private var target: String { binderId.flatMap { store.binder($0)?.name } ?? "Unsorted" }

    var body: some View {
        let _ = store.version
        T1Screen {
            Bar(title: "Add to \(target)", back: { T1Overlays.shared.dismissPanel() })
            if let message = error ?? store.error { Notice(message, error: true) }
            CatalogStatusRow(catalog: catalog)
            if let last {
                HStack(spacing: 12) {
                    LabelText(last.label)
                    Spacer(minLength: 0)
                    BarButton("Undo") { undo(last.batchId) }
                }
                .padding(.horizontal, 16).padding(.vertical, 12).background(T1.surface)
            }
            CardSearchBar(query: $query, prompt: "Card name, or Scryfall syntax", scan: { scan() }, focused: $focused)
            CardSearchStatus(query: query, result: result)
            HairlineList {
                if query.isEmpty {
                    Notice("Move in takes a copy you own from Unsorted or another binder. + New adds a new copy (\(addCondition), original printing) to your collection, in \(target). Scan adds the cards you scan, new, in \(target).")
                    LanguageRow(lang: addLang, title: "New copies in") {
                        LanguagePicker.present(current: addLang, subtitle: "For new copies") { addLang = $0 }
                    }
                }
                ForEach(hits, id: \.idx) { o in row(o) }
            }
            BigAction(text: "Done", accent: false) { T1Overlays.shared.dismissPanel() }
        }
        .onAppear { focused = true }
        .task(id: "\(query)-\(catalog.generation)") {
            catalog.load(userInitiated: true)
            guard let db = catalog.db else { return }
            let q = query
            try? await Task.sleep(for: CardSearchEngine.debounce(q))
            if Task.isCancelled { return }
            let found = await Task.detached(priority: .userInitiated) { await CardSearchEngine.run(q, db) }.value
            if !Task.isCancelled { hits = found.hits; covers = found.covers; result = found }
        }
        .task(id: "\(col.version)-\(catalog.generation)") {
            guard let db = catalog.db else { return }
            let items = Array(col.items.values)
            owned = await Task.detached(priority: .userInitiated) { () -> [Int: [CollectionItem]] in
                let printings = db.printings(ids: Array(Set(items.map(\.cardId))))
                var out: [Int: [CollectionItem]] = [:]
                for it in items { if let p = printings[it.cardId] { out[p.oracleIdx, default: []].append(it) } }
                return out
            }.value
        }
    }

    private func row(_ o: CatalogOracle) -> some View {
        let items = owned[o.idx] ?? []
        let places = store.places(items)
        let here = places.filter { $0.from?.id == binderId }.reduce(0) { $0 + $1.qty }
        let elsewhere = places.filter { $0.from?.id != binderId }
        var where_: [String: Int] = [:]
        for pl in elsewhere { where_[pl.from?.name ?? "Unsorted", default: 0] += pl.qty }
        let detail = items.isEmpty ? "Not in your collection"
            : ([here > 0 ? "\(here) here" : nil] + where_.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }).compactMap { $0 }.joined(separator: " · ")
        let source = BinderRules.moveInSource(places, into: binderId)
        return HStack(spacing: 1) {
            CardRow(printing: covers[o.idx], title: o.name, detail: detail)
            if let source {
                action("Move in") { moveIn(o, source) }
            }
            action("+ New") { addNew(o) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func action(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            LabelText(title, color: busy ? T1.disabled : T1.text).padding(.horizontal, 12).frame(maxHeight: .infinity)
                .background(T1.surfaceHover).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func moveIn(_ o: CatalogOracle, _ s: (item: CollectionItem, from: String?)) {
        let fromName = s.from.flatMap { store.binder($0)?.name } ?? "Unsorted"
        run("Moved 1 \(o.name) from \(fromName)") {
            try await store.move([BinderMove(item: s.item, from: s.from, to: binderId, qty: 1)])
        }
    }

    /// Scanned cards go in new, straight into this binder, as one batch (source "scan") that one Undo takes back.
    private func scan() {
        focused = false
        let target = binderId
        T1Overlays.shared.present(full: true, swipeBack: false) {
            CardScanView(title: "Scan into \(self.target)", doneLabel: "Add", onDone: { cards in
                Telemetry.capture("scan_session_ended", ["context": "binder", "cards": cards.count,
                                                         "exact": cards.filter(\.exact).count, "cancelled": false])
                T1Overlays.shared.dismissPanel()
                guard !cards.isEmpty else { return }
                run("Added \(cards.count) scanned card\(cards.count == 1 ? "" : "s")") {
                    try await col.apply(cards.map { CollectionOp(cardId: $0.printing.cardId, finish: $0.finish, condition: $0.condition,
                                                                 lang: $0.lang, delta: 1, binderId: target) }, source: "scan").batchId
                }
            }, onCancel: {
                Telemetry.capture("scan_session_ended", ["context": "binder", "cards": 0, "exact": 0, "cancelled": true])
                T1Overlays.shared.dismissPanel()
            })
            .screen("card_scanner")
        }
    }

    private func addNew(_ o: CatalogOracle) {
        guard let p = covers[o.idx] else { return }
        let finish = p.finishList.first?.rawValue ?? "nonfoil"
        let target = binderId
        let lang = Languages.forNew(p, picked: addLang)
        run("Added 1 \(o.name) · \(addCondition)\(lang == "en" ? "" : " · \(lang.uppercased())")") {
            try await col.apply([CollectionOp(cardId: p.cardId, finish: finish, condition: addCondition, lang: lang, delta: 1, binderId: target)]).batchId
        }
    }

    private func run(_ label: String, _ work: @escaping () async throws -> String) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let batch = try await work()
                last = batch.isEmpty ? nil : (batch, label)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func undo(_ batchId: String) {
        busy = true
        Task {
            defer { busy = false }
            do { _ = try await col.undo(batchId: batchId); last = nil } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: moving copies

/// Card detail → an owned item → Move: pick where from (when copies are in more than one place), how many, then
/// where to (a binder, Unsorted, or a new binder).
@MainActor
enum BinderMoveFlow {
    static func start(_ item: CollectionItem, label: String, done: @escaping (String?) -> Void) {
        let store = BindersStore.shared
        let p = store.placement(item)
        var sources: [(id: String?, name: String, qty: Int)] = p.binders.map { ($0.binder.id, $0.binder.name, $0.qty) }
        if p.unsorted > 0 { sources.append((nil, "Unsorted", p.unsorted)) }
        if sources.count == 1 { count(item, from: sources[0], label: label, done: done); return }
        T1Overlays.shared.showMenu("Move \(label) from", sources.map { s in
            T1MenuItem(title: s.name, detail: "\(s.qty) here") { count(item, from: s, label: label, done: done) }
        })
    }

    private static func count(_ item: CollectionItem, from: (id: String?, name: String, qty: Int), label: String, done: @escaping (String?) -> Void) {
        if from.qty == 1 { destination(item, from: from, qty: 1, label: label, done: done); return }
        let options = Array(Set([1, from.qty / 2, from.qty].filter { $0 >= 1 })).sorted()
        T1Overlays.shared.showMenu("How many?", options.map { n in
            T1MenuItem(title: n == from.qty ? "All \(n)" : "\(n)") { destination(item, from: from, qty: n, label: label, done: done) }
        })
    }

    private static func destination(_ item: CollectionItem, from: (id: String?, name: String, qty: Int), qty: Int, label: String,
                                     done: @escaping (String?) -> Void) {
        let store = BindersStore.shared
        var items = store.binders.filter { $0.id != from.id }.map { b in
            T1MenuItem(title: b.name, detail: b.forTrade ? "For trade" : nil) { run(item, from.id, b.id, qty, "Moved \(qty) \(label) to \(b.name)", done) }
        }
        if from.id != nil {
            items.append(T1MenuItem(title: "Unsorted") { run(item, from.id, nil, qty, "Moved \(qty) \(label) to Unsorted", done) })
        }
        items.append(T1MenuItem(title: "New binder…") {
            T1Overlays.shared.present {
                BinderEditPanel(binder: nil) { id in
                    run(item, from.id, id, qty, "Moved \(qty) \(label) to \(store.binder(id)?.name ?? "the new binder")", done)
                }
            }
        })
        T1Overlays.shared.showMenu("Move \(qty) to", items)
    }

    private static func run(_ item: CollectionItem, _ from: String?, _ to: String?, _ qty: Int, _ label: String, _ done: @escaping (String?) -> Void) {
        Task {
            do {
                _ = try await BindersStore.shared.move([BinderMove(item: item, from: from, to: to, qty: qty)])
                done(label)
            } catch {
                BindersStore.shared.error = error.localizedDescription
                done(nil)
            }
        }
    }
}

// MARK: wants

struct WantsView: View {
    @Binding var path: [LibraryRoute]
    @Environment(\.dismiss) private var dismiss
    private var store: BindersStore { BindersStore.shared }
    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var rows: [WantDisplay] = []
    @State private var missing: [(line: MissingLine, printing: CatalogPrinting?, name: String, oracleId: String?, type: String)] = []
    @State private var showAllMissing = false
    @State private var query = ""

    struct WantDisplay: Identifiable {
        let want: Want
        let name: String
        let printing: CatalogPrinting?
        var type = ""
        var id: String { want.id }
    }

    var body: some View {
        let wanted = rows.reduce(0) { $0 + $1.want.qty }
        let short = missing.reduce(0) { $0 + $1.line.short }
        let shownWants = query.isEmpty ? rows : rows.filter { CardSearch.matches(query, name: $0.name, type: $0.type) }
        let shownMissing = query.isEmpty ? missing : missing.filter { CardSearch.matches(query, name: $0.name, type: $0.type) }
        T1Screen {
            Bar(title: "Wants", subtitle: "\(wanted) wanted · \(short) missing", back: { dismiss() })
            if let error = store.error { Notice(error, error: true) }
            CatalogStatusRow(catalog: catalog)
            if !rows.isEmpty || !missing.isEmpty { T1SearchField(text: $query, prompt: "Name or type") }
            HairlineList {
                Button { addWant() } label: { ListRow(title: "Add a want", detail: "Any printing, or one in particular") }.buttonStyle(.plain)
                if !rows.isEmpty && query.isEmpty { ShareRow(target: .wants, from: "wants", path: $path) }
                Section1("Wanted · \(shownWants.count)")
                if shownWants.isEmpty && !query.isEmpty { ListRow(title: "No wants match") }
                else if rows.isEmpty { Notice("Cards you're after. Gets in a trade that match are marked, and confirming takes them off.") }
                ForEach(shownWants) { r in
                    Button { edit(r) } label: {
                        CardRow(printing: r.printing, title: r.name, detail: detail(r.want, r.printing)) {
                            Text("\(r.want.qty)").font(T1.mono(17)).monospacedDigit()
                        }
                    }.buttonStyle(.plain)
                }
                Section1(query.isEmpty ? "Missing from decks and cubes · \(short)" : "Missing from decks and cubes · \(shownMissing.count) match")
                if shownMissing.isEmpty && !query.isEmpty { ListRow(title: "Nothing missing matches") }
                else if shownMissing.isEmpty && catalog.phase == .ready { Notice("Your decks and cubes have every card they need.") }
                ForEach(Array((showAllMissing ? shownMissing : Array(shownMissing.prefix(60))).enumerated()), id: \.element.line.id) { _, m in
                    HStack(spacing: 1) {
                        Button { if let o = m.oracleId { path.append(.card(o)) } } label: {
                            CardRow(printing: m.printing, title: m.name,
                                    detail: [m.line.finish == "nonfoil" ? nil : m.line.finish.capitalized, m.line.lists.joined(separator: ", ")]
                                        .compactMap { $0 }.joined(separator: " · ")) {
                                Text("\(m.line.short)").font(T1.mono(17)).monospacedDigit().foregroundStyle(T1.error)
                            }
                        }.buttonStyle(.plain)
                        if let o = m.oracleId, !rows.contains(where: { $0.want.oracleId == o }) {
                            Button { want(m.line, oracleId: o) } label: {
                                LabelText("Want", color: T1.text).padding(.horizontal, 14).frame(maxHeight: .infinity)
                                    .background(T1.surfaceHover).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !showAllMissing && shownMissing.count > 60 {
                    Button { showAllMissing = true } label: { ListRow(title: "Show all \(shownMissing.count)") }.buttonStyle(.plain)
                }
            }
        }
        .task(id: "\(store.version)-\(CollectionStore.shared.version)-\(catalog.generation)-\(ListsStore.shared.lists.count)") { await rebuild() }
        .searchUsed(query, screen: "wants")
    }

    private func detail(_ w: Want, _ p: CatalogPrinting?) -> String {
        let which = w.cardId == nil ? "Any printing" : [p?.setLabel, w.finish.flatMap { Finish(rawValue: $0)?.label }].compactMap { $0 }.joined(separator: " · ")
        let price = w.cardId.flatMap { PriceBook.shared.usd($0, w.finish ?? "nonfoil") }
        return [which, w.maxUsd.map { "Max $\($0.formatted())" }, price.map { "Now $\($0.formatted())" }].compactMap { $0 }.joined(separator: " · ")
    }

    private func rebuild() async {
        catalog.load(userInitiated: true)
        guard let db = catalog.db else { return }
        let wants = store.liveWants
        let lists = ListsStore.shared.lists
        let owned = ownedByPrinting()
        let out = await Task.detached(priority: .userInitiated) { () -> ([WantDisplay], [(MissingLine, CatalogPrinting?, String, String?, String)]) in
            var shown: [WantDisplay] = []
            var oracleCache: [String: CatalogOracle] = [:]
            let printings = db.printings(ids: wants.compactMap(\.cardId))
            for w in wants {
                let o = oracleCache[w.oracleId] ?? db.oracle(id: w.oracleId)
                if let o { oracleCache[w.oracleId] = o }
                let p = w.cardId.flatMap { printings[$0] } ?? o.flatMap { db.covers(oracleIdxs: [$0.idx])[$0.idx] }
                shown.append(WantDisplay(want: w, name: o?.name ?? "Card not in local data yet", printing: p, type: o?.typeLine ?? ""))
            }
            let lines = MissingView.lines(lists, owned: owned)
            let mp = db.printings(ids: lines.map(\.cardId))
            let mo = db.oracles(idxs: Array(Set(mp.values.map(\.oracleIdx))))
            let miss = lines.map { l -> (MissingLine, CatalogPrinting?, String, String?, String) in
                let o = mp[l.cardId].flatMap { mo[$0.oracleIdx] }
                return (l, mp[l.cardId], o?.name ?? "Card not in local data yet", o?.oracleId, o?.typeLine ?? "")
            }
            return (shown, miss)
        }.value
        rows = out.0
        missing = out.1.map { ($0.0, $0.1, $0.2, $0.3, $0.4) }
        await PriceBook.shared.load(wants.compactMap(\.cardId))
    }

    private func want(_ m: MissingLine, oracleId: String) {
        Task {
            do {
                try await store.applyWants([WantOp(oracleId: oracleId, delta: m.short)], event: "want_added",
                                           props: ["any_printing": true, "finish": false, "has_max": false, "from": "missing"])
            } catch { store.error = error.localizedDescription }
        }
    }

    private func addWant() {
        T1Overlays.shared.present(full: true) { WantPickPanel().screen("want_add") }
    }

    private func edit(_ r: WantDisplay) {
        let w = r.want
        func set(_ op: WantOp, _ event: String = "want_changed", _ props: [String: Any] = [:]) {
            Task { do { try await store.applyWants([op], event: event, props: props) } catch { store.error = error.localizedDescription } }
        }
        let base = WantOp(oracleId: w.oracleId, cardId: w.cardId, finish: w.finish)
        var items: [T1MenuItem] = [
            T1MenuItem(title: "One more") { var o = base; o.delta = 1; set(o) },
            T1MenuItem(title: "One fewer", enabled: w.qty > 1) { var o = base; o.delta = -1; set(o) },
            T1MenuItem(title: "Max price", detail: w.maxUsd.map { "$\($0.formatted())" } ?? "None") {
                T1Overlays.shared.present { WantPricePanel(want: w) }
            },
        ]
        items.append(T1MenuItem(title: "Change printing", detail: w.cardId == nil ? "Any printing" : r.printing?.setLabel) {
            T1Overlays.shared.present(full: true) { WantPrintingPanel(oracleId: w.oracleId, replacing: w).screen("want_printing") }
        })
        items.append(T1MenuItem(title: "Open card") { path.append(.card(w.oracleId)) })
        items.append(T1MenuItem(title: "Remove", destructive: true) { var o = base; o.qty = 0; set(o, "want_removed") })
        T1Overlays.shared.showMenu(r.name, items)
    }
}

/// The highest price (USD) worth paying for a want.
struct WantPricePanel: View {
    let want: Want
    @State private var text: String

    init(want: Want) {
        self.want = want
        _text = State(initialValue: want.maxUsd.map { $0.formatted(.number.grouping(.never)) } ?? "")
    }

    var body: some View {
        VStack(spacing: 1) {
            Bar(title: "Max price") { BarButton("Cancel") { T1Overlays.shared.dismissPanel() } }
            Field(label: "Most you'd pay, USD (empty for none)", text: $text, number: true)
            BigAction(text: "Save", enabled: text.isEmpty || price != nil) {
                let op = WantOp(oracleId: want.oracleId, cardId: want.cardId, finish: want.finish, maxUsd: .some(text.isEmpty ? nil : price))
                T1Overlays.shared.dismissPanel()
                Task {
                    do { try await BindersStore.shared.applyWants([op], event: "want_changed") } catch { BindersStore.shared.error = error.localizedDescription }
                }
            }
        }
    }

    private var price: Double? { Double(text.replacingOccurrences(of: ",", with: ".")).flatMap { $0 >= 0 ? $0 : nil } }
}

/// Search for a card to want: Want adds any printing; tapping the card picks one printing or finish.
struct WantPickPanel: View {
    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var query = ""
    @State private var hits: [CatalogOracle] = []
    @State private var covers: [Int: CatalogPrinting] = [:]
    @State private var added: String?
    @State private var result: CardSearchEngine.Result?
    @FocusState private var focused: Bool

    var body: some View {
        T1Screen {
            Bar(title: "Add a want", subtitle: added, back: { T1Overlays.shared.dismissPanel() })
            CatalogStatusRow(catalog: catalog)
            CardSearchBar(query: $query, prompt: "Lightning Bolt, or Scryfall syntax", scan: { scan() }, focused: $focused)
            CardSearchStatus(query: query, result: result)
            HairlineList {
                if query.isEmpty { Notice("Want adds any printing. Tap a card to want one printing or finish. Scan wants each card you scan, any printing.") }
                ForEach(hits, id: \.idx) { o in
                    HStack(spacing: 1) {
                        Button { pickPrinting(o) } label: {
                            CardRow(printing: covers[o.idx], title: o.name, detail: o.typeLine) { LabelText("Printing", color: T1.muted) }
                        }.buttonStyle(.plain)
                        Button { add(o) } label: {
                            LabelText("Want", color: T1.text).padding(.horizontal, 14).frame(maxHeight: .infinity)
                                .background(T1.surfaceHover).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            BigAction(text: "Done", accent: false) { T1Overlays.shared.dismissPanel() }
        }
        .onAppear { focused = true }
        .task(id: "\(query)-\(catalog.generation)") {
            guard let db = catalog.db else { return }
            let q = query
            try? await Task.sleep(for: CardSearchEngine.debounce(q))
            if Task.isCancelled { return }
            let found = await Task.detached(priority: .userInitiated) { await CardSearchEngine.run(q, db) }.value
            if !Task.isCancelled { hits = found.hits; covers = found.covers; result = found }
        }
    }

    /// Each scanned card becomes a want for one copy, any printing.
    private func scan() {
        focused = false
        T1Overlays.shared.present(full: true, swipeBack: false) {
            CardScanView(title: "Scan what you want", doneLabel: "Want", onDone: { cards in
                Telemetry.capture("scan_session_ended", ["context": "wants", "cards": cards.count,
                                                         "exact": cards.filter(\.exact).count, "cancelled": false])
                T1Overlays.shared.dismissPanel()
                guard !cards.isEmpty else { return }
                Task {
                    do {
                        try await BindersStore.shared.applyWants(cards.map { WantOp(oracleId: $0.oracle.oracleId, delta: 1) }, event: "want_added",
                                                                 props: ["any_printing": true, "finish": false, "has_max": false, "from": "scan"])
                        added = "Wanted \(cards.count) scanned card\(cards.count == 1 ? "" : "s")"
                    } catch { BindersStore.shared.error = error.localizedDescription }
                }
            }, onCancel: {
                Telemetry.capture("scan_session_ended", ["context": "wants", "cards": 0, "exact": 0, "cancelled": true])
                T1Overlays.shared.dismissPanel()
            })
            .screen("card_scanner")
        }
    }

    private func pickPrinting(_ o: CatalogOracle) {
        focused = false
        T1Overlays.shared.present(full: true) {
            WantPrintingPanel(oracleId: o.oracleId, from: "search") { added = $0 }.screen("want_printing")
        }
    }

    private func add(_ o: CatalogOracle) {
        Task {
            do {
                try await BindersStore.shared.applyWants([WantOp(oracleId: o.oracleId, delta: 1)], event: "want_added",
                                                         props: ["any_printing": true, "finish": false, "has_max": false, "from": "search"])
                added = "Wanted \(o.name)"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch { BindersStore.shared.error = error.localizedDescription }
        }
    }
}

/// Which printing of a card to want: any printing, one printing in any finish (tap the printing), or one printing
/// in one finish (its finish buttons). Adds one copy, or with `replacing` points that want at the pick, keeping
/// its count and max price.
struct WantPrintingPanel: View {
    let oracleId: String
    var replacing: Want?
    var from = "search"
    var done: ((String) -> Void)?
    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var printings: [CatalogPrinting] = []
    @State private var name = ""
    @State private var query = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let shown = query.isEmpty ? printings : printings.filter { CardSearch.matches(query, set: $0.set, cn: $0.cn, releasedAt: $0.releasedAt) }
        T1Screen {
            Bar(title: replacing == nil ? "Want which printing" : "Change printing", subtitle: name, back: { T1Overlays.shared.dismissPanel() })
            if let error { Notice(error, error: true) }
            CatalogStatusRow(catalog: catalog)
            if printings.count > 8 { T1SearchField(text: $query, prompt: "Set, number or year") }
            HairlineList {
                let anyNow = replacing != nil && replacing?.cardId == nil
                Button { pick(nil, nil) } label: {
                    ListRow(title: "Any printing", detail: "A get of any printing meets it") {
                        if anyNow { LabelText("Current", color: T1.disabled) }
                    }
                }.buttonStyle(.plain).disabled(anyNow || busy)
                Section1(query.isEmpty ? "One printing · \(printings.count)" : "One printing · \(shown.count) of \(printings.count)")
                if shown.isEmpty && !query.isEmpty { ListRow(title: "No printings match") }
                ForEach(shown, id: \.cardId) { row($0) }
            }
        }
        .task(id: catalog.generation) {
            catalog.load(userInitiated: true)
            guard let db = catalog.db else { return }
            let id = oracleId
            let found = await Task.detached(priority: .userInitiated) { () -> (String, [CatalogPrinting]) in
                guard let o = db.oracle(id: id) else { return ("", []) }
                return (o.name, db.printings(oracleIdx: o.idx))
            }.value
            name = found.0
            printings = found.1
            await PriceBook.shared.load(found.1.map(\.cardId))
        }
    }

    private func row(_ p: CatalogPrinting) -> some View {
        let price = PriceBook.shared.usd(p.cardId, p.finishList.first?.rawValue ?? "nonfoil")
        let detail = [CatalogPack.rarityName[p.rarity], p.releasedAt.isEmpty ? nil : String(p.releasedAt.prefix(4)),
                      p.original ? "Original" : nil, p.lang == "en" ? nil : p.lang.uppercased(),
                      money(price)].compactMap { $0 }.joined(separator: " · ")
        let samePrinting = replacing?.cardId == p.cardId
        return HStack(spacing: 1) {
            Button { pick(p, nil) } label: {
                HStack(spacing: 12) {
                    p.art(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.setLabel).font(T1.mono(13)).lineLimit(1)
                        LabelText(samePrinting && replacing?.finish == nil ? "Current · \(detail)" : detail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy || (samePrinting && replacing?.finish == nil))
            // A finish button only matters when the printing comes in more than one.
            if p.finishList.count > 1 {
                ForEach(p.finishList, id: \.self) { f in
                    let same = samePrinting && replacing?.finish == f.rawValue
                    Button { pick(p, f.rawValue) } label: {
                        LabelText(same ? "Current" : f.label, color: same ? T1.disabled : T1.text)
                            .padding(.horizontal, 12).frame(maxHeight: .infinity)
                            .background(T1.surfaceHover)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(same || busy)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(T1.surface)
    }

    private func pick(_ p: CatalogPrinting?, _ finish: String?) {
        let store = BindersStore.shared
        let label = p.map { [$0.setLabel, finish.flatMap { Finish(rawValue: $0)?.label }].compactMap { $0 }.joined(separator: " ") } ?? name
        let ops: [WantOp]
        let event: String
        var props: [String: Any] = ["any_printing": p == nil, "finish": finish != nil]
        if let w = replacing {
            guard let r = BinderRules.repoint(w, cardId: p?.cardId, finish: finish) else { T1Overlays.shared.dismissPanel(); return }
            ops = r
            event = "want_changed"
            props["printing"] = true
        } else {
            ops = [WantOp(oracleId: oracleId, cardId: p?.cardId, finish: finish, delta: 1)]
            event = "want_added"
            props["has_max"] = false
            props["from"] = from
        }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await store.applyWants(ops, event: event, props: props)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                T1Overlays.shared.dismissPanel()
                done?(replacing == nil ? "Wanted 1 \(label)" : "Now wanting \(label)")
            } catch { self.error = error.localizedDescription }
        }
    }
}

extension View {
    /// `library_searched` once per visit, when a search field on the screen is first used (never the text).
    func searchUsed(_ query: String, screen: String) -> some View { modifier(SearchUsed(query: query, screen: screen)) }
}

private struct SearchUsed: ViewModifier {
    let query: String
    let screen: String
    @State private var sent = false
    func body(content: Content) -> some View {
        content.onChange(of: query.isEmpty) { _, empty in
            if !empty && !sent {
                sent = true
                Telemetry.capture("library_searched", ["screen": screen])
            }
        }
    }
}
