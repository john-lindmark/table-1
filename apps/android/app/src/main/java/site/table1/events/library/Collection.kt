package site.table1.events.library

import site.table1.events.util.Offline
import site.table1.events.util.Telemetry
import site.table1.events.util.rethrowIfCancelled
import kotlinx.serialization.encodeToString

import android.content.ContentValues
import android.database.sqlite.SQLiteDatabase
import io.github.jan.supabase.exceptions.HttpRequestException
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
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import site.table1.events.T1App
import java.io.File
import java.util.UUID

// The signed-in player's collection, mirrored locally (contract/collection-2026-10-15.md). Items live in a
// SQLite file per account and in memory while the app runs; the server is asked only for what changed since
// the highest seq we hold. Writes go through collection_apply, show at once, then a delta sync confirms them.

enum class Finish(val wire: String, val label: String) {
    Nonfoil("nonfoil", "Non-foil"), Foil("foil", "Foil"), Etched("etched", "Etched");
    companion object { fun of(wire: String) = entries.firstOrNull { it.wire == wire } }
}

data class CollectionItem(val cardId: String, val finish: String, val condition: String, val lang: String, val qty: Int, val seq: Long) {
    val key get() = itemKey(cardId, finish, condition, lang)
    val finishLabel get() = Finish.of(finish)?.label ?: finish
}

fun itemKey(cardId: String, finish: String, condition: String, lang: String) = "$cardId|$finish|$condition|$lang"

@Serializable
data class LibrarySummary(
    @SerialName("total_qty") val totalQty: Int = 0,
    @SerialName("unique_printings") val uniquePrintings: Int = 0,
    @SerialName("unique_cards") val uniqueCards: Int = 0,
    @SerialName("value_usd") val valueUsd: Double = 0.0,
    @SerialName("value_eur") val valueEur: Double = 0.0,
    val seq: Long = 0,
)

@Serializable
data class CollectionOp(
    val cardId: String, val finish: String = Finish.Nonfoil.wire, val condition: String = "NM", val lang: String = "en",
    val delta: Int? = null, val qty: Int? = null,
    /** With a delta: added copies go into this binder; removed copies come out of it first. */
    val binderId: String? = null,
) {
    val key get() = itemKey(cardId, finish, condition, lang)
}

/** A batch of adds that failed on the network and waits on the device to be sent again with the same idempotency key
 *  (contract/offline-2026-10-31.md § 3). */
@Serializable
data class OutboxBatch(val key: String, val source: String, val ops: List<CollectionOp>)

@Serializable
data class ApplyResult(
    @SerialName("batch_id") val batchId: String,
    val duplicate: Boolean = false,
    val items: List<Row> = emptyList(),
    val summary: LibrarySummary,
    /** Allocations the batch changed, and wants a trade met or an undo put back (contract/binders-wants-2026-10-17.md). */
    @SerialName("binder_items") val binderItems: List<JsonArray> = emptyList(),
    val wants: List<JsonArray> = emptyList(),
) {
    @Serializable
    data class Row(
        @SerialName("card_id") val cardId: String, val finish: String, val condition: String, val lang: String,
        val qty: Int, val seq: Long,
    )
}

@Serializable
data class HistoryEntry(
    /** timestamptz as Postgres prints it; the screen shows the date part. */
    val at: String,
    val finish: String,
    val condition: String,
    val lang: String,
    val delta: Int,
    @SerialName("qty_after") val qtyAfter: Int,
    val source: String,
    @SerialName("batch_id") val batchId: String,
    val undone: Boolean,
)

@Serializable
private data class ChangesPage(
    val resync: Boolean,
    /** [card_id, finish, condition, lang, qty, seq] */
    val items: List<JsonArray>,
    val next: Long,
    val more: Boolean,
    val summary: LibrarySummary,
)

/** The local mirror for one account: items keyed card_id|finish|condition|lang, plus the cursor and summary. */
private class LibraryDb(userId: String) {
    private val db: SQLiteDatabase = run {
        val dir = File(T1App.instance.filesDir, "library").apply { mkdirs() }
        SQLiteDatabase.openOrCreateDatabase(File(dir, "library-$userId.sqlite"), null).apply {
            execSQL("""CREATE TABLE IF NOT EXISTS items (k TEXT PRIMARY KEY, card_id TEXT NOT NULL, finish TEXT NOT NULL,
                condition TEXT NOT NULL, lang TEXT NOT NULL, qty INTEGER NOT NULL, seq INTEGER NOT NULL)""")
            execSQL("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        }
    }

    fun close() = db.close()

    fun load(): Triple<Map<String, CollectionItem>, Long, LibrarySummary?> {
        val items = db.rawQuery("SELECT card_id, finish, condition, lang, qty, seq FROM items", null).use { c ->
            buildMap { while (c.moveToNext()) CollectionItem(c.getString(0), c.getString(1), c.getString(2), c.getString(3), c.getInt(4), c.getLong(5)).let { put(it.key, it) } }
        }
        val meta = db.rawQuery("SELECT key, value FROM meta", null).use { c ->
            buildMap { while (c.moveToNext()) put(c.getString(0), c.getString(1)) }
        }
        val summary = meta["summary"]?.let { runCatching { T1App.json.decodeFromString<LibrarySummary>(it) }.getOrNull() }
        return Triple(items, meta["cursor"]?.toLongOrNull() ?: 0L, summary)
    }

    /** Upserts, deletes and the cursor move in one transaction, so a crash never splits them. */
    fun commit(put: List<CollectionItem>, delete: List<String>, cursor: Long, summary: LibrarySummary) {
        db.beginTransaction()
        try {
            for (it in put) {
                db.insertWithOnConflict("items", null, ContentValues().apply {
                    put("k", it.key); put("card_id", it.cardId); put("finish", it.finish); put("condition", it.condition)
                    put("lang", it.lang); put("qty", it.qty); put("seq", it.seq)
                }, SQLiteDatabase.CONFLICT_REPLACE)
            }
            for (k in delete) db.delete("items", "k = ?", arrayOf(k))
            setMeta("cursor", cursor.toString())
            setMeta("summary", T1App.json.encodeToString(LibrarySummary.serializer(), summary))
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    private fun setMeta(key: String, value: String) {
        db.insertWithOnConflict("meta", null, ContentValues().apply { put("key", key); put("value", value) }, SQLiteDatabase.CONFLICT_REPLACE)
    }

    fun clear() {
        db.execSQL("DELETE FROM items")
        db.execSQL("DELETE FROM meta")
    }
}

data class CollectionState(
    val userId: String? = null,
    /** True once the local copy or a first sync has something to show. */
    val ready: Boolean = false,
    val syncing: Boolean = false,
    val error: String? = null,
    val items: Map<String, CollectionItem> = emptyMap(),
    val summary: LibrarySummary? = null,
    /** Batches of adds that failed on the network and wait to be sent (contract/offline-2026-10-31.md § 3). */
    val outbox: List<OutboxBatch> = emptyList(),
    /** Bumped on every change so screens can recompute on it. */
    val version: Int = 0,
) {
    /** "3 changes waiting to send" on the Collection home while the outbox isn't empty. */
    val outboxNotice: String?
        get() = when (outbox.size) { 0 -> null; 1 -> "1 change waiting to send"; else -> "${outbox.size} changes waiting to send" }
}

object CollectionStore {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val _state = MutableStateFlow(CollectionState())
    val state: StateFlow<CollectionState> = _state.asStateFlow()

    private var local: LibraryDb? = null
    private var cursor = 0L
    private var syncRun: CompletableDeferred<Unit>? = null
    private var syncAgain = false

    private fun set(f: (CollectionState) -> CollectionState) = _state.update { f(it).copy(version = it.version + 1) }

    /** Opens (or switches to) an account's local copy, then syncs. */
    suspend fun start(userId: String) {
        if (_state.value.userId == userId) return
        stop()
        val db = withContext(Dispatchers.IO) { runCatching { LibraryDb(userId) }.getOrNull() }
        local = db
        val saved = db?.let { withContext(Dispatchers.IO) { runCatching { it.load() }.getOrNull() } }
        cursor = saved?.second ?: 0L
        // Adds made offline: on screen again on top of the mirror, sent with the first sync.
        val outbox = withContext(Dispatchers.IO) { loadOutbox(userId) }
        set {
            CollectionState(userId = userId, items = saved?.first ?: emptyMap(), summary = saved?.third,
                ready = (saved?.first?.isNotEmpty() ?: false) || cursor > 0, outbox = outbox)
        }
        for (b in outbox) showAdds(b.ops, 1)
        sync()
    }

    /** Signed out: forget the in-memory copy (the account's file stays for next time). */
    fun stop() {
        local?.close()
        local = null
        cursor = 0
        set { CollectionState() }
    }

    /* ── outbox (adds that failed on the network; contract/offline-2026-10-31.md § 3) ─────────────────────── */

    private val outboxJson = kotlinx.serialization.json.Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private fun outboxFile(userId: String) = File(File(T1App.instance.filesDir, "library").apply { mkdirs() }, "outbox-$userId.json")
    private fun loadOutbox(userId: String): List<OutboxBatch> =
        runCatching { outboxJson.decodeFromString<List<OutboxBatch>>(outboxFile(userId).readText()) }.getOrDefault(emptyList())

    private fun saveOutbox(outbox: List<OutboxBatch>) {
        val user = _state.value.userId ?: return
        set { it.copy(outbox = outbox) }
        scope.launch(Dispatchers.IO) {
            runCatching { if (outbox.isEmpty()) outboxFile(user).delete() else outboxFile(user).writeText(outboxJson.encodeToString(outbox)) }
        }
    }

    private fun applyParams(ops: List<CollectionOp>, source: String, key: String) = buildJsonObject {
        put("p_ops", buildJsonArray {
            for (op in ops) add(buildJsonObject {
                put("card_id", op.cardId); put("finish", op.finish); put("condition", op.condition); put("lang", op.lang)
                op.delta?.let { put("delta", it) }
                op.qty?.let { put("qty", it) }
                op.binderId?.let { put("binder_id", it) }
            })
        })
        put("p_source", source)
        put("p_source_id", JsonNull)
        put("p_idempotency_key", key)
    }

    /** A result for a batch that waits in the outbox: Undo takes it out again. */
    private fun queuedResult(key: String) = ApplyResult("queued:$key", false, emptyList(),
        _state.value.summary ?: LibrarySummary(0, 0, 0, 0.0, 0.0, 0))

    /** Sends the outbox in order before a sync. A batch the server refuses is taken back; a network failure keeps
     *  the rest for next time. */
    private suspend fun flushOutbox(user: String) {
        var sent = 0
        while (true) {
            val b = _state.value.outbox.firstOrNull() ?: break
            if (_state.value.userId != user) return
            try {
                val res = T1App.supabase.postgrest.rpc("collection_apply", applyParams(b.ops, b.source, b.key)).decodeAs<ApplyResult>()
                if (_state.value.userId != user) return
                saveOutbox(_state.value.outbox.drop(1))
                reflect(res)
                sent++
            } catch (e: Exception) {
                e.rethrowIfCancelled()
                if (Offline.isNetwork(e)) break
                if (_state.value.userId != user) return
                showAdds(b.ops, -1)
                saveOutbox(_state.value.outbox.drop(1))
                set { it.copy(error = "A change made offline was refused: ${e.message}") }
            }
        }
        if (sent > 0) Telemetry.capture("outbox_sent", mapOf("batches" to sent))
    }

    fun syncInBackground() { scope.launch { sync() } }

    /**
     * Pulls every change after the local cursor. A call made while a run is in flight schedules one more run
     * afterwards, so a write that lands mid-sync is always picked up.
     */
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
            return
        }
        // Binders, allocations and wants follow the items (their own cursor, library_changes).
        BindersStore.sync()
    }

    private suspend fun runSync() {
        val user = _state.value.userId ?: return
        set { it.copy(syncing = true, error = null) }
        try {
            flushOutbox(user)
            if (_state.value.userId != user) return
            repeat(200) {
                val page = T1App.supabase.postgrest.rpc("collection_changes", buildJsonObject {
                    put("p_after", cursor)
                    put("p_limit", 5000)
                }).decodeAs<ChangesPage>()
                if (_state.value.userId != user) return
                if (page.resync) {
                    cursor = 0
                    local?.let { withContext(Dispatchers.IO) { it.clear() } }
                    set { it.copy(items = emptyMap()) }
                    for (b in _state.value.outbox) showAdds(b.ops, 1)
                    return@repeat
                }
                // The server hasn't counted adds still in the outbox: rows show its count plus them (the mirror keeps
                // the server's, so the next launch adds them once).
                val queued = Offline.deltas(_state.value.outbox.map { it.ops })
                val items = _state.value.items.toMutableMap()
                val put = mutableListOf<CollectionItem>()
                val del = mutableListOf<String>()
                for (row in page.items) {
                    val it = CollectionItem(row[0].jsonPrimitive.content, row[1].jsonPrimitive.content, row[2].jsonPrimitive.content,
                        row[3].jsonPrimitive.content, row[4].jsonPrimitive.int, row[5].jsonPrimitive.long)
                    val held = items[it.key]
                    if (held != null && held.seq > it.seq) continue // a newer write is already shown
                    if (it.qty > 0) put.add(it) else del.add(it.key)
                    val shown = it.qty + (queued[it.key] ?: 0)
                    if (shown > 0) items[it.key] = it.copy(qty = shown) else items.remove(it.key)
                }
                cursor = page.next
                val next = cursor
                local?.let { withContext(Dispatchers.IO) { it.commit(put, del, next, page.summary) } }
                set { it.copy(items = items, summary = page.summary, ready = true) }
                site.table1.events.widgets.Widgets.noteValue(T1App.instance, page.summary)
                if (!page.more) return
            }
        } catch (e: Exception) {
            e.rethrowIfCancelled()
            if (_state.value.userId == user) set { it.copy(error = e.message ?: "Couldn't sync your collection") }
        } finally {
            set { it.copy(syncing = false) }
        }
    }

    /**
     * One user action = one batch with a fresh idempotency key (reused on the one automatic retry). Added copies
     * show before the server answers ([showAdds]), the answer replaces them, then a delta sync confirms. [key]: a caller that retries a batch itself (an import's
     * chunks) passes the same key each time, so a batch that already landed replays as a duplicate.
     */
    suspend fun apply(ops: List<CollectionOp>, source: String = "manual", key: String? = null): ApplyResult {
        val key = key ?: UUID.randomUUID().toString()
        val params = applyParams(ops, source, key)
        showAdds(ops, 1)
        // Behind batches already waiting: sent after them, in order, so the server sees them as they were made.
        if (_state.value.outbox.isNotEmpty() && Offline.queues(ops, true)) {
            saveOutbox(_state.value.outbox + OutboxBatch(key, source, ops))
            Telemetry.capture("outbox_queued", mapOf("ops" to ops.size))
            syncInBackground()
            return queuedResult(key)
        }
        val res = try {
            retryOnce { T1App.supabase.postgrest.rpc("collection_apply", params).decodeAs<ApplyResult>() }
        } catch (e: Exception) {
            e.rethrowIfCancelled()
            // Adds that couldn't reach the server stay on screen and wait in the outbox (contract/offline-2026-10-31.md § 3).
            if (_state.value.userId != null && Offline.queues(ops, Offline.isNetwork(e))) {
                saveOutbox(_state.value.outbox + OutboxBatch(key, source, ops))
                Telemetry.capture("outbox_queued", mapOf("ops" to ops.size))
                return queuedResult(key)
            }
            showAdds(ops, -1)
            syncInBackground()
            throw e
        }
        // A card added by hand right after a scan was deleted or missed tells which card it was (ScanReports).
        if (source == "manual") ops.firstOrNull { (it.delta ?: 0) > 0 }?.let { ScanReports.addedByHand(it.cardId) }
        reflect(res)
        syncInBackground()
        return res
    }

    suspend fun undo(batchId: String): ApplyResult {
        // A batch still in the outbox: out of the outbox and off the screen, nothing to undo on the server.
        if (batchId.startsWith("queued:")) {
            val key = batchId.removePrefix("queued:")
            _state.value.outbox.firstOrNull { it.key == key }?.let { b ->
                showAdds(b.ops, -1)
                saveOutbox(_state.value.outbox.filter { it.key != key })
            }
            return queuedResult(key)
        }
        val params = buildJsonObject {
            put("p_batch_id", batchId)
            put("p_idempotency_key", UUID.randomUUID().toString())
        }
        val res = retryOnce { T1App.supabase.postgrest.rpc("collection_undo", params).decodeAs<ApplyResult>() }
        reflect(res)
        syncInBackground()
        return res
    }

    suspend fun history(cardId: String): List<HistoryEntry> =
        T1App.supabase.postgrest.rpc("collection_card_history", buildJsonObject {
            put("p_card_id", cardId)
            put("p_limit", 50)
        }).decodeAs()

    /** Network failures only: the same idempotency key makes the retry safe. */
    private suspend fun <T> retryOnce(call: suspend () -> T): T =
        try { call() } catch (e: HttpRequestException) { call() }

    /**
     * A batch's added copies (and the binders they go into), shown while the server works (sign 1) so a scan session's
     * cards are on screen the moment it ends, or taken back when the call fails (-1). Removals wait for the server,
     * which owns the binder rules. Memory only: the answer or a sync replaces these rows.
     */
    private fun showAdds(ops: List<CollectionOp>, sign: Int) {
        if (ops.none { (it.delta ?: 0) > 0 }) return
        var allocs = emptyList<BinderAlloc>()
        set { s -> shiftAdds(s.items, ops, sign).let { (items, a) -> allocs = a; s.copy(items = items) } }
        BindersStore.shift(allocs)
    }

    /** Writes a batch result into memory (not the file or the cursor: the following sync owns those). */
    private fun reflect(res: ApplyResult) {
        if (res.duplicate) return
        set { s ->
            val items = s.items.toMutableMap()
            for (r in res.items) {
                val it = CollectionItem(r.cardId, r.finish, r.condition, r.lang, r.qty, r.seq)
                if (it.qty > 0) items[it.key] = it else items.remove(it.key)
            }
            s.copy(items = items, summary = res.summary)
        }
        site.table1.events.widgets.Widgets.noteValue(T1App.instance, res.summary)
        BindersStore.reflect(res.binderItems, res.wants)
    }
}

/**
 * The items with each op's added copies shifted by [sign], keeping a held item's seq so the sync row that follows is
 * never skipped as older, and the binder copies to shift with them. Cases: testdata/show-adds/cases.json.
 */
fun shiftAdds(held: Map<String, CollectionItem>, ops: List<CollectionOp>, sign: Int): Pair<Map<String, CollectionItem>, List<BinderAlloc>> {
    val items = held.toMutableMap()
    val allocs = mutableListOf<BinderAlloc>()
    for (op in ops) {
        val d = op.delta ?: 0
        if (d <= 0) continue
        val it = items[op.key]
        val qty = (it?.qty ?: 0) + sign * d
        if (qty > 0) items[op.key] = CollectionItem(op.cardId, op.finish, op.condition, op.lang, qty, it?.seq ?: 0)
        else items.remove(op.key)
        op.binderId?.let { allocs.add(BinderAlloc(it, op.cardId, op.finish, op.condition, op.lang, sign * d, 0)) }
    }
    return items to allocs
}
