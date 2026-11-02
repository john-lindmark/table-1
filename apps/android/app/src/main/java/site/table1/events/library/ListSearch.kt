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

/* Collection Search finds decks, cubes and binders (contract/library-search-2026-10-18.md § Collection search).
   Your own are matched on the device (CardSearch.matchesList); everyone else's you can see come from
   library_search: what you follow, friends', and anyone's set to Anyone. A section per kind above the cards. */

/** One of library_search's items: someone else's binder, deck or cube. */
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
) {
    /** Where it opens: its profile section, or the link it was followed through. */
    val route: String? get() = when {
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
        T1App.supabase.postgrest.rpc("library_search", buildJsonObject { put("p_query", query.trim()) }).decodeAs<ListHits>().items

    data class Hit(val key: String, val title: String, val detail: String, val value: Int?, val route: String, val whose: String)
    data class Group(val kind: String, val title: String, val hits: List<Hit>)

    private val KINDS = listOf(Triple("deck", "Decks", "Deck"), Triple("cube", "Cubes", "Cube"), Triple("binder", "Binders", "Binder"))

    /** Yours (by the shared order), then everyone else's (in the server's order), per kind; kinds with none left out. */
    fun groups(query: String, lists: List<CardList>, binders: List<Binder>, binderCopies: Map<String, Int>, others: List<ListHit>): List<Group> =
        KINDS.mapNotNull { (kind, title, label) ->
            val mine = if (kind == "binder") {
                CardSearch.order(query, binders.filter { CardSearch.matchesList(query, it.name, "") }) { it.name }.map { b ->
                    Hit(b.id, b.name, listOfNotNull(label, if (b.forTrade) "For trade" else null).joinToString(" · "), binderCopies[b.id], "collection/binder/${b.id}", "mine")
                }
            } else {
                val k = if (kind == "deck") ListKind.Deck else ListKind.Cube
                CardSearch.order(query, lists.filter { it.kind == k && CardSearch.matchesList(query, it.name, it.format) }) { it.name }.map { l ->
                    Hit(l.id, l.name, listOfNotNull(label, if (kind == "deck" && l.format.isNotEmpty()) CatalogPack.formatName(l.format) else null).joinToString(" · "),
                        l.count("main"), "collection/list/${l.id}", "mine")
                }
            }
            val theirs = others.filter { it.kind == kind }.mapNotNull { h ->
                val route = h.route ?: return@mapNotNull null
                val detail = listOfNotNull(label, if (kind == "deck") h.format?.takeIf { it.isNotEmpty() }?.let(CatalogPack::formatName) else null,
                    if (kind == "binder" && h.forTrade == true) "For trade" else null, h.owner?.displayName)
                Hit("${h.kind}|${h.id}", h.name, detail.joinToString(" · "), h.cards, route, if (h.following) "following" else "shared")
            }
            (mine + theirs).takeIf { it.isNotEmpty() }?.let { Group(kind, title, it) }
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
                Telemetry.capture("search_list_opened", mapOf("kind" to g.kind, "whose" to h.whose))
                go(h.route)
            }) {
                h.value?.let { Text("$it", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp) }
            }
        }
        if (!all) item(key = "lh-${g.kind}-all") { ListRow("Show all ${g.hits.size}", onClick = { state.expand(g.kind) }) }
    }
    if (state.groups.isNotEmpty()) item(key = "lh-cards") { Section("Cards") }
}
