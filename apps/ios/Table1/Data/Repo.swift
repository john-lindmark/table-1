import Foundation
import Supabase

/// Every call the app makes. Writes are RPCs (validated, audited and broadcast server-side);
/// pairing and standings come from the events-engine edge function so the rules exist once.
enum Repo {
    /// Postgres prints UUIDs lowercase; Swift's uuidString is uppercase.
    static var userId: String? { supabase.auth.currentUser?.id.uuidString.lowercased() }

    // MARK: events

    /// Everything the Events tab shows, in one call. Demo events only in TestFlight / Xcode builds.
    static func eventsHome() async throws -> HomeData {
        try await supabase.rpc("events_home", params: ["p_include_demo": AnyJSON.bool(BuildFlavor.isTest)]).execute().value
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

    /// Typed formats: constructed formats, or limited with a set or a cube; team formats carry a team size.
    /// The server names the event and always runs 50-minute rounds. `includeMe` seats the organizer first;
    /// `guests` are players by name only (no account), each with a claim link.
    static func createEventV2(_ draft: NewEventDraft, includeMe: Bool, guests: [String]) async throws -> CreateEventResult {
        func text(_ s: String?) -> AnyJSON {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return .null }
            return .string(t)
        }
        return try await supabase.rpc("create_event_v2", params: [
            "p_format_name": AnyJSON.string(draft.formatName),
            "p_rounds": .integer(draft.rounds),
            "p_set_code": text(draft.setCode),
            "p_set_name": text(draft.setName),
            "p_cube_name": text(draft.cubeName),
            "p_cube_url": text(draft.cubeUrl),
            "p_team_size": draft.teamSize.map { AnyJSON.integer($0) } ?? .null,
            "p_format_other": text(draft.formatOther),
            "p_player_names": .array(guests.map { .string($0) }),
            "p_include_me": .bool(includeMe),
            "p_show_clock": .bool(draft.showClock),
            "p_local_date": .string(EventNaming.localDate()),
        ]).execute().value
    }

    /// Scryfall sets for limited events, newest first (optionally filtered by name or code).
    static func draftableSets(query: String) async throws -> [DraftableSet] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await supabase.rpc("draftable_sets", params: [
            "p_query": q.isEmpty ? AnyJSON.null : .string(q),
            "p_limit": .integer(80),
        ]).execute().value
    }

    /// Pins the event where the organizer stands and, for nearby events, alerts opted-in players.
    static func setEventLocation(eventId: String, lat: Double, lng: Double, venue: String?, nearby: Bool) async throws {
        try await setEventLocation(eventId: eventId, lat: lat, lng: lng, venue: venue, visibility: nearby ? "nearby" : "link_only")
    }

    /// Same call with an explicit visibility: "nearby" | "link_only" | "private".
    static func setEventLocation(eventId: String, lat: Double, lng: Double, venue: String?, visibility: String) async throws {
        try await supabase.rpc("set_event_location", params: [
            "p_event_id": AnyJSON.string(eventId),
            "p_lat": .double(lat),
            "p_lng": .double(lng),
            "p_venue_name": .string(venue ?? ""),
            "p_join_radius_m": .integer(150),
            "p_visibility": .string(visibility),
        ]).execute()
    }

    /// Setup only (no rounds yet): saves every detail at once — the full current state on each call.
    /// Refused with "Details lock once round 1 is paired" (55000) after that, or a 22023 validation message.
    static func updateEventDetails(eventId: String, _ draft: NewEventDraft) async throws -> EventDetails {
        func text(_ s: String?) -> AnyJSON {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return .null }
            return .string(t)
        }
        let data = try await supabase.rpc("update_event_details", params: [
            "p_event_id": AnyJSON.string(eventId),
            "p_name": text(draft.name),
            "p_format_name": .string(draft.formatName),
            "p_rounds": .integer(draft.rounds),
            "p_round_seconds": .integer(3000),
            "p_show_clock": .bool(draft.showClock),
            "p_set_code": text(draft.setCode),
            "p_set_name": text(draft.setName),
            "p_cube_name": text(draft.cubeName),
            "p_cube_url": text(draft.cubeUrl),
            "p_team_size": draft.teamSize.map { AnyJSON.integer($0) } ?? .null,
            "p_format_other": text(draft.formatOther),
        ]).execute().data
        return try wireDecoder.decode(EventDetails.self, from: data)
    }

    static func loadEvent(_ eventId: String) async throws -> EventBundle {
        async let event: EventRow = supabase.from("events").select().eq("id", value: eventId).single().execute().value
        async let participants: [ParticipantRow] = supabase.from("participants").select()
            .eq("event_id", value: eventId).order("seat").execute().value
        async let rounds: [RoundRow] = supabase.from("rounds").select("*, matches(*, match_sides(*))")
            .eq("event_id", value: eventId).order("number").execute().value
        let organizer: Bool = (try? await supabase.rpc("is_event_organizer", params: ["p_event_id": AnyJSON.string(eventId)])
            .execute().value) ?? false
        let sorted = try await rounds.map { row -> RoundRow in
            var r = row
            r.matches.sort { ($0.tableNumber ?? 0) < ($1.tableNumber ?? 0) }
            return r
        }
        return try await EventBundle(event: event, participants: participants, rounds: sorted, isOrganizer: organizer)
    }

    /// Yields whenever anything in the event changes, so the screen can refetch. Holds at most one
    /// pending signal: a burst of row changes (seating touches every player) is one more reload, not one each.
    static func eventChanges(_ eventId: String) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
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

    enum ClockAction: String { case pause, resume, add }

    /// The round clock in one server call (keeps ends_at / last_started_at / remaining consistent and
    /// drives Live Activity pushes). `seconds` is used by `.add` (may be negative).
    @discardableResult
    static func setRoundClock(roundId: String, action: ClockAction, seconds: Int = 300) async throws -> RoundClockResult {
        let data = try await supabase.rpc("set_round_clock", params: [
            "p_round_id": AnyJSON.string(roundId),
            "p_action": .string(action.rawValue),
            "p_seconds": .integer(seconds),
        ]).execute().data
        return try wireDecoder.decode(RoundClockResult.self, from: data)
    }

    /// Drop ("dropped", with the round they dropped after) or reinstate ("active", round cleared).
    /// A direct update: organizer RLS allows it.
    static func setParticipantStatus(participantId: String, status: String, droppedInRound: Int?) async throws {
        let round: AnyJSON = droppedInRound.map { AnyJSON.integer($0) } ?? .null
        try await supabase.from("participants")
            .update(["status": AnyJSON.string(status), "dropped_in_round": status == "dropped" ? round : .null])
            .eq("id", value: participantId)
            .execute()
    }

    // MARK: engine (server-authoritative pairing + standings)

    static func pairNextRound(_ eventId: String) async throws -> PairRoundResponse {
        try await engine("pair_round", eventId)
    }

    /// Individual standings, plus team standings (team events) and seating (draft events).
    static func standings(_ eventId: String) async throws -> StandingsResponse {
        try await engine("standings", eventId)
    }

    /// Draft events before round 1: random seats in pods of up to 8. Calling again re-shuffles.
    /// One Postgres call (seat_event); the answer is the new seating.
    static func seatPlayers(_ eventId: String) async throws -> [SeatingPod] {
        let r: SeatPlayersResponse = try await supabase.rpc("seat_event", params: ["p_event_id": AnyJSON.string(eventId)])
            .execute().value
        return r.pods
    }

    private struct EngineError: Decodable { let error: String? }

    /// events-engine with the user's token. A refusal (4xx) surfaces the server's own message,
    /// e.g. "2 players aren't on a team yet".
    private static func engine<T: Decodable>(_ action: String, _ eventId: String) async throws -> T {
        do {
            return try await supabase.functions.invoke(
                "events-engine",
                options: FunctionInvokeOptions(body: ["action": action, "event_id": eventId])
            ) { data, _ in try wireDecoder.decode(T.self, from: data) }
        } catch FunctionsError.httpError(_, let data) {
            let message = (try? wireDecoder.decode(EngineError.self, from: data))?.error ?? "Something went wrong. Try again."
            throw NSError(domain: "Table1", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    // MARK: teams

    static func eventTeams(_ eventId: String) async throws -> [EventTeam] {
        try await supabase.rpc("get_event_teams", params: ["p_event_id": AnyJSON.string(eventId)]).execute().value
    }

    /// Shuffles every active player into full teams; anyone left over stays unassigned.
    static func randomizeTeams(_ eventId: String) async throws -> [EventTeam] {
        try await supabase.rpc("randomize_teams", params: ["p_event_id": AnyJSON.string(eventId)]).execute().value
    }

    /// Saves the whole layout. Member order is slot order (slot 1 = seat A).
    static func setTeams(_ eventId: String, teams: [(name: String, members: [String])]) async throws -> [EventTeam] {
        let payload: [AnyJSON] = teams.map { t in
            .object(["name": .string(t.name), "members": .array(t.members.map { .string($0) })])
        }
        return try await supabase.rpc("set_teams", params: [
            "p_event_id": AnyJSON.string(eventId), "p_teams": .array(payload),
        ]).execute().value
    }

    // MARK: life tracker

    static func trackerOpen(matchId: String, startingLife: Int = 20) async throws -> TrackerState {
        try await supabase.rpc("tracker_open", params: [
            "p_match_id": AnyJSON.string(matchId), "p_starting_life": .integer(startingLife),
        ]).execute().value
    }

    static func trackerState(_ sessionId: String) async throws -> TrackerState {
        try await supabase.rpc("tracker_state", params: ["p_session_id": AnyJSON.string(sessionId)]).execute().value
    }

    /// Idempotent by client_op_id; ops for games already recorded are ignored by the server.
    static func trackerPush(_ sessionId: String, ops: [TrackerOp]) async throws -> TrackerPushResult {
        let payload: [AnyJSON] = ops.map { op in
            .object([
                "client_op_id": .string(op.clientOpId),
                "game_no": .integer(op.gameNo),
                "side": .integer(op.side),
                "counter": .string(op.counter),
                "delta": .integer(op.delta),
                "tapped_at": .string(op.tappedAt),
            ])
        }
        return try await supabase.rpc("tracker_push", params: [
            "p_session_id": AnyJSON.string(sessionId), "p_ops": .array(payload),
        ]).execute().value
    }

    static func trackerRecordGame(_ sessionId: String, gameNo: Int, winnerSide: Int?, draw: Bool) async throws -> TrackerState {
        try await supabase.rpc("tracker_record_game", params: [
            "p_session_id": AnyJSON.string(sessionId),
            "p_game_no": .integer(gameNo),
            "p_winner_side": winnerSide.map { AnyJSON.integer($0) } ?? .null,
            "p_draw": .bool(draw),
        ]).execute().value
    }

    enum TrackerChange {
        case op(TrackerOp)
        case game(TrackerGame)
        /// The match's round clock changed (pause, resume, time added).
        case clock(RoundClockRecord)
        /// The channel (re)joined: anything sent while it was away is only in tracker_state.
        case subscribed
    }

    /// New ops and recorded games for one tracker session (RLS limits rows to its players + organizer),
    /// plus the round's clock when there is one.
    static func trackerChanges(_ sessionId: String, roundId: String?) -> AsyncStream<TrackerChange> {
        AsyncStream { continuation in
            let channel = supabase.channel("tracker-\(sessionId)-\(UUID().uuidString)")
            let ops = channel.postgresChange(InsertAction.self, schema: "public", table: "tracker_ops",
                                             filter: .eq("session_id", value: sessionId))
            let games = channel.postgresChange(InsertAction.self, schema: "public", table: "tracker_games",
                                               filter: .eq("session_id", value: sessionId))
            let rounds = roundId.map {
                channel.postgresChange(UpdateAction.self, schema: "public", table: "rounds", filter: .eq("id", value: $0))
            }
            let status = channel.statusChange
            let me = userId
            let task = Task {
                do {
                    try await channel.subscribeWithError()
                } catch {
                    continuation.finish()   // no live updates; reopening the tracker reloads it
                    return
                }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await action in ops {
                            guard let row = try? action.decodeRecord(as: TrackerOpRecord.self, decoder: wireDecoder) else { continue }
                            continuation.yield(.op(row.op(me: me)))
                        }
                    }
                    group.addTask {
                        for await action in games {
                            guard let game = try? action.decodeRecord(as: TrackerGame.self, decoder: wireDecoder) else { continue }
                            continuation.yield(.game(game))
                        }
                    }
                    if let rounds {
                        group.addTask {
                            for await action in rounds {
                                guard let row = try? action.decodeRecord(as: RoundClockRecord.self, decoder: wireDecoder) else { continue }
                                continuation.yield(.clock(row))
                            }
                        }
                    }
                    group.addTask {
                        for await s in status where s == .subscribed { continuation.yield(.subscribed) }
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await supabase.removeChannel(channel) }
            }
        }
    }

    // MARK: settings

    /// "elsewhere" (default) or "tracker". Nil when it couldn't be read.
    static func trackerMode() async -> String? {
        guard let uid = userId else { return nil }
        struct Row: Decodable { let trackerMode: String }
        do {
            let rows: [Row] = try await supabase.from("user_settings").select("tracker_mode")
                .eq("user_id", value: uid).execute().value
            return rows.first?.trackerMode ?? "elsewhere"
        } catch {
            return nil
        }
    }

    static func setTrackerMode(_ mode: String) async throws {
        guard let uid = userId else { return }
        try await supabase.from("user_settings")
            .upsert([
                "user_id": AnyJSON.string(uid),
                "tracker_mode": .string(mode),
                "updated_at": .string(ISO8601DateFormatter().string(from: Date())),
            ], onConflict: "user_id")
            .execute()
    }

    // MARK: account

    static func accountOverview() async throws -> AccountOverview {
        try await supabase.rpc("account_overview", params: ["p_include_demo": AnyJSON.bool(BuildFlavor.isTest)]).execute().value
    }

    static func nearbyAlertsOn() async -> Bool {
        guard let uid = userId else { return false }
        struct Pref: Decodable { let nearbyAlerts: Bool }
        let rows: [Pref] = (try? await supabase.from("notification_prefs").select("nearby_alerts")
            .eq("user_id", value: uid).execute().value) ?? []
        return rows.first?.nearbyAlerts ?? false
    }

    /// TestFlight only: (re)loads sample events, opponents and results on this account.
    static func seedDemo() async throws { try await supabase.rpc("demo_seed").execute() }
    static func removeDemo() async throws { try await supabase.rpc("demo_remove").execute() }

    // MARK: organizer

    /// Cancels the event for everyone. Results already confirmed stay on players' records.
    static func cancelEvent(_ eventId: String, reason: String) async throws {
        try await supabase.rpc("cancel_event", params: [
            "p_event_id": AnyJSON.string(eventId), "p_reason": .string(reason),
        ]).execute()
    }

    /// People who've shared your events, most-shared first (optionally filtered by name).
    static func suggestedPlayers(_ eventId: String, query: String) async throws -> [SuggestedPlayer] {
        try await supabase.rpc("suggested_players", params: [
            "p_event_id": AnyJSON.string(eventId), "p_query": .string(query),
            "p_limit": .integer(50), "p_include_demo": .bool(BuildFlavor.isTest),
        ]).execute().value
    }

    static func invitePlayers(_ eventId: String, userIds: [String]) async throws -> Int {
        let r: InviteResult = try await supabase.rpc("invite_players", params: [
            "p_event_id": AnyJSON.string(eventId), "p_user_ids": .array(userIds.map { .string($0) }),
        ]).execute().value
        return r.invited ?? 0
    }

    /// Existing accounts only; the answer never says whether the address has one.
    static func inviteByEmail(_ eventId: String, email: String) async throws {
        try await supabase.rpc("invite_by_email", params: [
            "p_event_id": AnyJSON.string(eventId), "p_email": .string(email),
        ]).execute()
    }


    /// Server-side delete: profile scrubbed (results stay as "Deleted player"), devices and alerts
    /// removed, Apple token revoked when a code is sent, then the sign-in itself is deleted.
    static func deleteAccount(appleAuthorizationCode: String?) async throws {
        var body: [String: String] = [:]
        if let appleAuthorizationCode { body["apple_authorization_code"] = appleAuthorizationCode }
        try await supabase.functions.invoke("delete-account", options: FunctionInvokeOptions(body: body))
    }

    /// Apple only shares the name on the first sign-in, so it is saved the moment it arrives.
    static func saveDisplayName(_ name: String) async {
        try? await setDisplayName(name)
    }

    /// The signed-in player's name as events show it ("You · <name>" on Create).
    static func myDisplayName() async -> String? {
        struct Row: Decodable { let displayName: String?; let handle: String? }
        guard let uid = userId else { return nil }
        let row: Row? = try? await supabase.from("profiles").select("display_name, handle").eq("id", value: uid)
            .single().execute().value
        return [row?.displayName, row?.handle].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    // MARK: players before round 1 (organizer)

    /// A player by name only, not tied to an account. Refuses duplicate names in the event.
    @discardableResult
    static func addGuest(_ eventId: String, name: String) async throws -> AddedPlayer {
        try await supabase.rpc("add_guest", params: ["p_event_id": AnyJSON.string(eventId), "p_name": .string(name)])
            .execute().value
    }

    /// The organizer joins their own event as a player.
    @discardableResult
    static func addSelf(_ eventId: String) async throws -> AddedPlayer {
        try await supabase.rpc("add_self_to_event", params: ["p_event_id": AnyJSON.string(eventId)]).execute().value
    }

    /// Before round 1 only (after that, Drop). Seats after theirs move up one.
    static func removeParticipant(_ participantId: String) async throws {
        try await supabase.rpc("remove_participant", params: ["p_participant_id": AnyJSON.string(participantId)]).execute()
    }

    // MARK: cubes

    static func recentCubes() async -> [RecentCube] {
        (try? await supabase.rpc("recent_cubes", params: ["p_limit": AnyJSON.integer(5)]).execute().value) ?? []
    }

    /// Cube Cobra link → name. Throws with the server's message ("Cube Cobra has no cube at that link").
    static func lookupCube(_ url: String) async throws -> CubeLookup {
        do {
            return try await supabase.functions.invoke(
                "cube-lookup", options: FunctionInvokeOptions(body: ["url": url])
            ) { data, _ in try wireDecoder.decode(CubeLookup.self, from: data) }
        } catch FunctionsError.httpError(_, let data) {
            let message = (try? wireDecoder.decode(EngineError.self, from: data))?.error ?? "Couldn't reach Cube Cobra"
            throw NSError(domain: "Table1", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func setDisplayName(_ name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uid = userId, !trimmed.isEmpty else { return }
        try await supabase.from("profiles").update(["display_name": AnyJSON.string(String(trimmed.prefix(40)))])
            .eq("id", value: uid).execute()
    }
}
