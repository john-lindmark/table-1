import Foundation
import Supabase

/// Every call the app makes. Writes are RPCs (validated, audited and broadcast server-side);
/// pairing and standings come from the events-engine edge function so the rules exist once.
enum Repo {
    /// Postgres prints UUIDs lowercase; Swift's uuidString is uppercase.
    static var userId: String? { supabase.auth.currentUser?.id.uuidString.lowercased() }

    // MARK: events

    struct MyEvent: Identifiable, Hashable {
        var id: String { event.id }
        let event: EventRow
        let organizing: Bool
    }

    private struct SeatWithEvent: Decodable { let eventId: String; let events: EventRow? }

    static func myEvents() async throws -> [MyEvent] {
        guard let uid = userId else { return [] }
        async let organizing: [EventRow] = supabase.from("events")
            .select("*, event_members!inner(user_id)")
            .eq("event_members.user_id", value: uid)
            .order("created_at", ascending: false)
            .execute().value
        async let playing: [SeatWithEvent] = supabase.from("participants")
            .select("event_id, events(*)")
            .eq("user_id", value: uid)
            .execute().value
        var byId: [String: MyEvent] = [:]
        let organizingRows = try await organizing
        let playingRows = try await playing
        for e in organizingRows { byId[e.id] = MyEvent(event: e, organizing: true) }
        for seat in playingRows {
            if let e = seat.events, byId[e.id] == nil { byId[e.id] = MyEvent(event: e, organizing: false) }
        }
        return byId.values.sorted { ($0.event.createdAt ?? "") > ($1.event.createdAt ?? "") }
    }

    static func createEvent(name: String, format: String, rounds: Int, roundMinutes: Int) async throws -> CreateEventResult {
        try await supabase.rpc("create_event", params: [
            "p_name": AnyJSON.string(name),
            "p_format": .string(format),
            "p_rounds": .integer(rounds),
            "p_round_seconds": .integer(roundMinutes * 60),
            "p_player_names": .array([]),
        ]).execute().value
    }

    /// Pins the event where the organizer stands and, for nearby events, alerts opted-in players.
    static func setEventLocation(eventId: String, lat: Double, lng: Double, venue: String?, nearby: Bool) async throws {
        try await supabase.rpc("set_event_location", params: [
            "p_event_id": AnyJSON.string(eventId),
            "p_lat": .double(lat),
            "p_lng": .double(lng),
            "p_venue_name": .string(venue ?? ""),
            "p_join_radius_m": .integer(150),
            "p_visibility": .string(nearby ? "nearby" : "link_only"),
        ]).execute()
    }

    static func loadEvent(_ eventId: String) async throws -> EventBundle {
        async let event: EventRow = supabase.from("events").select().eq("id", value: eventId).single().execute().value
        async let participants: [ParticipantRow] = supabase.from("participants").select()
            .eq("event_id", value: eventId).order("seat").execute().value
        async let rounds: [RoundRow] = supabase.from("rounds").select("*, matches(*, match_sides(*))")
            .eq("event_id", value: eventId).order("number").execute().value
        let organizer: Bool = (try? await supabase.rpc("is_event_organizer", params: ["p_event_id": AnyJSON.string(eventId)])
            .execute().value) ?? false
        let sorted = try await rounds.map { r in
            RoundRow(id: r.id, eventId: r.eventId, number: r.number, status: r.status, timerEndsAt: r.timerEndsAt,
                     matches: r.matches.sorted { ($0.tableNumber ?? 0) < ($1.tableNumber ?? 0) })
        }
        return try await EventBundle(event: event, participants: participants, rounds: sorted, isOrganizer: organizer)
    }

    /// Yields whenever anything in the event changes, so the screen can refetch.
    static func eventChanges(_ eventId: String) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let channel = supabase.channel("event-\(eventId)-\(UUID().uuidString)")
            let streams = ["matches", "match_sides", "rounds", "participants"].map { table in
                channel.postgresChange(AnyAction.self, schema: "public", table: table, filter: .eq("event_id", value: eventId))
            }
            let eventStream = channel.postgresChange(AnyAction.self, schema: "public", table: "events", filter: .eq("id", value: eventId))
            let task = Task {
                do {
                    try await channel.subscribeWithError()
                } catch {
                    continuation.finish()   // no live updates; reopening the event reloads it
                    return
                }
                await withTaskGroup(of: Void.self) { group in
                    for stream in streams + [eventStream] {
                        group.addTask { for await _ in stream { continuation.yield(()) } }
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await supabase.removeChannel(channel) }
            }
        }
    }

    // MARK: joining

    static func nearbyEvents(lat: Double, lng: Double, accuracyM: Int) async throws -> [NearbyEvent] {
        try await supabase.rpc("nearby_events", params: [
            "p_lat": AnyJSON.double(lat), "p_lng": .double(lng), "p_accuracy_m": .integer(accuracyM),
        ]).execute().value
    }

    static func joinNearby(eventId: String, lat: Double, lng: Double, accuracyM: Int) async throws -> SeatResult {
        try await supabase.rpc("join_event_nearby", params: [
            "p_event_id": AnyJSON.string(eventId), "p_lat": .double(lat), "p_lng": .double(lng), "p_accuracy_m": .integer(accuracyM),
        ]).execute().value
    }

    static func joinByQr(_ link: JoinLink) async throws -> SeatResult {
        try await supabase.rpc("join_event_qr", params: [
            "p_short_code": AnyJSON.string(link.code), "p_secret": .string(link.secret),
        ]).execute().value
    }

    static func joinQr(_ eventId: String, rotate: Bool = false) async throws -> JoinQr {
        try await supabase.rpc("get_join_qr", params: [
            "p_event_id": AnyJSON.string(eventId), "p_rotate": .bool(rotate),
        ]).execute().value
    }

    static func invites() async throws -> [InviteRow] {
        guard let uid = userId else { return [] }
        let rows: [InviteRow] = try await supabase.from("event_invites")
            .select("event_id, source, events(name, venue_name, status)")
            .eq("user_id", value: uid)
            .eq("status", value: "pending")
            .order("created_at", ascending: false)
            .execute().value
        return rows.filter { $0.events.map { !["completed", "archived"].contains($0.status) } ?? false }
    }

    static func respondToInvite(_ eventId: String, accept: Bool) async throws -> SeatResult {
        try await supabase.rpc("respond_to_invite", params: [
            "p_event_id": AnyJSON.string(eventId), "p_accept": .bool(accept),
        ]).execute().value
    }

    /// Foreground only: keeps this account's ~1 km area cell fresh for nearby alerts.
    static func updatePresence(lat: Double, lng: Double) async throws {
        try await supabase.rpc("update_presence", params: ["p_lat": AnyJSON.double(lat), "p_lng": .double(lng)]).execute()
    }

    static func setNearbyAlerts(_ enabled: Bool) async throws {
        guard let uid = userId else { return }
        try await supabase.from("notification_prefs")
            .upsert(["user_id": AnyJSON.string(uid), "nearby_alerts": .bool(enabled)])
            .execute()
    }

    // MARK: results

    static func reportMatch(_ match: MatchRow, side0: Int, side1: Int, draws: Int = 0) async throws -> ReportOutcome {
        try await supabase.rpc("report_match", params: [
            "p_match_id": AnyJSON.string(match.id),
            "p_side0_wins": .integer(side0),
            "p_side1_wins": .integer(side1),
            "p_draws": .integer(draws),
            "p_expected_version": .integer(match.version),
            "p_idempotency_key": .string(UUID().uuidString.lowercased()),
        ]).execute().value
    }

    static func respondToResult(_ matchId: String, accept: Bool) async throws {
        try await supabase.rpc("respond_to_result", params: ["p_match_id": AnyJSON.string(matchId), "p_accept": .bool(accept)]).execute()
    }

    static func setMatchResult(_ matchId: String, side0: Int, side1: Int, draws: Int, reason: String) async throws {
        try await supabase.rpc("set_match_result", params: [
            "p_match_id": AnyJSON.string(matchId),
            "p_side0_wins": .integer(side0),
            "p_side1_wins": .integer(side1),
            "p_draws": .integer(draws),
            "p_reason": .string(reason),
        ]).execute()
    }

    /// Closes the round (confirming undisputed reports); on the last round, completes the event.
    static func recordRound(eventId: String, roundId: String, finalRound: Bool) async throws {
        try await supabase.from("rounds")
            .update(["status": AnyJSON.string("recorded"), "recorded_at": .string(ISO8601DateFormatter().string(from: Date()))])
            .eq("id", value: roundId).execute()
        if finalRound {
            try await supabase.from("events").update(["status": AnyJSON.string("completed")]).eq("id", value: eventId).execute()
        }
    }

    // MARK: engine (server-authoritative pairing + standings)

    static func pairNextRound(_ eventId: String) async throws -> PairRoundResponse {
        try await supabase.functions.invoke(
            "events-engine",
            options: FunctionInvokeOptions(body: ["action": "pair_round", "event_id": eventId])
        ) { data, _ in try wireDecoder.decode(PairRoundResponse.self, from: data) }
    }

    static func standings(_ eventId: String) async throws -> [Standing] {
        try await supabase.functions.invoke(
            "events-engine",
            options: FunctionInvokeOptions(body: ["action": "standings", "event_id": eventId])
        ) { data, _ in try wireDecoder.decode(StandingsResponse.self, from: data).standings }
    }

    // MARK: records

    struct Rival: Identifiable, Hashable { var id: String { row.opponentId }; let name: String; let row: HeadToHeadRow }

    static func myProfile() async throws -> ProfileRow? {
        guard let uid = userId else { return nil }
        let rows: [ProfileRow] = try await supabase.from("profiles").select().eq("id", value: uid).execute().value
        return rows.first
    }

    static func myRecord() async throws -> PlayerRecord? {
        guard let uid = userId else { return nil }
        let rows: [PlayerRecord] = try await supabase.from("player_records").select().eq("user_id", value: uid).execute().value
        return rows.first
    }

    static func myRivals() async throws -> [Rival] {
        guard let uid = userId else { return [] }
        let rows: [HeadToHeadRow] = try await supabase.from("head_to_head").select()
            .eq("user_id", value: uid).order("last_played_at", ascending: false).limit(100).execute().value
        guard !rows.isEmpty else { return [] }
        let profiles: [ProfileRow] = try await supabase.from("profiles").select()
            .in("id", values: rows.map(\.opponentId)).execute().value
        let names = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.label) })
        return rows.map { Rival(name: names[$0.opponentId] ?? "Player", row: $0) }
    }

    // MARK: account

    /// Server-side delete: profile scrubbed (results stay as "Deleted player"), devices and alerts
    /// removed, Apple token revoked when a code is sent, then the sign-in itself is deleted.
    static func deleteAccount(appleAuthorizationCode: String?) async throws {
        var body: [String: String] = [:]
        if let appleAuthorizationCode { body["apple_authorization_code"] = appleAuthorizationCode }
        try await supabase.functions.invoke("delete-account", options: FunctionInvokeOptions(body: body))
    }

    /// Apple only shares the name on the first sign-in, so it is saved the moment it arrives.
    static func saveDisplayName(_ name: String) async {
        guard let uid = userId, !name.isEmpty else { return }
        _ = try? await supabase.from("profiles").update(["display_name": AnyJSON.string(String(name.prefix(40)))])
            .eq("id", value: uid).execute()
    }
}
