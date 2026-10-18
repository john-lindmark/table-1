#if DEBUG
import SwiftUI

// Debug only: `-T1LibraryDemo` opens the Library without signing in, on a local copy of
// DebugResources/library-demo.json (2,000 cards: five Modern decks, a Vintage cube and bulk, made by
// tools/make_library_demo.py). The card data and prices still come from the live catalog, which needs no
// account. Writes stay on the device: LibraryDemoBackend applies collection_apply's rules locally (whole batch
// rejected below zero, on an unknown card or a finish the printing doesn't have), with history and undo.

struct LibraryDemoFixture: Decodable {
    struct Summary: Decodable {
        let total_qty: Int
        let unique_printings: Int
        let unique_cards: Int
        let value_usd: Double
        let value_eur: Double
        let seq: Int
    }
    struct List: Decodable {
        let id: String
        let kind: String
        let name: String
        let format: String
        /// [card_id, board, qty]
        let entries: [[Entry]]
        let versions: [Version]?
    }
    struct Version: Decodable {
        let version: Int
        let at: Double
        let note: String
        let entries: [[Entry]]
    }
    enum Entry: Decodable {
        case text(String), int(Int)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { self = .int(i) } else { self = .text(try c.decode(String.self)) }
        }
        var text: String { if case .text(let s) = self { s } else { "" } }
        var int: Int { if case .int(let i) = self { i } else { 0 } }
    }
    let summary: Summary
    /// [card_id, finish, condition, lang, qty]
    let items: [[Entry]]
    let lists: [List]
    /// card_id → [usd, usd_foil, usd_etched, eur, eur_foil]
    let prices: [String: [Double?]]

    static func load() -> LibraryDemoFixture? {
        guard let url = Bundle.main.url(forResource: "library-demo", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LibraryDemoFixture.self, from: data)
    }
}

struct DemoError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class LibraryDemoBackend {
    private(set) var items: [String: CollectionItem] = [:]
    private(set) var summary: LibrarySummary
    private var seq = 0
    /// [usd, usd_foil, usd_etched, eur, eur_foil] per printing, as card_prices_get returns them.
    let prices: [String: [Double?]]
    private var ledger: [String: [HistoryEntry]] = [:]
    private var batches: [String: (rows: [(item: CollectionItem, delta: Int)], undone: Bool)] = [:]
    /// Binders, allocations and wants, with what each batch did to them (for undo).
    private(set) var binders: [String: Binder] = [:]
    private(set) var allocs: [String: BinderAlloc] = [:]
    private(set) var wants: [String: Want] = [:]
    private var batchAllocs: [String: [(alloc: BinderAlloc, delta: Int)]] = [:]
    private var batchWants: [String: [(want: Want, delta: Int)]] = [:]
    private var oracleOf: [String: Int] = [:]
    private let seedAt = ISO8601DateFormatter().string(from: .now)
    private var seed: [String: CollectionItem] = [:]

    init(_ f: LibraryDemoFixture) {
        prices = f.prices
        for r in f.items {
            seq += 1
            let it = CollectionItem(cardId: r[0].text, finish: r[1].text, condition: r[2].text, lang: r[3].text, qty: r[4].int, seq: seq)
            items[it.key] = it
        }
        seed = items
        summary = LibrarySummary(totalQty: f.summary.total_qty, uniquePrintings: f.summary.unique_printings,
                                 uniqueCards: f.summary.unique_cards, valueUsd: f.summary.value_usd,
                                 valueEur: f.summary.value_eur, seq: seq)
    }

    func apply(_ ops: [CollectionOp], source: String, undoing: String? = nil) throws -> ApplyResult {
        guard !ops.isEmpty else { throw DemoError(message: "Nothing to change") }
        let db = CatalogStore.shared.db
        let known = db?.printings(ids: Array(Set(ops.map(\.cardId)))) ?? [:]
        var plan: [String: (op: CollectionOp, cur: Int, new: Int)] = [:]
        for op in ops {
            let key = CollectionStore.key(op.cardId, op.finish, op.condition, op.lang)
            var p = plan[key] ?? (op, items[key]?.qty ?? 0, items[key]?.qty ?? 0)
            if let q = op.qty { p.new = q } else { p.new += op.delta ?? 0 }
            plan[key] = p
        }
        if db != nil, let bad = plan.values.first(where: { known[$0.op.cardId] == nil }) {
            throw DemoError(message: "Unknown card: \(bad.op.cardId)")
        }
        if let bad = plan.values.first(where: { p in known[p.op.cardId].map { !$0.finishList.map(\.rawValue).contains(p.op.finish) } ?? false }) {
            throw DemoError(message: "Not printed in that finish: \(bad.op.finish)")
        }
        if let bad = plan.values.first(where: { $0.new < 0 }) {
            throw DemoError(message: "Not enough copies (have \(bad.cur))")
        }

        if source != "undo", let bad = ops.first(where: { $0.binderId != nil && binders[$0.binderId!] == nil }) {
            throw DemoError(message: "That binder is gone (\(bad.binderId!))")
        }
        if ops.contains(where: { $0.binderId != nil && $0.qty != nil }) {
            throw DemoError(message: "A binder goes with copies added or removed, not a set quantity")
        }

        let batchId = UUID().uuidString.lowercased()
        var rows: [ApplyResult.Row] = []
        var done: [(item: CollectionItem, delta: Int)] = []
        let now = ISO8601DateFormatter().string(from: .now)
        for (key, p) in plan.sorted(by: { $0.key < $1.key }) where p.new != p.cur {
            seq += 1
            let it = CollectionItem(cardId: p.op.cardId, finish: p.op.finish, condition: p.op.condition, lang: p.op.lang, qty: p.new, seq: seq)
            items[key] = p.new > 0 ? it : nil
            rows.append(.init(cardId: it.cardId, finish: it.finish, condition: it.condition, lang: it.lang, qty: it.qty, seq: seq))
            done.append((it, p.new - p.cur))
            ledger[it.cardId, default: []].insert(HistoryEntry(at: now, finish: it.finish, condition: it.condition, lang: it.lang,
                                                               delta: p.new - p.cur, qtyAfter: p.new, source: source,
                                                               batchId: batchId, undone: false), at: 0)
        }
        batches[batchId] = (done, false)
        // Allocations: hints, then whatever an item no longer has copies for (BinderRules, as the server does).
        var hints: [String: [String: Int]] = [:]
        for op in ops { if let b = op.binderId, let d = op.delta, binders[b] != nil { hints[op.itemKey, default: [:]][b, default: 0] += d } }
        var changed: [BinderAlloc] = []
        for (key, p) in plan {
            var cur: [String: Int] = [:]
            for a in allocs.values where a.itemKey == key && a.qty > 0 { cur[a.binderId] = a.qty }
            let next = BinderRules.plan(current: cur, hints: hints[key] ?? [:], newQty: p.new, binders: binders)
            for (b, q) in next where q != (cur[b] ?? 0) {
                seq += 1
                let a = BinderAlloc(binderId: b, cardId: p.op.cardId, finish: p.op.finish, condition: p.op.condition, lang: p.op.lang, qty: q, seq: seq)
                allocs[a.key] = q > 0 ? a : nil
                changed.append(a)
                batchAllocs[batchId, default: []].append((a, q - (cur[b] ?? 0)))
            }
        }
        recompute()
        return ApplyResult(batchId: batchId, duplicate: false, items: rows, summary: summary, binderItems: changed)
    }

    // MARK: binders and wants

    func saveBinder(id: String, name: String, forTrade: Bool) throws -> Binder {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { throw DemoError(message: "Name the binder") }
        if binders.values.contains(where: { $0.id != id && $0.name.lowercased() == n.lowercased() }) {
            throw DemoError(message: "You already have a binder called \(n)")
        }
        seq += 1
        let b = Binder(id: id, name: String(n.prefix(60)), forTrade: forTrade, seq: seq)
        binders[id] = b
        return b
    }

    func deleteBinder(_ id: String) -> [BinderAlloc] {
        binders[id] = nil
        var out: [BinderAlloc] = []
        for (k, a) in allocs where a.binderId == id {
            seq += 1
            out.append(BinderAlloc(binderId: id, cardId: a.cardId, finish: a.finish, condition: a.condition, lang: a.lang, qty: 0, seq: seq))
            allocs[k] = nil
        }
        return out
    }

    /// binder_move: refused whole if a source holds fewer copies than asked.
    func move(_ moves: [BinderMove]) throws -> ApplyResult {
        for m in moves {
            let have = m.from.map { allocs["\($0)|\(m.item.key)"]?.qty ?? 0 }
                ?? max(0, (items[m.item.key]?.qty ?? 0) - allocs.values.filter { $0.itemKey == m.item.key }.reduce(0) { $0 + $1.qty })
            if m.qty > have { throw DemoError(message: "Not that many copies there") }
        }
        let ops = moves.flatMap { m in [
            CollectionOp(cardId: m.item.cardId, finish: m.item.finish, condition: m.item.condition, lang: m.item.lang, delta: -m.qty, binderId: m.from),
            CollectionOp(cardId: m.item.cardId, finish: m.item.finish, condition: m.item.condition, lang: m.item.lang, delta: m.qty, binderId: m.to),
        ] }
        return try apply(ops, source: "binder")
    }

    func applyWants(_ ops: [WantOp], batchId: String? = nil) throws -> [Want] {
        let db = CatalogStore.shared.db
        var out: [Want] = []
        for op in ops {
            var oracle = op.oracleId
            if let c = op.cardId, let db, let p = db.printings(ids: [c])[c], let o = db.oracles(idxs: [p.oracleIdx])[p.oracleIdx] { oracle = o.oracleId }
            let key = Want.key(oracle, op.cardId, op.finish)
            let cur = wants[key]
            let qty = min(999, max(0, op.qty ?? ((cur?.qty ?? 0) + (op.delta ?? 0))))
            if cur == nil && qty == 0 { continue }
            seq += 1
            let w = Want(oracleId: oracle, cardId: op.cardId, finish: op.finish, qty: qty,
                         maxUsd: op.maxUsd.map { $0 } ?? cur?.maxUsd, seq: seq)
            wants[key] = qty > 0 ? w : nil
            out.append(w)
            if let batchId, qty != (cur?.qty ?? 0) { batchWants[batchId, default: []].append((w, qty - (cur?.qty ?? 0))) }
        }
        return out
    }

    /// trade_confirm's second half: the gets come off the wants they meet, recorded on the trade's batch.
    func meetWants(_ gets: [TradeLine], batchId: String) -> [Want] {
        guard let db = CatalogStore.shared.db else { return [] }
        let p = db.printings(ids: gets.map(\.cardId))
        let o = db.oracles(idxs: Array(Set(p.values.map(\.oracleIdx))))
        var changed: [Want] = []
        for g in gets {
            guard let oracle = p[g.cardId].flatMap({ o[$0.oracleIdx] })?.oracleId else { continue }
            let before = wants
            for w in BinderRules.meet(oracleId: oracle, cardId: g.cardId, finish: g.finish, qty: g.qty, wants: &wants) {
                seq += 1
                var nw = w
                nw.seq = seq
                wants[w.id] = nw.qty > 0 ? nw : nil
                changed.append(nw)
                batchWants[batchId, default: []].append((nw, nw.qty - (before[w.id]?.qty ?? 0)))
            }
        }
        return changed
    }

    func undo(batchId: String) throws -> ApplyResult {
        guard let b = batches[batchId] else { throw DemoError(message: "Nothing to undo") }
        if b.undone { throw DemoError(message: "Already undone") }
        // Per item: each binder's copies go back where they were; the rest to or from Unsorted (as on the server).
        var ops: [CollectionOp] = []
        var net: [String: (op: CollectionOp, d: Int, bd: Int)] = [:]
        for r in b.rows {
            net[r.item.key] = (CollectionOp(cardId: r.item.cardId, finish: r.item.finish, condition: r.item.condition, lang: r.item.lang), r.delta, 0)
        }
        for (a, d) in batchAllocs[batchId] ?? [] {
            ops.append(CollectionOp(cardId: a.cardId, finish: a.finish, condition: a.condition, lang: a.lang, delta: -d, binderId: a.binderId))
            let k = a.itemKey
            var v = net[k] ?? (CollectionOp(cardId: a.cardId, finish: a.finish, condition: a.condition, lang: a.lang), 0, 0)
            v.bd += d
            net[k] = v
        }
        for (_, v) in net where -v.d + v.bd != 0 {
            var op = v.op
            op.delta = -v.d + v.bd
            ops.append(op)
        }
        guard !ops.isEmpty else { throw DemoError(message: "Nothing to undo") }
        var res = try apply(ops, source: "undo")
        batches[batchId]?.undone = true
        if let ws = batchWants[batchId] {
            res.wants = (try? applyWants(ws.map { WantOp(oracleId: $0.want.oracleId, cardId: $0.want.cardId, finish: $0.want.finish, delta: -$0.delta) })) ?? []
        }
        for (card, list) in ledger {
            ledger[card] = list.map { e in
                e.batchId == batchId ? HistoryEntry(at: e.at, finish: e.finish, condition: e.condition, lang: e.lang, delta: e.delta,
                                                    qtyAfter: e.qtyAfter, source: e.source, batchId: e.batchId, undone: true) : e
            }
        }
        return res
    }

    /// Two binders to start with: a for-trade binder holding a copy or two of every seventh item and "Box 1" holding
    /// every fifth item's other copies (the rest stay Unsorted).
    func seedBinders() {
        let trade = Binder(id: "d0000000-0000-0000-0000-00000000b001", name: "Trade binder", forTrade: true, seq: 1)
        let box = Binder(id: "d0000000-0000-0000-0000-00000000b002", name: "Box 1", forTrade: false, seq: 2)
        binders = [trade.id: trade, box.id: box]
        for (i, it) in items.values.sorted(by: { $0.key < $1.key }).enumerated() {
            var left = it.qty
            if i % 7 == 0 {
                let n = min(left, 1 + i % 2)
                allocs["\(trade.id)|\(it.key)"] = BinderAlloc(binderId: trade.id, cardId: it.cardId, finish: it.finish, condition: it.condition, lang: it.lang, qty: n, seq: 0)
                left -= n
            }
            if i % 5 == 0 && left > 0 {
                allocs["\(box.id)|\(it.key)"] = BinderAlloc(binderId: box.id, cardId: it.cardId, finish: it.finish, condition: it.condition, lang: it.lang, qty: left, seq: 0)
            }
        }
    }

    /// Changes made in the demo, newest first, then the copies the fixture started with (shown as one import).
    func history(cardId: String) -> [HistoryEntry] {
        (ledger[cardId] ?? []) + seed.values.filter { $0.cardId == cardId }.map {
            HistoryEntry(at: seedAt, finish: $0.finish, condition: $0.condition, lang: $0.lang, delta: $0.qty,
                         qtyAfter: $0.qty, source: "import", batchId: "demo-import", undone: false)
        }
    }

    private func recompute() {
        let db = CatalogStore.shared.db
        let missing = Set(items.values.map(\.cardId)).subtracting(oracleOf.keys)
        if let db, !missing.isEmpty {
            for (id, p) in db.printings(ids: Array(missing)) { oracleOf[id] = p.oracleIdx }
        }
        var usd = 0.0, eur = 0.0
        for it in items.values {
            let p = prices[it.cardId] ?? []
            func at(_ i: Int) -> Double { i < p.count ? (p[i] ?? 0) : 0 }
            switch it.finish {
            case "foil": usd += Double(it.qty) * at(1); eur += Double(it.qty) * at(4)
            case "etched": usd += Double(it.qty) * at(2); eur += Double(it.qty) * at(4)
            default: usd += Double(it.qty) * at(0); eur += Double(it.qty) * at(3)
            }
        }
        let cards = Set(items.values.map { oracleOf[$0.cardId].map(String.init) ?? $0.cardId }).count
        summary = LibrarySummary(totalQty: items.values.reduce(0) { $0 + $1.qty }, uniquePrintings: Set(items.values.map(\.cardId)).count,
                                 uniqueCards: cards, valueUsd: (usd * 100).rounded() / 100, valueEur: (eur * 100).rounded() / 100, seq: seq)
    }
}

enum LibraryDemo {
    /// Loads the fixture into the collection and lists stores. False when the fixture is missing.
    @MainActor
    @discardableResult
    static func start() -> Bool {
        guard let f = LibraryDemoFixture.load() else { return false }
        let backend = LibraryDemoBackend(f)
        backend.seedBinders()
        CollectionStore.shared.startDemo(backend)
        BindersStore.shared.startDemo(binders: Array(backend.binders.values), allocs: Array(backend.allocs.values), wants: [])
        func entries(_ rows: [[LibraryDemoFixture.Entry]]) -> [CardList.Entry] {
            rows.map { CardList.Entry(cardId: $0[0].text, board: $0[1].text, qty: $0[2].int, finish: $0.count > 3 ? $0[3].text : "nonfoil") }
        }
        ListsStore.shared.replace(f.lists.map { l in
            let versions = (l.versions ?? []).map {
                CardList.Version(number: $0.version, at: Date(timeIntervalSince1970: $0.at), note: $0.note, entries: entries($0.entries))
            }
            return CardList(id: l.id, kind: l.kind == "cube" ? .cube : .deck, name: l.name, format: l.format,
                            versions: versions.isEmpty ? [CardList.Version(number: 1, at: .now, note: "Imported", entries: entries(l.entries))] : versions)
        })
        return true
    }

    /// Once the card data is there: three wants from the demo lists (one with a max price, one a specific printing).
    @MainActor
    static func seedWants() {
        guard let demo = CollectionStore.shared.demo, demo.wants.isEmpty, let db = CatalogStore.shared.db else { return }
        let ids = Array(Set(ListsStore.shared.lists.flatMap { $0.entries.map(\.cardId) })).sorted().prefix(3)
        let p = db.printings(ids: Array(ids))
        let o = db.oracles(idxs: Array(Set(p.values.map(\.oracleIdx))))
        var ops: [WantOp] = []
        for (i, id) in ids.enumerated() {
            guard let oracle = p[id].flatMap({ o[$0.oracleIdx] })?.oracleId else { continue }
            ops.append(WantOp(oracleId: oracle, cardId: i == 2 ? id : nil, qty: 2 - i % 2, maxUsd: i == 1 ? .some(5) : nil))
        }
        if let rows = try? demo.applyWants(ops) { BindersStore.shared.reflect(wants: rows) }
    }
}

/// The Library on demo data, full screen over the signed-out app.
struct LibraryDemoRoot: View {
    @State private var path: [LibraryRoute] = []
    @State private var loaded = true

    var body: some View {
        NavigationStack(path: $path) {
            LibraryHomeView(path: $path)
                .navigationDestination(for: LibraryRoute.self) { LibraryDestination(route: $0, path: $path) }
        }
        .overlay(alignment: .top) {
            if !loaded { Notice("Demo data is missing from this build.", error: true) }
        }
        .background(T1.bg.ignoresSafeArea())
        .task {
            loaded = LibraryDemo.start()
            CatalogStore.shared.load(userInitiated: true)
            path = Self.startRoute
        }
        .task(id: CatalogStore.shared.generation) {
            LibraryDemo.seedWants()
            // `card`: a card with copies in the trade binder. `tradewants`: a draft giving a trade-binder copy and
            // getting a wanted card (the want is marked). Both need the card data, so they open once it's in.
            guard let db = CatalogStore.shared.db, path.isEmpty, let arg = Self.arg, ["card", "tradewants"].contains(arg) else { return }
            let store = BindersStore.shared
            guard let a = store.allocs.values.filter({ store.binder($0.binderId)?.forTrade == true }).sorted(by: { $0.key < $1.key }).first,
                  let p = db.printings(ids: [a.cardId])[a.cardId], let o = db.oracles(idxs: [p.oracleIdx])[p.oracleIdx] else { return }
            if arg == "card" { path = [.card(o.oracleId)]; return }
            guard let w = store.liveWants.first(where: { $0.maxUsd != nil }) ?? store.liveWants.first,
                  let wo = db.oracle(id: w.oracleId), let wp = w.cardId.flatMap({ db.printings(ids: [$0])[$0] }) ?? db.covers(oracleIdxs: [wo.idx])[wo.idx]
            else { return }
            let give = TradeLine(cardId: a.cardId, finish: a.finish, condition: a.condition, lang: a.lang, qty: 1, binderId: a.binderId)
            let get = TradeLine(cardId: wp.cardId, finish: "nonfoil", condition: "NM", lang: "en", qty: 1)
            if let t = try? await TradesStore.shared.save(nil, partner: "Demo", gives: [give], gets: [get]) { path = [.trades, .trade(t.id)] }
        }
    }

    /// Design QA: `-T1LibraryDemo allcards|add|import|trades|trade|tradewants|binders|binder|wants|card|deck|cube` opens that screen (deck and cube: the
    /// fixture's first of each). `import` with `-T1ImportFile <path>` reads that file as if it had been picked.
    private static var arg: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-T1LibraryDemo"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static var startRoute: [LibraryRoute] {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-T1LibraryDemo"), i + 1 < args.count else { return [] }
        switch args[i + 1] {
        case "allcards": return [.allCards]
        case "add": return [.add]
        case "import": return [.collectionImport]
        case "trades": return [.trades]
        case "binders": return [.binders]
        case "binder": return [.binders, .binder("d0000000-0000-0000-0000-00000000b001")]
        case "wants": return [.wants]
        case "trade": return [.trades, .trade(nil)]
        case "deck", "cube":
            let kind: CardList.Kind = args[i + 1] == "deck" ? .deck : .cube
            return ListsStore.shared.lists.first { $0.kind == kind }.map { [.lists(kind), .list($0.id)] } ?? []
        default: return []
        }
    }
}
#endif
