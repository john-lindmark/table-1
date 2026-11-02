package site.table1.events.library

import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.unit.sp
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.delay
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import site.table1.events.T1App
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Section
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry
import site.table1.events.util.rethrowIfCancelled

/* Collection Search finds decks, cubes and binders, Insights archetypes and rankings
   (contract/library-search-2026-10-18.md § Collection search). Your own lists are matched on the device by name
   (CardSearch.matchesList); everything else comes from library_search with p_all: other people's lists you can see,
   lists (yours too) holding a card the query names, archetypes and rankings. A section per kind above the cards. */

/** One of library_search's items. */
@Serializable
data class ListHit(
    val kind: String,
    val id: String,
    val name: String,
    val format: String? = null,
    @SerialName("for_trade") val forTrade: Boolean? = null,
    val cards: Int? = null,
    val owner: FollowOwner? = null,
    /** Seen on their profile: open it there. */
    @SerialName("user_id") val userId: String? = null,
    /** Seen through the link you followed with: open the link. */
    val token: String? = null,
    val following: Boolean = false,
    /** Your own, found by a card it holds. */
    val mine: Boolean = false,
    /** Found by a card it holds, not its name. */
    val has: Has? = null,
    /** Archetypes: lists in the last 90 days. */
    val decks: Int? = null,
    /** Rankings: the cube's id or "set:<KEY>", and the name its maker gave it. */
    val subject: String? = null,
    val label: String? = null,
) {
    @Serializable data class Has(val name: String, val qty: Int)

    /** Where it opens: your own screen, their profile section, the link it was followed through, an Insights archetype
     *  or a ranking. */
    val route: String? get() = when {
        kind == "archetype" -> format?.let { f -> id.toIntOrNull()?.let { site.table1.events.insights.InsightsRoutes.archetype(f, it) } }
        kind == "ranking" -> "collection/ranking/$id"
        mine -> if (kind == "binder") "collection/binder/$id" else "collection/list/$id"
        token != null -> "collection/shared/$token"
        userId != null -> "profile/$userId/$kind/$id"
        else -> null
    }
}

@Serializable
private data class ListHits(val items: List<ListHit>)

object ListSearch {
    /** How many of each kind show before "Show all N". */
    const val SHOWN = 3

    suspend fun search(query: String): List<ListHit> =
        T1App.supabase.postgrest.rpc("library_search", buildJsonObject { put("p_query", query.trim()); put("p_all", true) }).decodeAs<ListHits>().items

    data class Hit(val key: String, val title: String, val detail: String, val value: Int?, val route: String, val whose: String, val by: String = "name")
    data class Group(val kind: String, val title: String, val hits: List<Hit>)

    private val KINDS = listOf("deck" to "Decks", "cube" to "Cubes", "binder" to "Binders", "archetype" to "Archetypes", "ranking" to "Rankings")

    /** Yours by name (the shared order), then what the server found (yours by card, then everyone else's, in its order),
     *  per kind; kinds with none left out. */
    fun groups(query: String, lists: List<CardList>, binders: List<Binder>, binderCopies: Map<String, Int>, others: List<ListHit>): List<Group> =
        KINDS.mapNotNull { (kind, title) ->
            val mine = when (kind) {
                "binder" -> CardSearch.order(query, binders.filter { CardSearch.matchesList(query, it.name, "") }) { it.name }.map { b ->
                    Hit(b.id, b.name, CardSearch.hitDetail(CardSearch.HitLine(kind, forTrade = b.forTrade)), binderCopies[b.id], "collection/binder/${b.id}", "mine")
                }
                "deck", "cube" -> {
                    val k = if (kind == "deck") ListKind.Deck else ListKind.Cube
                    CardSearch.order(query, lists.filter { it.kind == k && CardSearch.matchesList(query, it.name, it.format) }) { it.name }.map { l ->
                        Hit(l.id, l.name, CardSearch.hitDetail(CardSearch.HitLine(kind, format = l.format)), l.count("main"), "collection/list/${l.id}", "mine")
                    }
                }
                else -> emptyList()
            }
            val seen = mine.map { it.key }.toSet()
            val found = others.filter { it.kind == kind && it.id !in seen }.mapNotNull { h ->
                val route = h.route ?: return@mapNotNull null
                val line = CardSearch.HitLine(h.kind, h.format, h.forTrade, if (h.mine) null else h.owner?.displayName, h.has, h.decks, h.label)
                Hit("${h.kind}|${h.id}", h.name, CardSearch.hitDetail(line), if (kind == "archetype" || kind == "ranking") null else h.cards, route,
                    if (h.mine) "mine" else if (h.following) "following" else "shared", if (h.has != null) "card" else "name")
            }
            (mine + found).takeIf { it.isNotEmpty() }?.let { Group(kind, title, it) }
        }
}

/** Collection Search's sections for this query, and which kinds show every row. */
class ListHitsState(val groups: List<ListSearch.Group>, val open: Set<String>, val expand: (String) -> Unit)

@Composable
fun rememberListHits(query: String, enabled: Boolean): ListHitsState {
    val lists by ListsStore.state.collectAsState()
    val binders by BindersStore.state.collectAsState()
    val col by CollectionStore.state.collectAsState()
    var others by remember { mutableStateOf<Pair<String, List<ListHit>>?>(null) }
    var open by remember { mutableStateOf(emptySet<String>()) }
    val searching = enabled && CardName.norm(query).length >= 2
    LaunchedEffect(query, searching) {
        open = emptySet()
        if (!searching) return@LaunchedEffect
        delay(300)
        // Offline or refused: yours still show.
        val items = runCatching { ListSearch.search(query) }.onFailure { it.rethrowIfCancelled() }.getOrDefault(emptyList())
        others = query to items
    }
    val copies = remember(binders.version, col.version) { binders.totals(col.items).first }
    val groups = if (!searching) emptyList()
        else ListSearch.groups(query, lists.lists, binders.binders, copies, others?.takeIf { it.first == query }?.second ?: emptyList())
    return ListHitsState(groups, open) { open = open + it }
}

fun LazyListScope.listHitSections(state: ListHitsState, go: (String) -> Unit) {
    for (g in state.groups) {
        val all = g.kind in state.open || g.hits.size <= ListSearch.SHOWN + 1
        item(key = "lh-${g.kind}") { Section("${g.title} · ${g.hits.size}") }
        items(if (all) g.hits else g.hits.take(ListSearch.SHOWN), key = { "lh-${g.kind}-${it.key}" }) { h ->
            ListRow(h.title, h.detail, onClick = {
                Telemetry.capture("search_list_opened", mapOf("kind" to g.kind, "whose" to h.whose, "by" to h.by))
                go(h.route)
            }) {
                h.value?.let { Text("$it", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp) }
            }
        }
        if (!all) item(key = "lh-${g.kind}-all") { ListRow("Show all ${g.hits.size}", onClick = { state.expand(g.kind) }) }
    }
    if (state.groups.isNotEmpty()) item(key = "lh-cards") { Section("Cards") }
}
