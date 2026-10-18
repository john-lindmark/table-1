import Foundation
import Supabase

// Binders, "for trade" and wants (contract/binders-wants-2026-10-17.md). A binder holds some of an item's copies
// (an allocation); copies no binder holds are Unsorted. Allocations only change through collection_apply,
// binder_move and binder_delete on the server, which keeps them within each item's copies; this store mirrors
// binders, allocations and wants on the device and syncs them by seq (library_changes), right after the
// collection's own sync.

struct Binder: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var forTrade: Bool
    var seq: Int
}

/// Copies of one item a binder holds.
struct BinderAlloc: Codable, Hashable, Sendable {
    let binderId: String
    let cardId: String
    let finish: String
    let condition: String
    let lang: String
    var qty: Int
    var seq: Int
    var itemKey: String { CollectionStore.key(cardId, finish, condition, lang) }
    var key: String { "\(binderId)|\(itemKey)" }
}

/// One wishlist line. No card id = any printing; no finish = any finish of that printing.
struct Want: Codable, Hashable, Identifiable, Sendable {
    let oracleId: String
    let cardId: String?
    let finish: String?
    var qty: Int
    var maxUsd: Double?
    var seq: Int
    var id: String { Self.key(oracleId, cardId, finish) }
    static func key(_ o: String, _ c: String?, _ f: String?) -> String { "\(o)|\(c ?? "")|\(f ?? "")" }
}

/// [binder_id, card_id, finish, condition, lang, qty, seq]
struct AllocRow: Decodable, Sendable {
    let alloc: BinderAlloc
    init(_ a: BinderAlloc) { alloc = a }
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        alloc = BinderAlloc(binderId: try c.decode(String.self), cardId: try c.decode(String.self), finish: try c.decode(String.self),
                            condition: try c.decode(String.self), lang: try c.decode(String.self), qty: try c.decode(Int.self),
                            seq: try c.decode(Int.self))
    }
}

/// [oracle_id, card_id, finish, qty, max_usd, seq]
struct WantRow: Decodable, Sendable {
    let want: Want
    init(_ w: Want) { want = w }
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let o = try c.decode(String.self), card = try c.decodeIfPresent(String.self), f = try c.decodeIfPresent(String.self)
        let q = try c.decode(Int.self)
        // numeric arrives as a number (or, from some encoders, a string).
        var max: Double?
        if let d = try? c.decodeIfPresent(Double.self) { max = d } else { max = Double((try? c.decodeIfPresent(String.self)) ?? "") }
        want = Want(oracleId: o, cardId: card, finish: f, qty: q, maxUsd: max, seq: try c.decode(Int.self))
    }
}

struct BinderMove: Sendable {
    let item: CollectionItem
    /// nil = Unsorted.
    let from: String?
    let to: String?
    let qty: Int

    var json: AnyJSON {
        .object(["card_id": .string(item.cardId), "finish": .string(item.finish), "condition": .string(item.condition),
                 "lang": .string(item.lang), "from": from.map { .string($0) } ?? .null, "to": to.map { .string($0) } ?? .null,
                 "qty": .integer(qty)])
    }
}

struct WantOp: Sendable {
    let oracleId: String
    var cardId: String?
    var finish: String?
    var qty: Int?
    var delta: Int?
    /// .some(nil) clears the max price; nil leaves it.
    var maxUsd: Double??

    var json: AnyJSON {
        var o: [String: AnyJSON] = ["oracle_id": .string(oracleId)]
        if let cardId { o["card_id"] = .string(cardId) }
        if let finish { o["finish"] = .string(finish) }
        if let qty { o["qty"] = .integer(qty) }
        if let delta { o["delta"] = .integer(delta) }
        if let maxUsd { o["max_usd"] = maxUsd.map { .double($0) } ?? .null }
        return .object(o)
    }
}

// MARK: rules (shared with the Debug demo, which applies them locally; the server is the authority)

enum BinderRules {
    /// One item's allocations after a change: hints first (a binder's copies added, or taken out of it first),
    /// then whatever exceeds `newQty` comes out of binders not for trade, then for-trade binders, each by name.
    /// Unsorted copies are what's left over, so they always go first.
    static func plan(current: [String: Int], hints: [String: Int], newQty: Int, binders: [String: Binder]) -> [String: Int] {
        var out = current
        for (b, d) in hints where binders[b] != nil { out[b] = max(0, (out[b] ?? 0) + d) }
        var excess = out.values.reduce(0, +) - newQty
        if excess > 0 {
            let order = out.keys.filter { (out[$0] ?? 0) > 0 }.sorted { a, b in
                let x = binders[a], y = binders[b]
                let ka = (x?.forTrade == true ? 1 : 0, x?.name.lowercased() ?? "", a), kb = (y?.forTrade == true ? 1 : 0, y?.name.lowercased() ?? "", b)
                return ka < kb
            }
            for b in order where excess > 0 {
                let take = min(out[b] ?? 0, excess)
                out[b] = (out[b] ?? 0) - take
                excess -= take
            }
        }
        return out
    }

    /// Ops that point a want at another printing (`cardId` nil = any printing; `finish` only with a printing): the
    /// old want comes off and its copies are added to the new one (merging into a want already there), keeping its
    /// max price. Nil when it already points there.
    static func repoint(_ w: Want, cardId: String?, finish: String?) -> [WantOp]? {
        let finish = cardId == nil ? nil : finish
        if w.cardId == cardId && w.finish == finish { return nil }
        return [WantOp(oracleId: w.oracleId, cardId: w.cardId, finish: w.finish, qty: 0),
                WantOp(oracleId: w.oracleId, cardId: cardId, finish: finish, delta: w.qty, maxUsd: .some(w.maxUsd))]
    }

    /// Where Move in (adding a card you own to a binder, `target` nil = Unsorted) takes one copy from: Unsorted
    /// first, then binders not for trade, then for-trade binders, each by name; in one place, the item with the most
    /// copies there. Never the target itself. Nil when every copy is already there.
    static func moveInSource(_ places: [(item: CollectionItem, from: Binder?, qty: Int)], into target: String?) -> (item: CollectionItem, from: String?)? {
        places.filter { $0.qty > 0 && $0.from?.id != target }
            .min { a, b in
                let ka = (a.from == nil ? 0 : a.from!.forTrade ? 2 : 1, a.from?.name.lowercased() ?? "", -a.qty, a.item.key)
                let kb = (b.from == nil ? 0 : b.from!.forTrade ? 2 : 1, b.from?.name.lowercased() ?? "", -b.qty, b.item.key)
                return ka < kb
            }
            .map { ($0.item, $0.from?.id) }
    }

    /// The want a trade's get meets first: that printing and finish, then that printing, then any printing.
    static func wantFor(oracleId: String, cardId: String, finish: String, in wants: [Want]) -> Want? {
        let live = wants.filter { $0.oracleId == oracleId && $0.qty > 0 }
        return live.first { $0.cardId == cardId && $0.finish == finish }
            ?? live.first { $0.cardId == cardId && $0.finish == nil }
            ?? live.first { $0.cardId == nil }
    }

    /// Takes `qty` copies of a printing off the wants they meet, in that order. Returns the wants that changed.
    static func meet(oracleId: String, cardId: String, finish: String, qty: Int, wants: inout [String: Want]) -> [Want] {
        var left = qty, changed: [Want] = []
        while left > 0, let w = wantFor(oracleId: oracleId, cardId: cardId, finish: finish, in: Array(wants.values)) {
            let n = min(left, w.qty)
            var nw = w
            nw.qty -= n
            wants[w.id] = nw
            changed.append(nw)
            left -= n
        }
        return changed
    }
}

/// A deck or cube line you own fewer copies of than it asks for.
struct MissingLine: Hashable, Identifiable, Sendable {
    let cardId: String
    let finish: String
    /// The largest need across lists, minus what you own.
    let short: Int
    /// Names of the lists that need more than you own.
    let lists: [String]
    var id: String { "\(cardId)|\(finish)" }
}

enum MissingView {
    /// Every list line (not Considering, not roto event decks) short of copies, per printing × finish, with the
    /// largest need across lists: lists don't reserve copies, so one set of copies covers them all.
    static func lines(_ lists: [CardList], owned: [String: Int]) -> [MissingLine] {
        var need: [String: (max: Int, lists: [String])] = [:]
        for l in lists where l.eventId == nil {
            var mine: [String: Int] = [:]
            for e in l.entries where e.board != "maybe" { mine["\(e.cardId)|\(e.finish)", default: 0] += e.qty }
            for (k, n) in mine where n > (owned[k] ?? 0) {
                var v = need[k] ?? (0, [])
                v.max = max(v.max, n)
                v.lists.append(l.name)
                need[k] = v
            }
        }
        return need.map { k, v in
            let parts = k.split(separator: "|", maxSplits: 1).map(String.init)
            return MissingLine(cardId: parts[0], finish: parts[1], short: v.max - (owned[k] ?? 0), lists: v.lists.sorted())
        }
        .sorted { $0.short != $1.short ? $0.short > $1.short : $0.id < $1.id }
    }
}

// MARK: store

private struct LibraryPage: Decodable {
    struct BinderDTO: Decodable {
        let id: String
        let name: String
        let forTrade: Bool
        let deleted: Bool
        let seq: Int
    }
    let resync: Bool
    let binders: [BinderDTO]
    let binderItems: [AllocRow]
    let wants: [WantRow]
    let next: Int
    let more: Bool
}

private struct BinderDTOResult: Decodable {
    let id: String
    let name: String
    let forTrade: Bool
    let deleted: Bool
    let seq: Int
}

private struct DeleteResult: Decodable {
    let binderItems: [AllocRow]
}

private struct WantsResult: Decodable {
    let duplicate: Bool
    let wants: [WantRow]
}

/// What the store keeps on disk per account.
private struct BindersFile: Codable {
    var binders: [Binder]
    var allocs: [BinderAlloc]
    var wants: [Want]
    var cursor: Int
}

@MainActor
@Observable
final class BindersStore {
    static let shared = BindersStore()

    /// Live binders, by name.
    private(set) var binders: [Binder] = []
    private(set) var allocs: [String: BinderAlloc] = [:]
    private(set) var wants: [String: Want] = [:]
    private(set) var version = 0
    var error: String?

    @ObservationIgnored private var userId: String?
    @ObservationIgnored private var cursor = 0
    @ObservationIgnored private var byItem: [String: [BinderAlloc]] = [:]
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private var isDemo: Bool { CollectionStore.shared.isDemo }

    // MARK: reading

    func binder(_ id: String) -> Binder? { binders.first { $0.id == id } }
    var liveWants: [Want] { wants.values.filter { $0.qty > 0 }.sorted { $0.seq > $1.seq } }

    /// Where an item's copies are: each binder holding some, by name, then Unsorted (never below 0).
    func placement(_ item: CollectionItem) -> (binders: [(binder: Binder, qty: Int)], unsorted: Int) {
        let held = (byItem[item.key] ?? []).compactMap { a in binder(a.binderId).map { ($0, a.qty) } }
            .sorted { $0.0.name.lowercased() < $1.0.name.lowercased() }
        return (held, max(0, item.qty - held.reduce(0) { $0 + $1.1 }))
    }

    /// Every place an item's copies are, Unsorted as a nil binder.
    func places(_ items: [CollectionItem]) -> [(item: CollectionItem, from: Binder?, qty: Int)] {
        items.flatMap { it -> [(item: CollectionItem, from: Binder?, qty: Int)] in
            let p = placement(it)
            return p.binders.map { (it, Optional($0.binder), $0.qty) } + (p.unsorted > 0 ? [(it, nil, p.unsorted)] : [])
        }
    }

    /// "Trade binder 2 · Unsorted 1", or nil when every copy is Unsorted.
    func placementText(_ item: CollectionItem) -> String? {
        let p = placement(item)
        if p.binders.isEmpty { return nil }
        return (p.binders.map { "\($0.binder.name) \($0.qty)" } + (p.unsorted > 0 ? ["Unsorted \(p.unsorted)"] : [])).joined(separator: " · ")
    }

    /// Copies of an item in for-trade binders, and the for-trade binder holding most of them.
    func forTrade(_ itemKey: String) -> (qty: Int, binderId: String?) {
        let held = (byItem[itemKey] ?? []).filter { binder($0.binderId)?.forTrade == true }
        return (held.reduce(0) { $0 + $1.qty }, held.max { $0.qty < $1.qty }?.binderId)
    }

    /// Printing → finishes that for-trade binders hold (the give-side scanner prefers these).
    func forTradePrintings() -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for a in allocs.values where a.qty > 0 && binder(a.binderId)?.forTrade == true { out[a.cardId, default: []].insert(a.finish) }
        return out
    }

    /// Copies each binder holds, clamped to what each item has.
    func totals(_ items: [String: CollectionItem]) -> (byBinder: [String: Int], unsorted: Int) {
        var by: [String: Int] = [:], unsorted = 0
        for it in items.values {
            let p = placement(it)
            for (b, q) in p.binders { by[b.id, default: 0] += min(q, it.qty) }
            unsorted += p.unsorted
        }
        return (by, unsorted)
    }

    /// Items with copies in a binder (nil = Unsorted), with how many are there.
    func items(in binderId: String?, _ items: [String: CollectionItem]) -> [(item: CollectionItem, qty: Int)] {
        items.values.compactMap { it in
            let p = placement(it)
            let n = binderId.map { id in p.binders.first { $0.binder.id == id }?.qty ?? 0 } ?? p.unsorted
            return n > 0 ? (it, min(n, it.qty)) : nil
        }
    }

    // MARK: lifecycle

    func start(userId: String) async {
        guard self.userId != userId else { return await sync() }
        stop()
        self.userId = userId
        if let f = Self.load(userId) {
            binders = f.binders.sorted { $0.name.lowercased() < $1.name.lowercased() }
            allocs = Dictionary(f.allocs.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            wants = Dictionary(f.wants.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            cursor = f.cursor
            reindex()
        }
        await sync()
    }

    func stop() {
        userId = nil
        cursor = 0
        binders = []
        allocs = [:]
        wants = [:]
        byItem = [:]
        error = nil
        version += 1
    }

    #if DEBUG
    func startDemo(binders: [Binder], allocs: [BinderAlloc], wants: [Want]) {
        stop()
        self.binders = binders.sorted { $0.name.lowercased() < $1.name.lowercased() }
        self.allocs = Dictionary(allocs.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        self.wants = Dictionary(wants.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        reindex()
    }
    #endif

    func sync() async {
        guard userId != nil, !isDemo else { return }
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
        do {
            for _ in 0..<200 {
                let page: LibraryPage = try await supabase.rpc("library_changes", params: [
                    "p_after": AnyJSON.integer(cursor), "p_limit": .integer(5000),
                ]).execute().value
                guard userId == user else { return }
                if page.resync {
                    cursor = 0
                    binders = []
                    allocs = [:]
                    wants = [:]
                    continue
                }
                for b in page.binders {
                    binders.removeAll { $0.id == b.id }
                    if !b.deleted { binders.append(Binder(id: b.id, name: b.name, forTrade: b.forTrade, seq: b.seq)) }
                }
                binders.sort { $0.name.lowercased() < $1.name.lowercased() }
                apply(allocs: page.binderItems.map(\.alloc))
                apply(wants: page.wants.map(\.want))
                cursor = page.next
                if !page.more { break }
            }
            error = nil
            reindex()
            persist()
        } catch {
            if userId == user { self.error = error.localizedDescription }
        }
    }

    /// Writes rows a call returned into memory (the next sync owns the cursor and the file).
    func reflect(allocs rows: [BinderAlloc]) {
        guard !rows.isEmpty else { return }
        apply(allocs: rows)
        reindex()
    }

    func reflect(wants rows: [Want]) {
        guard !rows.isEmpty else { return }
        apply(wants: rows)
        version += 1
    }

    private func apply(allocs rows: [BinderAlloc]) {
        for a in rows {
            if let held = allocs[a.key], held.seq > a.seq { continue }
            allocs[a.key] = a.qty > 0 ? a : nil
        }
    }

    private func apply(wants rows: [Want]) {
        for w in rows {
            if let held = wants[w.id], held.seq > w.seq { continue }
            wants[w.id] = w.qty > 0 ? w : nil
        }
    }

    private func reindex() {
        byItem = Dictionary(grouping: allocs.values.filter { $0.qty > 0 }, by: \.itemKey)
        version += 1
    }

    // MARK: writing

    /// Creates (new id) or renames / flags a binder.
    @discardableResult
    func save(id: String? = nil, name: String, forTrade: Bool) async throws -> Binder {
        let id = id ?? UUID().uuidString.lowercased()
        let isNew = binder(id) == nil
        let old = binder(id)
        let saved: Binder
        #if DEBUG
        if let demo = CollectionStore.shared.demo {
            saved = try demo.saveBinder(id: id, name: name, forTrade: forTrade)
            put(saved)
            track(isNew: isNew, old: old, saved: saved)
            return saved
        }
        #endif
        let r: BinderDTOResult = try await supabase.rpc("binder_save", params: [
            "p_id": AnyJSON.string(id), "p_name": .string(name), "p_for_trade": .bool(forTrade),
        ]).execute().value
        saved = Binder(id: r.id, name: r.name, forTrade: r.forTrade, seq: r.seq)
        put(saved)
        track(isNew: isNew, old: old, saved: saved)
        Task { await sync() }
        return saved
    }

    private func track(isNew: Bool, old: Binder?, saved: Binder) {
        if isNew {
            Telemetry.capture("binder_created", ["for_trade": saved.forTrade])
        } else if let old, old != saved {
            Telemetry.capture("binder_updated", ["renamed": old.name != saved.name, "for_trade": saved.forTrade])
        }
    }

    private func put(_ b: Binder) {
        binders.removeAll { $0.id == b.id }
        binders.append(b)
        binders.sort { $0.name.lowercased() < $1.name.lowercased() }
        version += 1
    }

    /// Deletes a binder; its copies go back to Unsorted.
    func delete(_ b: Binder) async throws {
        let copies = allocs.values.filter { $0.binderId == b.id }.reduce(0) { $0 + $1.qty }
        var rows: [BinderAlloc]
        #if DEBUG
        if let demo = CollectionStore.shared.demo {
            rows = demo.deleteBinder(b.id)
            finishDelete(b, rows, copies)
            return
        }
        #endif
        let r: DeleteResult = try await supabase.rpc("binder_delete", params: [
            "p_id": AnyJSON.string(b.id), "p_idempotency_key": .string(UUID().uuidString.lowercased()),
        ]).execute().value
        rows = r.binderItems.map(\.alloc)
        finishDelete(b, rows, copies)
        Task { await sync() }
    }

    private func finishDelete(_ b: Binder, _ rows: [BinderAlloc], _ copies: Int) {
        binders.removeAll { $0.id == b.id }
        apply(allocs: rows)
        for k in allocs.keys where allocs[k]?.binderId == b.id { allocs[k] = nil }
        reindex()
        Telemetry.capture("binder_deleted", ["copies": copies])
    }

    /// Moves copies; one batch, so Undo moves them back. Returns the batch id.
    @discardableResult
    func move(_ moves: [BinderMove]) async throws -> String {
        guard !moves.isEmpty else { return "" }
        let res: ApplyResult
        #if DEBUG
        if let demo = CollectionStore.shared.demo {
            res = try demo.move(moves)
            reflect(allocs: res.binderItems)
            trackMove(moves)
            return res.batchId
        }
        #endif
        res = try await supabase.rpc("binder_move", params: [
            "p_moves": AnyJSON.array(moves.map(\.json)), "p_idempotency_key": .string(UUID().uuidString.lowercased()),
        ]).execute().value
        reflect(allocs: res.binderItems)
        trackMove(moves)
        Task { await sync() }
        return res.batchId
    }

    private func trackMove(_ moves: [BinderMove]) {
        Telemetry.capture("binder_copies_moved", ["copies": moves.reduce(0) { $0 + $1.qty },
                                                  "from": moves.first?.from == nil ? "unsorted" : "binder",
                                                  "to": moves.first?.to == nil ? "unsorted" : "binder"])
    }

    /// One wishlist edit.
    func applyWants(_ ops: [WantOp], event: String? = nil, props: [String: Any] = [:]) async throws {
        guard !ops.isEmpty else { return }
        #if DEBUG
        if let demo = CollectionStore.shared.demo {
            reflect(wants: try demo.applyWants(ops))
            if let event { Telemetry.capture(event, props) }
            return
        }
        #endif
        let r: WantsResult = try await supabase.rpc("wants_apply", params: [
            "p_ops": AnyJSON.array(ops.map(\.json)), "p_idempotency_key": .string(UUID().uuidString.lowercased()),
        ]).execute().value
        reflect(wants: r.wants.map(\.want))
        if let event { Telemetry.capture(event, props) }
        if r.duplicate { Task { await sync() } }
    }

    // MARK: file

    nonisolated private static func url(_ userId: String) -> URL {
        URL.applicationSupportDirectory.appending(path: "Library", directoryHint: .isDirectory).appending(path: "binders-\(userId).json")
    }

    private static func load(_ userId: String) -> BindersFile? {
        guard let data = try? Data(contentsOf: url(userId)) else { return nil }
        return try? JSONDecoder().decode(BindersFile.self, from: data)
    }

    private func persist() {
        guard let userId, !isDemo else { return }
        let file = BindersFile(binders: binders, allocs: Array(allocs.values), wants: Array(wants.values), cursor: cursor)
        saveTask?.cancel()
        saveTask = Task.detached(priority: .utility) {
            let u = BindersStore.url(userId)
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(file) { try? data.write(to: u, options: .atomic) }
        }
    }
}
