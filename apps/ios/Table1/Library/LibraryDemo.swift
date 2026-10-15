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
    private let prices: [String: [Double?]]
    private var ledger: [String: [HistoryEntry]] = [:]
    private var batches: [String: (rows: [(item: CollectionItem, delta: Int)], undone: Bool)] = [:]
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
        recompute()
        return ApplyResult(batchId: batchId, duplicate: false, items: rows, summary: summary)
    }

    func undo(batchId: String) throws -> ApplyResult {
        guard let b = batches[batchId] else { throw DemoError(message: "Nothing to undo") }
        if b.undone { throw DemoError(message: "Already undone") }
        let ops = b.rows.map { CollectionOp(cardId: $0.item.cardId, finish: $0.item.finish, condition: $0.item.condition,
                                            lang: $0.item.lang, delta: -$0.delta) }
        let res = try apply(ops, source: "undo")
        batches[batchId]?.undone = true
        for (card, list) in ledger {
            ledger[card] = list.map { e in
                e.batchId == batchId ? HistoryEntry(at: e.at, finish: e.finish, condition: e.condition, lang: e.lang, delta: e.delta,
                                                    qtyAfter: e.qtyAfter, source: e.source, batchId: e.batchId, undone: true) : e
            }
        }
        return res
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
        CollectionStore.shared.startDemo(backend)
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
        }
    }
}
#endif
