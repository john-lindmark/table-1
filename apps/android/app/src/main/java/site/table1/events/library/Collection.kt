package site.table1.events.library

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

data class CollectionOp(
    val cardId: String, val finish: String = Finish.Nonfoil.wire, val condition: String = "NM", val lang: String = "en",
    val delta: Int? = null, val qty: Int? = null,
)

@Serializable
data class ApplyResult(
    @SerialName("batch_id") val batchId: String,
    val duplicate: Boolean = false,
    val items: List<Row> = emptyList(),
    val summary: LibrarySummary,
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
    /** Bumped on every change so screens can recompute on it. */
    val version: Int = 0,
)

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
        set {
            CollectionState(userId = userId, items = saved?.first ?: emptyMap(), summary = saved?.third,
                ready = (saved?.first?.isNotEmpty() ?: false) || cursor > 0)
        }
        sync()
    }

    /** Signed out: forget the in-memory copy (the account's file stays for next time). */
    fun stop() {
        local?.close()
        local = null
        cursor = 0
        set { CollectionState() }
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
        }
    }

    private suspend fun runSync() {
        val user = _state.value.userId ?: return
        set { it.copy(syncing = true, error = null) }
        try {
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
                    return@repeat
                }
                val items = _state.value.items.toMutableMap()
                val put = mutableListOf<CollectionItem>()
                val del = mutableListOf<String>()
                for (row in page.items) {
                    val it = CollectionItem(row[0].jsonPrimitive.content, row[1].jsonPrimitive.content, row[2].jsonPrimitive.content,
                        row[3].jsonPrimitive.content, row[4].jsonPrimitive.int, row[5].jsonPrimitive.long)
                    val held = items[it.key]
                    if (held != null && held.seq > it.seq) continue // a newer write is already shown
                    if (it.qty > 0) { items[it.key] = it; put.add(it) } else { items.remove(it.key); del.add(it.key) }
                }
                cursor = page.next
                val next = cursor
                local?.let { withContext(Dispatchers.IO) { it.commit(put, del, next, page.summary) } }
                set { it.copy(items = items, summary = page.summary, ready = true) }
                if (!page.more) return
            }
        } catch (e: Exception) {
            if (_state.value.userId == user) set { it.copy(error = e.message ?: "Couldn't sync your collection") }
        } finally {
            set { it.copy(syncing = false) }
        }
    }

    /**
     * One user action = one batch with a fresh idempotency key (reused on the one automatic retry). Shows the
     * result at once, then confirms with a delta sync.
     */
    suspend fun apply(ops: List<CollectionOp>, source: String = "manual"): ApplyResult {
        val params = buildJsonObject {
            put("p_ops", buildJsonArray {
                for (op in ops) add(buildJsonObject {
                    put("card_id", op.cardId); put("finish", op.finish); put("condition", op.condition); put("lang", op.lang)
                    op.delta?.let { put("delta", it) }
                    op.qty?.let { put("qty", it) }
                })
            })
            put("p_source", source)
            put("p_source_id", JsonNull)
            put("p_idempotency_key", UUID.randomUUID().toString())
        }
        val res = retryOnce { T1App.supabase.postgrest.rpc("collection_apply", params).decodeAs<ApplyResult>() }
        reflect(res)
        syncInBackground()
        return res
    }

    suspend fun undo(batchId: String): ApplyResult {
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
    }
}

