import Supabase
import SwiftUI

// Cube rankings (contract/cube-rankings-2026-10-21.md): stack-rank a cube's cards, cuberanker.com style. The server
// keeps each ranking's screen log; everything shown is worked out from it on the device (CubeRanking.swift). One
// RankingModel per open ranking is shared by its screens: it holds the log, saves locked-in screens one push at a
// time, and re-reads someone else's ranking while it's open so it can be watched live.

struct RankingCube: Decodable, Hashable, Sendable {
    let id: String
    var name: String
    var mine: Bool
    var owner: Person?
    var canSee: Bool?
    /// cube_ranking_get only: the main board's Oracle ids.
    var cards: [String]?
    /// cube_ranking_get only: Oracle id → the printing the cube holds, so cards show as they are in the cube.
    var printings: [String: String]?
}

struct RankingRow: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let listId: String
    var name: String
    var depth: String
    var top: Int
    var sharing: String
    var screens: Int
    var rev: Int
    var sorted: Int
    var categories: Int
    var ranked: Int
    var updatedAt: String?
    var mine: Bool
    var by: Person?
    var cube: RankingCube?

    var whose: String { mine ? "Your ranking" : "\(by?.displayName ?? "Someone")'s ranking" }
    var progress: String { "\(sorted)/\(categories) sorted · \(ranked)/\(top) ranked" }
    /// "Oct 21": when it last changed.
    var updatedShort: String? {
        guard let updatedAt, let d = ISO8601DateFormatter.flexible(updatedAt) else { return nil }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// ranking-brief: Claude's 2-5 sentence comparison of two rankings for one list, or why there isn't one yet.
struct RankingBrief: Decodable, Hashable, Sendable {
    var brief: String?
    var reason: String?
    var cached: Bool?
    var error: String?
    /// The demo's stand-in.
    var sample: Bool?
}

/// rankable_cubes: someone else's cube you can rank, with how many rankings of it you can see and how many are yours.
struct RankableCube: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var owner: Person?
    var cards: Int
    var rankings: Int
    var mine: Int
}

struct CubeRankings: Decodable, Sendable {
    var cube: RankingCube?
    var canRank: Bool
    var rankings: [RankingRow]
}

/// cube_ranking_get: the row, its whole log, its change log and its cube.
struct RankingDetail: Decodable, Sendable {
    var row: RankingRow
    var log: [RankScreen]
    var changes: [RankChange] = []
    var cube: RankingCube?

    private enum K: String, CodingKey { case log, changes, cube }
    init(row: RankingRow, log: [RankScreen], changes: [RankChange] = [], cube: RankingCube?) {
        self.row = row; self.log = log; self.changes = changes; self.cube = cube
    }
    init(from d: Decoder) throws {
        row = try RankingRow(from: d)
        let c = try d.container(keyedBy: K.self)
        log = try c.decode([RankScreen].self, forKey: .log)
        changes = try c.decodeIfPresent([RankChange].self, forKey: .changes) ?? []
        cube = try c.decodeIfPresent(RankingCube.self, forKey: .cube)
    }
}

extension ISO8601DateFormatter {
    static func flexible(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

@MainActor
@Observable
final class RankingsStore {
    static let shared = RankingsStore()
    /// Open rankings, shared by their screens.
    @ObservationIgnored private var models: [String: RankingModel] = [:]
    #if DEBUG
    @ObservationIgnored var demo: RankingsDemoBackend?
    #endif

    func model(_ id: String) -> RankingModel {
        if let m = models[id] { return m }
        let m = RankingModel(id: id)
        models[id] = m
        return m
    }

    func stop() { models = [:] }

    func rankings(listId: String?) async throws -> CubeRankings {
        #if DEBUG
        if let demo { return demo.rankings(listId: listId) }
        #endif
        return try await supabase.rpc("cube_rankings", params: ["p_list_id": listId.map { AnyJSON.string($0) } ?? .null]).execute().value
    }

    /// Briefs already fetched this session, by "a|b|list".
    @ObservationIgnored private var briefs: [String: RankingBrief] = [:]

    /// The brief comparing ranking `a` with `b` on one list (written once per change on the server, then cached).
    func brief(a: String, b: String, list: RankJob) async throws -> RankingBrief {
        let key = "\(a)|\(b)|\(list.rawValue)"
        if let hit = briefs[key] { return hit }
        let r: RankingBrief
        #if DEBUG
        if let demo { r = demo.brief(a: a, b: b, list: list) } else { r = try await briefLive(a: a, b: b, list: list) }
        #else
        r = try await briefLive(a: a, b: b, list: list)
        #endif
        if r.brief != nil || r.reason != nil { briefs[key] = r }
        Telemetry.capture(r.brief != nil ? "ranking_brief_shown" : "ranking_brief_missing", ["list": list.rawValue, "cached": r.cached ?? false])
        return r
    }

    private func briefLive(a: String, b: String, list: RankJob) async throws -> RankingBrief {
        do {
            return try await supabase.functions.invoke("ranking-brief", options: FunctionInvokeOptions(body: ["a": a, "b": b, "list": list.rawValue])) { data, _ in
                try JSONDecoder().decode(RankingBrief.self, from: data)
            }
        } catch FunctionsError.httpError(_, let data) {
            let r = try? JSONDecoder().decode(RankingBrief.self, from: data)
            throw RankingsDemoBackendError(r?.error ?? "The brief couldn't be written just now.")
        }
    }

    /// Other people's cubes you can see and rank (friends' and people you've played with).
    func rankable() async throws -> [RankableCube] {
        #if DEBUG
        if let demo { return demo.rankable() }
        #endif
        return try await supabase.rpc("rankable_cubes").execute().value
    }

    func get(_ id: String) async throws -> RankingDetail {
        #if DEBUG
        if let demo { return try demo.get(id) }
        #endif
        return try await supabase.rpc("cube_ranking_get", params: ["p_id": id]).execute().value
    }

    func create(listId: String, name: String, depth: String, top: Int, sharing: String, ownCube: Bool) async throws -> RankingRow {
        let id = UUID().uuidString.lowercased()
        let row: RankingRow
        #if DEBUG
        if let demo { row = demo.create(id: id, listId: listId, name: name, depth: depth, top: top, sharing: sharing) } else {
            row = try await createLive(id: id, listId: listId, name: name, depth: depth, top: top, sharing: sharing)
        }
        #else
        row = try await createLive(id: id, listId: listId, name: name, depth: depth, top: top, sharing: sharing)
        #endif
        Telemetry.capture("ranking_created", ["depth": depth, "top": top, "sharing": sharing, "own_cube": ownCube])
        return row
    }

    private func createLive(id: String, listId: String, name: String, depth: String, top: Int, sharing: String) async throws -> RankingRow {
        try await supabase.rpc("cube_ranking_create", params: [
            "p_id": AnyJSON.string(id), "p_list_id": .string(listId), "p_name": .string(name), "p_depth": .string(depth),
            "p_top": .integer(top), "p_sharing": .string(sharing),
        ]).execute().value
    }

    func update(_ id: String, name: String? = nil, depth: String? = nil, top: Int? = nil, sharing: String? = nil) async throws -> RankingRow {
        #if DEBUG
        if let demo { return try demo.update(id, name: name, depth: depth, top: top, sharing: sharing) }
        #endif
        return try await supabase.rpc("cube_ranking_update", params: [
            "p_id": AnyJSON.string(id), "p_name": name.map { .string($0) } ?? .null, "p_depth": depth.map { .string($0) } ?? .null,
            "p_top": top.map { .integer($0) } ?? .null, "p_sharing": sharing.map { .string($0) } ?? .null,
        ]).execute().value
    }

    func push(_ id: String, rev: Int, keep: Int, add: [RankScreen], progress: (sorted: Int, categories: Int, ranked: Int),
              changes: [RankChange], opId: String) async throws -> RankingRow {
        #if DEBUG
        if let demo { return try demo.push(id, rev: rev, keep: keep, add: add, progress: progress, changes: changes) }
        #endif
        let changeRows: [AnyJSON] = changes.map { c in
            var o: [String: AnyJSON] = ["s": .string(c.s), "c": .string(c.c), "f": c.f.map { .integer($0) } ?? .null,
                                        "to": c.to.map { .integer($0) } ?? .null]
            if let t = c.t { o["t"] = .double(t) }
            if let by = c.by { o["by"] = .string(by) }
            if let n = c.n { o["n"] = .integer(n) }
            return .object(o)
        }
        let screens: [AnyJSON] = add.map { s in
            var o: [String: AnyJSON] = ["s": .string(s.s), "o": .array(s.o.map { .string($0) })]
            if let t = s.t { o["t"] = .double(t) }
            return .object(o)
        }
        return try await supabase.rpc("cube_ranking_push", params: [
            "p_id": AnyJSON.string(id), "p_rev": .integer(rev), "p_keep": .integer(keep), "p_add": .array(screens),
            "p_sorted": .integer(progress.sorted), "p_categories": .integer(progress.categories), "p_ranked": .integer(progress.ranked),
            "p_op_id": .string(opId), "p_changes": .array(changeRows),
        ]).execute().value
    }

    func delete(_ id: String) async throws {
        #if DEBUG
        if let demo { demo.delete(id); models[id] = nil; Telemetry.capture("ranking_deleted"); return }
        #endif
        struct R: Decodable { let deleted: Bool }
        let _: R = try await supabase.rpc("cube_ranking_delete", params: ["p_id": id]).execute().value
        models[id] = nil
        Telemetry.capture("ranking_deleted")
    }
}

/// A card as the ranking screens show it.
struct RankCard: Hashable, Sendable {
    let oracleId: String
    let name: String
    let printing: CatalogPrinting?
}

/// One open ranking: its log, its cards and what's worked out from them.
@MainActor
@Observable
final class RankingModel {
    let id: String
    private(set) var row: RankingRow?
    private(set) var cube: RankingCube?
    private(set) var log: [RankScreen] = []
    /// The change log, oldest first: the server's plus what's waiting to be saved.
    private(set) var changes: [RankChange] = []
    private(set) var state: RankingState?
    private(set) var cards: [String: RankCard] = [:]
    /// A redone or undone screen's cards, asked again first while their order is open.
    private(set) var reask: (job: RankJob, cards: [String])?
    var error: String?
    var notice: String?
    private(set) var loading = false
    /// The cube can't be read any more (unshared or deleted): lists still show, the cards don't.
    private(set) var cubeGone = false

    @ObservationIgnored private var serverLog: [RankScreen] = []
    /// Changes not yet saved; sent with the next push.
    @ObservationIgnored private var pendingChanges: [RankChange] = []
    @ObservationIgnored private var saving = false
    @ObservationIgnored private var pendingOp: (keep: Int, count: Int, op: String)?
    @ObservationIgnored private var lastChange = Date.now

    init(id: String) { self.id = id }

    var mine: Bool { row?.mine ?? false }
    var unsaved: Bool { log != serverLog }

    func card(_ x: Int) -> RankCard? { state.flatMap { cards[$0.id(x)] } }
    func card(_ oracleId: String) -> RankCard? { cards[oracleId.lowercased()] }

    /// Loads (or reloads) the ranking. Unsaved screens stay unless the server's log moved on without them.
    func load() async {
        loading = true
        defer { loading = false }
        do {
            let d = try await RankingsStore.shared.get(id)
            await adopt(d)
            error = nil
        } catch where !error.isCancellation {
            self.error = error.localizedDescription
        } catch {}
    }

    private func adopt(_ d: RankingDetail) async {
        let changed = d.log != serverLog || row?.depth != d.row.depth || row?.top != d.row.top || state == nil
        row = d.row
        cube = d.cube
        if changed { lastChange = .now }
        if saving || unsaved && d.log == serverLog { return }
        serverLog = d.log
        log = d.log
        changes = d.changes
        pendingChanges = []
        if changed || cards.isEmpty { await rebuild(cubeCards: d.cube?.cards) }
    }

    /// Cards by Oracle id → how they show and their color; nil until the card data is in. Tests swap it.
    @ObservationIgnored static var resolve: @MainActor ([String]) async -> [String: (RankCard, RankJob)]? = { wanted in
        let catalog = CatalogStore.shared
        catalog.load(userInitiated: true)
        guard let db = catalog.db else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> [String: (RankCard, RankJob)] in
            let oracles = db.oracles(oracleIds: wanted)
            let covers = db.covers(oracleIdxs: oracles.values.map(\.idx))
            var out: [String: (RankCard, RankJob)] = [:]
            for (id, o) in oracles {
                guard let job = RankJob(colorGroup: GroupKeys(o).color) else { continue }
                out[id] = (RankCard(oracleId: id, name: o.name, printing: covers[o.idx]), job)
            }
            return out
        }.value
    }

    /// Printings by card id from the card data; tests swap it.
    @ObservationIgnored static var printings: @MainActor ([String]) async -> [String: CatalogPrinting] = { ids in
        guard !ids.isEmpty, let db = CatalogStore.shared.db else { return [:] }
        return await Task.detached(priority: .userInitiated) { db.printings(ids: ids) }.value
    }

    /// Each card in the printing the cube holds; a card whose printing isn't in the card data keeps its usual art.
    nonisolated static func asInCube(_ cards: [String: RankCard], printings: [String: String],
                                     found: [String: CatalogPrinting]) -> [String: RankCard] {
        cards.mapValues { c in
            guard let id = printings[c.oracleId], let p = found[id] else { return c }
            return RankCard(oracleId: c.oracleId, name: c.name, printing: p)
        }
    }

    /// Resolves the cube's cards against the catalog and works out the state.
    private func rebuild(cubeCards: [String]?) async {
        guard let row else { return }
        var ids = cubeCards?.map { $0.lowercased() }
        if ids == nil, cards.isEmpty == false { ids = Array(cards.keys) }
        cubeGone = cubeCards == nil
        let wanted: [String] = ids ?? Array(Set(log.flatMap(\.o).map { $0.lowercased() }))
        guard let resolved = await Self.resolve(wanted) else { return }
        cards = Self.asInCube(resolved.mapValues(\.0), printings: cube?.printings ?? [:],
                              found: await Self.printings(Array(Set((cube?.printings ?? [:]).values))))
        let log = self.log, depth = row.depth, top = row.top, rid = id
        state = await Task.detached(priority: .userInitiated) {
            RankingState(rankingId: rid, cards: resolved.mapValues(\.1), log: log, depth: depth, top: top)
        }.value
    }

    /// The next screen of a job: a redone screen's cards first while their order is open.
    func question(_ job: RankJob) -> (session: RankSession, cards: [Int], pinned: [Int])? {
        guard let state else { return nil }
        let s = state.session(job)
        guard let q = s.question else { return (s, [], []) }
        if let r = reask, r.job == job, CubeRanking.reaskOpen(state.knowledge, s, r.cards) {
            return (s, state.knowledge.indexes(r.cards), [])
        }
        return (s, q, s.pinned)
    }

    private static var now: Double { (Date.now.timeIntervalSince1970 * 1000).rounded() }

    /// Notes what moved in every list between two states, for the change log.
    private func record(_ before: RankingState?, _ after: RankingState?, by: String, screen: Int?, only: [RankJob]? = nil) {
        guard let before, let after else { return }
        let t = Self.now
        let rows = RankChange.diff(before.places(only), after.places(only)).map { var c = $0; c.t = t; c.by = by; c.n = screen; return c }
        changes += rows
        pendingChanges += rows
    }

    /// Locks a screen in (yours only) and saves it.
    func lockIn(_ job: RankJob, order: [Int]) {
        guard mine, let state else { return }
        let screen = RankScreen(s: job.rawValue, o: order.map(state.id), t: Self.now)
        let wasDone = state.session(job).done
        log.append(screen)
        reask = nil
        let next = state.appending(screen)
        self.state = next
        record(state, next, by: "screen", screen: log.count, only: job == .final ? nil : [job, .final])
        if !wasDone, next.session(job).done {
            Telemetry.capture("ranking_job_done", ["job": job.rawValue, "screens": next.knowledge.perJob[job.rawValue] ?? 0])
        }
        save()
    }

    /// Takes back this job's latest screen and asks those cards again.
    func undo(_ job: RankJob) {
        guard mine, let i = log.lastIndex(where: { $0.s == job.rawValue }) else { return }
        let removed = log.remove(at: i)
        reask = (job, removed.o)
        Telemetry.capture("ranking_undo")
        let before = state
        rebuildState()
        record(before, state, by: "undo", screen: i + 1)
        save()
    }

    /// Removes screen `i` (from 0) and asks its cards again when their order is open.
    func redo(_ i: Int) {
        guard mine, log.indices.contains(i), let job = log[i].job else { return }
        let removed = log.remove(at: i)
        reask = job == .pick ? nil : (job, removed.o)
        Telemetry.capture("ranking_redo")
        let before = state
        rebuildState()
        record(before, state, by: "redo", screen: i + 1)
        save()
    }

    // MARK: P1P1

    /// The next pack for this ranking (oracle ids, in the order shown).
    var pack: [String] { state.map { CubeRanking.pack(rankingId: id, $0.knowledge) } ?? [] }

    /// Pack cards your ranking puts above the picked one.
    func disagreements(picked: String, pack: [String]) -> [String] {
        state.map { CubeRanking.disagreements($0.knowledge, picked: picked, pack: pack) } ?? []
    }

    /// How many of the pick's orders the ranking didn't know yet.
    func newOrders(picked: String, pack: [String]) -> Int {
        guard let K = state?.knowledge, let p = K.index[picked.lowercased()] else { return 0 }
        return pack.compactMap { K.index[$0.lowercased()] }.filter { $0 != p && !K.known(p, $0) && !K.known($0, p) }.count
    }

    /// The screens "Let the pick win" would take out (log indexes).
    func pickWinRemovals(picked: String, pack: [String]) -> [Int] {
        guard let state else { return [] }
        return CubeRanking.pickWins(cards: state.knowledge.ids, log: log, picked: picked, pack: pack)
    }

    /// Saves a pick. `wins`: first take out the screens behind its disagreements.
    func pick(_ picked: String, pack: [String], wins: Bool) {
        guard mine, let state, let row else { return }
        let disagreed = disagreements(picked: picked, pack: pack).count
        let removed = wins ? pickWinRemovals(picked: picked, pack: pack) : []
        let screen = RankScreen(s: RankJob.pick.rawValue, o: [picked] + pack.filter { $0 != picked }, t: Self.now)
        for i in removed.reversed() { log.remove(at: i) }
        log.append(screen)
        reask = nil
        let next = removed.isEmpty ? state.appending(screen)
            : RankingState(rankingId: id, cards: state.category, log: log, depth: row.depth, top: row.top)
        self.state = next
        record(state, next, by: removed.isEmpty ? "pick" : "pick_win", screen: log.count)
        Telemetry.capture("ranking_pick", ["disagreed": disagreed, "resolution": disagreed == 0 ? "none" : wins ? "pick_wins" : "keep",
                                           "removed": removed.count])
        save()
    }

    /// Every pick so far, newest first: how many of its orders disagreed with the ranking and were kept out, and whether
    /// it won over the ranking (its screens taken out; the change log says so).
    var picks: [(index: Int, screen: RankScreen, disagreed: Int, won: Bool)] {
        guard let K = state?.knowledge else { return [] }
        let won = Set(changes.filter { $0.by == "pick_win" }.compactMap(\.n))
        return log.enumerated().filter { $0.element.s == RankJob.pick.rawValue }
            .map { ($0.offset, $0.element, K.contradicted[$0.offset]?.count ?? 0, won.contains($0.offset + 1)) }.reversed()
    }

    /// Would removing screen `i` change anything?
    func redoChangesNothing(_ i: Int) -> Bool {
        guard let state, log.indices.contains(i) else { return false }
        var rest = log
        rest.remove(at: i)
        return RankKnowledge(cards: state.knowledge.ids, log: rest).sameKnowledge(state.knowledge)
    }

    private func rebuildState() {
        guard let state, let row else { return }
        self.state = RankingState(rankingId: id, cards: state.category, log: log, depth: row.depth, top: row.top)
    }

    /// Settings moved places but no screens: push the change log alone.
    private func saveChangesOnly() {
        if unsaved { save(); return }
        guard !saving, !pendingChanges.isEmpty else { return }
        forceSave = true
        save()
    }
    @ObservationIgnored private var forceSave = false

    /// One push at a time: keep what the server and this device agree on, send the rest.
    private func save() {
        guard !saving, unsaved || forceSave, let row else { return }
        forceSave = false
        saving = true
        let local = log
        let keep = zip(serverLog, local).prefix { $0 == $1 }.count
        let add = Array(local[keep...])
        let op = pendingOp.flatMap { $0.keep == keep && $0.count == local.count ? $0.op : nil } ?? UUID().uuidString.lowercased()
        pendingOp = (keep, local.count, op)
        let progress = state?.progress ?? (0, 0, 0)
        let sending = pendingChanges
        Task {
            defer { saving = false }
            do {
                let r = try await RankingsStore.shared.push(id, rev: row.rev, keep: min(keep, serverLog.count), add: add, progress: progress,
                                                            changes: sending, opId: op)
                self.row = r
                serverLog = local
                pendingChanges.removeFirst(min(sending.count, pendingChanges.count))
                pendingOp = nil
                error = nil
                lastChange = .now
                if unsaved { saving = false; save() }
            } catch let e as PostgrestError where e.code == "PT409" || e.code == "40001" {
                pendingOp = nil
                pendingChanges = []
                notice = "This ranking changed on another device, so it has been reloaded. Check the screen you just locked in."
                serverLog = []
                saving = false
                if let d = try? await RankingsStore.shared.get(id) {
                    serverLog = d.log; log = d.log; self.row = d.row; reask = nil; changes = d.changes
                    await rebuild(cubeCards: d.cube?.cards)
                }
            } catch where !error.isCancellation {
                self.error = "Couldn't save: \(error.localizedDescription). It's kept here and saves on the next lock-in."
            } catch {}
        }
    }

    /// Settings: rename, depth, top, sharing.
    func update(name: String? = nil, depth: String? = nil, top: Int? = nil, sharing: String? = nil) async {
        do {
            let before = state
            row = try await RankingsStore.shared.update(id, name: name, depth: depth, top: top, sharing: sharing)
            rebuildState()
            if depth != nil || top != nil { record(before, state, by: "settings", screen: nil) }
            if depth != nil || top != nil { saveChangesOnly() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Watching: someone else's ranking every 10 s (60 s once nothing has changed for a minute); yours every 60 s,
    /// for picks made on another device. Runs while a ranking screen is open.
    func watch() async {
        while !Task.isCancelled {
            let quiet = Date.now.timeIntervalSince(lastChange) > 60
            let wait: Double = mine || quiet ? 60 : 10
            try? await Task.sleep(for: .seconds(wait))
            if Task.isCancelled { return }
            if !saving, !unsaved, let d = try? await RankingsStore.shared.get(id) { await adopt(d) }
        }
    }

    // MARK: lists

    /// A job's list: the placed cards, best first, then the rest by name.
    func list(_ job: RankJob) -> (placed: [RankCard], rest: [RankCard], restTitle: String?)? {
        guard let state else { return nil }
        let s = state.session(job)
        let placed = s.top.compactMap(card)
        let inList = Set(s.top)
        let rest = state.scope(job).members.filter { !inList.contains($0) }.compactMap(card)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let title: String? = rest.isEmpty ? nil
            : s.done ? "Below the top \(s.target), in no particular order · \(rest.count)" : "Not placed yet · \(rest.count)"
        return (placed, rest, title)
    }

    /// "1. Name" lines, then the rest, for Copy list.
    func listText(_ job: RankJob) -> String {
        guard let l = list(job) else { return "" }
        var lines = l.placed.enumerated().map { "\($0.offset + 1). \($0.element.name)" }
        if let t = l.restTitle, !l.rest.isEmpty {
            lines.append("")
            lines.append(t)
            lines += l.rest.map(\.name)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

struct RankingsDemoBackendError: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}

#if DEBUG
/// Rankings on demo data: the fixture's cube with two finished rankings by friends and one of yours in progress, and
/// a cube of Mara's (the same cards) that you can rank too, with her own ranking started. Built off the main thread (it
/// plays every screen of the rankings), then used from it.
final class RankingsDemoBackend: @unchecked Sendable {
    private var rows: [String: RankingRow] = [:]
    private var logs: [String: [RankScreen]] = [:]
    private var changeLogs: [String: [RankChange]] = [:]
    let cubeId: String
    let cubeName: String
    let cards: [String]
    static let mine = "d0000000-0000-0000-0000-0000000aa001"
    /// Mara's cube, shared with you: one that isn't yours to rank.
    static let maraCube = "d0000000-0000-0000-0000-0000000fc001"
    static let maraCubeName = "Mara's Legacy Cube"

    init?(cubeId: String, cubeName: String, cards: [String], categories: [String: RankJob]) {
        guard cards.count >= 8 else { return nil }
        self.cubeId = cubeId
        self.cubeName = cubeName
        self.cards = cards
        let me = Person(userId: FriendsDemoBackend.me, displayName: "You")
        let mara = Person(userId: FriendsDemoBackend.mara, displayName: "Mara Quinn")
        let theo = Person(userId: FriendsDemoBackend.theo, displayName: "Theo Vance")
        // Friends' "taste": a fixed order of the cards from a hash, so their rankings agree in part.
        func taste(_ salt: String) -> [String: Int] {
            let order = cards.sorted { CubeRanking.fnv1a(salt + $0) < CubeRanking.fnv1a(salt + $1) }
            return Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        }
        func run(_ id: String, _ who: Person, _ name: String, _ depth: String, _ top: Int, mine: Bool, finalScreens: Int?,
                 taste t: [String: Int], cube listId: String? = nil, stopAfter: RankJob? = nil) {
            var st = RankingState(rankingId: id, cards: categories, log: [], depth: depth, top: top)
            var log: [RankScreen] = []
            var changes: [RankChange] = []
            let jobs = st.jobs + [.final]
            for job in jobs {
                var n = 0
                while let q = st.session(job).question, n < (job == .final ? (finalScreens ?? 10_000) : 10_000) {
                    let s = RankScreen(s: job.rawValue, o: q.map(st.id).sorted { t[$0]! < t[$1]! },
                                       t: Date.now.addingTimeInterval(Double(log.count - 3000) * 20).timeIntervalSince1970 * 1000)
                    log.append(s)
                    let next = st.appending(s)
                    let only: [RankJob]? = job == .final ? nil : [job, .final]
                    changes += RankChange.diff(st.places(only), next.places(only)).map { var c = $0; c.t = s.t; c.by = "screen"; c.n = log.count; return c }
                    st = next
                    n += 1
                }
                if job == stopAfter { break }
            }
            let p = st.progress
            rows[id] = RankingRow(id: id, listId: listId ?? cubeId, name: name, depth: depth, top: top, sharing: "cube", screens: log.count,
                                  rev: 1, sorted: p.sorted, categories: p.categories, ranked: p.ranked,
                                  updatedAt: ISO8601DateFormatter().string(from: .now), mine: mine, by: who)
            // A friend also made a few picks after their ranking was done.
            if !mine && stopAfter == nil {
                for _ in 0..<5 {
                    let pk = CubeRanking.pack(rankingId: id, st.knowledge)
                    guard let picked = pk.min(by: { t[$0]! < t[$1]! }) else { break }
                    let s = RankScreen(s: "P", o: [picked] + pk.filter { $0 != picked }, t: Date.now.timeIntervalSince1970 * 1000)
                    log.append(s)
                    st = st.appending(s)
                }
            }
            logs[id] = log
            changeLogs[id] = changes
        }
        let base = taste("base")
        func mixed(_ salt: String) -> [String: Int] {
            let own = taste(salt)
            let order = cards.sorted { 3 * base[$0]! + own[$0]! < 3 * base[$1]! + own[$1]! }
            return Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        }
        run("d0000000-0000-0000-0000-0000000aa002", mara, "Aggro all the way", "half", 100, mine: false, finalScreens: nil, taste: mixed("mara"))
        run("d0000000-0000-0000-0000-0000000aa003", theo, "Theo's picks", "half", 50, mine: false, finalScreens: nil, taste: mixed("theo"))
        run(Self.mine, me, "My ranking", "half", 100, mine: true, finalScreens: 0, taste: mixed("me"), stopAfter: .b)
        run("d0000000-0000-0000-0000-0000000aa004", mara, "Mara's own order", "half", 100, mine: false, finalScreens: 0,
            taste: mixed("mara2"), cube: Self.maraCube, stopAfter: .u)
    }

    private func cube(_ listId: String, withCards: Bool) -> RankingCube {
        listId == Self.maraCube
            ? RankingCube(id: listId, name: Self.maraCubeName, mine: false, owner: Person(userId: FriendsDemoBackend.mara, displayName: "Mara Quinn"),
                          canSee: true, cards: withCards ? cards : nil)
            : RankingCube(id: cubeId, name: cubeName, mine: true, owner: Person(userId: FriendsDemoBackend.me, displayName: "You"),
                          canSee: true, cards: withCards ? cards : nil)
    }

    func rankings(listId: String?) -> CubeRankings {
        let all = rows.values.sorted { $0.mine != $1.mine ? $0.mine : $0.name < $1.name }
        if listId == nil {
            return CubeRankings(cube: nil, canRank: false, rankings: all.filter(\.mine).map { var r = $0; r.cube = cube(r.listId, withCards: false); return r })
        }
        guard listId == cubeId || listId == Self.maraCube else { return CubeRankings(cube: nil, canRank: false, rankings: []) }
        return CubeRankings(cube: cube(listId!, withCards: false), canRank: true, rankings: all.filter { $0.listId == listId })
    }

    /// A stand-in for Claude's brief (the demo has no server): marked as a sample, built from the comparison numbers.
    func brief(a: String, b: String, list: RankJob) -> RankingBrief {
        guard let ra = rows[a], let rb = rows[b] else { return RankingBrief(reason: "That's private") }
        return RankingBrief(brief: "Sample brief (the demo has no server; on Table 1 Claude writes this from both rankings): " +
                            "\(ra.by?.displayName ?? "One") and \(rb.by?.displayName ?? "the other") agree on most of the strongest cards in " +
                            "\(list == .final ? "the top \(min(ra.top, rb.top))" : list.title), and part ways further down.",
                            reason: nil, cached: true, sample: true)
    }

    /// Cubes of other people you can rank: Mara's.
    func rankable() -> [RankableCube] {
        [RankableCube(id: Self.maraCube, name: Self.maraCubeName, owner: Person(userId: FriendsDemoBackend.mara, displayName: "Mara Quinn"),
                      cards: cards.count, rankings: rows.values.filter { $0.listId == Self.maraCube }.count,
                      mine: rows.values.filter { $0.listId == Self.maraCube && $0.mine }.count)]
    }

    func get(_ id: String) throws -> RankingDetail {
        guard let r = rows[id] else { throw DemoError("That's private") }
        return RankingDetail(row: r, log: logs[id] ?? [], changes: changeLogs[id] ?? [], cube: cube(r.listId, withCards: true))
    }

    func create(id: String, listId: String, name: String, depth: String, top: Int, sharing: String) -> RankingRow {
        let r = RankingRow(id: id, listId: listId, name: name.isEmpty ? "My ranking" : name, depth: depth, top: top, sharing: sharing,
                           screens: 0, rev: 0, sorted: 0, categories: 0, ranked: 0, updatedAt: ISO8601DateFormatter().string(from: .now),
                           mine: true, by: Person(userId: FriendsDemoBackend.me, displayName: "You"))
        rows[id] = r
        logs[id] = []
        return r
    }

    func update(_ id: String, name: String?, depth: String?, top: Int?, sharing: String?) throws -> RankingRow {
        guard var r = rows[id] else { throw DemoError("That's private") }
        if let name { r.name = name }
        if let depth { r.depth = depth }
        if let top { r.top = top }
        if let sharing { r.sharing = sharing }
        rows[id] = r
        return r
    }

    func push(_ id: String, rev: Int, keep: Int, add: [RankScreen], progress: (sorted: Int, categories: Int, ranked: Int),
              changes: [RankChange] = []) throws -> RankingRow {
        guard var r = rows[id], var log = logs[id] else { throw DemoError("That's private") }
        log = Array(log.prefix(keep)) + add
        logs[id] = log
        changeLogs[id, default: []] += changes
        r.rev += 1
        r.screens = log.count
        (r.sorted, r.categories, r.ranked) = progress
        r.updatedAt = ISO8601DateFormatter().string(from: .now)
        rows[id] = r
        return r
    }

    func delete(_ id: String) {
        rows[id] = nil
        logs[id] = nil
    }

    struct DemoError: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }
}
#endif
