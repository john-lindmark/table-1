package site.table1.events.library

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
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
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

data class ListEntry(val cardId: String, val board: String, val qty: Int)
data class ListVersion(val number: Int, val at: Double, val note: String, val entries: List<ListEntry>)
data class ListChange(val cardId: String, val board: String, val delta: Int)

data class CardList(val id: String, val kind: ListKind, val name: String, val format: String, val versions: List<ListVersion>) {
    val current get() = versions.last()
    val entries get() = current.entries
    fun count(board: String) = entries.filter { it.board == board }.sumOf { it.qty }
    val boards get() = BOARD_ORDER.filter { b -> entries.any { it.board == b } }
    val sections get() = if (kind == ListKind.Deck) listOf("main", "side", "maybe") else listOf("main", "maybe")

    fun boardTitle(board: String) = when (board) {
        "commander" -> "Commander"
        "main" -> if (kind == ListKind.Deck) "Main deck" else "Main"
        "side" -> "Sideboard"
        "maybe" -> "Considering"
        else -> board
    }

    /** Copies still needed: covered only by the printing a line names; Considering never counts. */
    fun missing(owned: Map<String, Int>): Int =
        entries.filter { it.board != "maybe" }.groupBy { it.cardId }
            .entries.sumOf { (id, es) -> maxOf(0, es.sumOf { it.qty } - (owned[id] ?: 0)) }

    companion object {
        val BOARD_ORDER = listOf("commander", "main", "side", "maybe")

        /** What changed from `older` (null = nothing) to `newer`, per card and section; removals first. */
        fun diff(older: ListVersion?, newer: ListVersion): List<ListChange> {
            val q = HashMap<String, Int>()
            older?.entries?.forEach { q.merge("${it.board}|${it.cardId}", -it.qty, Int::plus) }
            newer.entries.forEach { q.merge("${it.board}|${it.cardId}", it.qty, Int::plus) }
            return q.filterValues { it != 0 }.map { (k, d) -> k.split("|", limit = 2).let { ListChange(it[1], it[0], d) } }
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
) {
    @Serializable
    data class VersionWire(val version: Int, val note: String, val at: Double, val entries: List<JsonArray>)

    fun toList(): CardList? {
        if (deleted || kind == null || name == null || versions.isEmpty()) return null
        return CardList(id, if (kind == "cube") ListKind.Cube else ListKind.Deck, name, format ?: "", versions.map { v ->
            ListVersion(v.version, v.at, v.note, v.entries.map {
                ListEntry(it[0].jsonPrimitive.content, it[1].jsonPrimitive.content, it[2].jsonPrimitive.int)
            })
        })
    }

    companion object {
        fun of(l: CardList) = ListWire(l.id, false, l.kind.wire, l.name, l.format, l.versions.map { v ->
            VersionWire(v.number, v.note, v.at, v.entries.map { e ->
                buildJsonArray { add(kotlinx.serialization.json.JsonPrimitive(e.cardId)); add(kotlinx.serialization.json.JsonPrimitive(e.board)); add(kotlinx.serialization.json.JsonPrimitive(e.qty)) }
            })
        })
    }
}

@Serializable
private data class ListsPage(val lists: List<ListWire>, val next: Long, val more: Boolean)

@Serializable
private data class ListsCache(val cursor: Long, val lists: List<ListWire>)

data class ListsState(val userId: String? = null, val lists: List<CardList> = emptyList(), val ready: Boolean = false, val error: String? = null)

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
            _state.value = _state.value.copy(ready = true)
        }
        sync()
    }

    fun stop() {
        cursor = 0
        _state.value = ListsState()
    }

    private suspend fun saveCache() {
        val user = _state.value.userId ?: return
        val c = ListsCache(cursor, _state.value.lists.map { ListWire.of(it) })
        withContext(Dispatchers.IO) { runCatching { cacheFile(user).writeText(json.encodeToString(c)) } }
    }

    fun syncInBackground() { scope.launch { sync() } }

    /** Pulls every list changed after the local cursor; a call during a run schedules one more run. */
    suspend fun sync() {
        val user = _state.value.userId ?: return
        syncRun?.let { syncAgain = true; it.await(); return }
        val run = CompletableDeferred<Unit>()
        syncRun = run
        try {
            repeat(50) {
                val page = T1App.supabase.postgrest.rpc("lists_changes", buildJsonObject {
                    put("p_after", cursor); put("p_limit", 100)
                }).decodeAs<ListsPage>()
                if (_state.value.userId != user) return
                val byId = _state.value.lists.associateBy { it.id }.toMutableMap()
                for (w in page.lists) { val l = w.toList(); if (l != null) byId[l.id] = l else byId.remove(w.id) }
                cursor = page.next
                setLists(byId.values.toList())
                _state.value = _state.value.copy(ready = true, error = null)
                saveCache()
                if (!page.more) return@repeat
            }
        } catch (e: Exception) {
            if (_state.value.userId == user) _state.value = _state.value.copy(error = e.message ?: "Couldn't sync your decks and cubes")
        } finally {
            syncRun = null
            run.complete(Unit)
        }
        if (syncAgain) { syncAgain = false; sync() }
    }

    private suspend fun call(fn: String, params: JsonObject) {
        try {
            val w = T1App.supabase.postgrest.rpc(fn, params).decodeAs<ListWire>()
            val rest = _state.value.lists.filter { it.id != w.id }
            setLists(w.toList()?.let { rest + it } ?: rest)
            _state.value = _state.value.copy(error = null)
            saveCache()
        } catch (e: Exception) {
            _state.value = _state.value.copy(error = e.message ?: "Couldn't save that change")
            sync()
            throw e
        }
    }

    suspend fun create(kind: ListKind, name: String, format: String): String {
        val id = UUID.randomUUID().toString()
        call("list_create", buildJsonObject {
            put("p_id", id); put("p_kind", kind.wire); put("p_name", name); put("p_format", format)
            put("p_entries", buildJsonArray {}); put("p_note", "Created")
        })
        return id
    }

    suspend fun add(listId: String, cardId: String, board: String, delta: Int) =
        edit(listId, buildJsonObject { put("card_id", cardId); put("board", board); put("delta", delta) })

    suspend fun move(listId: String, cardId: String, from: String, to: String) =
        edit(listId, buildJsonObject { put("card_id", cardId); put("from", from); put("to", to) })

    suspend fun remove(listId: String, cardId: String, board: String) =
        edit(listId, buildJsonObject { put("card_id", cardId); put("board", board); put("qty", 0) })

    private suspend fun edit(listId: String, op: JsonObject) =
        call("list_edit", buildJsonObject { put("p_list_id", listId); put("p_ops", buildJsonArray { add(op) }) })

    suspend fun restore(listId: String, version: Int) =
        call("list_restore", buildJsonObject { put("p_list_id", listId); put("p_version", version) })

    suspend fun delete(listId: String) {
        T1App.supabase.postgrest.rpc("list_delete", buildJsonObject { put("p_list_id", listId) })
        setLists(_state.value.lists.filter { it.id != listId })
        saveCache()
    }
}
