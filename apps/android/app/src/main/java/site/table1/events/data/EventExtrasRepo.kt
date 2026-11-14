package site.table1.events.data

import io.github.jan.supabase.functions.functions
import io.github.jan.supabase.postgrest.postgrest
import io.ktor.client.statement.bodyAsText
import kotlinx.coroutines.async
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import site.table1.events.T1App
import site.table1.events.util.Telemetry
import site.table1.events.util.rethrowIfCancelled

/*
 * The calls behind entry fees (contract/entry-fees-2026-11-13.md), teams, finals and alerts
 * (contract/teams-finals-alerts-2026-11-13.md) and the room tools (contract/room-tools-2026-11-13.md). The server part
 * may not be live: a missing function, or the payments function without its Stripe keys (503), throws like any refusal,
 * and callers hide their part or show its plain line (Leagues.isMissing, Fees.notSetUp). Nothing here reports to Sentry.
 */

private val supabase get() = T1App.supabase
private val json get() = T1App.json

/** What an event screen reads beside the event itself; each part null when the server doesn't have it (or refused). */
data class EventExtras(val money: EventMoney? = null, val room: EventRoom? = null) {
    val fee: EventFee? get() = money?.fee
}

/** A server without these functions is asked once a launch, not at every refresh of every event. */
private object ExtrasLive {
    @Volatile var noMoney = false
    @Volatile var noRoom = false
}

/** Both parts at once, failing soft: a part that can't be read is null, never an error on screen. */
suspend fun Repo.eventExtras(eventId: String): EventExtras = kotlinx.coroutines.coroutineScope {
    val money = async {
        if (ExtrasLive.noMoney) null
        else runCatching { eventMoney(eventId) }.onFailure { it.rethrowIfCancelled(); if (Leagues.isMissing(it)) ExtrasLive.noMoney = true }.getOrNull()
    }
    val room = async {
        if (ExtrasLive.noRoom) null
        else runCatching { eventRoom(eventId) }.onFailure { it.rethrowIfCancelled(); if (Leagues.isMissing(it)) ExtrasLive.noRoom = true }.getOrNull()
    }
    EventExtras(money.await(), room.await())
}

// ── entry fees ──

/**
 * "Hidden for now" (contract/entry-fees-2026-11-13.md § 1): until payments_account says `enabled`, nothing about
 * payments that an organizer could act on shows: no Account → Payments row, no Entry fee row in Setup → Details, no Cut
 * per entry in the season editor, no Dues tool. False, missing or a failed call all hide. What players see (the fee
 * line, Prize pool, Pay, prizes) needs no flag. Read once per sign-in and kept; the Account tab reads it again.
 */
object PaymentsGate {
    /** The rule: only an answer that says so opens payments. */
    fun shows(account: PaymentsAccount?): Boolean = account?.enabled == true

    /** The last answer and whose it was; another account's answer never counts. */
    internal fun shows(account: PaymentsAccount?, of: String?, me: String?): Boolean = me != null && of == me && shows(account)

    private data class Known(val user: String, val account: PaymentsAccount?)
    private val known = kotlinx.coroutines.flow.MutableStateFlow<Known?>(null)

    /** Changes when an answer arrives; read [on] after it. */
    val changes: kotlinx.coroutines.flow.StateFlow<Any?> get() = known

    /** Payments show for the signed-in account. Stand-in data (Debug) always shows them. */
    val on: Boolean get() = EventDemo.data != null || LeaguesDemo.on || known.value.let { shows(it?.account, it?.user, Repo.userId) }

    /** payments_account, asked once per sign-in ([again] asks anyway: the Account tab). A failed call hides and is
     *  asked again next time. Returns the account, null when the call failed. */
    suspend fun load(again: Boolean = false): PaymentsAccount? {
        val me = Repo.userId ?: return null
        known.value?.let { if (!again && it.user == me && it.account != null) return it.account }
        val a = try { Repo.paymentsAccount() } catch (e: Throwable) { e.rethrowIfCancelled(); null }
        known.value = Known(me, a)
        return a
    }
}

/** Your own Stripe connection as last heard from Stripe (no call to Stripe). */
suspend fun Repo.paymentsAccount(): PaymentsAccount {
    EventDemo.data?.let { return it.account }
    return supabase.postgrest.rpc("payments_account").decodeAs<PaymentsAccount>()
}

/** One call to the payments function; its body as text. A refusal throws with the function's `{error}` in the message. */
private suspend fun payments(body: JsonObject): String = supabase.functions.invoke("payments", body).bodyAsText()

/** The function's own words out of a refusal (`{"error": "…"}`), else the first line. */
fun paymentsMessage(e: Throwable): String {
    if (Fees.notSetUp(e)) return Fees.NOT_SET_UP
    val text = generateSequence(e) { it.cause }.take(4).joinToString("\n") { it.message.orEmpty() }
    Regex(""""error"\s*:\s*"((?:[^"\\]|\\.)*)"""").find(text)?.let { return it.groupValues[1].replace("\\\"", "\"") }
    return text.lineSequence().firstOrNull { it.isNotBlank() }?.trim() ?: "Something went wrong."
}

private fun urlOf(raw: String): String {
    val r = json.decodeFromString(PaymentsUrl.serializer(), raw)
    return r.url ?: throw IllegalStateException(r.error ?: "Something went wrong.")
}

/** Stripe's own onboarding for you (your account is made on the first call). Open it in a Custom Tab. */
suspend fun Repo.connectStart(): String {
    Telemetry.capture("stripe_connect_started")
    return urlOf(payments(buildJsonObject { put("action", "connect_start") }))
}

/** Asks Stripe now. */
suspend fun Repo.connectStatus(): PaymentsAccount {
    EventDemo.data?.let { return it.account }
    val a = json.decodeFromString(PaymentsAccount.serializer(), payments(buildJsonObject { put("action", "connect_status") }))
    Telemetry.capture("stripe_connect_status", mapOf("ready" to a.ready))
    return a
}

/** A one-time link to your Stripe dashboard. */
suspend fun Repo.connectDashboard(): String = urlOf(payments(buildJsonObject { put("action", "connect_dashboard") }))

/** Stripe's hosted checkout for your entry (an open one is handed back, not doubled). Open it in a Custom Tab; the
 *  return proves nothing, so re-read event_money after. */
suspend fun Repo.checkout(eventId: String): String {
    Telemetry.capture("pay_started", mapOf("origin" to "android"))
    // Stand-in events: the payment waits as it would on Stripe's webhook.
    EventDemo.data?.let { d -> d.setPayment(d.me, "pending", "app"); return "https://checkout.stripe.com/" }
    return urlOf(payments(buildJsonObject { put("action", "checkout"); put("event_id", eventId); put("origin", "android") }))
}

/** Your own app payment while `me.can_refund`, or any app payment when you run the event ([participantId]). */
suspend fun Repo.refund(eventId: String, participantId: String? = null): RefundResult {
    Telemetry.capture("refund_asked", mapOf("by" to if (participantId == null) "player" else "organizer"))
    EventDemo.data?.let { d -> d.setPayment(participantId ?: d.me, "refunded", "app"); return RefundResult(true, d.money.fee?.amountCents ?: 0) }
    return json.decodeFromString(RefundResult.serializer(), payments(buildJsonObject {
        put("action", "refund"); put("event_id", eventId)
        participantId?.let { put("participant_id", it) }
    }))
}

/** The fee, the pool as it stands, your own payment, prizes, and for organizers every player's payment. */
suspend fun Repo.eventMoney(eventId: String): EventMoney {
    EventDemo.data?.let { return it.money }
    if (LeaguesDemo.on) return EventMoney()
    return supabase.postgrest.rpc("event_money", buildJsonObject { put("p_event_id", eventId) }).decodeAs<EventMoney>()
}

/** Sets or changes the fee; null removes it. */
suspend fun Repo.setEventFee(eventId: String, fee: EventFee?): EventFee? {
    EventDemo.data?.let { d -> d.money = d.money.copy(fee = fee); return fee }
    val r = supabase.postgrest.rpc("event_fee_set", buildJsonObject {
        put("p_event_id", eventId)
        if (fee == null) put("p_fee", JsonNull) else put("p_fee", Fees.json(fee))
    }).decodeAs<EventFeeSet>()
    Telemetry.capture("fee_saved", mapOf("pay_mode" to (fee?.payMode ?: "none"), "amount" to (fee?.amountCents ?: 0)))
    return r.fee
}

/** The organizer marks a player paid at the door, comped, or unpaid again ([state] door | comp | unpaid). */
suspend fun Repo.markPayment(eventId: String, participantId: String, state: String) {
    Telemetry.capture("payment_marked", mapOf("state" to state))
    EventDemo.data?.let { d -> d.setPayment(participantId, if (state == "unpaid") "unpaid" else "paid", state.takeIf { it != "unpaid" }); return }
    supabase.postgrest.rpc("event_payment_mark", buildJsonObject {
        put("p_event_id", eventId); put("p_participant_id", participantId); put("p_state", state)
    })
}

/** An agreed split or any change ([rows]: participant id → cents); null goes back to the table. */
suspend fun Repo.setPrizes(eventId: String, rows: List<Pair<String, Int>>?): PrizesSet {
    Telemetry.capture("prizes_split", mapOf("back_to_table" to (rows == null)))
    EventDemo.data?.let { d -> d.splitPrizes(rows); return PrizesSet(rows?.sumOf { it.second } ?: 0, d.money.pool?.poolCents ?: 0) }
    return supabase.postgrest.rpc("event_prizes_set", buildJsonObject {
        put("p_event_id", eventId)
        if (rows == null) put("p_rows", JsonNull)
        else put("p_rows", buildJsonArray { rows.forEach { (p, c) -> add(buildJsonObject { put("participant_id", p); put("amount_cents", c) }) } })
    }).decodeAs<PrizesSet>()
}

suspend fun Repo.markPrize(eventId: String, participantId: String, paid: Boolean, how: String?) {
    Telemetry.capture("prize_marked", mapOf("how" to (how ?: if (paid) "other" else "unpaid")))
    EventDemo.data?.let { d ->
        d.money = d.money.copy(prizes = d.money.prizes.map { if (it.participantId == participantId) it.copy(paid = paid, paidHow = how.takeIf { paid }) else it })
        return
    }
    supabase.postgrest.rpc("event_prize_mark", buildJsonObject {
        put("p_event_id", eventId); put("p_participant_id", participantId); put("p_paid", paid)
        if (how == null) put("p_how", JsonNull) else put("p_how", how)
    })
}

/** A season's cut and pool (signed out too); the league's organizers also get what each event owes. */
suspend fun Repo.leagueMoney(seasonId: String): LeagueMoney {
    LeaguesDemo.data?.let { return it.moneyAs(LeaguesDemo.screen) }
    return supabase.postgrest.rpc("league_money", buildJsonObject { put("p_season_id", seasonId) }).decodeAs<LeagueMoney>()
}

suspend fun Repo.markLeagueDue(eventId: String, receivedCents: Int) {
    Telemetry.capture("dues_marked")
    if (LeaguesDemo.on) return
    supabase.postgrest.rpc("league_due_mark", buildJsonObject { put("p_event_id", eventId); put("p_received_cents", receivedCents) })
}

// ── Team Trios, teams that sign themselves up ──

/** Team Trios before round 1: each seat's format, seat A first. */
suspend fun Repo.setEventTrios(eventId: String, seats: List<String>): List<String> {
    EventDemo.data?.let { return seats }
    return supabase.postgrest.rpc("set_event_trios", buildJsonObject {
        put("p_event_id", eventId)
        putJsonArray("p_seat_formats") { seats.forEach { add(it) } }
    }).decodeAs<SeatFormatsSet>().seatFormats
}

suspend fun Repo.setTeamSignup(eventId: String, on: Boolean): Boolean {
    Telemetry.capture("team_signup_set", mapOf("on" to on))
    EventDemo.data?.let { d -> d.teams = d.teams?.copy(teamSignup = on); return on }
    return supabase.postgrest.rpc("team_signup_set", buildJsonObject { put("p_event_id", eventId); put("p_on", on) }).decodeAs<TeamSignupSet>().teamSignup
}

/** Teams as the event page shows them, for anyone who can open the event. */
suspend fun Repo.teamMine(eventId: String): TeamMine {
    EventDemo.data?.let { return it.teams ?: TeamMine() }
    if (LeaguesDemo.on) return TeamMine()
    return supabase.postgrest.rpc("team_mine", buildJsonObject { put("p_event_id", eventId) }).decodeAs<TeamMine>()
}

/** Signs you up and makes the team: you are its captain in seat A. */
suspend fun Repo.teamCreate(eventId: String, name: String): TeamMine {
    EventDemo.data?.let { return it.createTeam(name.trim()) }
    val r = supabase.postgrest.rpc("team_create", buildJsonObject { put("p_event_id", eventId); put("p_name", name.trim()) }).decodeAs<TeamMine>()
    Telemetry.capture("team_created")
    return r
}

/** Signs you up into the team's next free seat. [how]: code | link. */
suspend fun Repo.teamJoin(eventId: String, code: String, how: String): TeamMine {
    EventDemo.data?.let { return it.joinTeam(code) }
    val r = supabase.postgrest.rpc("team_join", buildJsonObject { put("p_event_id", eventId); put("p_code", code.trim().uppercase()) }).decodeAs<TeamMine>()
    Telemetry.capture("team_joined", mapOf("how" to how))
    return r
}

/** The captain or an organizer, before round 1. [patch] keys: name; order; captain; remove. [what] is telemetry's. */
suspend fun Repo.teamUpdate(teamId: String, patch: JsonObject, what: String): TeamMine {
    Telemetry.capture("team_updated", mapOf("what" to what))
    EventDemo.data?.let { return it.updateTeam(patch) }
    return supabase.postgrest.rpc("team_update", buildJsonObject { put("p_team_id", teamId); put("p_patch", patch) }).decodeAs<TeamMine>()
}

// ── a season's final ──

/** Who qualified and who is next in line, for someone who runs both the final and its league (42501 otherwise). */
suspend fun Repo.finalStatus(eventId: String): FinalStatus {
    EventDemo.data?.let { return it.final ?: throw IllegalStateException("Only the organizers of a season's final can see this") }
    return supabase.postgrest.rpc("league_final_status", buildJsonObject { put("p_event_id", eventId) }).decodeAs<FinalStatus>()
}

/** [keys] null: everyone qualified who has an account and isn't in or invited; else those players (passing it down). */
suspend fun Repo.finalInvite(eventId: String, keys: List<String>?): Int {
    EventDemo.data?.let { return it.invite(keys) }
    val r = supabase.postgrest.rpc("league_final_invite", buildJsonObject {
        put("p_event_id", eventId)
        if (keys == null) put("p_keys", JsonNull) else putJsonArray("p_keys") { keys.forEach { add(it) } }
    }).decodeAs<FinalInvited>()
    Telemetry.capture("final_invited", mapOf("count" to r.invited, "passed_down" to (keys != null)))
    return r.invited
}

// ── alerts for new public events ──

suspend fun Repo.eventAlerts(): EventAlerts {
    LeaguesDemo.data?.let { return it.alerts }
    return supabase.postgrest.rpc("event_alerts_get").decodeAs<EventAlerts>()
}

/** [patch] keys: on; formats; km (null = anywhere); lat + lng (your area); `place: null` forgets the area. */
suspend fun Repo.setEventAlerts(patch: JsonObject): EventAlerts {
    val r = LeaguesDemo.data?.patchAlerts(patch)
        ?: supabase.postgrest.rpc("event_alerts_set", buildJsonObject { put("p_patch", patch) }).decodeAs<EventAlerts>()
    Telemetry.capture("event_alerts_saved", mapOf("on" to r.on, "formats" to r.formats.size, "km" to (r.km ?: 0)))
    return r
}

// ── the room ──

/** What displays show, tables with extra time this round, judge calls (organizers) and your own table. */
suspend fun Repo.eventRoom(eventId: String): EventRoom {
    EventDemo.data?.let { return it.room }
    if (LeaguesDemo.on) return EventRoom()
    return supabase.postgrest.rpc("event_room", buildJsonObject { put("p_event_id", eventId) }).decodeAs<EventRoom>()
}

/** [show] auto | clock | pairings | standings; [message] up to 140 characters, blank clears it. Only what's given is sent. */
suspend fun Repo.setDisplay(eventId: String, show: String? = null, message: String? = null): RoomDisplay {
    Telemetry.capture("display_set", mapOf("show" to (show ?: "kept"), "message" to !message.isNullOrBlank()))
    EventDemo.data?.let { d ->
        val next = RoomDisplay(show ?: d.room.display.show, if (message == null) d.room.display.message else message.trim().ifEmpty { null })
        d.room = d.room.copy(display = next)
        return next
    }
    return supabase.postgrest.rpc("event_display_set", buildJsonObject {
        put("p_event_id", eventId)
        put("p_patch", buildJsonObject {
            show?.let { put("show", it) }
            message?.let { put("message", it) }
        })
    }).decodeAs<RoomDisplay>()
}

/** Adds [seconds] (negative takes time back) to a table in the round being played; its total stays 0–3600. */
suspend fun Repo.extendMatch(matchId: String, seconds: Int): RoomExtension {
    Telemetry.capture("time_extended", mapOf("seconds" to seconds))
    EventDemo.data?.let { return it.extend(matchId, seconds) }
    return supabase.postgrest.rpc("match_time_extend", buildJsonObject { put("p_match_id", matchId); put("p_seconds", seconds) }).decodeAs<RoomExtension>()
}

/** A player at that table calls a judge; calling while a call is open returns the same call. */
suspend fun Repo.judgeCall(matchId: String) {
    Telemetry.capture("judge_called")
    EventDemo.data?.let { d -> d.room = d.room.copy(myMatch = d.room.myMatch?.copy(callOpen = true)); return }
    supabase.postgrest.rpc("judge_call", buildJsonObject { put("p_match_id", matchId) })
}

suspend fun Repo.judgeCancel(matchId: String) {
    Telemetry.capture("judge_cancelled")
    EventDemo.data?.let { d -> d.room = d.room.copy(myMatch = d.room.myMatch?.copy(callOpen = false)); return }
    supabase.postgrest.rpc("judge_call_cancel", buildJsonObject { put("p_match_id", matchId) })
}

/** An organizer marks a call handled. */
suspend fun Repo.judgeResolve(callId: String) {
    Telemetry.capture("judge_resolved")
    EventDemo.data?.let { d -> d.room = d.room.copy(calls = d.room.calls?.filterNot { it.callId == callId }); return }
    supabase.postgrest.rpc("judge_call_resolve", buildJsonObject { put("p_call_id", callId) })
}

/** The rules level ([rel] casual | competitive | null) and the decklist deadline (null clears); only what's set is sent. */
suspend fun Repo.setEventRules(eventId: String, rel: String? = null, setRel: Boolean = false, dueAt: String? = null, setDue: Boolean = false) {
    EventDemo.data?.let { d ->
        d.about = d.about.copy(rel = if (setRel) rel else d.about.rel, decklistDueAt = if (setDue) dueAt else d.about.decklistDueAt)
        return
    }
    supabase.postgrest.rpc("event_listing_set", buildJsonObject {
        put("p_event_id", eventId)
        put("p_patch", buildJsonObject {
            if (setRel) { if (rel == null) put("rel", JsonNull) else put("rel", rel) }
            if (setDue) { if (dueAt == null) put("decklist_due_at", JsonNull) else put("decklist_due_at", dueAt) }
        })
    })
}
