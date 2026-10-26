package site.table1.events.library

import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import site.table1.events.T1App
import site.table1.events.util.Telemetry
import java.io.File
import java.util.UUID

// Binders, "for trade" and wants (contract/binders-wants-2026-10-17.md). A binder holds some of an item's copies
// (an allocation); copies no binder holds are Unsorted. Allocations only change through collection_apply,
// binder_move and binder_delete on the server, which keeps them within each item's copies; this store mirrors
// binders, allocations and wants on the device (a JSON file per account) and syncs them by seq (library_changes)
// right after the collection's own sync. Same rules as apps/ios/Table1/Library/Binders.swift.

@Serializable
data class Binder(val id: String, val name: String, @SerialName("for_trade") val forTrade: Boolean = false, val seq: Long = 0)

/** Copies of one item a binder holds. */
@Serializable
data class BinderAlloc(val binderId: String, val cardId: String, val finish: String, val condition: String, val lang: String,
                       val qty: Int, val seq: Long) {
    val itemKey get() = itemKey(cardId, finish, condition, lang)
    val key get() = "$binderId|$itemKey"

    companion object {
        /** [binder_id, card_id, finish, condition, lang, qty, seq] */
        fun of(r: JsonArray) = BinderAlloc(r[0].jsonPrimitive.content, r[1].jsonPrimitive.content, r[2].jsonPrimitive.content,
            r[3].jsonPrimitive.content, r[4].jsonPrimitive.content, r[5].jsonPrimitive.int, r[6].jsonPrimitive.long)
    }
}

/** One wishlist line. No card id = any printing; no finish = any finish of that printing. */
@Serializable
data class Want(val oracleId: String, val cardId: String? = null, val finish: String? = null, val qty: Int, val maxUsd: Double? = null,
                val seq: Long = 0) {
    val key get() = wantKey(oracleId, cardId, finish)

    companion object {
        /** [oracle_id, card_id, finish, qty, max_usd, seq] */
        fun of(r: JsonArray) = Want(r[0].jsonPrimitive.content, r[1].jsonPrimitive.contentOrNull, r[2].jsonPrimitive.contentOrNull,
            r[3].jsonPrimitive.int, (r[4] as? JsonPrimitive)?.let { it.doubleOrNull ?: it.contentOrNull?.toDoubleOrNull() }, r[5].jsonPrimitive.long)
    }
}

fun wantKey(oracleId: String, cardId: String?, finish: String?) = "$oracleId|${cardId ?: ""}|${finish ?: ""}"

data class BinderMove(val item: CollectionItem, val from: String?, val to: String?, val qty: Int)

/** [maxUsd] set means "set the max price" (null inside clears it); unset leaves it. */
data class WantOp(val oracleId: String, val cardId: String? = null, val finish: String? = null, val qty: Int? = null,
                  val delta: Int? = null, val setMax: Boolean = false, val maxUsd: Double? = null)

/* ── rules (the server is the authority; these keep the device's view and the tests in step) ── */

object BinderRules {
    /**
     * One item's allocations after a change: hints first (a binder's copies added, or taken out of it first), then
     * whatever exceeds [newQty] comes out of binders not for trade, then for-trade binders, each by name. Unsorted
     * copies are what's left over, so they always go first.
     */
    fun plan(current: Map<String, Int>, hints: Map<String, Int>, newQty: Int, binders: Map<String, Binder>): Map<String, Int> {
        val out = current.toMutableMap()
        for ((b, d) in hints) if (b in binders) out[b] = maxOf(0, (out[b] ?: 0) + d)
        var excess = out.values.sum() - newQty
        if (excess > 0) {
            val order = out.keys.filter { (out[it] ?: 0) > 0 }.sortedWith(compareBy<String>({ binders[it]?.forTrade == true },
                { binders[it]?.name?.lowercase() ?: "" }, { it }))
            for (b in order) {
                if (excess <= 0) break
                val take = minOf(out[b] ?: 0, excess)
                out[b] = (out[b] ?: 0) - take
                excess -= take
            }
        }
        return out
    }

    /** The want a trade's get meets first: that printing and finish, then that printing, then any printing. */
    fun wantFor(oracleId: String, cardId: String, finish: String, wants: Collection<Want>): Want? {
        val live = wants.filter { it.oracleId == oracleId && it.qty > 0 }
        return live.firstOrNull { it.cardId == cardId && it.finish == finish } ?: live.firstOrNull { it.cardId == cardId && it.finish == null }
            ?: live.firstOrNull { it.cardId == null }
    }

    /** Takes [qty] copies of a printing off the wants they meet, in that order. Returns the wants that changed. */
    fun meet(oracleId: String, cardId: String, finish: String, qty: Int, wants: MutableMap<String, Want>): List<Want> {
        var left = qty
        val changed = mutableListOf<Want>()
        while (left > 0) {
            val w = wantFor(oracleId, cardId, finish, wants.values) ?: break
            val n = minOf(left, w.qty)
            val nw = w.copy(qty = w.qty - n)
            wants[w.key] = nw
            changed.add(nw)
            left -= n
        }
        return changed
    }
}

/** A deck or cube line you own fewer copies of than it asks for. */
data class MissingLine(val cardId: String, val finish: String, val short: Int, val lists: List<String>) {
    val key get() = ownKey(cardId, finish)
}

object MissingView {
    /**
     * Every list line (not Considering) short of copies, per printing × finish, with the largest need across lists:
     * lists don't reserve copies, so one set of copies covers them all. Basic lands ([basics]) are never missing
     * (contract/basics-2026-10-24.md).
     */
    fun lines(lists: List<CardList>, owned: Map<String, Int>, basics: Set<String>): List<MissingLine> {
        val need = LinkedHashMap<String, Pair<Int, MutableList<String>>>()
        for (l in lists) {
            val mine = l.entries.filter { it.board != "maybe" && it.cardId !in basics }.groupBy { ownKey(it.cardId, it.finish) }.mapValues { (_, v) -> v.sumOf { it.qty } }
            for ((k, n) in mine) {
                if (n <= (owned[k] ?: 0)) continue
                val v = need[k] ?: (0 to mutableListOf())
                v.second.add(l.name)
                need[k] = maxOf(v.first, n) to v.second
            }
        }
        return need.map { (k, v) ->
            val (cardId, finish) = k.split("|", limit = 2)
            MissingLine(cardId, finish, v.first - (owned[k] ?: 0), v.second.sorted())
        }.sortedWith(compareByDescending<MissingLine> { it.short }.thenBy { it.key })
    }
}

/* ── store ────────────────────────────────────────────────────────────── */

data class BindersState(
    val userId: String? = null,
    /** Live binders, by name. */
    val binders: List<Binder> = emptyList(),
    val allocs: Map<String, BinderAlloc> = emptyMap(),
    val wants: Map<String, Want> = emptyMap(),
    val error: String? = null,
    val version: Int = 0,
) {
    private val byItem: Map<String, List<BinderAlloc>> by lazy { allocs.values.filter { it.qty > 0 }.groupBy { it.itemKey } }

    fun binder(id: String?) = id?.let { b -> binders.firstOrNull { it.id == b } }
    val liveWants get() = wants.values.filter { it.qty > 0 }.sortedByDescending { it.seq }

    /** Where an item's copies are: each binder holding some, by name, then Unsorted (never below 0). */
    fun placement(item: CollectionItem): Pair<List<Pair<Binder, Int>>, Int> {
        val held = (byItem[item.key] ?: emptyList()).mapNotNull { a -> binder(a.binderId)?.let { it to a.qty } }.sortedBy { it.first.name.lowercase() }
        return held to maxOf(0, item.qty - held.sumOf { it.second })
    }

    /** "Trade binder 2 · Unsorted 1", or null when every copy is Unsorted. */
    fun placementText(item: CollectionItem): String? {
        val (held, unsorted) = placement(item)
        if (held.isEmpty()) return null
        return (held.map { "${it.first.name} ${it.second}" } + listOfNotNull(if (unsorted > 0) "Unsorted $unsorted" else null)).joinToString(" · ")
    }

    /** Copies of an item in for-trade binders, and the for-trade binder holding most of them. */
    fun forTrade(itemKey: String): Pair<Int, String?> {
        val held = (byItem[itemKey] ?: emptyList()).filter { binder(it.binderId)?.forTrade == true }
        return held.sumOf { it.qty } to held.maxByOrNull { it.qty }?.binderId
    }

    /** Printing → finishes that for-trade binders hold (the give-side scanner prefers these). */
    fun forTradePrintings(): Map<String, Set<String>> =
        allocs.values.filter { it.qty > 0 && binder(it.binderId)?.forTrade == true }.groupBy { it.cardId }.mapValues { (_, v) -> v.map { it.finish }.toSet() }

    /** Copies each binder holds (clamped to what each item has), and the Unsorted total. */
    fun totals(items: Map<String, CollectionItem>): Pair<Map<String, Int>, Int> {
        val by = HashMap<String, Int>()
        var unsorted = 0
        for (it in items.values) {
            val (held, u) = placement(it)
            for ((b, q) in held) by[b.id] = (by[b.id] ?: 0) + minOf(q, it.qty)
            unsorted += u
        }
        return by to unsorted
    }

    /** Items with copies in a binder (null = Unsorted), as items whose qty is the copies there. */
    fun itemsIn(binderId: String?, items: Map<String, CollectionItem>): List<CollectionItem> = items.values.mapNotNull { it ->
        val (held, u) = placement(it)
        val n = if (binderId == null) u else held.firstOrNull { h -> h.first.id == binderId }?.second ?: 0
        if (n > 0) it.copy(qty = minOf(n, it.qty)) else null
    }
}

@Serializable
private data class BindersFile(val binders: List<Binder>, val allocs: List<BinderAlloc>, val wants: List<Want>, val cursor: Long)

@Serializable
private data class LibraryPage(
    val resync: Boolean,
    val binders: List<BinderDTO> = emptyList(),
    @SerialName("binder_items") val binderItems: List<JsonArray> = emptyList(),
    val wants: List<JsonArray> = emptyList(),
    val next: Long,
    val more: Boolean,
)

@Serializable
private data class BinderDTO(val id: String, val name: String, @SerialName("for_trade") val forTrade: Boolean, val deleted: Boolean = false, val seq: Long)

@Serializable
private data class DeleteResult(@SerialName("binder_items") val binderItems: List<JsonArray> = emptyList())

@Serializable
private data class WantsResult(val duplicate: Boolean = false, val wants: List<JsonArray> = emptyList())

@Serializable
private data class MoveResult(@SerialName("batch_id") val batchId: String, @SerialName("binder_items") val binderItems: List<JsonArray> = emptyList())

object BindersStore {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val _state = MutableStateFlow(BindersState())
    val state: StateFlow<BindersState> = _state.asStateFlow()
    private var cursor = 0L
    private var syncRun: CompletableDeferred<Unit>? = null
    private var syncAgain = false

    private fun set(f: (BindersState) -> BindersState) = _state.update { f(it).copy(version = it.version + 1) }
    private fun file(userId: String) = File(File(T1App.instance.filesDir, "library").apply { mkdirs() }, "binders-$userId.json")
    private fun byName(l: List<Binder>) = l.sortedBy { it.name.lowercase() }

    suspend fun start(userId: String) {
        if (_state.value.userId == userId) return sync()
        cursor = 0
        val saved = withContext(Dispatchers.IO) {
            runCatching { T1App.json.decodeFromString(BindersFile.serializer(), file(userId).readText()) }.getOrNull()
        }
        cursor = saved?.cursor ?: 0
        set {
            BindersState(userId = userId, binders = byName(saved?.binders ?: emptyList()), allocs = saved?.allocs?.associateBy { it.key } ?: emptyMap(),
                wants = saved?.wants?.associateBy { it.key } ?: emptyMap())
        }
        sync()
    }

    fun stop() {
        cursor = 0
        set { BindersState() }
    }

    fun syncInBackground() { scope.launch { sync() } }

    suspend fun sync() {
        if (_state.value.userId == null) return
        syncRun?.let {
            syncAgain = true
            it.await()
            return
        }
        val run = CompletableDeferred<Unit>()
        syncRun = run
        try {
            runSync()
        } finally {
            syncRun = null
            run.complete(Unit)
        }
        if (syncAgain) {
            syncAgain = false
            sync()
        }
    }

    private suspend fun runSync() {
        val user = _state.value.userId ?: return
        try {
            repeat(200) {
                val page = T1App.supabase.postgrest.rpc("library_changes", buildJsonObject {
                    put("p_after", cursor)
                    put("p_limit", 5000)
                }).decodeAs<LibraryPage>()
                if (_state.value.userId != user) return
                if (page.resync) {
                    cursor = 0
                    set { it.copy(binders = emptyList(), allocs = emptyMap(), wants = emptyMap()) }
                    return@repeat
                }
                set { s ->
                    var binders = s.binders
                    for (b in page.binders) {
                        binders = binders.filter { it.id != b.id }
                        if (!b.deleted) binders = binders + Binder(b.id, b.name, b.forTrade, b.seq)
                    }
                    s.copy(binders = byName(binders), allocs = merged(s.allocs, page.binderItems.map(BinderAlloc::of)),
                        wants = mergedWants(s.wants, page.wants.map(Want::of)))
                }
                cursor = page.next
                if (!page.more) {
                    set { it.copy(error = null) }
                    persist()
                    return
                }
            }
        } catch (e: Exception) {
            if (_state.value.userId == user) set { it.copy(error = e.message ?: "Couldn't sync your binders") }
        }
    }

    private fun merged(held: Map<String, BinderAlloc>, rows: List<BinderAlloc>): Map<String, BinderAlloc> {
        val out = held.toMutableMap()
        for (a in rows) {
            val h = out[a.key]
            if (h != null && h.seq > a.seq) continue
            if (a.qty > 0) out[a.key] = a else out.remove(a.key)
        }
        return out
    }

    private fun mergedWants(held: Map<String, Want>, rows: List<Want>): Map<String, Want> {
        val out = held.toMutableMap()
        for (w in rows) {
            val h = out[w.key]
            if (h != null && h.seq > w.seq) continue
            if (w.qty > 0) out[w.key] = w else out.remove(w.key)
        }
        return out
    }

    /** Writes rows a call returned into memory (the next sync owns the cursor and the file). */
    fun reflect(allocs: List<JsonArray>, wants: List<JsonArray>) {
        if (allocs.isEmpty() && wants.isEmpty()) return
        set { it.copy(allocs = merged(it.allocs, allocs.map(BinderAlloc::of)), wants = mergedWants(it.wants, wants.map(Want::of))) }
    }

    /** Adds (or, negative, takes back) copies shown in binders before the server answers (collection showAdds). */
    fun shift(rows: List<BinderAlloc>) {
        if (rows.isEmpty()) return
        set { it.copy(allocs = shiftAllocs(it.allocs, rows)) }
    }

    private suspend fun persist() {
        val s = _state.value
        val user = s.userId ?: return
        val f = BindersFile(s.binders, s.allocs.values.toList(), s.wants.values.toList(), cursor)
        withContext(Dispatchers.IO) { runCatching { file(user).writeText(T1App.json.encodeToString(BindersFile.serializer(), f)) } }
    }

    /* ── writing ── */

    /** Creates (new id) or renames / flags a binder. */
    suspend fun save(id: String?, name: String, forTrade: Boolean): Binder {
        val old = _state.value.binder(id)
        val r = T1App.supabase.postgrest.rpc("binder_save", buildJsonObject {
            put("p_id", id ?: UUID.randomUUID().toString())
            put("p_name", name)
            put("p_for_trade", forTrade)
        }).decodeAs<BinderDTO>()
        val saved = Binder(r.id, r.name, r.forTrade, r.seq)
        set { s -> s.copy(binders = byName(s.binders.filter { it.id != saved.id } + saved)) }
        if (old == null) Telemetry.capture("binder_created", mapOf("for_trade" to saved.forTrade))
        else if (old.name != saved.name || old.forTrade != saved.forTrade) {
            Telemetry.capture("binder_updated", mapOf("renamed" to (old.name != saved.name), "for_trade" to saved.forTrade))
        }
        syncInBackground()
        return saved
    }

    /** Deletes a binder; its copies go back to Unsorted. */
    suspend fun delete(b: Binder) {
        val copies = _state.value.allocs.values.filter { it.binderId == b.id }.sumOf { it.qty }
        val r = T1App.supabase.postgrest.rpc("binder_delete", buildJsonObject {
            put("p_id", b.id)
            put("p_idempotency_key", UUID.randomUUID().toString())
        }).decodeAs<DeleteResult>()
        set { s ->
            s.copy(binders = s.binders.filter { it.id != b.id },
                allocs = merged(s.allocs, r.binderItems.map(BinderAlloc::of)).filterValues { it.binderId != b.id })
        }
        Telemetry.capture("binder_deleted", mapOf("copies" to copies))
        syncInBackground()
    }

    /** Moves copies; one batch, so Undo moves them back. Returns the batch id. */
    suspend fun move(moves: List<BinderMove>): String {
        if (moves.isEmpty()) return ""
        val r = T1App.supabase.postgrest.rpc("binder_move", buildJsonObject {
            put("p_moves", buildJsonArray {
                for (m in moves) add(buildJsonObject {
                    put("card_id", m.item.cardId); put("finish", m.item.finish); put("condition", m.item.condition); put("lang", m.item.lang)
                    if (m.from == null) put("from", JsonNull) else put("from", m.from)
                    if (m.to == null) put("to", JsonNull) else put("to", m.to)
                    put("qty", m.qty)
                })
            })
            put("p_idempotency_key", UUID.randomUUID().toString())
        }).decodeAs<MoveResult>()
        reflect(r.binderItems, emptyList())
        Telemetry.capture("binder_copies_moved", mapOf("copies" to moves.sumOf { it.qty },
            "from" to (if (moves[0].from == null) "unsorted" else "binder"), "to" to (if (moves[0].to == null) "unsorted" else "binder")))
        syncInBackground()
        return r.batchId
    }

    /** One wishlist edit. */
    suspend fun applyWants(ops: List<WantOp>, event: String? = null, props: Map<String, Any> = emptyMap()) {
        if (ops.isEmpty()) return
        val r = T1App.supabase.postgrest.rpc("wants_apply", buildJsonObject {
            put("p_ops", buildJsonArray {
                for (op in ops) add(buildJsonObject {
                    put("oracle_id", op.oracleId)
                    op.cardId?.let { put("card_id", it) }
                    op.finish?.let { put("finish", it) }
                    op.qty?.let { put("qty", it) }
                    op.delta?.let { put("delta", it) }
                    if (op.setMax) { if (op.maxUsd == null) put("max_usd", JsonNull) else put("max_usd", op.maxUsd) }
                })
            })
            put("p_idempotency_key", UUID.randomUUID().toString())
        }).decodeAs<WantsResult>()
        reflect(emptyList(), r.wants)
        event?.let { Telemetry.capture(it, props) }
        if (r.duplicate) syncInBackground()
    }
}

fun shiftAllocs(held: Map<String, BinderAlloc>, rows: List<BinderAlloc>): Map<String, BinderAlloc> {
    val out = held.toMutableMap()
    for (a in rows) {
        val qty = (out[a.key]?.qty ?: 0) + a.qty
        if (qty > 0) out[a.key] = (out[a.key] ?: a).copy(qty = qty) else out.remove(a.key)
    }
    return out
}
