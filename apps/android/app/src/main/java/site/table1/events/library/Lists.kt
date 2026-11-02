package site.table1.events.library

import site.table1.events.util.Offline
import site.table1.events.util.rethrowIfCancelled

import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import site.table1.events.T1App
import java.io.File
import java.util.UUID

// Decks and cubes (contract/lists-2026-10-15.md). The database is the source of truth: lists sync by seq with
// lists_changes and every change goes through a list_* RPC, whose answer (the list with all its versions)
// replaces the local copy. A per-account JSON file makes them show instantly and offline.

enum class ListKind(val wire: String) { Deck("deck"), Cube("cube") }

/**
 * A line is printing × section × finish × language × condition, so 2 foil and 2 non-foil copies of a card are two
 * lines. A non-English printing is always its own language (contract/lists-2026-10-15.md, "Languages"); the condition
 * is NM unless the copies came from the collection ("Conditions").
 */
data class ListEntry(val cardId: String, val board: String, val qty: Int, val finish: String = "nonfoil", val lang: String = "en",
                     val cond: String = "NM") {
    fun isLine(cardId: String, board: String, finish: String, lang: String, cond: String) =
        this.cardId == cardId && this.board == board && this.finish == finish && this.lang == lang && this.cond == cond
}
data class ListVersion(val number: Int, val at: Double, val note: String, val entries: List<ListEntry>)
data class ListChange(val cardId: String, val board: String, val delta: Int, val finish: String = "nonfoil", val lang: String = "en",
                      val cond: String = "NM")

/** Key into the owned map: "card_id|finish". */
fun ownKey(cardId: String, finish: String) = "$cardId|$finish"

/** One line (or grid/stack card) reads short when you own fewer copies than it lists: never for Considering, never for a
 *  basic land (contract/basics-2026-10-24.md). */
fun isShort(board: String, qty: Int, owned: Int, basic: Boolean) = board != "maybe" && !basic && owned < qty

/** [seq] is the server's (null for a list it hasn't sent), [sourceUrl] the link it syncs from (a Cube Cobra cube,
 *  contract/cube-sync-2026-10-30.md). */
data class CardList(val id: String, val kind: ListKind, val name: String, val format: String, val versions: List<ListVersion>,
                    val seq: Long? = null, val sourceUrl: String? = null) {
    val current get() = versions.last()
    val entries get() = current.entries
    fun count(board: String) = entries.filter { it.board == board }.sumOf { it.qty }
    val boards get() = BOARD_ORDER.filter { b -> entries.any { it.board == b } }
    val sections get() = if (kind == ListKind.Deck) listOf("main", "side", "maybe") else listOf("main", "maybe")

    fun boardTitle(board: String) = when (board) {
        "commander" -> if (format == "oathbreaker") "Command zone" else "Commander"
        "main" -> if (kind == ListKind.Deck) "Main deck" else "Main"
        "side" -> "Sideboard"
        "maybe" -> "Considering"
        else -> board
    }

    /**
     * Copies still needed: any printing of a card covers its lines (contract/owned-by-card-2026-10-31.md); Considering
     * and basic lands ([basics], contract/basics-2026-10-24.md) never count.
     */
    fun missing(h: Holdings, basics: Set<String>): Int = OwnedByCard.shorts(OwnedByCard.needs(this), h, basics).sum()

    companion object {
        val BOARD_ORDER = listOf("commander", "main", "side", "maybe")

        /** What changed from `older` (null = nothing) to `newer`, per card and section; removals first. */
        fun diff(older: ListVersion?, newer: ListVersion): List<ListChange> {
            val q = HashMap<String, Int>()
            older?.entries?.forEach { q.merge("${it.board}|${it.cardId}|${it.finish}|${it.lang}|${it.cond}", -it.qty, Int::plus) }
            newer.entries.forEach { q.merge("${it.board}|${it.cardId}|${it.finish}|${it.lang}|${it.cond}", it.qty, Int::plus) }
            return q.filterValues { it != 0 }.map { (k, d) -> k.split("|", limit = 5).let { ListChange(it[1], it[0], d, it[2], it[3], it[4]) } }
                .sortedWith(compareBy<ListChange>({ BOARD_ORDER.indexOf(it.board) }, { it.delta }))
        }
    }
}

/** A list on the wire: entries are [card_id, board, qty]. */
@Serializable
data class ListWire(
    val id: String,
    val deleted: Boolean = false,
    val kind: String? = null,
    val name: String? = null,
    val format: String? = null,
    val versions: List<VersionWire> = emptyList(),
    val seq: Long? = null,
    @SerialName("source_url") val sourceUrl: String? = null,
) {
    @Serializable
    data class VersionWire(val version: Int, val note: String, val at: Double, val entries: List<JsonArray>)

    fun toList(): CardList? {
        if (deleted || kind == null || name == null || versions.isEmpty()) return null
        return CardList(id, if (kind == "cube") ListKind.Cube else ListKind.Deck, name, format ?: "", versions.map { v ->
            ListVersion(v.version, v.at, v.note, v.entries.map {
                ListEntry(it[0].jsonPrimitive.content, it[1].jsonPrimitive.content, it[2].jsonPrimitive.int,
                    if (it.size > 3) it[3].jsonPrimitive.content else "nonfoil", if (it.size > 4) it[4].jsonPrimitive.content else "en",
                    if (it.size > 5) it[5].jsonPrimitive.content else "NM")
            })
        }, seq, sourceUrl)
    }

    companion object {
        /** [card_id, board, qty] for non-foil English NM; foil and etched add the finish; another language adds the finish
         *  and the language; another condition adds all three. */
        fun entryWire(e: ListEntry) = buildJsonArray {
            add(JsonPrimitive(e.cardId)); add(JsonPrimitive(e.board)); add(JsonPrimitive(e.qty))
            if (e.finish != "nonfoil" || e.lang != "en" || e.cond != "NM") add(JsonPrimitive(e.finish))
            if (e.lang != "en" || e.cond != "NM") add(JsonPrimitive(e.lang))
            if (e.cond != "NM") add(JsonPrimitive(e.cond))
        }

        fun of(l: CardList) = ListWire(l.id, false, l.kind.wire, l.name, l.format, l.versions.map { v ->
            VersionWire(v.number, v.note, v.at, v.entries.map { entryWire(it) })
        }, l.seq, l.sourceUrl)
    }
}

@Serializable
internal data class ListsPage(val lists: List<ListWire>, val next: Long, val more: Boolean)

/**
 * Reads lists_changes pages from [after] until one says there's no more, at most [maxPages] (contract/lists-2026-10-15.md,
 * "Sync"); also stops if a page asks for more without moving the cursor. [apply] takes each page and returns false to
 * stop (the account changed). Returns the number of calls made. (`return@repeat` here once only skipped to the next of
 * 50 pages, so every sync made 50 calls back to back.)
 */
internal suspend fun readListPages(after: Long, maxPages: Int = 50, fetch: suspend (after: Long) -> ListsPage,
                                   apply: suspend (ListsPage) -> Boolean): Int {
    var cursor = after
    var calls = 0
    while (calls < maxPages) {
        val page = fetch(cursor)
        calls++
        if (!apply(page)) break
        if (!page.more || page.next <= cursor) break
        cursor = page.next
    }
    return calls
}

/** A change to a saved list that failed on the network, waiting to be sent (contract/offline-2026-10-31.md § 4). */
@Serializable
data class PendingCall(val fn: String, val params: JsonObject)

@Serializable
private data class ListsCache(val cursor: Long, val lists: List<ListWire>, val unsaved: Map<String, String>? = null, val pending: List<PendingCall>? = null)

/**
 * [unsaved]: lists made on this device that the server hasn't saved yet, with why the last try failed ("" = not tried
 * yet, or offline); each sync sends them again until the server has them. [pending]: changes to saved lists that
 * failed on the network, in order; sent before the next pull. The lists already show both.
 */
data class ListsState(val userId: String? = null, val lists: List<CardList> = emptyList(), val ready: Boolean = false, val error: String? = null,
                      val unsaved: Map<String, String> = emptyMap(), val pending: List<PendingCall> = emptyList())

/** What a list's screen says while the server doesn't have it. */
fun unsavedNotice(l: CardList, why: String): String {
    val kind = if (l.kind == ListKind.Cube) "cube" else "deck"
    return if (why.isEmpty()) "Saving this $kind to your account…"
    else "This $kind isn't saved to your account yet: $why It's sent again each time Table 1 syncs."
}

/** The ops of a list_edit applied to a version's entries the way the server applies them (a change queued offline). */
fun applyListOps(entries: List<ListEntry>, ops: List<JsonObject>): List<ListEntry> {
    val out = entries.toMutableList()
    fun str(o: JsonObject, k: String) = o[k]?.jsonPrimitive?.content
    fun find(cardId: String, board: String, finish: String, lang: String, cond: String) = out.indexOfFirst { it.isLine(cardId, board, finish, lang, cond) }
    fun put(cardId: String, board: String, finish: String, lang: String, cond: String, q: Int) {
        val j = find(cardId, board, finish, lang, cond)
        if (j >= 0) out[j] = out[j].copy(qty = out[j].qty + q) else out.add(ListEntry(cardId, board, q, finish, lang, cond))
    }
    for (op in ops) {
        val cardId = str(op, "card_id") ?: continue
        val fin = str(op, "finish") ?: "nonfoil"
        val lang = str(op, "lang") ?: "en"
        val cond = str(op, "cond") ?: "NM"
        val from = str(op, "from")
        if (from != null) {
            val to = str(op, "to") ?: continue
            val i = find(cardId, from, fin, lang, cond)
            if (i < 0) continue
            val moved = out.removeAt(i)
            put(cardId, to, fin, lang, cond, moved.qty)
            continue
        }
        val board = str(op, "board") ?: continue
        if (op.containsKey("to_card_id") || op.containsKey("to_finish") || op.containsKey("to_lang") || op.containsKey("to_cond")) {
            val i = find(cardId, board, fin, lang, cond)
            if (i < 0) continue
            val have = out[i].qty
            val n = minOf(have, op["qty"]?.jsonPrimitive?.int ?: have)
            if (have - n > 0) out[i] = out[i].copy(qty = have - n) else out.removeAt(i)
            put(str(op, "to_card_id") ?: cardId, board, str(op, "to_finish") ?: fin, str(op, "to_lang") ?: lang, str(op, "to_cond") ?: cond, n)
            continue
        }
        val i = find(cardId, board, fin, lang, cond)
        val q = op["qty"]?.jsonPrimitive?.int ?: ((if (i >= 0) out[i].qty else 0) + (op["delta"]?.jsonPrimitive?.int ?: 0))
        if (i >= 0 && q > 0) out[i] = out[i].copy(qty = q)
        else if (i >= 0) out.removeAt(i)
        else if (q > 0) put(cardId, board, fin, lang, cond, q)
    }
    return out
}

/** A name as the server keeps it (list_update): trimmed, at most 60 characters. Blank means "keep the old one". */
fun listName(raw: String): String = raw.trim().take(60)

object ListsStore {
    private val _state = MutableStateFlow(ListsState())
    val state: StateFlow<ListsState> = _state.asStateFlow()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val json = Json { ignoreUnknownKeys = true }
    private var cursor = 0L
    private var syncRun: CompletableDeferred<Unit>? = null
    private var syncAgain = false

    fun list(id: String) = _state.value.lists.firstOrNull { it.id == id }

    private fun cacheFile(userId: String) = File(T1App.instance.filesDir, "library/lists-$userId.json").apply { parentFile?.mkdirs() }

    private fun setLists(lists: List<CardList>) {
        _state.value = _state.value.copy(lists = lists.sortedBy { it.name.lowercase() })
    }

    suspend fun start(userId: String) {
        if (_state.value.userId == userId) return sync()
        cursor = 0
        _state.value = ListsState(userId = userId)
        val cached = withContext(Dispatchers.IO) {
            runCatching { json.decodeFromString<ListsCache>(cacheFile(userId).readText()) }.getOrNull()
        }
        if (cached != null && _state.value.userId == userId) {
            cursor = cached.cursor
            setLists(cached.lists.mapNotNull { it.toList() })
            _state.value = _state.value.copy(ready = true, unsaved = cached.unsaved ?: emptyMap(), pending = cached.pending ?: emptyList())
        }
        sync()
    }

    fun stop() {
        cursor = 0
        _state.value = ListsState()
    }

    private suspend fun saveCache() {
        val user = _state.value.userId ?: return
        val c = ListsCache(cursor, _state.value.lists.map { ListWire.of(it) }, _state.value.unsaved, _state.value.pending)
        withContext(Dispatchers.IO) { runCatching { cacheFile(user).writeText(json.encodeToString(c)) } }
    }

    fun syncInBackground() { scope.launch { sync() } }

    /** Sends the queued changes in order. False when the network stopped it: the pull is skipped so the server's copy
     *  doesn't hide what's still to send. A change the server refuses is dropped; the pull then sets things right. */
    private suspend fun flushPending(user: String): Boolean {
        while (true) {
            val p = _state.value.pending.firstOrNull() ?: return true
            if (_state.value.userId != user) return false
            try {
                val w = T1App.supabase.postgrest.rpc(p.fn, p.params).decodeAs<ListWire>()
                if (_state.value.userId != user) return false
                _state.value = _state.value.copy(pending = _state.value.pending.drop(1))
                mergeWire(w)
                saveCache()
            } catch (e: Exception) {
                e.rethrowIfCancelled()
                if (Offline.isNetwork(e)) return false
                if (_state.value.userId != user) return false
                _state.value = _state.value.copy(pending = _state.value.pending.drop(1), error = "A change made offline was refused: ${e.message}")
                saveCache()
            }
        }
    }

    private fun mergeWire(w: ListWire) {
        val rest = _state.value.lists.filter { it.id != w.id }
        setLists(w.toList()?.let { rest + it } ?: rest)
    }

    /** Sends a list the server doesn't have yet with what this device holds now; list_create returns the list it
     *  already has for a retried id. A failure is kept on the list, and the next sync tries again. */
    private val saving = HashMap<String, CompletableDeferred<Unit>>()
    private suspend fun saveUnsaved(id: String) {
        saving[id]?.let { it.await(); return }
        val user = _state.value.userId
        val l = list(id)
        if (user == null || l == null) { dropUnsaved(id); return }
        val run = CompletableDeferred<Unit>()
        saving[id] = run
        try {
            val w = T1App.supabase.postgrest.rpc("list_create", buildJsonObject {
                put("p_id", l.id); put("p_kind", l.kind.wire); put("p_name", l.name); put("p_format", l.format)
                put("p_entries", buildJsonArray { l.entries.forEach { add(ListWire.entryWire(it)) } })
                put("p_note", l.versions.firstOrNull()?.note ?: "Created")
            }).decodeAs<ListWire>()
            if (_state.value.userId != user) return
            dropUnsaved(id)
            mergeWire(w)
            saveCache()
            // The Cube Cobra link set while the list was on its way (an import).
            if (l.sourceUrl != null && w.sourceUrl == null) runCatching { call("list_source_set", buildJsonObject { put("p_list_id", id); put("p_source_url", l.sourceUrl) }) }
        } catch (e: Exception) {
            e.rethrowIfCancelled()
            if (_state.value.userId == user) {
                _state.value = _state.value.copy(unsaved = _state.value.unsaved + (id to (e.message ?: "")))
                saveCache()
            }
        } finally {
            saving.remove(id)
            run.complete(Unit)
        }
    }

    private fun dropUnsaved(id: String) {
        if (id !in _state.value.unsaved) return
        _state.value = _state.value.copy(unsaved = _state.value.unsaved - id)
    }

    /** Pulls every list changed after the local cursor; a call during a run schedules one more run. */
    suspend fun sync() {
        val user = _state.value.userId ?: return
        syncRun?.let { syncAgain = true; it.await(); return }
        val run = CompletableDeferred<Unit>()
        syncRun = run
        try {
            if (!flushPending(user)) return
            val seen = HashSet<String>()
            readListPages(cursor, fetch = { after ->
                T1App.supabase.postgrest.rpc("lists_changes", buildJsonObject {
                    put("p_after", after); put("p_limit", 100)
                }).decodeAs<ListsPage>()
            }) { page ->
                if (_state.value.userId != user) return@readListPages false
                val byId = _state.value.lists.associateBy { it.id }.toMutableMap()
                for (w in page.lists) { seen.add(w.id); val l = w.toList(); if (l != null) byId[l.id] = l else byId.remove(w.id) }
                cursor = page.next
                setLists(byId.values.toList())
                _state.value = _state.value.copy(ready = true, error = null)
                saveCache()
                true
            }
            // Lists the server sent are saved; the rest are sent again.
            if (_state.value.userId == user) {
                _state.value = _state.value.copy(unsaved = _state.value.unsaved.filterKeys { it !in seen })
                for (id in _state.value.unsaved.keys.sorted()) saveUnsaved(id)
            }
        } catch (e: Exception) {
            e.rethrowIfCancelled()
            if (_state.value.userId == user) _state.value = _state.value.copy(error = e.message ?: "Couldn't sync your decks and cubes")
        } finally {
            syncRun = null
            run.complete(Unit)
        }
        if (syncAgain) { syncAgain = false; sync() }
    }

    /** A change that couldn't reach the server: applied here, queued in order, sent before the next pull. */
    private suspend fun queue(fn: String, params: JsonObject, local: () -> Unit) {
        local()
        _state.value = _state.value.copy(pending = _state.value.pending + PendingCall(fn, params))
        site.table1.events.util.Telemetry.capture("list_change_queued")
        saveCache()
    }

    /**
     * Sends one change and replaces the local list with the server's version (the source of truth: it groups edits
     * into versions). On a network failure the change is applied here ([local]) and queued (contract/offline-2026-10-31.md
     * § 4); on any other failure the local copy is re-synced. A change to a list the server doesn't have yet waits
     * for the create, which carries the current cards.
     */
    private suspend fun call(fn: String, params: JsonObject, local: (() -> Unit)? = null) {
        val id = params["p_list_id"]?.jsonPrimitive?.content
        if (id != null && id in _state.value.unsaved) {
            local?.invoke()
            saveCache()
            scope.launch { saveUnsaved(id) }
            return
        }
        if (_state.value.pending.isNotEmpty() && local != null) return queue(fn, params, local)
        try {
            val w = T1App.supabase.postgrest.rpc(fn, params).decodeAs<ListWire>()
            mergeWire(w)
            _state.value = _state.value.copy(error = null)
            saveCache()
        } catch (e: Exception) {
            e.rethrowIfCancelled()
            if (local != null && Offline.isNetwork(e)) return queue(fn, params, local)
            _state.value = _state.value.copy(error = e.message ?: "Couldn't save that change")
            sync()
            throw e
        }
    }

    /** The version an editing session is filling: edits within 10 minutes of each other share one version, as on the
     *  server (for a change applied here while offline). */
    private val openEdit = HashMap<String, Pair<Int, Double>>()

    private fun localEdit(id: String, note: String = "Edited", change: (List<ListEntry>) -> List<ListEntry>) {
        val l = list(id) ?: return
        val cur = l.current
        val entries = change(cur.entries)
        val now = System.currentTimeMillis() / 1000.0
        val open = openEdit[id]
        val versions = if (note == "Edited" && open != null && open.first == cur.number && now - open.second < 600)
            l.versions.dropLast(1) + cur.copy(at = now, entries = entries)
        else l.versions + ListVersion((l.versions.maxOfOrNull { it.number } ?: 0) + 1, now, note, entries)
        openEdit[id] = if (note == "Edited") versions.last().number to now else -1 to 0.0
        setLists(_state.value.lists.filter { it.id != id } + l.copy(versions = versions))
    }

    /** A new list, optionally starting with cards. `from` is for telemetry only: new / duplicate / import / finder /
     *  profile (a copy of a shared deck or cube). Made here and saved by the next sync when the server can't be reached. */
    suspend fun create(kind: ListKind, name: String, format: String, entries: List<ListEntry> = emptyList(), note: String = "Created",
                       from: String = "new"): String {
        val id = UUID.randomUUID().toString()
        try {
            val w = T1App.supabase.postgrest.rpc("list_create", buildJsonObject {
                put("p_id", id); put("p_kind", kind.wire); put("p_name", name); put("p_format", format)
                put("p_entries", buildJsonArray {
                    entries.forEach { e -> add(ListWire.entryWire(e)) }
                })
                put("p_note", note)
            }).decodeAs<ListWire>()
            mergeWire(w)
            _state.value = _state.value.copy(error = null)
            saveCache()
        } catch (e: Exception) {
            e.rethrowIfCancelled()
            if (!Offline.isNetwork(e) || _state.value.userId == null) {
                _state.value = _state.value.copy(error = e.message ?: "Couldn't save that change")
                sync()
                throw e
            }
            val l = CardList(id, kind, name, format, listOf(ListVersion(1, System.currentTimeMillis() / 1000.0, note, entries)))
            setLists(_state.value.lists + l)
            _state.value = _state.value.copy(unsaved = _state.value.unsaved + (id to ""))
            saveCache()
            site.table1.events.util.Telemetry.capture("list_change_queued")
        }
        site.table1.events.util.Telemetry.capture("list_created", mapOf("kind" to kind.wire, "format" to format, "from" to from))
        return id
    }

    /** Changes the list's format; the cards stay as they are. */
    suspend fun setFormat(listId: String, format: String) {
        val l = list(listId) ?: return
        if (l.format == format) return
        call("list_update", buildJsonObject { put("p_list_id", listId); put("p_format", format) }) {
            list(listId)?.let { now -> setLists(_state.value.lists.filter { it.id != listId } + now.copy(format = format)) }
        }
        site.table1.events.util.Telemetry.capture("list_format_changed", mapOf("kind" to l.kind.wire, "from" to l.format, "to" to format))
    }

    /** Renames the list; a blank name is ignored. */
    suspend fun rename(listId: String, raw: String) {
        val name = listName(raw)
        val l = list(listId) ?: return
        if (name.isEmpty() || l.name == name) return
        call("list_update", buildJsonObject { put("p_list_id", listId); put("p_name", name) }) {
            list(listId)?.let { now -> setLists(_state.value.lists.filter { it.id != listId } + now.copy(name = name)) }
        }
        site.table1.events.util.Telemetry.capture("list_renamed", mapOf("kind" to l.kind.wire))
    }

    /** Remembers the Cube Cobra link a cube was imported from, so syncing needs no link. */
    suspend fun setSource(listId: String, url: String) {
        if (list(listId)?.sourceUrl == url) return
        call("list_source_set", buildJsonObject { put("p_list_id", listId); put("p_source_url", url) }) {
            list(listId)?.let { now -> setLists(_state.value.lists.filter { it.id != listId } + now.copy(sourceUrl = url)) }
        }
    }

    /** Saves a cube synced with Cube Cobra as one new version (contract/cube-sync-2026-10-30.md). A list that changed
     *  since [seq] is refused ([isSyncConflict]); the store syncs either way on failure. */
    suspend fun syncList(listId: String, seq: Long?, entries: List<ListEntry>, sourceUrl: String) {
        try {
            val w = T1App.supabase.postgrest.rpc("list_sync", buildJsonObject {
                put("p_list_id", listId); put("p_seq", seq ?: -1L); put("p_source_url", sourceUrl)
                put("p_entries", buildJsonArray { entries.forEach { add(ListWire.entryWire(it)) } })
            }).decodeAs<ListWire>()
            val rest = _state.value.lists.filter { it.id != w.id }
            setLists(w.toList()?.let { rest + it } ?: rest)
            _state.value = _state.value.copy(error = null)
            saveCache()
        } catch (e: Exception) {
            e.rethrowIfCancelled()
            sync()
            throw e
        }
    }

    fun isSyncConflict(e: Throwable) = e.message?.let { "PT409" in it || "changed since you checked" in it } == true

    /** A new list with the current version's cards; its history starts fresh and names where it came from. */
    suspend fun duplicate(listId: String): String? {
        val l = list(listId) ?: return null
        return create(l.kind, "${l.name} (copy)".take(60), l.format, l.entries, "Duplicated from ${l.name} v${l.current.number}", "duplicate")
    }

    suspend fun add(listId: String, cardId: String, board: String, delta: Int, finish: String = "nonfoil", lang: String = "en", cond: String = "NM") =
        edit(listId, buildJsonObject {
            put("card_id", cardId); put("board", board); put("finish", finish); put("lang", lang); put("cond", cond); put("delta", delta)
        })

    suspend fun move(listId: String, cardId: String, from: String, to: String, finish: String = "nonfoil", lang: String = "en", cond: String = "NM") =
        edit(listId, buildJsonObject { put("card_id", cardId); put("finish", finish); put("lang", lang); put("cond", cond); put("from", from); put("to", to) })

    suspend fun remove(listId: String, cardId: String, board: String, finish: String = "nonfoil", lang: String = "en", cond: String = "NM") =
        edit(listId, buildJsonObject { put("card_id", cardId); put("board", board); put("finish", finish); put("lang", lang); put("cond", cond); put("qty", 0) })

    /**
     * Moves [qty] copies (null = all) of a line to another printing, finish and/or language in the same section: change
     * a printing, split 4 non-foil into 2 non-foil and 2 foil, or call 2 of them Japanese. [toLang] null keeps the line's
     * language, [toCond] null its condition.
     */
    suspend fun swap(listId: String, cardId: String, board: String, finish: String, toCardId: String, toFinish: String, qty: Int?,
                     lang: String = "en", toLang: String? = null, cond: String = "NM", toCond: String? = null) =
        edit(listId, buildJsonObject {
            put("card_id", cardId); put("board", board); put("finish", finish); put("lang", lang); put("cond", cond)
            put("to_card_id", toCardId); put("to_finish", toFinish); put("to_lang", toLang ?: lang); put("to_cond", toCond ?: cond)
            if (qty != null) put("qty", qty)
        })

    /** Several cards into one section as one edit (a scan session): one request, one step in the history. [cards]: one entry
     *  per scanned copy (qty 1), in the condition picked in the scanner (contract/lists-2026-10-15.md § Conditions). */
    suspend fun addMany(listId: String, board: String, cards: List<ListEntry>) {
        if (cards.isEmpty()) return
        call("list_edit", buildJsonObject {
            put("p_list_id", listId)
            put("p_ops", buildJsonArray {
                cards.forEach { c ->
                    add(buildJsonObject {
                        put("card_id", c.cardId); put("board", board); put("finish", c.finish); put("lang", c.lang); put("cond", c.cond); put("delta", 1)
                    })
                }
            })
        })
    }

    /** Several ops as one edit (card detail's changes and their Undo): one request, one step in the history. */
    suspend fun editMany(listId: String, ops: List<JsonObject>) {
        if (ops.isEmpty()) return
        call("list_edit", buildJsonObject { put("p_list_id", listId); put("p_ops", buildJsonArray { ops.forEach { add(it) } }) }) {
            localEdit(listId) { applyListOps(it, ops) }
        }
    }

    private suspend fun edit(listId: String, op: JsonObject) = editMany(listId, listOf(op))

    suspend fun restore(listId: String, version: Int) =
        call("list_restore", buildJsonObject { put("p_list_id", listId); put("p_version", version) }) {
            list(listId)?.versions?.firstOrNull { it.number == version }?.let { v -> localEdit(listId, "Restored v$version") { v.entries } }
        }

    suspend fun delete(listId: String) {
        if (listId in _state.value.unsaved) {
            // Never reached the server: forgotten here.
            dropUnsaved(listId)
            setLists(_state.value.lists.filter { it.id != listId })
            saveCache()
            return
        }
        try {
            T1App.supabase.postgrest.rpc("list_delete", buildJsonObject { put("p_list_id", listId) })
        } catch (e: Exception) {
            e.rethrowIfCancelled()
            if (!Offline.isNetwork(e)) throw e
            queue("list_delete", buildJsonObject { put("p_list_id", listId) }) { setLists(_state.value.lists.filter { it.id != listId }) }
            return
        }
        setLists(_state.value.lists.filter { it.id != listId })
        saveCache()
    }
}
