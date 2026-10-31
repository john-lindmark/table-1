import Foundation
import Supabase

extension Error {
    /// A request dropped because its task was cancelled (a screen's .task ends when the screen goes away or
    /// reappears, e.g. a tapped push re-routing): not a failure, so never shown.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let e = self as? URLError, e.code == .cancelled { return true }
        return (self as NSError).domain == NSURLErrorDomain && (self as NSError).code == NSURLErrorCancelled
    }
}

/// Every call the app makes. Writes are RPCs (validated, audited and broadcast server-side);
/// pairing and standings come from the events-engine edge function so the rules exist once.
enum Repo {
    /// Postgres prints UUIDs lowercase; Swift's uuidString is uppercase.
    static var userId: String? { supabase.auth.currentUser?.id.uuidString.lowercased() }

    // MARK: events

    /// Everything the Events tab shows, in one call. Demo events only in TestFlight / Xcode builds. The answer is kept
    /// on the device for the next time the server can't be reached (contract/offline-2026-10-31.md § 1).
    static func eventsHome() async throws -> HomeData {
        let data = try await supabase.rpc("events_home", params: ["p_include_demo": AnyJSON.bool(BuildFlavor.isTest)]).execute().data
        let home = try wireDecoder.decode(HomeData.self, from: data)
        if let u = userId { OfflineCache.save(u, "home", data) }
        return home
    }

    /// The last events_home this account saw, with when.
    static func savedHome() -> (value: HomeData, at: Date)? {
        guard let u = userId else { return nil }
        return OfflineCache.load(u, "home", as: HomeData.self)
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
    static func createEventV2(_ draft: NewEventDraft, includeMe: Bool, guests: [String],
                              schedule: EventSchedule = EventSchedule()) async throws -> CreateEventResult {
        func text(_ s: String?) -> AnyJSON {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return .null }
            return .string(t)
        }
        let props: [String: Any] = [
            "format": draft.formatName, "rounds": draft.rounds, "round_timer": draft.showClock,
            "kind": draft.cubeName != nil ? "cube" : draft.setCode != nil ? "limited" : "constructed",
            "team_size": draft.teamSize ?? 0, "organizer_plays": includeMe, "guests": guests.count,
            "pairing": draft.pairing ?? "swiss",
            "scheduled": schedule.startsAt != nil, "capped": schedule.capacity != nil, "top_cut": draft.topCut,
            "auto_rounds": draft.autoRounds, "named": !(draft.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
            "decklists": draft.decklists,
        ]
        return try await Telemetry.after("event_created", props) { try await supabase.rpc("create_event_v2", params: [
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
            "p_local_date": .string(EventNaming.localDate(schedule.startsAt ?? Date())),
            "p_pairing": draft.pairing.map { AnyJSON.string($0) } ?? .null,
            "p_name": text(draft.name),
            "p_starts_at": schedule.startsAt.map { AnyJSON.string(iso($0)) } ?? .null,
            "p_venue_name": text(schedule.venue),
            "p_capacity": schedule.capacity.map { AnyJSON.integer($0) } ?? .null,
            "p_top_cut": .integer(draft.topCut),
            "p_auto_rounds": .bool(draft.autoRounds),
            "p_decklists": .string(draft.decklists),
        ]).execute().value }
    }

    static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    /// When, where and the cap, before round 1 (full state; opening places moves the waitlist up).
    static func setEventSchedule(eventId: String, _ s: EventSchedule) async throws {
        let venue = s.venue.trimmingCharacters(in: .whitespaces)
        try await supabase.rpc("set_event_schedule", params: [
            "p_event_id": AnyJSON.string(eventId),
            "p_starts_at": s.startsAt.map { AnyJSON.string(iso($0)) } ?? .null,
            "p_venue_name": venue.isEmpty ? .null : .string(venue),
            "p_capacity": s.capacity.map { AnyJSON.integer($0) } ?? .null,
            "p_local_date": .string(EventNaming.localDate(s.startsAt ?? Date())),
        ]).execute()
    }

    /// The event page: what anyone with the link sees (works signed out).
    static func eventPage(_ eventId: String) async throws -> EventPage {
        try await supabase.rpc("event_public", params: ["p_event_id": AnyJSON.string(eventId)]).execute().value
    }

    /// Sign up from the link: a seat, or the waitlist when it's full.
    static func signUp(_ eventId: String, signedInNow: Bool) async throws -> SignUpResult {
        let r: SignUpResult = try await supabase.rpc("event_sign_up", params: ["p_event_id": AnyJSON.string(eventId)]).execute().value
        if r.status == "joined" || r.status == "waitlisted" {
            Telemetry.capture("event_signed_up", ["status": r.status, "signed_in_now": signedInNow])
        }
        return r
    }

    /// Before round 1: leave your seat or your waitlist place.
    static func leaveEvent(_ eventId: String, waitlist: Bool) async throws {
        try await supabase.rpc("event_leave", params: ["p_event_id": AnyJSON.string(eventId)]).execute()
        Telemetry.capture("event_left", ["waitlist": waitlist])
    }

    static func waitlistAdmit(_ eventId: String, userId: String) async throws {
        try await supabase.rpc("waitlist_admit", params: ["p_event_id": AnyJSON.string(eventId), "p_user_id": .string(userId)]).execute()
        Telemetry.capture("waitlist_admitted")
    }

    static func waitlistRemove(_ eventId: String, userId: String) async throws {
        try await supabase.rpc("waitlist_remove", params: ["p_event_id": AnyJSON.string(eventId), "p_user_id": .string(userId)]).execute()
    }

    // MARK: decklists

    static func decklist(_ participantId: String) async throws -> Decklist? {
        let data = try await supabase.rpc("decklist_get", params: ["p_participant_id": AnyJSON.string(participantId)]).execute().data
        if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "null" { return nil }
        return try wireDecoder.decode(Decklist.self, from: data)
    }

    static func submitDecklist(participantId: String, body: String, listId: String?, byOrganizer: Bool) async throws {
        try await supabase.rpc("decklist_submit", params: [
            "p_participant_id": AnyJSON.string(participantId), "p_body": .string(body),
            "p_list_id": listId.map { AnyJSON.string($0) } ?? .null,
        ]).execute()
        Telemetry.capture("decklist_sent", ["source": listId == nil ? "text" : "deck", "by": byOrganizer ? "organizer" : "player"])
    }

    static func removeDecklist(_ participantId: String) async throws {
        try await supabase.rpc("decklist_remove", params: ["p_participant_id": AnyJSON.string(participantId)]).execute()
        Telemetry.capture("decklist_removed")
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
        try await Telemetry.after("event_location_set", ["visibility": visibility]) { try await supabase.rpc("set_event_location", params: [
            "p_event_id": AnyJSON.string(eventId),
            "p_lat": .double(lat),
            "p_lng": .double(lng),
            "p_venue_name": .string(venue ?? ""),
            "p_join_radius_m": .integer(150),
            "p_visibility": .string(visibility),
        ]).execute() }
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
            "p_pairing": draft.pairing.map { AnyJSON.string($0) } ?? .null,
            "p_auto_name": .bool(draft.autoName),
            "p_top_cut": .integer(draft.topCut),
            "p_auto_rounds": .bool(draft.autoRounds),
            "p_decklists": .string(draft.decklists),
        ]).execute().data
        return try wireDecoder.decode(EventDetails.self, from: data)
    }

    /// Draft seating drawn with players at the ends of the table (organizer; audited).
    static func setSeatEnds(_ eventId: String, on: Bool) async throws {
        try await supabase.rpc("set_seat_ends", params: [
            "p_event_id": AnyJSON.string(eventId), "p_on": .bool(on),
        ]).execute()
    }

    /// event_bundle's shape (rows exactly as the tables return them); testdata/event-bundle/bundle.json in tests.
    struct BundleWire: Decodable {
        let event: EventRow
        let participants: [ParticipantRow]
        let rounds: [RoundRow]
        let isOrganizer: Bool
        var waitlist: [WaitlistEntry]?
        var decklists: [DecklistInfo]?
    }

    /// The whole event in one call (contract/privacy-lockdown-2026-10-18.md): event_bundle checks who's asking
    /// (organizer or player) and refuses anyone else with "That event isn't available".
    static func loadEvent(_ eventId: String) async throws -> EventBundle {
        let data = try await supabase.rpc("event_bundle", params: ["p_event_id": AnyJSON.string(eventId)]).execute().data
        let w = try wireDecoder.decode(BundleWire.self, from: data)
        if let u = userId { OfflineCache.save(u, "event-\(eventId)", data) }
        return bundle(w)
    }

    /// The event as this account last saw it, with when (contract/offline-2026-10-31.md § 1).
    static func savedEvent(_ eventId: String) -> (value: EventBundle, at: Date)? {
        guard let u = userId, let (w, at) = OfflineCache.load(u, "event-\(eventId)", as: BundleWire.self) else { return nil }
        return (bundle(w), at)
    }

    static func savedStandings(_ eventId: String) -> StandingsResponse? {
        guard let u = userId else { return nil }
        return OfflineCache.load(u, "standings-\(eventId)", as: StandingsResponse.self)?.value
    }

    static func bundle(_ w: BundleWire) -> EventBundle {
        let rounds = w.rounds.map { row -> RoundRow in
            var r = row
            r.matches.sort { ($0.tableNumber ?? 0) < ($1.tableNumber ?? 0) }
            return r
        }
        return EventBundle(event: w.event, participants: w.participants, rounds: rounds, isOrganizer: w.isOrganizer,
                           waitlist: w.waitlist ?? [], decklists: w.decklists ?? [])
    }

    /// Yields whenever anything in the event changes, so the screen can refetch. The server pings the public topic
    /// `event:<id>` (event `changed`, no data) once per write; it also yields when the channel rejoins, since a ping
    /// sent while away is lost. Holds at most one pending signal: a burst of changes is one more reload, not one each.
    static func eventChanges(_ eventId: String) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let channel = supabase.channel("event:\(eventId)")
            let pings = channel.broadcastStream(event: "changed")
            let status = channel.statusChange
            let task = Task {
                do {
                    try await channel.subscribeWithError()
                } catch {
                    continuation.finish()   // no live updates; reopening the event reloads it
                    return
                }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { for await _ in pings { continuation.yield(()) } }
                    group.addTask {
                        var first = true
                        for await s in status where s == .subscribed {
                            if first { first = false; continue }
                            continuation.yield(())
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

    // MARK: joining

    static func nearbyEvents(lat: Double, lng: Double, accuracyM: Int) async throws -> [NearbyEvent] {
        try await supabase.rpc("nearby_events", params: [
            "p_lat": AnyJSON.double(lat), "p_lng": .double(lng), "p_accuracy_m": .integer(accuracyM),
        ]).execute().value
    }

    static func joinNearby(eventId: String, lat: Double, lng: Double, accuracyM: Int) async throws -> SeatResult {
        try await Telemetry.after("event_joined", ["via": "nearby"]) { try await supabase.rpc("join_event_nearby", params: [
            "p_event_id": AnyJSON.string(eventId), "p_lat": .double(lat), "p_lng": .double(lng), "p_accuracy_m": .integer(accuracyM),
        ]).execute().value }
    }

    /// `via`: "qr" from the in-app scanner, "link" from a universal link or shared URL (telemetry only).
    static func joinByQr(_ link: JoinLink, via: String = "qr") async throws -> SeatResult {
        try await Telemetry.after("event_joined", ["via": via]) { try await supabase.rpc("join_event_qr", params: [
            "p_short_code": AnyJSON.string(link.code), "p_secret": .string(link.secret),
        ]).execute().value }
    }

    /// A shared /join/<code> link (open events only, rate-limited). An account already in the event lands on it.
    static func joinByCode(_ code: String) async throws -> SeatResult {
        struct Wire: Decodable {
            let eventId: String?; let participantId: String?; let alreadyJoined: Bool?; let message: String?
            var waitlisted: Bool?
        }
        let name = await myDisplayName() ?? "Player"
        let w: Wire = try await supabase.rpc("join_event", params: [
            "p_code": AnyJSON.string(code), "p_display_name": .string(name),
        ]).execute().value
        // A code that leads nowhere joinable comes back as {error, message} (so the server's miss count sticks).
        // Full: signed in, you're on the waitlist now, and the server's message says your place.
        if w.waitlisted == true {
            Telemetry.capture("event_signed_up", ["status": "waitlisted", "signed_in_now": false])
            throw NSError(domain: "Table1", code: 1, userInfo: [NSLocalizedDescriptionKey: w.message ?? "This event is full"])
        }
        guard let eventId = w.eventId else {
            throw NSError(domain: "Table1", code: 1, userInfo: [NSLocalizedDescriptionKey: w.message ?? "No event found with that code"])
        }
        if w.alreadyJoined != true { Telemetry.capture("event_joined", ["via": "link"]) }
        return SeatResult(eventId: eventId, participantId: w.participantId, alreadyJoined: w.alreadyJoined)
    }

    /// How this account can see an event (event_preview: organizer / player / guest / invited / link / none); nil if unknown.
    static func eventAccess(_ eventId: String) async -> String? {
        struct Wire: Decodable { let access: String? }
        let w: Wire? = try? await supabase.rpc("event_preview", params: ["p_event_id": AnyJSON.string(eventId)]).execute().value
        return w?.access
    }

    /// The event behind a scanned QR's code, for the header over sign-in (works signed out; open events only).
    static func joinPreview(code: String) async -> JoinPreview? {
        let w: JoinPreview.Wire? = try? await supabase.rpc("event_preview", params: ["p_code": AnyJSON.string(code)]).execute().value
        return w.flatMap(JoinPreview.init)
    }

    static func joinQr(_ eventId: String, rotate: Bool = false) async throws -> JoinQr {
        try await supabase.rpc("get_join_qr", params: [
            "p_event_id": AnyJSON.string(eventId), "p_rotate": .bool(rotate),
        ]).execute().value
    }

    static func respondToInvite(_ eventId: String, accept: Bool) async throws -> SeatResult {
        try await Telemetry.after("invite_responded", ["accepted": accept]) { try await supabase.rpc("respond_to_invite", params: [
            "p_event_id": AnyJSON.string(eventId), "p_accept": .bool(accept),
        ]).execute().value }
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
        Telemetry.capture("nearby_alerts_changed", ["enabled": enabled])
    }

    // MARK: results

    static func reportMatch(_ match: MatchRow, side0: Int, side1: Int, draws: Int = 0) async throws -> ReportOutcome {
        let outcome: ReportOutcome = try await supabase.rpc("report_match", params: [
            "p_match_id": AnyJSON.string(match.id),
            "p_side0_wins": .integer(side0),
            "p_side1_wins": .integer(side1),
            "p_draws": .integer(draws),
            "p_expected_version": .integer(match.version),
            "p_idempotency_key": .string(UUID().uuidString.lowercased()),
        ]).execute().value
        Telemetry.capture("match_reported", ["status": outcome.status ?? "unknown", "games": side0 + side1 + draws, "draws": draws])
        return outcome
    }

    static func respondToResult(_ matchId: String, accept: Bool) async throws {
        try await supabase.rpc("respond_to_result", params: ["p_match_id": AnyJSON.string(matchId), "p_accept": .bool(accept)]).execute()
        Telemetry.capture("result_responded", ["accepted": accept])
    }

    static func setMatchResult(_ matchId: String, side0: Int, side1: Int, draws: Int, reason: String) async throws {
        try await supabase.rpc("set_match_result", params: [
            "p_match_id": AnyJSON.string(matchId),
            "p_side0_wins": .integer(side0),
            "p_side1_wins": .integer(side1),
            "p_draws": .integer(draws),
            "p_reason": .string(reason),
        ]).execute()
        Telemetry.capture("result_overridden")
    }

    /// Closes the round (confirming undisputed reports); on the last round, completes the event.
    /// One audited server call; refuses to finish while a result is disputed.
    static func recordRound(eventId: String, roundId: String, finalRound: Bool) async throws {
        try await supabase.rpc("record_round", params: [
            "p_event_id": AnyJSON.string(eventId),
            "p_round_id": .string(roundId),
            "p_final": .bool(finalRound),
        ]).execute()
        Telemetry.capture("round_recorded", ["final": finalRound])
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
        Telemetry.capture("round_clock_changed", ["action": action.rawValue])
        return try wireDecoder.decode(RoundClockResult.self, from: data)
    }

    /// Drop ("dropped", with the round they dropped after) or reinstate ("active", round cleared).
    /// Organizer only, audited on the server.
    static func setParticipantStatus(participantId: String, status: String, droppedInRound: Int?) async throws {
        let round: AnyJSON = droppedInRound.map { AnyJSON.integer($0) } ?? .null
        try await supabase.rpc("set_participant_status", params: [
            "p_participant_id": AnyJSON.string(participantId),
            "p_status": .string(status),
            "p_dropped_in_round": status == "dropped" ? round : .null,
        ]).execute()
        Telemetry.capture("player_dropped", ["status": status])
    }

    // MARK: engine (server-authoritative pairing + standings)

    static func pairNextRound(_ eventId: String, pairing: String = "swiss") async throws -> PairRoundResponse {
        let r: PairRoundResponse = try await engine("pair_round", eventId)
        if r.error == nil { Telemetry.capture("round_paired", ["round": r.roundNumber ?? 0, "pairing": pairing, "stage": r.stage ?? "swiss"]) }
        return r
    }

    /// Individual standings, plus team standings (team events) and seating (draft events).
    static func standings(_ eventId: String) async throws -> StandingsResponse {
        let data = try await engineData("standings", eventId)
        let s = try wireDecoder.decode(StandingsResponse.self, from: data)
        if let u = userId { OfflineCache.save(u, "standings-\(eventId)", data) }
        return s
    }

    /// Draft events before round 1: random seats in pods of up to 8. Calling again re-shuffles.
    /// One Postgres call (seat_event); the answer is the new seating.
    static func seatPlayers(_ eventId: String) async throws -> [SeatingPod] {
        let r: SeatPlayersResponse = try await supabase.rpc("seat_event", params: ["p_event_id": AnyJSON.string(eventId)])
            .execute().value
        Telemetry.capture("seating_drawn", ["pods": r.pods.count])
        return r.pods
    }

    private struct EngineError: Decodable { let error: String? }

    /// events-engine with the user's token. A refusal (4xx) surfaces the server's own message,
    /// e.g. "2 players aren't on a team yet".
    private static func engine<T: Decodable>(_ action: String, _ eventId: String) async throws -> T {
        try wireDecoder.decode(T.self, from: try await engineData(action, eventId))
    }

    private static func engineData(_ action: String, _ eventId: String) async throws -> Data {
        do {
            return try await supabase.functions.invoke(
                "events-engine",
                options: FunctionInvokeOptions(body: ["action": action, "event_id": eventId])
            ) { data, _ in data }
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
        let teams: [EventTeam] = try await supabase.rpc("randomize_teams", params: ["p_event_id": AnyJSON.string(eventId)]).execute().value
        Telemetry.capture("teams_set", ["teams": teams.count, "random": true])
        return teams
    }

    /// Saves the whole layout. Member order is slot order (slot 1 = seat A).
    static func setTeams(_ eventId: String, teams: [(name: String, members: [String])]) async throws -> [EventTeam] {
        let payload: [AnyJSON] = teams.map { t in
            .object(["name": .string(t.name), "members": .array(t.members.map { .string($0) })])
        }
        return try await Telemetry.after("teams_set", ["teams": teams.count, "random": false]) { try await supabase.rpc("set_teams", params: [
            "p_event_id": AnyJSON.string(eventId), "p_teams": .array(payload),
        ]).execute().value }
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
        try await Telemetry.after("tracker_game_recorded", ["draw": draw, "game_no": gameNo]) { try await supabase.rpc("tracker_record_game", params: [
            "p_session_id": AnyJSON.string(sessionId),
            "p_game_no": .integer(gameNo),
            "p_winner_side": winnerSide.map { AnyJSON.integer($0) } ?? .null,
            "p_draw": .bool(draw),
        ]).execute().value }
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

    /// Insights picks on the account (user_settings.insights); nil when signed out or unreadable, empty when none yet.
    static func insightsPicks() async -> [String: AnyJSON]? {
        guard let uid = userId else { return nil }
        struct Row: Decodable { let insights: [String: AnyJSON]? }
        do {
            let rows: [Row] = try await supabase.from("user_settings").select("insights").eq("user_id", value: uid).execute().value
            return rows.first?.insights ?? [:]
        } catch {
            return nil
        }
    }

    static func setInsightsPicks(_ picks: [String: AnyJSON]) async throws {
        guard let uid = userId else { return }
        try await supabase.from("user_settings")
            .upsert(["user_id": AnyJSON.string(uid), "insights": .object(picks),
                     "updated_at": .string(ISO8601DateFormatter().string(from: Date()))], onConflict: "user_id")
            .execute()
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
        Telemetry.capture("tracker_mode_changed", ["mode": mode])
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

    /// Whether this account is on the server's demo tester list (only testers see or seed demo data).
    static func isDemoTester() async -> Bool {
        (try? await supabase.rpc("demo_tester").execute().value as Bool) ?? false
    }

    /// Testers only: (re)loads sample events, opponents and results on this account.
    static func seedDemo() async throws { try await supabase.rpc("demo_seed").execute() }
    static func removeDemo() async throws { try await supabase.rpc("demo_remove").execute() }

    // MARK: organizer

    /// Cancels the event for everyone. Results already confirmed stay on players' records.
    static func cancelEvent(_ eventId: String, reason: String) async throws {
        try await supabase.rpc("cancel_event", params: [
            "p_event_id": AnyJSON.string(eventId), "p_reason": .string(reason),
        ]).execute()
        Telemetry.capture("event_cancelled")
    }

    /// People who've shared your events, most-shared first (optionally filtered by name).
    static func suggestedPlayers(_ eventId: String, query: String) async throws -> [SuggestedPlayer] {
        try await supabase.rpc("suggested_players", params: [
            "p_event_id": AnyJSON.string(eventId), "p_query": .string(query),
            "p_limit": .integer(50), "p_include_demo": .bool(BuildFlavor.isTest),
        ]).execute().value
    }

    /// `friends`: how many of them are friends (telemetry only).
    static func invitePlayers(_ eventId: String, userIds: [String], friends: Int = 0) async throws -> Int {
        let r: InviteResult = try await supabase.rpc("invite_players", params: [
            "p_event_id": AnyJSON.string(eventId), "p_user_ids": .array(userIds.map { .string($0) }),
        ]).execute().value
        Telemetry.capture("players_invited", ["count": r.invited ?? 0, "via": "account", "friends": friends])
        return r.invited ?? 0
    }

    /// Existing accounts only; the answer never says whether the address has one.
    static func inviteByEmail(_ eventId: String, email: String) async throws {
        try await supabase.rpc("invite_by_email", params: [
            "p_event_id": AnyJSON.string(eventId), "p_email": .string(email),
        ]).execute()
        Telemetry.capture("players_invited", ["count": 1, "via": "email"])
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
        try await Telemetry.after("guest_added") { try await supabase.rpc("add_guest", params: ["p_event_id": AnyJSON.string(eventId), "p_name": .string(name)])
            .execute().value }
    }

    /// The organizer joins their own event as a player.
    @discardableResult
    static func addSelf(_ eventId: String) async throws -> AddedPlayer {
        try await supabase.rpc("add_self_to_event", params: ["p_event_id": AnyJSON.string(eventId)]).execute().value
    }

    /// Before round 1 only (after that, Drop). Seats after theirs move up one.
    static func removeParticipant(_ participantId: String) async throws {
        try await supabase.rpc("remove_participant", params: ["p_participant_id": AnyJSON.string(participantId)]).execute()
        Telemetry.capture("player_removed")
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
