import Foundation
import Supabase

/// Everything a roto draft asks of the server (contract/roto-2026-10-16.md). The Draft screens talk to this, so
/// the Debug demo can swap in a local draft (`RotoDemoBackend`).
@MainActor
protocol RotoBackend: AnyObject {
    func state(_ eventId: String, after: Int, pool: Bool) async throws -> RotoState
    func pick(_ eventId: String, slot: Int, pickNo: Int) async throws -> RotoPickResult
    func undo(_ eventId: String) async throws -> RotoState
    func queue(_ eventId: String, slots: [Int], autoPick: Bool?) async throws -> RotoQueueResult
    /// `clock` nil keeps the schedule; `[]` clears it. `paused` nil keeps the pause state.
    func setClock(_ eventId: String, clock: [RotoClockRange]?, paused: Bool?) async throws -> RotoState
    func expire(_ eventId: String) async throws -> RotoExpireResult
    func changes(_ eventId: String) -> AsyncStream<RotoChange>
}

final class RotoLiveBackend: RotoBackend {
    func state(_ eventId: String, after: Int, pool: Bool) async throws -> RotoState {
        try await Repo.rotoState(eventId, after: after, pool: pool)
    }
    func pick(_ eventId: String, slot: Int, pickNo: Int) async throws -> RotoPickResult {
        try await Repo.rotoPick(eventId, slot: slot, pickNo: pickNo)
    }
    func undo(_ eventId: String) async throws -> RotoState { try await Repo.rotoUndo(eventId) }
    func queue(_ eventId: String, slots: [Int], autoPick: Bool?) async throws -> RotoQueueResult {
        try await Repo.rotoQueueSet(eventId, slots: slots, autoPick: autoPick)
    }
    func setClock(_ eventId: String, clock: [RotoClockRange]?, paused: Bool?) async throws -> RotoState {
        try await Repo.rotoSetClock(eventId, clock: clock, paused: paused)
    }
    func expire(_ eventId: String) async throws -> RotoExpireResult { try await Repo.rotoExpire(eventId) }
    func changes(_ eventId: String) -> AsyncStream<RotoChange> { Repo.rotoChanges(eventId) }
}

extension Repo {
    // MARK: roto (telemetry is recorded by the callers, which know where a pick came from)

    static func rotoState(_ eventId: String, after: Int = 0, pool: Bool? = nil) async throws -> RotoState {
        let data = try await supabase.rpc("roto_state", params: [
            "p_event_id": AnyJSON.string(eventId),
            "p_after_pick": .integer(after),
            "p_pool": pool.map { AnyJSON.bool($0) } ?? .null,
        ]).execute().data
        return try wireDecoder.decode(RotoState.self, from: data)
    }

    static func rotoPick(_ eventId: String, slot: Int, pickNo: Int) async throws -> RotoPickResult {
        let data = try await supabase.rpc("roto_pick", params: [
            "p_event_id": AnyJSON.string(eventId), "p_slot": .integer(slot), "p_pick_no": .integer(pickNo),
        ]).execute().data
        return try wireDecoder.decode(RotoPickResult.self, from: data)
    }

    static func rotoUndo(_ eventId: String) async throws -> RotoState {
        let data = try await supabase.rpc("roto_undo", params: ["p_event_id": AnyJSON.string(eventId)]).execute().data
        return try wireDecoder.decode(RotoState.self, from: data)
    }

    static func rotoQueueSet(_ eventId: String, slots: [Int], autoPick: Bool?) async throws -> RotoQueueResult {
        let data = try await supabase.rpc("roto_queue_set", params: [
            "p_event_id": AnyJSON.string(eventId),
            "p_slots": .array(slots.map { .integer($0) }),
            "p_auto_pick": autoPick.map { AnyJSON.bool($0) } ?? .null,
        ]).execute().data
        return try wireDecoder.decode(RotoQueueResult.self, from: data)
    }

    static func rotoSetClock(_ eventId: String, clock: [RotoClockRange]?, paused: Bool?) async throws -> RotoState {
        let wire: AnyJSON = clock.map { ranges in
            .array(ranges.map { .object(["from_round": .integer($0.fromRound), "seconds": .integer($0.seconds)]) })
        } ?? .null
        let data = try await supabase.rpc("roto_set_clock", params: [
            "p_event_id": AnyJSON.string(eventId),
            "p_clock": wire,
            "p_paused": paused.map { AnyJSON.bool($0) } ?? .null,
        ]).execute().data
        return try wireDecoder.decode(RotoState.self, from: data)
    }

    static func rotoExpire(_ eventId: String) async throws -> RotoExpireResult {
        let data = try await supabase.rpc("roto_expire", params: ["p_event_id": AnyJSON.string(eventId)]).execute().data
        return try wireDecoder.decode(RotoExpireResult.self, from: data)
    }

    /// One of your Library cubes becomes the draft's pool (its Main board). `from`: library / cube_cobra.
    static func rotoSetCube(_ eventId: String, listId: String, from: String) async throws -> RotoCubeResult {
        let data = try await supabase.rpc("roto_set_cube", params: [
            "p_event_id": AnyJSON.string(eventId), "p_list_id": .string(listId),
        ]).execute().data
        let r = try wireDecoder.decode(RotoCubeResult.self, from: data)
        Telemetry.capture("roto_cube_set", ["pool": r.poolCount, "from": from])
        return r
    }

    /// Seats everyone at random (unless already seated), snapshots the cube and starts the draft.
    static func rotoStart(_ eventId: String, picksPerPlayer: Int, order: String, clockRanges: Int) async throws -> RotoState {
        let data = try await supabase.rpc("roto_start", params: [
            "p_event_id": AnyJSON.string(eventId), "p_picks_per_player": .integer(picksPerPlayer), "p_order": .string(order),
        ]).execute().data
        let s = try wireDecoder.decode(RotoState.self, from: data)
        Telemetry.capture("roto_started", [
            "players": s.draft.players, "picks_per_player": s.draft.picksPerPlayer, "pool": s.draft.poolCount,
            "order": s.draft.pickOrder, "clock": clockRanges > 0, "clock_ranges": clockRanges,
        ])
        return s
    }

    /// A Cube Cobra link → a cube in your Library (through list-import, written and confirmed by the server before
    /// returning, so roto_set_cube can use it at once). Returns the new list's id.
    static func importCubeToLibrary(url: String) async throws -> (id: String, name: String, cards: Int) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let r: ImportedList
        do {
            r = try await supabase.functions.invoke("list-import", options: FunctionInvokeOptions(body: ["url": url])) { data, _ in
                try decoder.decode(ImportedList.self, from: data)
            }
        } catch FunctionsError.httpError(_, let data) {
            throw NSError(domain: "Table1", code: 1, userInfo: [NSLocalizedDescriptionKey:
                (try? decoder.decode(ImportedList.self, from: data))?.error ?? "That cube couldn't be read."])
        }
        guard let lines = r.entries, !lines.isEmpty else {
            throw NSError(domain: "Table1", code: 1, userInfo: [NSLocalizedDescriptionKey: r.error ?? "No cards in that cube."])
        }
        guard let db = await CatalogStore.shared.db else {
            throw NSError(domain: "Table1", code: 1, userInfo: [NSLocalizedDescriptionKey: "Card data is still loading. Try again in a moment."])
        }
        let resolved = await Task.detached(priority: .userInitiated) { ListImportView.resolve(lines, kind: .cube, db) }.value
        guard !resolved.entries.isEmpty else {
            throw NSError(domain: "Table1", code: 1, userInfo: [NSLocalizedDescriptionKey: "None of that cube's cards are in the card data."])
        }
        let id = UUID().uuidString.lowercased()
        let name = String((r.name ?? "Cube").prefix(60))
        let host = r.sourceUrl.flatMap { URL(string: $0)?.host() }
        let wire: [AnyJSON] = resolved.entries.map { e in
            .array([.string(e.cardId), .string(e.board), .integer(e.qty)] + (e.finish == "nonfoil" ? [] : [.string(e.finish)]))
        }
        try await supabase.rpc("list_create", params: [
            "p_id": AnyJSON.string(id), "p_kind": .string("cube"), "p_name": .string(name), "p_format": .string(r.format ?? "vintage"),
            "p_entries": .array(wire), "p_note": .string(host.map { "Imported from \($0)" } ?? "Imported"),
        ]).execute()
        let cards = resolved.entries.filter { $0.board == "main" }.reduce(0) { $0 + $1.qty }
        Telemetry.capture("list_imported", ["kind": "cube", "from": "link", "cards": cards])
        await ListsStore.shared.sync()
        return (id, name, cards)
    }

    /// Broadcast topic `roto:<event_id>`, event `roto_changed` (one message per change; an auto-pick chain is one).
    /// Also yields once each time the channel (re)joins, since anything sent while it was away is only in roto_state.
    static func rotoChanges(_ eventId: String) -> AsyncStream<RotoChange> {
        AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation in
            let channel = supabase.channel("roto:\(eventId)")
            let messages = channel.broadcastStream(event: "roto_changed")
            let status = channel.statusChange
            let task = Task {
                do {
                    try await channel.subscribeWithError()
                } catch {
                    continuation.finish()   // no live updates; foreground refreshes still catch up
                    return
                }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await message in messages {
                            let payload = message["payload"]?.objectValue ?? message
                            let kind = payload["kind"]?.stringValue ?? "pick"
                            let made = payload["picks_made"]?.intValue
                            continuation.yield(RotoChange(kind: kind, picksMade: made))
                        }
                    }
                    group.addTask {
                        var first = true
                        for await s in status where s == .subscribed {
                            if first { first = false; continue }
                            continuation.yield(RotoChange(kind: "resubscribed", picksMade: nil))
                        }
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await supabase.removeChannel(channel) }
            }
        }
    }
}
