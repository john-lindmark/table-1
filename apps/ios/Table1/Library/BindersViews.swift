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

    var body: some View {
        let totals = store.totals(col.items)
        let _ = store.version
        T1Screen {
            Bar(title: "Binders", subtitle: "\(store.binders.count) · \(store.binders.filter(\.forTrade).count) for trade", back: { dismiss() })
            if let error = store.error { Notice(error, error: true) }
            HairlineList {
                Button { newBinder() } label: { ListRow(title: "New binder", detail: "A box, a deck box, a trade binder") }.buttonStyle(.plain)
                Button { path.append(.binder(BinderRoute.unsorted)) } label: {
                    ListRow(title: "Unsorted", detail: "Copies not in a binder") {
                        Text(totals.unsorted.formatted()).font(T1.mono(17)).monospacedDigit()
                    }
                }.buttonStyle(.plain)
                ForEach(store.binders) { b in
                    let rows = store.items(in: b.id, col.items)
                    Button { path.append(.binder(b.id)) } label: {
                        ListRow(title: b.name, detail: [b.forTrade ? "For trade" : nil, money(value(rows))].compactMap { $0 }.joined(separator: " · ")) {
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
        .refreshable { await col.sync() }
        .task(id: col.version) { await PriceBook.shared.load(col.items.values.map(\.cardId)) }
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

    private var binder: Binder? { store.binder(binderId) }
    private var unsorted: Bool { binderId == BinderRoute.unsorted }

    var body: some View {
        let rows = store.items(in: unsorted ? nil : binderId, col.items)
        let copies = rows.reduce(0) { $0 + $1.qty }
        T1Screen {
            Bar(title: unsorted ? "Unsorted" : binder?.name ?? "Binder",
                subtitle: ["\(copies.formatted()) cards", binder?.forTrade == true ? "For trade" : nil, money(value(rows))].compactMap { $0 }.joined(separator: " · "),
                back: { dismiss() }) {
                if let binder { BarButton("Edit") { menu(binder) } }
            }
            if !unsorted && binder == nil { Notice("This binder was deleted.") }
            CatalogStatusRow(catalog: catalog)
            T1SearchField(text: $query, prompt: "Name or type")
            HairlineList {
                let n = CardName.norm(query)
                let shown = n.isEmpty ? groups : groups.filter { $0.norm.contains(n) || CardName.norm($0.type).contains(n) }
                if groups.isEmpty && catalog.phase == .ready {
                    Notice(unsorted ? "Every copy is in a binder." : "No cards here yet. Open a card and move copies here, or add copies straight into this binder from a trade or an import.")
                }
                ForEach(shown) { g in
                    Button { if g.known { path.append(.card(g.id)) } } label: {
                        CardRow(printing: g.cover, title: g.name, detail: "\(g.printings) printing\(g.printings == 1 ? "" : "s") · \(g.type)") {
                            Text("\(g.qty)").font(T1.mono(17)).monospacedDigit()
                        }
                    }.buttonStyle(.plain)
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
        .task(id: "\(col.version)-\(store.version)-\(catalog.generation)") {
            catalog.load(userInitiated: true)
            guard let db = catalog.db else { return }
            let items = rows.map { r in CollectionItem(cardId: r.item.cardId, finish: r.item.finish, condition: r.item.condition, lang: r.item.lang, qty: r.qty, seq: r.item.seq) }
            groups = await Task.detached(priority: .userInitiated) { CardGroup.build(items, db).sorted { $0.qty != $1.qty ? $0.qty > $1.qty : $0.norm < $1.norm } }.value
            await PriceBook.shared.load(items.map(\.cardId))
        }
    }

    private func menu(_ b: Binder) {
        T1Overlays.shared.showMenu(b.name, [
            T1MenuItem(title: "Rename") { T1Overlays.shared.present { BinderEditPanel(binder: b) } },
            T1MenuItem(title: b.forTrade ? "Not for trade" : "For trade", detail: b.forTrade ? "Trades stops offering these first" : "Trades offers these first when you give") {
                Task {
                    do { try await store.save(id: b.id, name: b.name, forTrade: !b.forTrade) } catch { store.error = error.localizedDescription }
                }
            },
            T1MenuItem(title: "Delete binder", destructive: true) { confirmDelete = true },
        ])
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
    @State private var missing: [(line: MissingLine, printing: CatalogPrinting?, name: String, oracleId: String?)] = []
    @State private var showAllMissing = false

    struct WantDisplay: Identifiable {
        let want: Want
        let name: String
        let printing: CatalogPrinting?
        var id: String { want.id }
    }

    var body: some View {
        let wanted = rows.reduce(0) { $0 + $1.want.qty }
        let short = missing.reduce(0) { $0 + $1.line.short }
        T1Screen {
            Bar(title: "Wants", subtitle: "\(wanted) wanted · \(short) missing", back: { dismiss() })
            if let error = store.error { Notice(error, error: true) }
            CatalogStatusRow(catalog: catalog)
            HairlineList {
                Button { addWant() } label: { ListRow(title: "Add a want", detail: "Any printing, or one in particular") }.buttonStyle(.plain)
                Section1("Wanted · \(rows.count)")
                if rows.isEmpty { Notice("Cards you're after. Gets in a trade that match are marked, and confirming takes them off.") }
                ForEach(rows) { r in
                    Button { edit(r) } label: {
                        CardRow(printing: r.printing, title: r.name, detail: detail(r.want, r.printing)) {
                            Text("\(r.want.qty)").font(T1.mono(17)).monospacedDigit()
                        }
                    }.buttonStyle(.plain)
                }
                Section1("Missing from decks and cubes · \(short)")
                if missing.isEmpty && catalog.phase == .ready { Notice("Your decks and cubes have every card they need.") }
                ForEach(Array((showAllMissing ? missing : Array(missing.prefix(60))).enumerated()), id: \.element.line.id) { _, m in
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
                if !showAllMissing && missing.count > 60 {
                    Button { showAllMissing = true } label: { ListRow(title: "Show all \(missing.count)") }.buttonStyle(.plain)
                }
            }
        }
        .task(id: "\(store.version)-\(CollectionStore.shared.version)-\(catalog.generation)-\(ListsStore.shared.lists.count)") { await rebuild() }
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
        let out = await Task.detached(priority: .userInitiated) { () -> ([WantDisplay], [(MissingLine, CatalogPrinting?, String, String?)]) in
            var shown: [WantDisplay] = []
            var oracleCache: [String: CatalogOracle] = [:]
            let printings = db.printings(ids: wants.compactMap(\.cardId))
            for w in wants {
                let o = oracleCache[w.oracleId] ?? db.oracle(id: w.oracleId)
                if let o { oracleCache[w.oracleId] = o }
                let p = w.cardId.flatMap { printings[$0] } ?? o.flatMap { db.covers(oracleIdxs: [$0.idx])[$0.idx] }
                shown.append(WantDisplay(want: w, name: o?.name ?? "Card not in local data yet", printing: p))
            }
            let lines = MissingView.lines(lists, owned: owned)
            let mp = db.printings(ids: lines.map(\.cardId))
            let mo = db.oracles(idxs: Array(Set(mp.values.map(\.oracleIdx))))
            let miss = lines.map { l -> (MissingLine, CatalogPrinting?, String, String?) in
                let o = mp[l.cardId].flatMap { mo[$0.oracleIdx] }
                return (l, mp[l.cardId], o?.name ?? "Card not in local data yet", o?.oracleId)
            }
            return (shown, miss)
        }.value
        rows = out.0
        missing = out.1.map { ($0.0, $0.1, $0.2, $0.3) }
        await PriceBook.shared.load(wants.compactMap(\.cardId))
    }

    private func want(_ m: MissingLine, oracleId: String) {
        Task {
            do {
                try await store.applyWants([WantOp(oracleId: oracleId, delta: m.short)], event: "want_added",
                                           props: ["any_printing": true, "has_max": false, "from": "missing"])
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
        if w.cardId == nil, let p = r.printing {
            items.append(T1MenuItem(title: "Only \(p.setLabel)", detail: "Want that printing instead of any") {
                Task {
                    do {
                        try await store.applyWants([WantOp(oracleId: w.oracleId, qty: 0),
                                                    WantOp(oracleId: w.oracleId, cardId: p.cardId, qty: w.qty, maxUsd: .some(w.maxUsd))])
                    } catch { store.error = error.localizedDescription }
                }
            })
        } else if w.cardId != nil {
            items.append(T1MenuItem(title: "Any printing") {
                Task {
                    do {
                        try await store.applyWants([WantOp(oracleId: w.oracleId, cardId: w.cardId, finish: w.finish, qty: 0),
                                                    WantOp(oracleId: w.oracleId, delta: w.qty, maxUsd: .some(w.maxUsd))])
                    } catch { store.error = error.localizedDescription }
                }
            })
        }
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

/// Search for a card to want (any printing).
struct WantPickPanel: View {
    private var catalog: CatalogStore { CatalogStore.shared }
    @State private var query = ""
    @State private var hits: [CatalogOracle] = []
    @State private var covers: [Int: CatalogPrinting] = [:]
    @State private var added: String?
    @FocusState private var focused: Bool

    var body: some View {
        T1Screen {
            Bar(title: "Add a want", subtitle: added, back: { T1Overlays.shared.dismissPanel() })
            CatalogStatusRow(catalog: catalog)
            T1SearchField(text: $query, prompt: "Lightning Bolt").focused($focused)
            HairlineList {
                ForEach(hits, id: \.idx) { o in
                    Button { add(o) } label: {
                        CardRow(printing: covers[o.idx], title: o.name, detail: o.typeLine) { LabelText("Want", color: T1.text) }
                    }.buttonStyle(.plain)
                }
            }
            BigAction(text: "Done", accent: false) { T1Overlays.shared.dismissPanel() }
        }
        .onAppear { focused = true }
        .task(id: "\(query)-\(catalog.generation)") {
            guard let db = catalog.db else { return }
            let q = query
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
            let found = await Task.detached(priority: .userInitiated) { () -> ([CatalogOracle], [Int: CatalogPrinting]) in
                let h = db.search(q)
                return (h, db.covers(oracleIdxs: h.map(\.idx)))
            }.value
            if !Task.isCancelled { hits = found.0; covers = found.1 }
        }
    }

    private func add(_ o: CatalogOracle) {
        Task {
            do {
                try await BindersStore.shared.applyWants([WantOp(oracleId: o.oracleId, delta: 1)], event: "want_added",
                                                         props: ["any_printing": true, "has_max": false, "from": "search"])
                added = "Wanted \(o.name)"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch { BindersStore.shared.error = error.localizedDescription }
        }
    }
}
