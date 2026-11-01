import Foundation
import Sentry
import SwiftUI

/// What the Draft screens show of a card: from the local catalog only (no network, no images in the grid).
struct RotoCard: Hashable, Sendable {
    let cardId: String
    let name: String
    let typeLine: String
    let manaCost: String
    /// W U B R G present in the mana cost, in that order.
    let colors: [String]
    let manaValue: Int
    /// White … Multicolor, Colorless, Lands (the lists contract "Display" for cubes).
    let group: String
    let printing: CatalogPrinting?

    var isLand: Bool { typeLine.components(separatedBy: " // ").first?.contains("Land") ?? false }
    var isCreature: Bool { typeLine.components(separatedBy: " // ").first?.contains("Creature") ?? false }

    static func unknown(_ cardId: String) -> RotoCard {
        RotoCard(cardId: cardId, name: "Card", typeLine: "", manaCost: "", colors: [], manaValue: 0, group: "Colorless", printing: nil)
    }

    /// "{2}{U}{U}" → 4; X counts 0, hybrid and Phyrexian count 1. Split cards use the front face.
    nonisolated static func manaValue(_ cost: String) -> Int {
        let front = cost.components(separatedBy: " // ").first ?? cost
        var total = 0
        var i = front.startIndex
        while let open = front[i...].firstIndex(of: "{"), let close = front[open...].firstIndex(of: "}") {
            let sym = front[front.index(after: open)..<close]
            if let n = Int(sym) { total += n } else if sym != "X" && sym != "Y" && sym != "Z" { total += 1 }
            i = front.index(after: close)
        }
        return total
    }

    nonisolated static func resolve(_ cardIds: [String], _ db: CatalogDB) -> [String: RotoCard] {
        let printings = db.printings(ids: Array(Set(cardIds)))
        let oracles = db.oracles(idxs: Array(Set(printings.values.map(\.oracleIdx))))
        var out: [String: RotoCard] = [:]
        for (id, p) in printings {
            guard let o = oracles[p.oracleIdx] else { continue }
            let type = o.typeLine.components(separatedBy: " // ").first ?? o.typeLine
            let colors = ["W", "U", "B", "R", "G"].filter { o.manaCost.contains("{\($0)") || o.manaCost.contains("/\($0)") }
            let group = type.contains("Land") ? "Lands" : ListLine.colorGroup(o.manaCost)
            out[id] = RotoCard(cardId: id, name: o.name, typeLine: o.typeLine, manaCost: o.manaCost, colors: colors,
                               manaValue: manaValue(o.manaCost), group: group, printing: p)
        }
        return out
    }
}

/// One roto draft on screen: the state from the server, the pool (fetched once), picks (by delta), your list.
/// Picks render at once and are replaced by the server's answer; a conflict merges the newer state.
@MainActor
@Observable
final class RotoStore {
    let eventId: String
    @ObservationIgnored let backend: RotoBackend

    private(set) var loaded = false
    private(set) var phase: RotoPhase = .setup
    private(set) var draft = RotoDraftInfo()
    private(set) var onClock: RotoOnClock?
    private(set) var seats: [RotoSeat] = []
    private(set) var me: RotoMe?
    /// Slot → copy, from the first load only.
    private(set) var pool: [Int: RotoPoolCard] = [:]
    /// Slots in a stable display order (by card name once the catalog answers).
    private(set) var poolOrder: [Int] = []
    private(set) var picks: [RotoPick] = []
    /// Slot → the pick that took it.
    private(set) var pickBySlot: [Int: RotoPick] = [:]
    /// Your pick, shown before the server answers.
    private(set) var pending: RotoPick?
    private(set) var cards: [String: RotoCard] = [:]
    /// Your private list (slots, best first) and the auto-pick switch, as shown (saves are debounced).
    private(set) var queue: [Int] = []
    private(set) var autoPick = true
    /// "Taken by ANNA (#41)": cards that left your list since you last looked; shown once.
    private(set) var takenFromList: [(slot: Int, pick: RotoPick)] = []
    var error: String?
    var notice: String?
    private(set) var busy = false
    /// Setup: what Start draft will send (roto_start takes them; nothing is saved before).
    var planPicks = 45
    var planOrder = "snake"
    @ObservationIgnored var gridTraced = false

    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var queueTask: Task<Void, Never>?
    @ObservationIgnored private var expiring = false
    @ObservationIgnored private var lastExpireFor = 0

    init(eventId: String, backend: RotoBackend? = nil) {
        self.eventId = eventId
        self.backend = backend ?? RotoLiveBackend()
    }

    // MARK: derived

    var picksMade: Int { max(draft.picksMade, picks.last?.pickNo ?? 0) + (pending == nil ? 0 : 1) }
    var total: Int { draft.total }
    var players: Int { max(draft.players, seats.count) }
    var mySeat: Int? { me?.seat }
    var isMyTurn: Bool { phase == .drafting && pending == nil && onClock != nil && onClock?.participantId == me?.participantId }
    var orderedSeats: [RotoSeat] { seats.sorted { ($0.seat ?? .max) < ($1.seat ?? .max) } }

    func seat(_ n: Int) -> RotoSeat? { seats.first { $0.seat == n } }
    func card(slot: Int) -> RotoCard? { pool[slot].map { cards[$0.cardId] ?? .unknown($0.cardId) } }
    /// The pick at a number, including your pending one.
    func pick(_ no: Int) -> RotoPick? {
        if let pending, pending.pickNo == no { return pending }
        guard no >= 1, no <= picks.count, picks[no - 1].pickNo == no else { return picks.first { $0.pickNo == no } }
        return picks[no - 1]
    }
    func takenBy(slot: Int) -> RotoPick? {
        if let pending, pending.slot == slot { return pending }
        return pickBySlot[slot]
    }
    func picks(seat: Int) -> [RotoPick] {
        var out = picks.filter { $0.seat == seat }
        if let pending, pending.seat == seat { out.append(pending) }
        return out
    }
    func name(seat: Int) -> String { self.seat(seat)?.displayName ?? "Seat \(seat)" }
    func inList(_ slot: Int) -> Int? { queue.firstIndex(of: slot).map { $0 + 1 } }

    /// Picks before yours (0 = your pick); nil when you're not drafting or have no picks left.
    var picksUntilMine: Int? {
        guard phase == .drafting, let seat = mySeat else { return nil }
        return RotoMath.picksUntil(seat: seat, picksMade: picksMade, players: players, total: total, snake: draft.snake)
    }

    /// Seconds left on the current turn at `date`; nil without a clock (or between turns).
    func secondsLeft(at date: Date) -> Int? {
        guard let c = onClock, pending == nil else { return nil }
        if draft.clockPaused { return c.remainingSeconds }
        guard let deadline = c.deadline else { return nil }
        return max(0, Int((deadline - date.timeIntervalSince1970).rounded(.up)))
    }

    // MARK: loading

    /// First load: everything, pool included. Later calls fetch picks by delta.
    func load() async {
        guard !loaded else { return await refresh() }
        let span = RotoTrace.start("roto.state", "load")
        do {
            let s = try await backend.state(eventId, after: 0, pool: true)
            apply(s, full: true)
            loaded = true
            error = nil
            span?.finish()
            await resolveCards()
        } catch {
            span?.finish(status: .internalError)
            self.error = error.localizedDescription
        }
    }

    /// Delta: picks after the last one held. A burst of calls runs at most one more time after the current one.
    func refresh(full: Bool = false) async {
        guard loaded else { return await load() }
        if refreshing { refreshAgain = true; return }
        refreshing = true
        defer { refreshing = false }
        // The pool exists only once the draft starts: a store loaded in Setup fetches it then, once.
        var full = full || pool.isEmpty
        repeat {
            refreshAgain = false
            let after = full ? 0 : (picks.last?.pickNo ?? 0)
            let span = RotoTrace.start("roto.state", full ? "full" : "delta")
            do {
                let wantPool = pool.isEmpty
                let s = try await backend.state(eventId, after: after, pool: wantPool)
                span?.finish()
                if full {
                    apply(s, full: true)
                    if wantPool && !pool.isEmpty { await resolveCards() }
                } else {
                    let merged = RotoMerge.apply(held: picks, delta: s.picks, picksMade: s.draft.picksMade)
                    if merged.needsFull { full = true; refreshAgain = true; continue }
                    apply(s, merged: merged.picks)
                }
                full = false
                error = nil
            } catch {
                span?.finish(status: .internalError)
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        } while refreshAgain
    }

    /// A state that carries every pick (first load, full refresh).
    private func apply(_ s: RotoState, full: Bool) {
        if let p = s.pool, !p.isEmpty {
            pool = Dictionary(p.map { ($0.slot, $0) }, uniquingKeysWith: { a, _ in a })
            poolOrder = p.map(\.slot).sorted()
        }
        apply(s, merged: s.picks.sorted { $0.pickNo < $1.pickNo })
    }

    private func apply(_ s: RotoState, merged: [RotoPick]) {
        let wasList = Set(queue)
        phase = s.phase
        draft = s.draft
        onClock = s.onClock
        if !s.seats.isEmpty { seats = s.seats }
        if let m = s.me {
            me = m
            // Your list as the server kept it (taken cards dropped), unless an edit is still waiting to be sent.
            if queueTask == nil { queue = m.queue; autoPick = m.autoPick }
        }
        setPicks(merged)
        pending = nil
        // Cards on your list someone else took since the last look.
        let mySeat = me?.seat
        let gone = wasList.compactMap { slot -> (Int, RotoPick)? in
            guard let p = pickBySlot[slot], p.seat != mySeat else { return nil }
            return (slot, p)
        }
        if !gone.isEmpty {
            takenFromList.append(contentsOf: gone.map { (slot: $0.0, pick: $0.1) })
            queue.removeAll { pickBySlot[$0] != nil }
        }
    }

    private func setPicks(_ p: [RotoPick]) {
        picks = p
        pickBySlot = Dictionary(p.map { ($0.slot, $0) }, uniquingKeysWith: { _, b in b })
    }

    /// Card names and colors for the whole pool, read once from the local catalog off the main thread.
    func resolveCards() async {
        let catalog = CatalogStore.shared
        catalog.load(userInitiated: true)
        guard let db = catalog.db else { return }
        let ids = pool.values.map(\.cardId).filter { cards[$0] == nil }
        guard !ids.isEmpty else { return }
        let resolved = await Task.detached(priority: .userInitiated) { RotoCard.resolve(ids, db) }.value
        cards.merge(resolved) { _, b in b }
        let pool = pool, cards = cards
        poolOrder = pool.keys.sorted { a, b in
            let na = pool[a].flatMap { cards[$0.cardId]?.name } ?? "", nb = pool[b].flatMap { cards[$0.cardId]?.name } ?? ""
            return na != nb ? na < nb : a < b
        }
    }

    func dismissTaken() { takenFromList.removeAll() }

    // MARK: picking

    enum PickSource: String { case cube, grid, list, detail }

    /// Picks `slot` for whoever is on the clock: you on your turn, or (organizer) Pick for. Renders at once;
    /// the server's answer replaces it. Returns true when the server took the pick.
    @discardableResult
    func pick(slot: Int, from: PickSource) async -> Bool {
        guard phase == .drafting, let clock = onClock, pending == nil, takenBy(slot: slot) == nil else { return false }
        let pickNo = draft.picksMade + 1
        let seat = clock.seat > 0 ? clock.seat : RotoMath.seat(players: players, pickNo: pickNo, snake: draft.snake)
        let mine = clock.participantId == me?.participantId
        let how = mine ? "player" : "organizer"
        pending = RotoPick(pickNo: pickNo, seat: seat, slot: slot, how: how, at: Date().timeIntervalSince1970)
        queue.removeAll { $0 == slot }
        error = nil
        notice = nil
        let span = RotoTrace.start("roto.pick", "tap_to_answer")
        let secondsOnClock = clock.turnStartedAt.map { max(0, Int(Date().timeIntervalSince1970 - $0)) } ?? 0
        do {
            let r = try await backend.pick(eventId, slot: slot, pickNo: pickNo)
            span?.finish()
            let merged = RotoMerge.apply(held: picks, delta: r.state.picks, picksMade: r.state.draft.picksMade)
            apply(r.state, merged: merged.picks)
            if merged.needsFull { await refresh(full: true) }
            if r.ok {
                Telemetry.capture("roto_picked", [
                    "how": how, "from": from.rawValue, "round": clock.round, "seconds_on_clock": secondsOnClock,
                    "auto_followed": max(0, r.state.draft.picksMade - pickNo),
                ])
                return true
            }
            notice = "Someone picked first. Have another look."
            return false
        } catch {
            span?.finish(status: .internalError)
            pending = nil
            self.error = Self.message(error)
            await refresh()
            return false
        }
    }

    /// Organizer: removes the last pick a person made and the automatic picks after it.
    func undo() async {
        busy = true
        defer { busy = false }
        let before = picksMade
        do {
            let s = try await backend.undo(eventId)
            let merged = RotoMerge.apply(held: picks, delta: s.picks, picksMade: s.draft.picksMade)
            apply(s, merged: merged.picks)
            Telemetry.capture("roto_pick_undone", ["picks_removed": max(0, before - s.draft.picksMade)])
            await refresh(full: true)
        } catch {
            self.error = Self.message(error)
        }
    }

    /// Organizer: a new schedule (`[]` clears it), or pause / resume with `paused`.
    func setClock(_ ranges: [RotoClockRange]?, paused: Bool? = nil) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let s = try await backend.setClock(eventId, clock: ranges, paused: paused)
            phase = s.phase
            draft = s.draft
            onClock = s.onClock
            let action = paused.map { $0 ? "pause" : "resume" } ?? ((ranges ?? []).isEmpty ? "clear" : "set")
            Telemetry.capture("roto_clock_changed", ["action": action, "ranges": s.draft.clock?.count ?? 0])
            error = nil
            return true
        } catch {
            self.error = Self.message(error)
            return false
        }
    }

    /// A countdown reached zero here: ask the server to apply the timeout (no-op if it's early or already done).
    func expireIfDue(now: Date = .now) {
        guard phase == .drafting, !expiring, let c = onClock, !draft.clockPaused, !c.overdue,
              let deadline = c.deadline, now.timeIntervalSince1970 >= deadline, lastExpireFor != c.pickNo else { return }
        expiring = true
        lastExpireFor = c.pickNo
        Task {
            defer { expiring = false }
            _ = try? await backend.expire(eventId)
            await refresh()
        }
    }

    // MARK: your list

    func addToList(_ slot: Int) { editList { if !$0.contains(slot) { $0.append(slot) } } }
    func removeFromList(_ slot: Int) { editList { $0.removeAll { $0 == slot } } }
    func moveInList(from: IndexSet, to: Int) { editList { $0.move(fromOffsets: from, toOffset: to) } }
    func setAutoPick(_ on: Bool) {
        autoPick = on
        scheduleQueueSave(autoChanged: true)
    }

    private func editList(_ change: (inout [Int]) -> Void) {
        var q = queue
        change(&q)
        guard q != queue else { return }
        queue = q
        scheduleQueueSave(autoChanged: false)
    }

    @ObservationIgnored private var autoDirty = false

    /// The whole list, ~600 ms after the last change (one save per pause, not per drag).
    private func scheduleQueueSave(autoChanged: Bool) {
        if autoChanged { autoDirty = true }
        queueTask?.cancel()
        queueTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled else { return }
            await self.saveQueue()
        }
    }

    private func saveQueue() async {
        let slots = queue, auto = autoPick, sendAuto = autoDirty
        autoDirty = false
        do {
            let r = try await backend.queue(eventId, slots: slots, autoPick: sendAuto ? auto : nil)
            queueTask = nil
            // Keep edits made while this save was in flight; otherwise take the server's list.
            if queue == slots { queue = r.queue }
            autoPick = r.autoPick
            Telemetry.capture("roto_list_changed", ["cards": r.queue.count, "auto_pick": r.autoPick])
            if r.picksMade != draft.picksMade { await refresh() }
        } catch {
            queueTask = nil
            if Task.isCancelled { return }
            self.error = Self.message(error)
        }
    }

    // MARK: realtime

    /// Runs until cancelled: each roto_changed message fetches the picks after the last one held.
    func listen() async {
        for await change in backend.changes(eventId) {
            if let made = change.picksMade, made == draft.picksMade, change.kind == "pick" { continue }
            await refresh(full: change.kind == "undo" || change.kind == "resubscribed")
        }
    }

    // MARK: errors

    /// The server's own message where it has one ("Not your pick"), else the system's.
    static func message(_ error: Error) -> String { error.localizedDescription }
}

/// Sentry spans for the Draft screens (contract/roto-2026-10-16.md: roto.state, roto.pick, grid first render).
enum RotoTrace {
    static func start(_ name: String, _ operation: String) -> Span? {
        SentrySDK.isEnabled ? SentrySDK.startTransaction(name: name, operation: operation) : nil
    }
}
