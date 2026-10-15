import Foundation
import Supabase

// The signed-in player's collection, mirrored locally (contract/collection-2026-10-15.md). Items live in a
// SQLite file per account and in memory while the app runs; the server is asked only for what changed since
// the highest seq we hold. Writes go through collection_apply, show at once, then a delta sync confirms them.

enum Finish: String, Codable, CaseIterable, Sendable {
    case nonfoil, foil, etched
    var label: String {
        switch self {
        case .nonfoil: "Non-foil"
        case .foil: "Foil"
        case .etched: "Etched"
        }
    }
}

struct CollectionItem: Hashable, Sendable {
    let cardId: String
    let finish: String
    let condition: String
    let lang: String
    let qty: Int
    let seq: Int
    var key: String { CollectionStore.key(cardId, finish, condition, lang) }
    var finishLabel: String { Finish(rawValue: finish)?.label ?? finish }
}

struct LibrarySummary: Codable, Equatable, Sendable {
    let totalQty: Int
    let uniquePrintings: Int
    let uniqueCards: Int
    let valueUsd: Double
    let valueEur: Double
    let seq: Int
}

struct CollectionOp {
    let cardId: String
    var finish: String = Finish.nonfoil.rawValue
    var condition = "NM"
    var lang = "en"
    var delta: Int?
    var qty: Int?

    var json: AnyJSON {
        var o: [String: AnyJSON] = [
            "card_id": .string(cardId), "finish": .string(finish), "condition": .string(condition), "lang": .string(lang),
        ]
        if let delta { o["delta"] = .integer(delta) }
        if let qty { o["qty"] = .integer(qty) }
        return .object(o)
    }
}

struct ApplyResult: Decodable {
    struct Row: Decodable {
        let cardId: String
        let finish: String
        let condition: String
        let lang: String
        let qty: Int
        let seq: Int
    }
    let batchId: String
    let duplicate: Bool
    let items: [Row]
    let summary: LibrarySummary
}

struct HistoryEntry: Decodable, Hashable {
    /// timestamptz as Postgres prints it; the screen shows the date part.
    let at: String
    let finish: String
    let condition: String
    let lang: String
    let delta: Int
    let qtyAfter: Int
    let source: String
    let batchId: String
    let undone: Bool
}

private struct ChangesPage: Decodable {
    /// [card_id, finish, condition, lang, qty, seq]
    struct Row: Decodable {
        let item: CollectionItem
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            item = CollectionItem(cardId: try c.decode(String.self), finish: try c.decode(String.self),
                                  condition: try c.decode(String.self), lang: try c.decode(String.self),
                                  qty: try c.decode(Int.self), seq: try c.decode(Int.self))
        }
    }
    let resync: Bool
    let items: [Row]
    let next: Int
    let more: Bool
    let summary: LibrarySummary
}

/// The local mirror for one account: items keyed card_id|finish|condition|lang, plus the cursor and summary.
private final class LibraryDB {
    let db: SQLiteDB

    init(userId: String) throws {
        let dir = URL.applicationSupportDirectory.appending(path: "Library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try SQLiteDB(path: dir.appending(path: "library-\(userId).sqlite").path)
        try db.exec("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS items (k TEXT PRIMARY KEY, card_id TEXT NOT NULL, finish TEXT NOT NULL,
              condition TEXT NOT NULL, lang TEXT NOT NULL, qty INTEGER NOT NULL, seq INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
    }

    func load() throws -> (items: [String: CollectionItem], cursor: Int, summary: LibrarySummary?) {
        let rows = try db.query("SELECT card_id, finish, condition, lang, qty, seq FROM items") {
            CollectionItem(cardId: $0.text(0), finish: $0.text(1), condition: $0.text(2), lang: $0.text(3), qty: $0.int(4), seq: $0.int(5))
        }
        let meta = Dictionary(try db.query("SELECT key, value FROM meta") { ($0.text(0), $0.text(1)) }, uniquingKeysWith: { a, _ in a })
        let summary = meta["summary"].flatMap { try? JSONDecoder().decode(LibrarySummary.self, from: Data($0.utf8)) }
        return (Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a }), Int(meta["cursor"] ?? "") ?? 0, summary)
    }

    /// Upserts, deletes and the cursor move in one transaction, so a crash never splits them.
    func commit(put: [CollectionItem], delete: [String], cursor: Int, summary: LibrarySummary) throws {
        let json = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        try db.transaction {
            let up = try db.prepare("INSERT OR REPLACE INTO items VALUES (?,?,?,?,?,?,?)")
            for it in put {
                try up.run([.text(it.key), .text(it.cardId), .text(it.finish), .text(it.condition), .text(it.lang), .int(it.qty), .int(it.seq)])
            }
            let del = try db.prepare("DELETE FROM items WHERE k = ?")
            for k in delete { try del.run([.text(k)]) }
            try db.run("INSERT OR REPLACE INTO meta VALUES ('cursor', ?)", [.text(String(cursor))])
            try db.run("INSERT OR REPLACE INTO meta VALUES ('summary', ?)", [.text(json)])
        }
    }

    func clear() throws {
        try db.exec("DELETE FROM items; DELETE FROM meta;")
    }
}

@MainActor
@Observable
final class CollectionStore {
    static let shared = CollectionStore()

    nonisolated static func key(_ cardId: String, _ finish: String, _ condition: String, _ lang: String) -> String {
        "\(cardId)|\(finish)|\(condition)|\(lang)"
    }

    private(set) var userId: String?
    /// True once the local copy or a first sync has something to show.
    private(set) var ready = false
    private(set) var syncing = false
    var error: String?
    private(set) var items: [String: CollectionItem] = [:]
    private(set) var summary: LibrarySummary?
    /// Bumped on every change so views can recompute on it.
    private(set) var version = 0

    @ObservationIgnored private var local: LibraryDB?
    @ObservationIgnored private var cursor = 0
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var syncAgain = false
    #if DEBUG
    /// Set by `-T1LibraryDemo`: reads and writes go to local demo data instead of the server.
    @ObservationIgnored private(set) var demo: LibraryDemoBackend?
    #endif

    var isDemo: Bool {
        #if DEBUG
        demo != nil
        #else
        false
        #endif
    }

    #if DEBUG
    func startDemo(_ backend: LibraryDemoBackend) {
        stop()
        demo = backend
        userId = "demo"
        items = backend.items
        summary = backend.summary
        ready = true
        version += 1
    }
    #endif

    /// Opens (or switches to) an account's local copy, then syncs.
    func start(userId: String) async {
        guard self.userId != userId else { return }
        stop()
        self.userId = userId
        if let db = try? LibraryDB(userId: userId) {
            local = db
            if let saved = try? db.load() {
                items = saved.items
                cursor = saved.cursor
                summary = saved.summary
                ready = !saved.items.isEmpty || saved.cursor > 0
                version += 1
            }
        }
        await sync()
    }

    /// Signed out: forget the in-memory copy (the account's file stays for next time).
    func stop() {
        #if DEBUG
        demo = nil
        #endif
        userId = nil
        local = nil
        cursor = 0
        items = [:]
        summary = nil
        ready = false
        error = nil
        version += 1
    }

    /// Pulls every change after the local cursor. A call made while a run is in flight schedules one more run
    /// afterwards, so a write that lands mid-sync is always picked up.
    func sync() async {
        guard userId != nil else { return }
        #if DEBUG
        if demo != nil { return }
        #endif
        if let running = syncTask {
            syncAgain = true
            await running.value
            return
        }
        let task = Task { await runSync() }
        syncTask = task
        await task.value
        syncTask = nil
        if syncAgain {
            syncAgain = false
            await sync()
        }
    }

    private func runSync() async {
        guard let user = userId else { return }
        syncing = true
        error = nil
        defer { syncing = false }
        do {
            for _ in 0..<200 {
                let page: ChangesPage = try await supabase.rpc("collection_changes", params: [
                    "p_after": AnyJSON.integer(cursor), "p_limit": .integer(5000),
                ]).execute().value
                guard userId == user else { return }
                if page.resync {
                    cursor = 0
                    try? local?.clear()
                    items = [:]
                    version += 1
                    continue
                }
                var put: [CollectionItem] = []
                var del: [String] = []
                for row in page.items {
                    let it = row.item
                    if let held = items[it.key], held.seq > it.seq { continue } // a newer write is already shown
                    if it.qty > 0 {
                        items[it.key] = it
                        put.append(it)
                    } else {
                        items[it.key] = nil
                        del.append(it.key)
                    }
                }
                cursor = page.next
                try local?.commit(put: put, delete: del, cursor: cursor, summary: page.summary)
                summary = page.summary
                ready = true
                version += 1
                if !page.more { break }
            }
        } catch {
            if userId == user { self.error = error.localizedDescription }
        }
    }

    /// One user action = one batch with a fresh idempotency key (reused on the one automatic retry). Shows the
    /// result at once, then confirms with a delta sync.
    @discardableResult
    func apply(_ ops: [CollectionOp], source: String = "manual") async throws -> ApplyResult {
        #if DEBUG
        if let demo {
            let res = try demo.apply(ops, source: source)
            reflect(res)
            return res
        }
        #endif
        let key = UUID().uuidString.lowercased()
        let params: [String: AnyJSON] = [
            "p_ops": .array(ops.map(\.json)), "p_source": .string(source), "p_source_id": .null,
            "p_idempotency_key": .string(key),
        ]
        let res: ApplyResult = try await retryOnce { try await supabase.rpc("collection_apply", params: params).execute().value }
        reflect(res)
        Task { await sync() }
        return res
    }

    @discardableResult
    func undo(batchId: String) async throws -> ApplyResult {
        #if DEBUG
        if let demo {
            let res = try demo.undo(batchId: batchId)
            reflect(res)
            return res
        }
        #endif
        let params: [String: AnyJSON] = ["p_batch_id": .string(batchId), "p_idempotency_key": .string(UUID().uuidString.lowercased())]
        let res: ApplyResult = try await retryOnce { try await supabase.rpc("collection_undo", params: params).execute().value }
        reflect(res)
        Task { await sync() }
        return res
    }

    func history(cardId: String) async throws -> [HistoryEntry] {
        #if DEBUG
        if let demo { return demo.history(cardId: cardId) }
        #endif
        return try await supabase.rpc("collection_card_history", params: [
            "p_card_id": AnyJSON.string(cardId), "p_limit": .integer(50),
        ]).execute().value
    }

    /// Network failures only: the same idempotency key makes the retry safe.
    private func retryOnce<T>(_ call: () async throws -> T) async throws -> T {
        do { return try await call() } catch is URLError { return try await call() }
    }

    /// Writes a batch result into memory (not the file or the cursor: the following sync owns those).
    private func reflect(_ res: ApplyResult) {
        if res.duplicate { return }
        for r in res.items {
            let it = CollectionItem(cardId: r.cardId, finish: r.finish, condition: r.condition, lang: r.lang, qty: r.qty, seq: r.seq)
            items[it.key] = it.qty > 0 ? it : nil
        }
        summary = res.summary
        version += 1
    }
}
