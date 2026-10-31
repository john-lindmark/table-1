import Foundation
import Supabase
import WidgetKit

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

struct CollectionOp: Codable {
    let cardId: String
    var finish: String = Finish.nonfoil.rawValue
    var condition = "NM"
    var lang = "en"
    var delta: Int?
    var qty: Int?
    /// With a delta: added copies go into this binder; removed copies come out of it first.
    var binderId: String?

    var json: AnyJSON {
        var o: [String: AnyJSON] = [
            "card_id": .string(cardId), "finish": .string(finish), "condition": .string(condition), "lang": .string(lang),
        ]
        if let delta { o["delta"] = .integer(delta) }
        if let qty { o["qty"] = .integer(qty) }
        if let binderId { o["binder_id"] = .string(binderId) }
        return .object(o)
    }
    var itemKey: String { CollectionStore.key(cardId, finish, condition, lang) }
}

/// A batch of adds that failed on the network and waits on the device to be sent again with the same idempotency
/// key (contract/offline-2026-10-31.md § 3).
struct OutboxBatch: Codable {
    let key: String
    let source: String
    let ops: [CollectionOp]
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
    /// Allocations the batch changed (contract/binders-wants-2026-10-17.md).
    var binderItems: [BinderAlloc] = []
    /// Wants a trade met, or an undo put back.
    var wants: [Want] = []

    private enum CodingKeys: String, CodingKey { case batchId, duplicate, items, summary, binderItems, wants }

    init(batchId: String, duplicate: Bool, items: [Row], summary: LibrarySummary, binderItems: [BinderAlloc] = [], wants: [Want] = []) {
        self.batchId = batchId
        self.duplicate = duplicate
        self.items = items
        self.summary = summary
        self.binderItems = binderItems
        self.wants = wants
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        batchId = try c.decode(String.self, forKey: .batchId)
        duplicate = try c.decode(Bool.self, forKey: .duplicate)
        items = try c.decodeIfPresent([Row].self, forKey: .items) ?? []
        summary = try c.decode(LibrarySummary.self, forKey: .summary)
        binderItems = try c.decodeIfPresent([AllocRow].self, forKey: .binderItems)?.map(\.alloc) ?? []
        wants = try c.decodeIfPresent([WantRow].self, forKey: .wants)?.map(\.want) ?? []
    }
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
        // Adds made offline: on screen again on top of the mirror, sent with the first sync.
        outbox = Self.loadOutbox(userId)
        for b in outbox { showAdds(b.ops) }
        await sync()
    }

    // MARK: outbox (adds that failed on the network; contract/offline-2026-10-31.md § 3)

    /// Batches waiting to be sent, in order. Each keeps its idempotency key, so the retry can't double-count.
    private(set) var outbox: [OutboxBatch] = []
    /// "3 changes waiting to send" on the Collection home while the outbox isn't empty.
    var outboxNotice: String? {
        outbox.isEmpty ? nil : outbox.count == 1 ? "1 change waiting to send" : "\(outbox.count) changes waiting to send"
    }

    nonisolated private static func outboxURL(_ userId: String) -> URL {
        let dir = URL.applicationSupportDirectory.appending(path: "Library", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "outbox-\(userId).json")
    }

    nonisolated private static func loadOutbox(_ userId: String) -> [OutboxBatch] {
        guard let data = try? Data(contentsOf: outboxURL(userId)) else { return [] }
        return (try? JSONDecoder().decode([OutboxBatch].self, from: data)) ?? []
    }

    private func persistOutbox() {
        guard let userId else { return }
        if outbox.isEmpty { try? FileManager.default.removeItem(at: Self.outboxURL(userId)); return }
        if let data = try? JSONEncoder().encode(outbox) { try? data.write(to: Self.outboxURL(userId), options: .atomic) }
    }

    private static func applyParams(_ ops: [CollectionOp], source: String, key: String) -> [String: AnyJSON] {
        ["p_ops": .array(ops.map(\.json)), "p_source": .string(source), "p_source_id": .null, "p_idempotency_key": .string(key)]
    }

    /// Sends the outbox in order before a sync. A batch the server refuses is taken back; a network failure keeps
    /// the rest for next time.
    private func flushOutbox(_ user: String) async {
        var sent = 0
        while let b = outbox.first, userId == user {
            do {
                let res: ApplyResult = try await supabase.rpc("collection_apply", params: Self.applyParams(b.ops, source: b.source, key: b.key))
                    .execute().value
                guard userId == user else { return }
                outbox.removeFirst()
                persistOutbox()
                reflect(res)
                sent += 1
            } catch where Offline.isNetwork(error) || error.isCancellation {
                break
            } catch {
                guard userId == user else { return }
                takeBackAdds(b.ops)
                outbox.removeFirst()
                persistOutbox()
                self.error = "A change made offline was refused: \(error.localizedDescription)"
            }
        }
        if sent > 0 { Telemetry.capture("outbox_sent", ["batches": sent]) }
    }

    /// A result for a batch that waits in the outbox: Undo takes it out again.
    private func queuedResult(_ key: String) -> ApplyResult {
        ApplyResult(batchId: "queued:\(key)", duplicate: false, items: [],
                    summary: summary ?? LibrarySummary(totalQty: 0, uniquePrintings: 0, uniqueCards: 0, valueUsd: 0, valueEur: 0, seq: 0))
    }

    /// The Collection value widget's daily point (contract/widgets-2026-10-22.md); never for the demo.
    private func noteValue() {
        guard !isDemo, let userId, let s = summary else { return }
        if ValueStore.note(userId: userId, usd: s.valueUsd, cards: s.uniqueCards, copies: s.totalQty) {
            WidgetCenter.shared.reloadTimelines(ofKind: "site.table1.value")
        }
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
        outbox = []
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
            return
        }
        // Binders, allocations and wants follow the items (their own cursor, library_changes).
        await BindersStore.shared.sync()
    }

    private func runSync() async {
        guard let user = userId else { return }
        syncing = true
        error = nil
        defer { syncing = false }
        await flushOutbox(user)
        guard userId == user else { return }
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
                    for b in outbox { showAdds(b.ops) }
                    version += 1
                    continue
                }
                // The server hasn't counted adds still in the outbox: rows show its count plus them (the mirror keeps
                // the server's, so the next launch adds them once).
                let queued = Offline.deltas(outbox.map(\.ops))
                var put: [CollectionItem] = []
                var del: [String] = []
                for row in page.items {
                    let it = row.item
                    if let held = items[it.key], held.seq > it.seq { continue } // a newer write is already shown
                    if it.qty > 0 { put.append(it) } else { del.append(it.key) }
                    let shown = it.qty + (queued[it.key] ?? 0)
                    items[it.key] = shown > 0 ? CollectionItem(cardId: it.cardId, finish: it.finish, condition: it.condition,
                                                                lang: it.lang, qty: shown, seq: it.seq) : nil
                }
                cursor = page.next
                try local?.commit(put: put, delete: del, cursor: cursor, summary: page.summary)
                summary = page.summary
                noteValue()
                ready = true
                version += 1
                if !page.more { break }
            }
        } catch {
            if userId == user { self.error = error.localizedDescription }
        }
    }

    /// One user action = one batch with a fresh idempotency key (reused on the one automatic retry). Added copies
    /// show before the server answers (`showAdds`), the answer replaces them, then a delta sync confirms. `key`: a
    /// caller that retries a batch itself (an import's chunks) passes the same key each time, so a batch that
    /// already landed replays as a duplicate.
    @discardableResult
    func apply(_ ops: [CollectionOp], source: String = "manual", key: String? = nil) async throws -> ApplyResult {
        #if DEBUG
        if let demo {
            let res = try demo.apply(ops, source: source)
            reflect(res)
            return res
        }
        #endif
        let key = key ?? UUID().uuidString.lowercased()
        let params = Self.applyParams(ops, source: source, key: key)
        showAdds(ops)
        // Behind batches already waiting: sent after them, in order, so the server sees them as they were made.
        if !outbox.isEmpty, Offline.queues(ops, network: true) {
            outbox.append(OutboxBatch(key: key, source: source, ops: ops))
            persistOutbox()
            Telemetry.capture("outbox_queued", ["ops": ops.count])
            Task { await sync() }
            return queuedResult(key)
        }
        let res: ApplyResult
        do {
            res = try await retryOnce { try await supabase.rpc("collection_apply", params: params).execute().value }
        } catch {
            // Adds that couldn't reach the server stay on screen and wait in the outbox (contract/offline-2026-10-31.md § 3).
            if Offline.queues(ops, network: Offline.isNetwork(error)), userId != nil {
                outbox.append(OutboxBatch(key: key, source: source, ops: ops))
                persistOutbox()
                Telemetry.capture("outbox_queued", ["ops": ops.count])
                return queuedResult(key)
            }
            takeBackAdds(ops)
            Task { await sync() }
            throw error
        }
        Telemetry.capture("collection_changed", ["source": source, "ops": ops.count, "copies": ops.reduce(0) { $0 + ($1.delta ?? 0) }])
        // A card added by hand right after a scan was deleted or missed tells which card it was (ScanReports).
        if source == "manual", let added = ops.first(where: { ($0.delta ?? 0) > 0 })?.cardId {
            Task { @MainActor in ScanReports.addedByHand(added) }
        }
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
        // A batch still in the outbox: out of the outbox and off the screen, nothing to undo on the server.
        if batchId.hasPrefix("queued:") {
            let key = String(batchId.dropFirst("queued:".count))
            if let i = outbox.firstIndex(where: { $0.key == key }) {
                takeBackAdds(outbox[i].ops)
                outbox.remove(at: i)
                persistOutbox()
            }
            Telemetry.capture("collection_undone")
            return queuedResult(key)
        }
        let params: [String: AnyJSON] = ["p_batch_id": .string(batchId), "p_idempotency_key": .string(UUID().uuidString.lowercased())]
        let res: ApplyResult = try await retryOnce { try await supabase.rpc("collection_undo", params: params).execute().value }
        Telemetry.capture("collection_undone")
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

    /// A batch's added copies (and the binders they go into), shown while the server works, so a scan session's
    /// cards are on screen the moment it ends instead of a round trip later. Removals wait for the server, which
    /// owns the binder rules. Memory only: the answer (`reflect`) or a sync replaces these rows.
    func showAdds(_ ops: [CollectionOp]) {
        shiftAdds(ops, by: 1)
    }

    /// The call failed: takes back what `showAdds` put on screen.
    func takeBackAdds(_ ops: [CollectionOp]) {
        shiftAdds(ops, by: -1)
    }

    private func shiftAdds(_ ops: [CollectionOp], by sign: Int) {
        guard ops.contains(where: { ($0.delta ?? 0) > 0 }) else { return }
        BindersStore.shared.shift(allocs: Self.shiftAdds(&items, ops, by: sign))
        version += 1
    }

    /// Adds (sign 1) or takes back (-1) each op's added copies in `items`, keeping the held seq so a sync row is
    /// never skipped for it; returns the binder copies to shift with them. Cases: testdata/show-adds/cases.json.
    nonisolated static func shiftAdds(_ items: inout [String: CollectionItem], _ ops: [CollectionOp], by sign: Int) -> [BinderAlloc] {
        var allocs: [BinderAlloc] = []
        for op in ops {
            guard let d = op.delta, d > 0 else { continue }
            let held = items[op.itemKey]
            let qty = (held?.qty ?? 0) + sign * d
            items[op.itemKey] = qty > 0 ? CollectionItem(cardId: op.cardId, finish: op.finish, condition: op.condition, lang: op.lang,
                                                         qty: qty, seq: held?.seq ?? 0) : nil
            if let b = op.binderId {
                allocs.append(BinderAlloc(binderId: b, cardId: op.cardId, finish: op.finish, condition: op.condition, lang: op.lang,
                                          qty: sign * d, seq: 0))
            }
        }
        return allocs
    }

    /// Writes a batch result into memory (not the file or the cursor: the following sync owns those).
    func reflect(_ res: ApplyResult) {
        if res.duplicate { return }
        for r in res.items {
            let it = CollectionItem(cardId: r.cardId, finish: r.finish, condition: r.condition, lang: r.lang, qty: r.qty, seq: r.seq)
            items[it.key] = it.qty > 0 ? it : nil
        }
        summary = res.summary
        noteValue()
        BindersStore.shared.reflect(allocs: res.binderItems)
        BindersStore.shared.reflect(wants: res.wants)
        version += 1
    }
}
