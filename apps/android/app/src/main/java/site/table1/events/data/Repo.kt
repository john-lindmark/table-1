package site.table1.events.data

import site.table1.events.util.rethrowIfCancelled
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.functions.functions
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import io.github.jan.supabase.postgrest.query.filter.FilterOperator
import io.github.jan.supabase.realtime.PostgresAction
import io.github.jan.supabase.realtime.RealtimeChannel
import io.github.jan.supabase.realtime.broadcastFlow
import io.github.jan.supabase.realtime.channel
import io.github.jan.supabase.realtime.postgresChangeFlow
import io.github.jan.supabase.realtime.realtime
import io.ktor.client.statement.bodyAsText
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.add
import site.table1.events.T1App
import site.table1.events.util.Telemetry
import java.util.UUID

/**
 * Every call the app makes. Writes are RPCs (validated, audited and broadcast server-side);
 * pairing and standings come from the events-engine edge function so the rules exist once.
 */
object Repo {
    private val supabase get() = T1App.supabase
    private val json get() = T1App.json

    val userId: String? get() = supabase.auth.currentUserOrNull()?.id

    /* ── events ─────────────────────────────────────────────────────────────── */

    /** Everything the Events tab shows, in one call. Android never shows demo data (TestFlight only). */
    suspend fun eventsHome(): HomeData =
        supabase.postgrest.rpc("events_home", buildJsonObject { put("p_include_demo", true) }).decodeAs()

    /** Live seats with table, opponent, ranks and clock — the same state the iOS Live Activity shows. */
    suspend fun liveSnapshots(): List<LiveSnapshot> = liveState()?.snapshots.orEmpty()

    /** Events you play in or run that are live (live-activity `state`), shown in the live notification and the Current
     *  match widget too; null when it couldn't be read. */
    suspend fun liveState(): LiveStateResponse? = runCatching {
        val response = supabase.functions.invoke("live-activity", buildJsonObject {
            put("action", "state"); put("include_demo", true)
        })
        json.decodeFromString<LiveStateResponse>(response.bodyAsText())
    }.onFailure { it.rethrowIfCancelled() }.getOrNull()
        ?.also { site.table1.events.util.LiveUpdates.show(site.table1.events.T1App.instance, it) }

    suspend fun createEvent(name: String, format: String, rounds: Int, roundMinutes: Int): CreateEventResult =
        supabase.postgrest.rpc("create_event", buildJsonObject {
            put("p_name", name)
            put("p_format", format)
            put("p_rounds", rounds)
            put("p_round_seconds", roundMinutes * 60)
            put("p_player_names", JsonArray(emptyList()))
        }).decodeAs()

    /**
     * Typed formats (contract §2). The server names the event and always runs 50-minute rounds; [showClock] only
     * decides whether clocks are shown. [includeMe] seats the organizer first; [guests] are players by name only.
     */
    suspend fun createEventV2(
        formatName: String,
        rounds: Int?,
        showClock: Boolean,
        setCode: String?,
        setName: String?,
        cubeName: String?,
        cubeUrl: String?,
        teamSize: Int?,
        formatOther: String?,
        includeMe: Boolean,
        guests: List<String>,
        name: String? = null,
        startsAt: String? = null,
        venueName: String? = null,
        capacity: Int? = null,
        topCut: Int = 0,
        autoRounds: Boolean = false,
        decklists: String = "off",
        localDate: String = EventNaming.localDate(),
        /** Roto only: swiss | round_robin. */
        pairing: String? = null,
    ): CreateEventResult =
        supabase.postgrest.rpc("create_event_v2", buildJsonObject {
            put("p_format_name", formatName)
            put("p_rounds", rounds)
            put("p_set_code", setCode)
            put("p_set_name", setName)
            put("p_cube_name", cubeName)
            put("p_cube_url", cubeUrl)
            put("p_team_size", teamSize)
            put("p_format_other", formatOther)
            put("p_player_names", JsonArray(guests.map { JsonPrimitive(it) }))
            put("p_include_me", includeMe)
            put("p_show_clock", showClock)
            put("p_local_date", localDate)
            put("p_name", name?.trim()?.ifEmpty { null })
            put("p_starts_at", startsAt)
            put("p_venue_name", venueName?.trim()?.ifEmpty { null })
            put("p_capacity", capacity)
            put("p_top_cut", topCut)
            put("p_auto_rounds", autoRounds)
            put("p_decklists", decklists)
            pairing?.let { put("p_pairing", it) }
        }).decodeAs<CreateEventResult>().also {
            Telemetry.capture("event_created", mapOf("format" to formatName, "organizer_plays" to includeMe, "guests" to guests.size, "scheduled" to (startsAt != null), "capped" to (capacity != null),
                "top_cut" to topCut, "auto_rounds" to autoRounds, "named" to !name.isNullOrBlank(), "decklists" to decklists))
        }

    /* ── scheduled events, sign-up link, waitlist, decklists (2026-10-27) ──────── */

    /** When, where and the cap, before round 1 (full state; opening places moves the waitlist up). */
    suspend fun setEventSchedule(eventId: String, startsAt: String?, venueName: String?, capacity: Int?, localDate: String) {
        supabase.postgrest.rpc("set_event_schedule", buildJsonObject {
            put("p_event_id", eventId)
            put("p_starts_at", startsAt)
            put("p_venue_name", venueName?.trim()?.ifEmpty { null })
            put("p_capacity", capacity)
            put("p_local_date", localDate)
        })
    }

    /** The event page: what anyone with the link sees (works signed out). */
    suspend fun eventPage(eventId: String): EventPage =
        supabase.postgrest.rpc("event_public", buildJsonObject { put("p_event_id", eventId) }).decodeAs()

    /** Sign up from the link: a seat, or the waitlist when it's full. */
    suspend fun signUp(eventId: String, signedInNow: Boolean): SignUpResult {
        val r = supabase.postgrest.rpc("event_sign_up", buildJsonObject { put("p_event_id", eventId) }).decodeAs<SignUpResult>()
        if (r.status == "joined" || r.status == "waitlisted") {
            Telemetry.capture("event_signed_up", mapOf("status" to r.status, "signed_in_now" to signedInNow))
        }
        return r
    }

    suspend fun leaveEvent(eventId: String, waitlist: Boolean) {
        supabase.postgrest.rpc("event_leave", buildJsonObject { put("p_event_id", eventId) })
        Telemetry.capture("event_left", mapOf("waitlist" to waitlist))
    }

    suspend fun waitlistAdmit(eventId: String, userId: String) {
        supabase.postgrest.rpc("waitlist_admit", buildJsonObject { put("p_event_id", eventId); put("p_user_id", userId) })
        Telemetry.capture("waitlist_admitted")
    }

    suspend fun waitlistRemove(eventId: String, userId: String) {
        supabase.postgrest.rpc("waitlist_remove", buildJsonObject { put("p_event_id", eventId); put("p_user_id", userId) })
    }

    suspend fun decklist(participantId: String): Decklist? {
        val text = supabase.postgrest.rpc("decklist_get", buildJsonObject { put("p_participant_id", participantId) }).data
        return if (text.isBlank() || text.trim() == "null") null else json.decodeFromString<Decklist>(text)
    }

    suspend fun submitDecklist(participantId: String, body: String, listId: String?, byOrganizer: Boolean) {
        supabase.postgrest.rpc("decklist_submit", buildJsonObject {
            put("p_participant_id", participantId)
            put("p_body", body)
            put("p_list_id", listId)
        })
        Telemetry.capture("decklist_sent", mapOf("source" to (if (listId == null) "text" else "deck"),
            "by" to (if (byOrganizer) "organizer" else "player")))
    }

    suspend fun removeDecklist(participantId: String) {
        supabase.postgrest.rpc("decklist_remove", buildJsonObject { put("p_participant_id", participantId) })
        Telemetry.capture("decklist_removed")
    }

    /* ── players before round 1 (organizer) ─────────────────────────────────── */

    /** A player by name only, not tied to an account. Refuses a name already in the event. */
    suspend fun addGuest(eventId: String, name: String): AddedPlayer =
        supabase.postgrest.rpc("add_guest", buildJsonObject {
            put("p_event_id", eventId)
            put("p_name", name)
        }).decodeAs()

    /** The organizer joins their own event as a player. */
    suspend fun addSelf(eventId: String): AddedPlayer =
        supabase.postgrest.rpc("add_self_to_event", buildJsonObject { put("p_event_id", eventId) }).decodeAs()

    /** Before round 1 only (after that, Drop). Seats after theirs move up one. */
    suspend fun removeParticipant(participantId: String) {
        supabase.postgrest.rpc("remove_participant", buildJsonObject { put("p_participant_id", participantId) })
    }

    /** The signed-in player's name as events show it ("You · <name>" on Create). */
    suspend fun myDisplayName(): String? {
        val uid = supabase.auth.currentUserOrNull()?.id ?: return null
        val row = runCatching {
            supabase.from("profiles").select { filter { eq("id", uid) } }.decodeSingleOrNull<ProfileName>()
        }.getOrNull()
        return listOfNotNull(row?.displayName, row?.handle).map { it.trim() }.firstOrNull { it.isNotEmpty() }
    }

    /* ── cubes ──────────────────────────────────────────────────────────────── */

    suspend fun recentCubes(): List<RecentCube> =
        runCatching { supabase.postgrest.rpc("recent_cubes", buildJsonObject { put("p_limit", 5) }).decodeList<RecentCube>() }
            .getOrDefault(emptyList())

    /** Cube Cobra link → name, server-side. Throws with the server's message ("Cube Cobra has no cube at that link"). */
    suspend fun lookupCube(url: String): CubeLookup {
        val response = supabase.functions.invoke("cube-lookup", buildJsonObject { put("url", url) })
        val r = runCatching { json.decodeFromString<CubeLookup>(response.bodyAsText()) }
            .getOrElse { CubeLookup(error = "Couldn't reach Cube Cobra") }
        r.error?.let { throw IllegalStateException(it) }
        return r
    }

    /** Scryfall sets for limited events, newest first. */
    suspend fun draftableSets(query: String, limit: Int = 80): List<DraftableSet> =
        supabase.postgrest.rpc("draftable_sets", buildJsonObject {
            put("p_query", query.trim().ifEmpty { null })
            put("p_limit", limit)
        }).decodeList()

    /** Pins the event where the organizer stands and, for nearby events, alerts opted-in players. */
    suspend fun setEventLocation(eventId: String, lat: Double, lng: Double, venue: String?, nearby: Boolean) =
        setEventLocation(eventId, lat, lng, venue, if (nearby) "nearby" else "link_only")

    /** Same call with an explicit visibility: 'nearby' | 'link_only' | 'private'. */
    suspend fun setEventLocation(eventId: String, lat: Double, lng: Double, venue: String?, visibility: String) {
        supabase.postgrest.rpc("set_event_location", buildJsonObject {
            put("p_event_id", eventId)
            put("p_lat", lat)
            put("p_lng", lng)
            put("p_venue_name", venue ?: "")
            put("p_join_radius_m", 150)
            put("p_visibility", visibility)
        })
    }

    /**
     * Setup only (no rounds yet): saves the event's details. Send the full current state every time.
     * Errors: 55000 "Details lock once round 1 is paired", 22023 validation messages.
     */
    suspend fun updateEventDetails(
        eventId: String,
        name: String?,
        formatName: String,
        rounds: Int,
        showClock: Boolean,
        setCode: String?,
        setName: String?,
        cubeName: String?,
        cubeUrl: String?,
        teamSize: Int?,
        formatOther: String?,
        autoName: Boolean? = null,
        topCut: Int? = null,
        autoRounds: Boolean? = null,
        decklists: String? = null,
        /** Roto only: swiss | round_robin; null leaves it. */
        pairing: String? = null,
    ): EventDetails =
        supabase.postgrest.rpc("update_event_details", buildJsonObject {
            put("p_event_id", eventId)
            put("p_name", name)
            put("p_format_name", formatName)
            put("p_rounds", rounds)
            put("p_round_seconds", 3000)
            put("p_show_clock", showClock)
            put("p_set_code", setCode)
            put("p_set_name", setName)
            put("p_cube_name", cubeName)
            put("p_cube_url", cubeUrl)
            put("p_team_size", teamSize)
            put("p_format_other", formatOther)
            put("p_auto_name", autoName)
            put("p_top_cut", topCut)
            put("p_auto_rounds", autoRounds)
            put("p_decklists", decklists)
            pairing?.let { put("p_pairing", it) }
        }).decodeAs()

    /**
     * The whole event in one call (contract/privacy-lockdown-2026-10-18.md): event_bundle checks who's asking
     * (organizer or player) and refuses anyone else with "That event isn't available".
     */
    suspend fun loadEvent(eventId: String): EventBundle =
        bundle(supabase.postgrest.rpc("event_bundle", buildJsonObject { put("p_event_id", eventId) }).decodeAs<EventBundleWire>())

    /** event_bundle's rows into the screen's bundle (testdata/event-bundle/bundle.json in EventBundleTest). */
    fun bundle(w: EventBundleWire): EventBundle = EventBundle(
        event = w.event,
        participants = w.participants,
        rounds = w.rounds.map { r -> r.copy(matches = r.matches.sortedBy { it.tableNumber ?: 0 }) },
        isOrganizer = w.isOrganizer,
        teams = w.teams.sortedBy { it.order }.map { EventTeamRow(id = it.id, name = it.name, displayOrder = it.order) },
        waitlist = w.waitlist,
        decklists = w.decklists,
    )

    /**
     * Emits whenever anything in the event changes, so the screen can refetch. The server pings the public topic
     * `event:<id>` (event `changed`, no data) once per write; a rejoin also emits, since a ping sent while away is lost.
     */
    fun eventChanges(eventId: String): Flow<Unit> = callbackFlow {
        val channel = supabase.channel("event:$eventId")
        val pings = channel.broadcastFlow<JsonObject>(event = "changed")
        val job = launch { pings.collect { trySend(Unit) } }
        val rejoins = launch {
            var first = true
            channel.status.collect { s ->
                if (s != RealtimeChannel.Status.SUBSCRIBED) return@collect
                if (first) first = false else trySend(Unit)
            }
        }
        channel.subscribe()
        awaitClose {
            job.cancel()
            rejoins.cancel()
            CoroutineScope(Dispatchers.IO).launch { supabase.realtime.removeChannel(channel) }
        }
    }

    /* ── joining ────────────────────────────────────────────────────────────── */

    suspend fun nearbyEvents(lat: Double, lng: Double, accuracyM: Int): List<NearbyEvent> =
        supabase.postgrest.rpc("nearby_events", buildJsonObject {
            put("p_lat", lat)
            put("p_lng", lng)
            put("p_accuracy_m", accuracyM)
        }).decodeList()

    suspend fun joinNearby(eventId: String, lat: Double, lng: Double, accuracyM: Int): SeatResult =
        supabase.postgrest.rpc("join_event_nearby", buildJsonObject {
            put("p_event_id", eventId)
            put("p_lat", lat)
            put("p_lng", lng)
            put("p_accuracy_m", accuracyM)
        }).decodeAs()

    suspend fun joinByQr(link: JoinLink): SeatResult =
        supabase.postgrest.rpc("join_event_qr", buildJsonObject {
            put("p_short_code", link.code)
            put("p_secret", link.secret)
        }).decodeAs()

    /** A shared /join/<code> link (open events only, rate-limited). An account already in the event lands on it. */
    suspend fun joinByCode(code: String): SeatResult {
        val w = supabase.postgrest.rpc("join_event", buildJsonObject {
            put("p_code", code)
            put("p_display_name", myDisplayName() ?: "Player")
        }).decodeAs<JoinCodeWire>()
        // A code that leads nowhere joinable comes back as {error, message} (so the server's miss count sticks); a full
        // event puts a signed-in caller on its waitlist and says so in the message.
        if (w.waitlisted) Telemetry.capture("event_signed_up", mapOf("status" to "waitlisted", "signed_in_now" to false))
        if (w.waitlisted) throw IllegalStateException(w.message ?: "This event is full")
        val eventId = w.eventId ?: throw IllegalStateException(w.message ?: "No event found with that code")
        if (!w.alreadyJoined) Telemetry.capture("event_joined", mapOf("via" to "link"))
        return SeatResult(eventId = eventId, participantId = w.participantId, alreadyJoined = w.alreadyJoined)
    }

    /** How this account can see an event (event_preview: organizer / player / guest / invited / link / none); null if unknown. */
    suspend fun eventAccess(eventId: String): String? = runCatching {
        supabase.postgrest.rpc("event_preview", buildJsonObject { put("p_event_id", eventId) }).decodeAs<EventAccessWire>().access
    }.getOrNull()

    /** The event behind a scanned QR's code, for the header over sign-in (works signed out; open events only). */
    suspend fun joinPreview(code: String): JoinPreview? = runCatching {
        JoinPreview.from(supabase.postgrest.rpc("event_preview", buildJsonObject { put("p_code", code) }).decodeAs<JoinPreview.Wire>())
    }.getOrNull()

    suspend fun joinQr(eventId: String, rotate: Boolean = false): JoinQr =
        supabase.postgrest.rpc("get_join_qr", buildJsonObject {
            put("p_event_id", eventId)
            put("p_rotate", rotate)
        }).decodeAs()

    suspend fun respondToInvite(eventId: String, accept: Boolean): SeatResult =
        supabase.postgrest.rpc("respond_to_invite", buildJsonObject {
            put("p_event_id", eventId)
            put("p_accept", accept)
        }).decodeAs()

    /** Foreground only: keeps this account's ~1 km area cell fresh for nearby alerts. */
    suspend fun updatePresence(lat: Double, lng: Double) {
        supabase.postgrest.rpc("update_presence", buildJsonObject {
            put("p_lat", lat)
            put("p_lng", lng)
        })
    }

    suspend fun setNearbyAlerts(enabled: Boolean) {
        val uid = userId ?: return
        supabase.from("notification_prefs").upsert(buildJsonObject {
            put("user_id", uid)
            put("nearby_alerts", enabled)
        })
    }

    /* ── results ────────────────────────────────────────────────────────────── */

    suspend fun reportMatch(match: MatchRow, side0: Int, side1: Int, draws: Int = 0): ReportOutcome =
        supabase.postgrest.rpc("report_match", buildJsonObject {
            put("p_match_id", match.id)
            put("p_side0_wins", side0)
            put("p_side1_wins", side1)
            put("p_draws", draws)
            put("p_expected_version", match.version)
            put("p_idempotency_key", UUID.randomUUID().toString())
        }).decodeAs()

    /** Report from the Events tab's live card (or the life tracker), by match id (same RPC, version check and idempotency). */
    suspend fun reportFromHome(matchId: String, mySide: Int, my: Int, their: Int, version: Int?, draws: Int = 0) {
        supabase.postgrest.rpc("report_match", buildJsonObject {
            put("p_match_id", matchId)
            put("p_side0_wins", if (mySide == 0) my else their)
            put("p_side1_wins", if (mySide == 0) their else my)
            put("p_draws", draws)
            if (version != null) put("p_expected_version", version)
            put("p_idempotency_key", UUID.randomUUID().toString())
        })
    }

    suspend fun respondToResult(matchId: String, accept: Boolean) {
        supabase.postgrest.rpc("respond_to_result", buildJsonObject {
            put("p_match_id", matchId)
            put("p_accept", accept)
        })
    }

    suspend fun setMatchResult(matchId: String, side0: Int, side1: Int, draws: Int, reason: String) {
        supabase.postgrest.rpc("set_match_result", buildJsonObject {
            put("p_match_id", matchId)
            put("p_side0_wins", side0)
            put("p_side1_wins", side1)
            put("p_draws", draws)
            put("p_reason", reason)
        })
    }

    /**
     * The round clock in one server call: [action] 'pause' | 'resume' | 'add' ([seconds], may be negative).
     * Keeps timer_ends_at / timer_last_started_at / timer_remaining_at_change consistent and drives Live Activity pushes.
     */
    suspend fun setRoundClock(roundId: String, action: String, seconds: Int = 300): RoundClockState =
        supabase.postgrest.rpc("set_round_clock", buildJsonObject {
            put("p_round_id", roundId)
            put("p_action", action)
            put("p_seconds", seconds)
        }).decodeAs()

    /** Drop ('dropped', with the round it happened in) or reinstate ('active') a player. Organizer only, audited on the server. */
    suspend fun setParticipantStatus(participantId: String, status: String, droppedInRound: Int?) {
        supabase.postgrest.rpc("set_participant_status", buildJsonObject {
            put("p_participant_id", participantId)
            put("p_status", status)
            put("p_dropped_in_round", if (status == "dropped") droppedInRound else null)
        })
    }

    /**
     * Closes the round (confirming undisputed reports); on the last round, completes the event.
     * One audited server call; refuses to finish while a result is disputed.
     */
    suspend fun recordRound(eventId: String, roundId: String, finalRound: Boolean) {
        supabase.postgrest.rpc("record_round", buildJsonObject {
            put("p_event_id", eventId)
            put("p_round_id", roundId)
            put("p_final", finalRound)
        })
    }

    /* ── engine: pairing + standings (server-authoritative) ─────────────────── */

    suspend fun pairNextRound(eventId: String): PairRoundResponse {
        val response = supabase.functions.invoke("events-engine", buildJsonObject {
            put("action", "pair_round")
            put("event_id", eventId)
        })
        return json.decodeFromString(response.bodyAsText())
    }

    suspend fun standings(eventId: String): List<Standing> = standingsFull(eventId).standings

    /** Individual standings plus team standings (team events) and draft seating (draft events). */
    suspend fun standingsFull(eventId: String): StandingsResponse {
        val response = supabase.functions.invoke("events-engine", buildJsonObject {
            put("action", "standings")
            put("event_id", eventId)
        })
        return json.decodeFromString<StandingsResponse>(response.bodyAsText())
    }

    /**
     * Draft events before round 1: random seats in pods of up to 8. Calling again re-shuffles.
     * One Postgres call (seat_event); the answer is the new seating. Refusals throw with the server's message.
     */
    suspend fun seatPlayers(eventId: String): SeatPlayersResponse =
        supabase.postgrest.rpc("seat_event", buildJsonObject { put("p_event_id", eventId) }).decodeAs()

    /* ── teams ──────────────────────────────────────────────────────────────── */

    suspend fun eventTeams(eventId: String): List<EventTeam> =
        supabase.postgrest.rpc("get_event_teams", buildJsonObject { put("p_event_id", eventId) }).decodeList()

    suspend fun randomizeTeams(eventId: String): List<EventTeam> =
        supabase.postgrest.rpc("randomize_teams", buildJsonObject { put("p_event_id", eventId) }).decodeList()

    /** Saves the whole layout; member order is slot order (1 = seat A). */
    /** Draft seating drawn with players at the ends of the table (organizer; audited). */
    suspend fun setSeatEnds(eventId: String, on: Boolean) {
        supabase.postgrest.rpc("set_seat_ends", buildJsonObject { put("p_event_id", eventId); put("p_on", on) })
    }

    suspend fun setTeams(eventId: String, teams: List<EventTeam>): List<EventTeam> =
        supabase.postgrest.rpc("set_teams", buildJsonObject {
            put("p_event_id", eventId)
            put("p_teams", buildJsonArray {
                teams.forEach { t ->
                    addJsonObject {
                        put("name", t.name)
                        putJsonArray("members") { t.members.forEach { add(it.participantId) } }
                    }
                }
            })
        }).decodeList()

    /* ── life tracker ───────────────────────────────────────────────────────── */

    suspend fun trackerOpen(matchId: String, startingLife: Int = 20): TrackerState =
        supabase.postgrest.rpc("tracker_open", buildJsonObject {
            put("p_match_id", matchId)
            put("p_starting_life", startingLife)
        }).decodeAs()

    suspend fun trackerState(sessionId: String): TrackerState =
        supabase.postgrest.rpc("tracker_state", buildJsonObject { put("p_session_id", sessionId) }).decodeAs()

    /** Up to 200 ops; idempotent by client_op_id. */
    suspend fun trackerPush(sessionId: String, ops: List<TrackerOp>): TrackerPushResult =
        supabase.postgrest.rpc("tracker_push", buildJsonObject {
            put("p_session_id", sessionId)
            put("p_ops", buildJsonArray {
                ops.forEach { o ->
                    addJsonObject {
                        put("client_op_id", o.clientOpId)
                        put("game_no", o.gameNo)
                        put("side", o.side)
                        put("counter", o.counter)
                        put("delta", o.delta)
                        put("tapped_at", o.tappedAt)
                    }
                }
            })
        }).decodeAs()

    suspend fun trackerRecordGame(sessionId: String, gameNo: Int, winnerSide: Int?, draw: Boolean): TrackerState =
        supabase.postgrest.rpc("tracker_record_game", buildJsonObject {
            put("p_session_id", sessionId)
            put("p_game_no", gameNo)
            put("p_winner_side", winnerSide)
            put("p_draw", draw)
        }).decodeAs()

    sealed interface TrackerChange {
        data class Op(val op: TrackerOp) : TrackerChange
        data class Game(val game: TrackerGame) : TrackerChange
        /** The match's round clock changed (pause, resume, time added). */
        data class Clock(val row: RoundClockRow) : TrackerChange
        /** The channel (re)joined: re-fetch tracker_state to catch anything missed while away. */
        data object Resubscribed : TrackerChange
    }

    /**
     * Inserts on tracker_ops / tracker_games for one session (RLS limits rows to the players + organizer),
     * plus updates to the round's clock when there is one.
     */
    fun trackerChanges(sessionId: String, roundId: String?): Flow<TrackerChange> = callbackFlow {
        val channel = supabase.channel("tracker-$sessionId-${UUID.randomUUID()}")
        val ops = channel.postgresChangeFlow<PostgresAction.Insert>(schema = "public") {
            table = "tracker_ops"
            filter("session_id", FilterOperator.EQ, sessionId)
        }
        val games = channel.postgresChangeFlow<PostgresAction.Insert>(schema = "public") {
            table = "tracker_games"
            filter("session_id", FilterOperator.EQ, sessionId)
        }
        val rounds = roundId?.let { id ->
            channel.postgresChangeFlow<PostgresAction.Update>(schema = "public") {
                table = "rounds"
                filter("id", FilterOperator.EQ, id)
            }
        }
        val me = userId
        val clockJob = rounds?.let { flow ->
            launch {
                flow.collect { action ->
                    runCatching { json.decodeFromJsonElement(RoundClockRow.serializer(), action.record) }.getOrNull()?.let {
                        trySend(TrackerChange.Clock(it))
                    }
                }
            }
        }
        val opJob = launch {
            ops.collect { action ->
                runCatching { json.decodeFromJsonElement(TrackerOpRow.serializer(), action.record) }.getOrNull()?.let { r ->
                    trySend(TrackerChange.Op(TrackerOp(r.clientOpId, r.gameNo, r.side, r.counter, r.delta,
                        r.tappedAt ?: java.time.Instant.now().toString(), mine = me != null && r.actor == me)))
                }
            }
        }
        val gameJob = launch {
            games.collect { action ->
                runCatching { json.decodeFromJsonElement(TrackerGame.serializer(), action.record) }.getOrNull()?.let {
                    trySend(TrackerChange.Game(it))
                }
            }
        }
        // Every (re)join re-fetches: covers the gap between tracker_open and the first join, and any reconnect.
        val statusJob = launch {
            channel.status.collect { status ->
                if (status == RealtimeChannel.Status.SUBSCRIBED) trySend(TrackerChange.Resubscribed)
            }
        }
        channel.subscribe()
        awaitClose {
            opJob.cancel()
            gameJob.cancel()
            clockJob?.cancel()
            statusJob.cancel()
            CoroutineScope(Dispatchers.IO).launch { supabase.realtime.removeChannel(channel) }
        }
    }

    /* ── settings ───────────────────────────────────────────────────────────── */

    /** 'elsewhere' (default) or 'tracker'. */
    suspend fun trackerMode(): String {
        val uid = userId ?: return "elsewhere"
        return supabase.from("user_settings").select { filter { eq("user_id", uid) } }
            .decodeList<UserSettings>().firstOrNull()?.trackerMode ?: "elsewhere"
    }

    suspend fun setTrackerMode(mode: String) {
        val uid = userId ?: return
        supabase.from("user_settings").upsert(buildJsonObject {
            put("user_id", uid)
            put("tracker_mode", mode)
            put("updated_at", java.time.Instant.now().toString())
        })
    }

    /** Insights picks on the account (user_settings.insights; contract/insights-2026-10-24.md § What the viewer picked). */
    suspend fun insightsPicks(): kotlinx.serialization.json.JsonObject? {
        val uid = userId ?: return null
        return supabase.from("user_settings").select(io.github.jan.supabase.postgrest.query.Columns.list("insights")) { filter { eq("user_id", uid) } }
            .decodeList<kotlinx.serialization.json.JsonObject>().firstOrNull()?.get("insights") as? kotlinx.serialization.json.JsonObject
    }

    suspend fun setInsightsPicks(picks: kotlinx.serialization.json.JsonObject) {
        val uid = userId ?: return
        supabase.from("user_settings").upsert(buildJsonObject {
            put("user_id", uid)
            put("insights", picks)
            put("updated_at", java.time.Instant.now().toString())
        })
    }

    /** Whether this account is on the server's demo tester list. Every call above asks for demo data; the server shows
     *  it only to testers (t1_private.demo_testers), in any build, so the store review account sees its sample events. */
    suspend fun isDemoTester(): Boolean = runCatching { supabase.postgrest.rpc("demo_tester").decodeAs<Boolean>() }.getOrDefault(false)

    /** Testers only: (re)loads sample events, opponents and results on this account, or removes them. */
    suspend fun seedDemo() { supabase.postgrest.rpc("demo_seed") }
    suspend fun removeDemo() { supabase.postgrest.rpc("demo_remove") }

    /* ── account ────────────────────────────────────────────────────────────── */

    /** Server-side delete: profile scrubbed (results stay as "Deleted player"), devices and alerts removed,
     *  then the sign-in itself is deleted. Apple revocation needs an Apple authorization code, which only the
     *  iOS app gets; on Android the Apple link is removed with the account. */
    suspend fun deleteAccount() {
        supabase.functions.invoke("delete-account", buildJsonObject { })
    }

    suspend fun accountOverview(): AccountOverview =
        supabase.postgrest.rpc("account_overview", buildJsonObject { put("p_include_demo", true) }).decodeAs()

    suspend fun nearbyAlertsOn(): Boolean {
        val uid = userId ?: return false
        return runCatching {
            supabase.from("notification_prefs").select(Columns.raw("nearby_alerts")) { filter { eq("user_id", uid) } }
                .decodeList<NearbyPref>().firstOrNull()?.nearbyAlerts ?: false
        }.getOrDefault(false)
    }

    @Serializable
    private data class NearbyPref(@SerialName("nearby_alerts") val nearbyAlerts: Boolean = false)

    suspend fun setDisplayName(name: String) {
        val uid = userId ?: return
        val trimmed = name.trim().take(40)
        if (trimmed.isEmpty()) return
        supabase.from("profiles").update(buildJsonObject { put("display_name", trimmed) }) { filter { eq("id", uid) } }
    }

    /* ── organizer ──────────────────────────────────────────────────────────── */

    /** Cancels the event for everyone. Results already confirmed stay on players' records. */
    suspend fun cancelEvent(eventId: String, reason: String) {
        supabase.postgrest.rpc("cancel_event", buildJsonObject {
            put("p_event_id", eventId)
            put("p_reason", reason)
        })
    }

    /** People who've shared your events, most-shared first (optionally filtered by name). */
    suspend fun suggestedPlayers(eventId: String, query: String): List<SuggestedPlayer> =
        supabase.postgrest.rpc("suggested_players", buildJsonObject {
            put("p_event_id", eventId)
            put("p_query", query)
            put("p_limit", 50)
            put("p_include_demo", true)
        }).decodeList()

    suspend fun invitePlayers(eventId: String, userIds: List<String>): Int =
        supabase.postgrest.rpc("invite_players", buildJsonObject {
            put("p_event_id", eventId)
            put("p_user_ids", kotlinx.serialization.json.JsonArray(userIds.map { kotlinx.serialization.json.JsonPrimitive(it) }))
        }).decodeAs<InviteResult>().invited

    /** Existing accounts only; the answer never says whether the address has one. */
    suspend fun inviteByEmail(eventId: String, email: String) {
        supabase.postgrest.rpc("invite_by_email", buildJsonObject {
            put("p_event_id", eventId)
            put("p_email", email)
        })
    }
}

@Serializable
private data class JoinCodeWire(
    @SerialName("event_id") val eventId: String? = null,
    @SerialName("participant_id") val participantId: String? = null,
    @SerialName("already_joined") val alreadyJoined: Boolean = false,
    val message: String? = null,
    val waitlisted: Boolean = false,
)

@Serializable
private data class EventAccessWire(val access: String? = null)

@Serializable
private data class ProfileName(@SerialName("display_name") val displayName: String? = null, val handle: String? = null)
