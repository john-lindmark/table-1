package site.table1.events.library

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import site.table1.events.T1App
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry

// Hero cards (contract/library-heroes-2026-10-19.md): the few cards that stand for a deck, a cube, a binder or the
// whole collection. Picked by card (oracle id), so changing a printing keeps the hero; the art shown is the printing
// the list or binder holds. Fetched with library_heroes when the Library starts and on each return to the app,
// cached per account; a toggle shows at once and library_heroes_set's answer replaces it (on failure, refetch).

sealed interface HeroScope {
    data object Collection : HeroScope
    data class InList(val id: String) : HeroScope
    data class InBinder(val id: String) : HeroScope

    /** Key in the store and the cache. */
    val key: String get() = when (this) {
        Collection -> "collection"
        is InList -> "list:${id.lowercase()}"
        is InBinder -> "binder:${id.lowercase()}"
    }

    val wire: String get() = when (this) { Collection -> "collection"; is InList -> "list"; is InBinder -> "binder" }
    val targetId: String? get() = when (this) { Collection -> null; is InList -> id; is InBinder -> id }

    companion object {
        /** From a card detail's context: a deck/cube, a binder (not Unsorted), or the collection. */
        fun of(context: CardContext?): HeroScope? = when (context) {
            is CardContext.InList -> InList(context.listId)
            is CardContext.InBinder -> if (context.binderId == UNSORTED) null else InBinder(context.binderId)
            null -> Collection
        }
    }
}

data class HeroesState(val userId: String? = null, val heroes: Map<String, List<String>> = emptyMap(), val error: String? = null) {
    fun heroes(scope: HeroScope): List<String> = heroes[scope.key] ?: emptyList()
    fun isHero(oracleId: String?, scope: HeroScope): Boolean = oracleId != null && oracleId.lowercase() in heroes(scope)
}

object HeroesStore {
    const val LIMIT = 10

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val _state = MutableStateFlow(HeroesState())
    val state: StateFlow<HeroesState> = _state.asStateFlow()

    @Serializable
    private data class Row(val scope: String, @SerialName("target_id") val targetId: String? = null, @SerialName("oracle_ids") val oracleIds: List<String>) {
        val key get() = when (scope) { "list" -> "list:${targetId?.lowercase() ?: ""}"; "binder" -> "binder:${targetId?.lowercase() ?: ""}"; else -> "collection" }
    }

    private val prefs get() = T1App.instance.getSharedPreferences("library", Context.MODE_PRIVATE)
    private val cacheSerializer = MapSerializer(String.serializer(), ListSerializer(String.serializer()))

    private fun loadCache(userId: String): Map<String, List<String>> =
        prefs.getString("heroes.$userId", null)?.let { runCatching { T1App.json.decodeFromString(cacheSerializer, it) }.getOrNull() } ?: emptyMap()

    private fun saveCache() {
        val s = _state.value
        val user = s.userId ?: return
        prefs.edit().putString("heroes.$user", T1App.json.encodeToString(cacheSerializer, s.heroes)).apply()
    }

    suspend fun start(userId: String) {
        if (_state.value.userId != userId) _state.value = HeroesState(userId = userId, heroes = loadCache(userId))
        refresh()
    }

    fun stop() { _state.value = HeroesState() }

    /** All of the account's heroes (a few rows, so no cursor). */
    suspend fun refresh() {
        val user = _state.value.userId ?: return
        runCatching { T1App.supabase.postgrest.rpc("library_heroes").decodeAs<List<Row>>() }
            .onSuccess { rows ->
                if (_state.value.userId != user) return
                val heroes = LinkedHashMap<String, List<String>>()
                for (r in rows) heroes.putIfAbsent(r.key, r.oracleIds.map { it.lowercase() })
                _state.update { it.copy(heroes = heroes, error = null) }
                saveCache()
            }
            .onFailure { e -> if (_state.value.userId == user) _state.update { it.copy(error = e.message) } }
    }

    /** The next list after a toggle, or null when the scope already has [LIMIT] heroes. */
    fun toggled(ids: List<String>, oracleId: String): List<String>? {
        val o = oracleId.lowercase()
        if (o in ids) return ids - o
        return if (ids.size >= LIMIT) null else ids + o
    }

    /** Makes the card a hero of the scope, or stops it being one. False when the scope already has [LIMIT] heroes. */
    fun toggle(oracleId: String, s: HeroScope): Boolean {
        val before = _state.value.heroes(s)
        val ids = toggled(before, oracleId) ?: return false
        _state.update { st -> st.copy(heroes = if (ids.isEmpty()) st.heroes - s.key else st.heroes + (s.key to ids)) }
        saveCache()
        Telemetry.capture(if (ids.size > before.size) "hero_added" else "hero_removed", mapOf("scope" to s.wire, "count" to ids.size))
        val user = _state.value.userId ?: return true
        scope.launch {
            runCatching {
                T1App.supabase.postgrest.rpc("library_heroes_set", buildJsonObject {
                    put("p_scope", s.wire)
                    if (s.targetId != null) put("p_target_id", s.targetId) else put("p_target_id", JsonNull)
                    putJsonArray("p_oracle_ids") { ids.forEach { add(kotlinx.serialization.json.JsonPrimitive(it)) } }
                }).decodeAs<Row>()
            }.onSuccess { r ->
                if (_state.value.userId != user) return@onSuccess
                val got = r.oracleIds.map { it.lowercase() }
                _state.update { st -> st.copy(heroes = if (got.isEmpty()) st.heroes - r.key else st.heroes + (r.key to got), error = null) }
                saveCache()
            }.onFailure { e ->
                _state.update { it.copy(error = e.message) }
                refresh()
            }
        }
        return true
    }
}

object HeroArt {
    /** The printings to show for these heroes: the one the place holds (`held`, card ids, most copies first), else the
     *  card's cover. Hero order is kept; heroes the card data doesn't know are left out. */
    fun printings(heroes: List<String>, held: List<String>, db: CatalogDb): List<CatalogPrinting> {
        if (heroes.isEmpty()) return emptyList()
        val oracles = heroes.mapNotNull { db.oracle(it) }
        val wanted = oracles.map { it.idx }.toSet()
        val byOracle = HashMap<Int, CatalogPrinting>()
        val heldPrintings = db.printings(held.toSet())
        for (id in held) heldPrintings[id]?.let { p -> if (p.oracleIdx in wanted) byOracle.putIfAbsent(p.oracleIdx, p) }
        val covers = db.covers(oracles.map { it.idx }.filter { it !in byOracle })
        return oracles.mapNotNull { byOracle[it.idx] ?: covers[it.idx] }
    }
}

/** Up to three hero cards fanned at the left of a row that lists a deck, cube, binder or the collection. */
@Composable
fun HeroThumbs(printings: List<CatalogPrinting>) {
    val shown = printings.take(3)
    Box(Modifier.size(36.dp + 10.dp * (shown.size - 1).coerceAtLeast(0), 36.dp / CARD_ASPECT).clearAndSetSemantics {}) {
        shown.forEachIndexed { i, p -> CardArt(p, 36.dp, Modifier.offset(x = 10.dp * i)) }
    }
}

/** A row for a deck, cube, binder or the collection: its heroes (when it has any) left of the title. */
@Composable
fun HeroListRow(heroes: List<CatalogPrinting>, title: String, detail: String? = null, onClick: () -> Unit, trailing: @Composable () -> Unit = {}) {
    if (heroes.isEmpty()) {
        ListRow(title, detail, onClick = onClick) { trailing() }
        return
    }
    Row(Modifier.fillMaxWidth().background(T1.surface).clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        HeroThumbs(heroes)
        Column(Modifier.weight(1f)) {
            Text(title, color = T1.text, fontFamily = T1.mono, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            detail?.let { Label(it) }
        }
        trailing()
    }
}
