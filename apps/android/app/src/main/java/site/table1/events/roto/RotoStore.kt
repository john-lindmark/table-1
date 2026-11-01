package site.table1.events.roto

import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.realtime.RealtimeChannel
import io.github.jan.supabase.realtime.broadcastFlow
import io.github.jan.supabase.realtime.channel
import io.github.jan.supabase.realtime.realtime
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import site.table1.events.T1App
import site.table1.events.library.CatalogStore
import site.table1.events.library.ListKind
import site.table1.events.library.ListsStore
import site.table1.events.library.readImport
import site.table1.events.library.resolveImport
import site.table1.events.util.Telemetry
import site.table1.events.util.rethrowIfCancelled

/** Everything a roto draft asks of the server (contract/roto-2026-10-16.md). */
object RotoApi {
    private val rpc get() = T1App.supabase.postgrest
    private suspend fun call(fn: String, params: JsonObject): JsonObject = Json.parse(rpc.rpc(fn, params).data)

    suspend fun state(eventId: String, after: Int, pool: Boolean?) = RotoWire.state(call("roto_state", buildJsonObject {
        put("p_event_id", eventId); put("p_after_pick", after); if (pool == null) put("p_pool", JsonNull) else put("p_pool", pool)
    }))

    suspend fun pick(eventId: String, slot: Int, pickNo: Int) = RotoWire.pickResult(call("roto_pick", buildJsonObject {
        put("p_event_id", eventId); put("p_slot", slot); put("p_pick_no", pickNo)
    }))

    suspend fun undo(eventId: String) = RotoWire.state(call("roto_undo", buildJsonObject { put("p_event_id", eventId) }))

    suspend fun queue(eventId: String, slots: List<Int>, autoPick: Boolean?) = RotoWire.queue(call("roto_queue_set", buildJsonObject {
        put("p_event_id", eventId); put("p_slots", buildJsonArray { slots.forEach { add(JsonPrimitive(it)) } })
        if (autoPick == null) put("p_auto_pick", JsonNull) else put("p_auto_pick", autoPick)
    }))

    /** [clock] null keeps the schedule; empty clears it. [paused] null keeps the pause state. */
    suspend fun setClock(eventId: String, clock: List<RotoClockRange>?, paused: Boolean?) = RotoWire.state(call("roto_set_clock", buildJsonObject {
        put("p_event_id", eventId)
        if (clock == null) put("p_clock", JsonNull) else put("p_clock", buildJsonArray {
            clock.forEach { r -> add(buildJsonObject { put("from_round", r.fromRound); put("seconds", r.seconds) }) }
        })
        if (paused == null) put("p_paused", JsonNull) else put("p_paused", paused)
    }))

    suspend fun expire(eventId: String) { rpc.rpc("roto_expire", buildJsonObject { put("p_event_id", eventId) }) }

    /** One of your Library cubes becomes the draft's pool (its Main board). [from]: library / cube_cobra. */
    suspend fun setCube(eventId: String, listId: String, from: String): RotoCubeResult {
        val r = RotoWire.cube(call("roto_set_cube", buildJsonObject { put("p_event_id", eventId); put("p_list_id", listId) }))
        Telemetry.capture("roto_cube_set", mapOf("pool" to r.poolCount, "from" to from))
        return r
    }

    /** Seats everyone at random (unless already seated), snapshots the cube and starts the draft. */
    suspend fun start(eventId: String, picksPerPlayer: Int, order: String, clockRanges: Int): RotoState {
        val s = RotoWire.state(call("roto_start", buildJsonObject { put("p_event_id", eventId); put("p_picks_per_player", picksPerPlayer); put("p_order", order) }))
        Telemetry.capture("roto_started", mapOf("players" to s.draft.players, "picks_per_player" to s.draft.picksPerPlayer, "pool" to s.draft.poolCount,
            "order" to s.draft.pickOrder, "clock" to (clockRanges > 0), "clock_ranges" to clockRanges))
        return s
    }

    /** A Cube Cobra link → a cube in your Library (through list-import), so roto_set_cube can use it at once. */
    suspend fun importCube(url: String): String {
        val r = readImport(url, "")
        if (r.entries.isEmpty()) throw IllegalStateException(r.error ?: "No cards in that cube.")
        CatalogStore.load(userInitiated = true)
        val db = CatalogStore.db ?: throw IllegalStateException("Card data is still loading. Try again in a moment.")
        val resolved = withContext(Dispatchers.Default) { resolveImport(r.entries, ListKind.Cube, db) }
        if (resolved.entries.isEmpty()) throw IllegalStateException("None of that cube's cards are in the card data.")
        val host = r.sourceUrl?.let { runCatching { java.net.URI(it).host }.getOrNull() }
        val id = ListsStore.create(ListKind.Cube, (r.name ?: "Cube").take(60), r.format ?: "vintage", resolved.entries,
            host?.let { "Imported from $it" } ?: "Imported", "import")
        Telemetry.capture("list_imported", mapOf("kind" to "cube", "from" to "link", "cards" to resolved.entries.sumOf { it.qty }))
        return id
    }

    /**
     * After Create: the Library cube with the typed name, else the Cube Cobra link imported into the Library, becomes
     * the pool. Quietly leaves it for Setup → Details when neither works.
     */
    suspend fun linkCube(eventId: String, name: String, url: String) {
        try {
            val wanted = name.trim().lowercase()
            ListsStore.sync()
            val library = ListsStore.state.value.lists.firstOrNull { it.kind == ListKind.Cube && it.name.trim().lowercase() == wanted }
            when {
                library != null -> setCube(eventId, library.id, "library")
                url.isNotBlank() -> setCube(eventId, importCube(url.trim()), "cube_cobra")
                else -> return
            }
            RotoStore.of(eventId).refresh(full = true)
        } catch (e: Exception) {
            e.rethrowIfCancelled()
            Telemetry.error(e, "roto")
        }
    }

    /** Broadcast `roto:<event_id>`, event `roto_changed` (kind, picks_made); a rejoin yields "resubscribed". */
    fun changes(eventId: String): Flow<Pair<String, Int?>> = callbackFlow {
        val channel = T1App.supabase.channel("roto:$eventId")
        val messages = channel.broadcastFlow<JsonObject>(event = "roto_changed")
        val job = launch {
            messages.collect { m ->
                val p = (m["payload"] as? JsonObject) ?: m
                trySend((p["kind"]?.jsonPrimitive?.contentOrNull ?: "pick") to p["picks_made"]?.jsonPrimitive?.intOrNull)
            }
        }
        val rejoins = launch {
            var first = true
            channel.status.collect { s ->
                if (s != RealtimeChannel.Status.SUBSCRIBED) return@collect
                if (first) first = false else trySend("resubscribed" to null)
            }
        }
        channel.subscribe()
        awaitClose {
            job.cancel(); rejoins.cancel()
            CoroutineScope(Dispatchers.IO).launch { T1App.supabase.realtime.removeChannel(channel) }
        }
    }

    private object Json {
        fun parse(raw: String): JsonObject = kotlinx.serialization.json.Json.parseToJsonElement(raw).jsonObject
    }
}

/** What the Draft screens show, one immutable snapshot per change. */
data class RotoView(
    val loaded: Boolean = false, val phase: String = "setup", val draft: RotoDraftInfo = RotoDraftInfo(), val onClock: RotoOnClock? = null,
    val seats: List<RotoSeat> = emptyList(), val me: RotoMe? = null, val pool: Map<Int, RotoPoolCard> = emptyMap(), val poolOrder: List<Int> = emptyList(),
    val picks: List<RotoPick> = emptyList(), val pending: RotoPick? = null, val cards: Map<String, RotoCard> = emptyMap(),
    val queue: List<Int> = emptyList(), val autoPick: Boolean = true, val takenFromList: List<Pair<Int, RotoPick>> = emptyList(),
    val error: String? = null, val notice: String? = null, val busy: Boolean = false,
    /** Start draft's choices (Setup), sent with roto_start. */
    val planPicks: Int = 45, val planOrder: String = "snake",
) {
    val pickBySlot: Map<Int, RotoPick> by lazy { picks.associateBy { it.slot } }
    val picksMade get() = maxOf(draft.picksMade, picks.lastOrNull()?.pickNo ?: 0) + if (pending == null) 0 else 1
    val total get() = draft.total
    val players get() = maxOf(draft.players, seats.size)
    val mySeat get() = me?.seat
    val isMyTurn get() = phase == "drafting" && pending == null && onClock != null && onClock.participantId == me?.participantId
    val orderedSeats get() = seats.sortedBy { it.seat ?: Int.MAX_VALUE }
    fun seat(n: Int) = seats.firstOrNull { it.seat == n }
    fun name(seat: Int) = seat(seat)?.let { if (it.me) "You" else it.displayName } ?: "Seat $seat"
    fun card(slot: Int) = pool[slot]?.let { cards[it.cardId] ?: RotoCard.unknown(it.cardId) }
    fun pick(no: Int): RotoPick? = if (pending?.pickNo == no) pending else picks.getOrNull(no - 1)?.takeIf { it.pickNo == no } ?: picks.firstOrNull { it.pickNo == no }
    fun takenBy(slot: Int) = if (pending?.slot == slot) pending else pickBySlot[slot]
    fun picksOf(seat: Int) = picks.filter { it.seat == seat } + listOfNotNull(pending?.takeIf { it.seat == seat })
    fun inList(slot: Int) = queue.indexOf(slot).takeIf { it >= 0 }?.plus(1)
    val picksUntilMine get() = if (phase != "drafting") null else mySeat?.let { RotoMath.picksUntil(it, picksMade, players, total, draft.snake) }
    fun secondsLeft(nowMs: Long): Int? {
        val c = onClock ?: return null
        if (pending != null) return null
        if (draft.clockPaused) return c.remainingSeconds
        val d = c.deadline ?: return null
        return maxOf(0, kotlin.math.ceil(d - nowMs / 1000.0).toInt())
    }
}

/** One draft's state and actions. Same behaviour as iOS RotoStore and web roto.ts. */
class RotoStore(val eventId: String) {
    private val _view = MutableStateFlow(RotoView())
    val view: StateFlow<RotoView> = _view.asStateFlow()
    private val v get() = _view.value
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var refreshing = false
    private var refreshAgain = false
    private var queueJob: Job? = null
    private var autoDirty = false
    private var expiring = false
    private var lastExpireFor = 0

    private fun set(f: (RotoView) -> RotoView) = _view.update(f)
    fun clearMessages() = set { it.copy(error = null, notice = null) }
    fun setPlan(picks: Int? = null, order: String? = null) = set { it.copy(planPicks = picks ?: it.planPicks, planOrder = order ?: it.planOrder) }

    suspend fun load() {
        if (v.loaded) return refresh()
        try {
            apply(RotoApi.state(eventId, 0, true), full = true)
            set { it.copy(loaded = true, error = null) }
            resolveCards()
        } catch (e: Exception) {
            e.rethrowIfCancelled()
            set { it.copy(error = message(e)) }
        }
    }

    suspend fun refresh(full: Boolean = false) {
        if (!v.loaded) return load()
        if (refreshing) { refreshAgain = true; return }
        refreshing = true
        var whole = full || v.pool.isEmpty()
        try {
            do {
                refreshAgain = false
                val wantPool = v.pool.isEmpty()
                try {
                    val s = RotoApi.state(eventId, if (whole) 0 else (v.picks.lastOrNull()?.pickNo ?: 0), if (wantPool) true else null)
                    if (whole) {
                        apply(s, full = true)
                        if (wantPool && v.pool.isNotEmpty()) resolveCards()
                    } else {
                        val (merged, needsFull) = RotoMerge.apply(v.picks, s.picks, s.draft.picksMade)
                        if (needsFull) { whole = true; refreshAgain = true; continue }
                        apply(s, merged)
                    }
                    whole = false
                    set { it.copy(error = null) }
                } catch (e: Exception) {
                    e.rethrowIfCancelled()
                    set { it.copy(error = message(e)) }
                }
            } while (refreshAgain)
        } finally { refreshing = false }
    }

    private fun apply(s: RotoState, full: Boolean) {
        s.pool?.takeIf { it.isNotEmpty() }?.let { p -> set { it.copy(pool = p.associateBy { c -> c.slot }, poolOrder = sortedOrder(p.associateBy { c -> c.slot }, it.cards)) } }
        apply(s, s.picks.sortedBy { it.pickNo })
    }

    private fun apply(s: RotoState, merged: List<RotoPick>) = set { old ->
        val wasList = old.queue.toSet()
        val bySlot = merged.associateBy { it.slot }
        val me = s.me ?: old.me
        val gone = wasList.mapNotNull { slot -> bySlot[slot]?.takeIf { it.seat != me?.seat }?.let { slot to it } }
        val listFromServer = queueJob == null && s.me != null
        var queue = if (listFromServer) s.me!!.queue else old.queue
        if (gone.isNotEmpty()) queue = queue.filter { bySlot[it] == null }
        old.copy(phase = s.phase, draft = s.draft, onClock = s.onClock, seats = s.seats.ifEmpty { old.seats }, me = me, picks = merged, pending = null,
            queue = queue, autoPick = if (listFromServer) s.me!!.autoPick else old.autoPick, takenFromList = old.takenFromList + gone)
    }

    private fun sortedOrder(pool: Map<Int, RotoPoolCard>, cards: Map<String, RotoCard>) =
        pool.keys.sortedWith(compareBy<Int>({ pool[it]?.let { p -> cards[p.cardId]?.name } ?: "" }, { it }))

    /** Card names, types and colors from the local catalog only (no network per card). */
    suspend fun resolveCards() {
        CatalogStore.load(userInitiated = true)
        val db = CatalogStore.db ?: return
        val ids = v.pool.values.map { it.cardId }.filter { v.cards[it] == null }.toSet()
        if (ids.isEmpty()) return
        val resolved = withContext(Dispatchers.Default) {
            val printings = db.printings(ids)
            val oracles = db.oracles(printings.values.map { it.oracleIdx }.toSet())
            printings.mapNotNull { (id, p) -> oracles[p.oracleIdx]?.let { o -> id to RotoCard.of(id, o.name, o.typeLine, o.manaCost) } }.toMap()
        }
        set { it.copy(cards = it.cards + resolved, poolOrder = sortedOrder(it.pool, it.cards + resolved)) }
    }

    fun dismissTaken() = set { it.copy(takenFromList = emptyList()) }

    /** [from]: cube / grid / list / detail. */
    suspend fun pick(slot: Int, from: String): Boolean {
        val clock = v.onClock ?: return false
        if (v.phase != "drafting" || v.pending != null || v.takenBy(slot) != null) return false
        val pickNo = v.draft.picksMade + 1
        val seat = if (clock.seat > 0) clock.seat else RotoMath.seat(v.players, pickNo, v.draft.snake)
        val mine = clock.participantId == v.me?.participantId
        val how = if (mine) "player" else "organizer"
        // Shown at once; the answer replaces it.
        set { it.copy(pending = RotoPick(pickNo, seat, slot, how, System.currentTimeMillis() / 1000.0), queue = it.queue - slot, error = null, notice = null) }
        val onClockFor = clock.turnStartedAt?.let { maxOf(0, (System.currentTimeMillis() / 1000.0 - it).toInt()) } ?: 0
        return try {
            val r = RotoApi.pick(eventId, slot, pickNo)
            val (merged, needsFull) = RotoMerge.apply(v.picks, r.state.picks, r.state.draft.picksMade)
            apply(r.state, merged)
            if (needsFull) refresh(full = true)
            if (r.ok) {
                Telemetry.capture("roto_picked", mapOf("how" to how, "from" to from, "round" to clock.round, "seconds_on_clock" to onClockFor,
                    "auto_followed" to maxOf(0, r.state.draft.picksMade - pickNo)))
                true
            } else {
                set { it.copy(notice = "Someone picked first. Have another look.") }
                false
            }
        } catch (e: Exception) {
            e.rethrowIfCancelled()
            set { it.copy(pending = null, error = message(e)) }
            refresh()
            false
        }
    }

    suspend fun undo() {
        set { it.copy(busy = true) }
        val before = v.picksMade
        try {
            val s = RotoApi.undo(eventId)
            apply(s, RotoMerge.apply(v.picks, s.picks, s.draft.picksMade).first)
            Telemetry.capture("roto_pick_undone", mapOf("picks_removed" to maxOf(0, before - s.draft.picksMade)))
            refresh(full = true)
        } catch (e: Exception) {
            e.rethrowIfCancelled()
            set { it.copy(error = message(e)) }
        } finally { set { it.copy(busy = false) } }
    }

    suspend fun setClock(ranges: List<RotoClockRange>?, paused: Boolean? = null): Boolean {
        set { it.copy(busy = true) }
        return try {
            val s = RotoApi.setClock(eventId, ranges, paused)
            set { it.copy(phase = s.phase, draft = s.draft, onClock = s.onClock, error = null) }
            val action = paused?.let { if (it) "pause" else "resume" } ?: if (ranges.isNullOrEmpty()) "clear" else "set"
            Telemetry.capture("roto_clock_changed", mapOf("action" to action, "ranges" to (s.draft.clock?.size ?: 0)))
            true
        } catch (e: Exception) {
            e.rethrowIfCancelled()
            set { it.copy(error = message(e)) }
            false
        } finally { set { it.copy(busy = false) } }
    }

    /** A countdown reached zero: any client in the event asks the server to move on (pg_cron sweeps too). */
    fun expireIfDue(nowMs: Long) {
        val c = v.onClock ?: return
        val deadline = c.deadline ?: return
        if (v.phase != "drafting" || expiring || v.draft.clockPaused || c.overdue || nowMs / 1000.0 < deadline || lastExpireFor == c.pickNo) return
        expiring = true
        lastExpireFor = c.pickNo
        scope.launch {
            try { runCatching { RotoApi.expire(eventId) }; refresh() } finally { expiring = false }
        }
    }

    fun addToList(slot: Int) = editList { if (slot in it) it else it + slot }
    fun removeFromList(slot: Int) = editList { it - slot }
    fun moveInList(from: Int, to: Int) = editList { q ->
        if (from !in q.indices || to !in q.indices) q else q.toMutableList().apply { add(to, removeAt(from)) }
    }
    fun setAutoPick(on: Boolean) { set { it.copy(autoPick = on) }; saveSoon(autoChanged = true) }

    private fun editList(change: (List<Int>) -> List<Int>) {
        val q = change(v.queue)
        if (q == v.queue) return
        set { it.copy(queue = q) }
        saveSoon(autoChanged = false)
    }

    /** The whole list, ~600 ms after the last change. */
    private fun saveSoon(autoChanged: Boolean) {
        if (autoChanged) autoDirty = true
        queueJob?.cancel()
        queueJob = scope.launch {
            delay(600)
            val slots = v.queue; val auto = v.autoPick; val sendAuto = autoDirty
            autoDirty = false
            try {
                val r = RotoApi.queue(eventId, slots, if (sendAuto) auto else null)
                queueJob = null
                set { it.copy(queue = if (it.queue == slots) r.queue else it.queue, autoPick = r.autoPick) }
                Telemetry.capture("roto_list_changed", mapOf("cards" to r.queue.size, "auto_pick" to r.autoPick))
                if (r.picksMade != v.draft.picksMade) refresh()
            } catch (e: Exception) {
                queueJob = null
                e.rethrowIfCancelled()
                set { it.copy(error = message(e)) }
            }
        }
    }

    /** Live: refetch on every change (a pick we already hold is skipped), the whole state after an undo or a rejoin. */
    suspend fun listen() {
        RotoApi.changes(eventId).collect { (kind, made) ->
            if (made != null && made == v.draft.picksMade && kind == "pick") return@collect
            refresh(full = kind == "undo" || kind == "resubscribed")
        }
    }

    companion object {
        private val stores = HashMap<String, RotoStore>()
        fun of(eventId: String) = stores.getOrPut(eventId) { RotoStore(eventId) }

        /** The server's refusals in plain words (contract § Errors). */
        fun message(e: Throwable): String {
            val t = e.message ?: e.toString()
            return when {
                "23505" in t -> "Someone picked that card first."
                "55000" in t -> Regex("\"message\"\\s*:\\s*\"([^\"]+)\"").find(t)?.groupValues?.get(1) ?: "The draft isn't open for that right now."
                "42501" in t -> "That isn't your pick."
                else -> Regex("\"message\"\\s*:\\s*\"([^\"]+)\"").find(t)?.groupValues?.get(1) ?: t
            }
        }
    }
}
