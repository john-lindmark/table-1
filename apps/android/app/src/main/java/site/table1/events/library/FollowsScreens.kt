package site.table1.events.library

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry

/* Following screens (contract/follows-2026-10-25.md): the Follow rows on someone else's binder, deck or cube, the
   Library home row, Following, and an item's Changes. Same screens as the iOS app. */

private data class FollowMenu(val title: String, val items: List<T1MenuItem>)

private fun followMenu(title: String, kind: String, id: String, push: Boolean, from: String, run: (suspend () -> Unit) -> Unit) =
    FollowMenu(title, listOf(
        T1MenuItem(if (push) "Turn pushes off" else "Turn pushes on") { run { FollowsStore.set(kind, id, true, push = !push, from = from) } },
        T1MenuItem("Unfollow", danger = true) { run { FollowsStore.set(kind, id, false, from = from) } },
    ))

/** On a binder, deck or cube someone else shares with you: Follow, or Following and its Changes. */
@Composable
fun FollowRows(kind: String, id: String, title: String, owner: String?, token: String?, onChanges: () -> Unit) {
    val s by FollowsStore.state.collectAsState()
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf<FollowMenu?>(null) }
    var fail by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(kind, id) { FollowsStore.loadState(kind, id) }
    val run: (suspend () -> Unit) -> Unit = { work -> scope.launch { runCatching { work() }.onFailure { fail = it.message } } }
    val st = s.states[id] ?: return
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        fail?.let { Notice(it, error = true) }
        if (st.following) {
            ListRow("Following", if (st.push) "Pushes on" else "Pushes off · changes show in Following",
                onClick = { menu = followMenu(title, kind, id, st.push, "item", run) }) { Label("✓", color = T1.accent) }
            st.lastUpdate?.let { u ->
                ListRow("Changes", Follows.since(u, System.currentTimeMillis()), onClick = onChanges) {
                    if (st.unseen > 0) Label("${st.unseen} new", color = T1.accent)
                }
            }
        } else {
            ListRow("Follow", "Get a push when ${owner?.let { "$it changes" } ?: "they change"} it") {
                Box(Modifier.background(T1.accent).clickable(enabled = !busy) {
                    busy = true
                    scope.launch {
                        runCatching { FollowsStore.set(kind, id, true, token = token, from = "item") }.onFailure { fail = it.message }
                        busy = false
                    }
                }.padding(horizontal = 12.dp, vertical = 10.dp)) { Label(if (busy) "…" else "Follow", color = T1.ink) }
            }
        }
    }
    menu?.let { m -> T1Menu(m.title, m.items) { menu = null } }
}

/** Library home, once you follow anything. */
@Composable
fun FollowingRow(onClick: () -> Unit) {
    val s by FollowsStore.state.collectAsState()
    LaunchedEffect(Unit) { if (s.items == null) FollowsStore.load() }
    val items = s.items.orEmpty()
    if (items.isEmpty()) return
    val updated = items.count { it.available && it.unseen > 0 }
    ListRow("Following", Follows.home(items), onClick = onClick) { if (updated > 0) Label("$updated new", color = T1.accent) }
}

@Composable
fun FollowingScreen(onBack: () -> Unit, onOpen: (String) -> Unit) {
    val s by FollowsStore.state.collectAsState()
    val scope = rememberCoroutineScope()
    var menu by remember { mutableStateOf<FollowMenu?>(null) }
    var fail by remember { mutableStateOf<String?>(null) }
    val run: (suspend () -> Unit) -> Unit = { work -> scope.launch { runCatching { work() }.onFailure { fail = it.message } } }
    LaunchedEffect(Unit) {
        Telemetry.screen("following")
        FollowsStore.load()?.let { items ->
            Telemetry.capture("following_viewed", mapOf("items" to items.size, "updated" to items.count { it.available && it.unseen > 0 }))
        }
    }
    fun more(f: Follow) {
        menu = if (f.available) followMenu(f.title, f.kind, f.id, f.push, "following", run)
        else FollowMenu("This isn't available", listOf(T1MenuItem("Unfollow", danger = true) { run { FollowsStore.set(f.kind, f.id, false, from = "following") } }))
    }
    val now = System.currentTimeMillis()
    T1Screen {
        Bar("Following", s.items?.let(Follows::home), onBack = onBack)
        (fail ?: s.error)?.let { Notice(it, error = true) }
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (s.items == null) item { Notice("Loading…") }
            if (s.items?.isEmpty() == true) item { Notice("Follow a friend's deck, cube or binder to see their changes here.") }
            items(s.items.orEmpty(), key = { it.id }) { f ->
                Row(Modifier.height(androidx.compose.foundation.layout.IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    Box(Modifier.weight(1f)) {
                        ListRow(f.title, listOfNotNull(f.subtitle.takeIf { f.available }, Follows.detail(f, now)).joinToString(" · "),
                            onClick = { f.route?.let(onOpen) ?: more(f) }) {
                            if (f.available && f.unseen > 0) Label("${f.unseen} new", color = T1.accent)
                        }
                    }
                    Box(Modifier.fillMaxHeight().background(T1.surface).clickable { more(f) }.padding(horizontal = 16.dp),
                        contentAlignment = Alignment.Center) { Label("•••") }
                }
            }
        }
    }
    menu?.let { m -> T1Menu(m.title, m.items) { menu = null } }
}

/** An item's updates since you followed, newest first: Added, then Taken out. */
@Composable
fun FollowChangesScreen(kind: String, id: String, onBack: () -> Unit, onCard: (String) -> Unit) {
    val cat by CatalogStore.state.collectAsState()
    var changes by remember { mutableStateOf<FollowChanges?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var printings by remember { mutableStateOf<Map<String, CatalogPrinting>>(emptyMap()) }
    var oracles by remember { mutableStateOf<Map<Int, CatalogOracle>>(emptyMap()) }
    LaunchedEffect(kind, id) {
        Telemetry.screen("follow_changes")
        CatalogStore.load(userInitiated = true)
        runCatching { FollowsStore.changes(kind, id) }.onSuccess { changes = it }.onFailure { error = it.message }
    }
    LaunchedEffect(changes, cat.generation) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        val c = changes ?: return@LaunchedEffect
        val p = db.printings(c.updates.flatMap { u -> u.cards().map { it.cardId } }.toSet())
        printings = p
        oracles = db.oracles(p.values.map { it.oracleIdx }.toSet())
    }
    val now = System.currentTimeMillis()
    val sectionName = mapOf("main" to "Main deck", "side" to "Sideboard", "commander" to "Commander")
    @Composable
    fun card(c: FollowCard, sign: String) {
        val p = printings[c.cardId]
        val o = p?.let { oracles[it.oracleIdx] }
        CardRow(p, o?.name ?: "Unknown card", listOfNotNull(if (kind == "deck") sectionName[c.board] else null, p?.setLabel).joinToString(" · "),
            onClick = { o?.let { onCard(it.oracleId) } }) {
            Text("$sign${c.qty}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
        }
    }
    T1Screen {
        Bar(changes?.name ?: "Changes", "Changes", onBack = onBack)
        error?.let { Notice(it, error = true) }
        CatalogStatus(cat)
        LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            val c = changes
            if (c == null && error == null) item { Notice("Loading…") }
            if (c != null && c.updates.isEmpty()) item { Notice("No changes since you followed.") }
            c?.updates?.forEach { u ->
                val (added, removed) = Follows.sections(u.cards())
                item(key = "h-${u.at}") { Section(Follows.since(FollowUpdateSummary(u.at, u.added, u.removed), now)) }
                if (added.isNotEmpty()) {
                    item(key = "a-${u.at}") { BoardHeader("Added", added.sumOf { it.qty }) }
                    items(added, key = { "a-${u.at}-${it.cardId}-${it.board}" }) { card(it, "+") }
                }
                if (removed.isNotEmpty()) {
                    item(key = "r-${u.at}") { BoardHeader("Taken out", removed.sumOf { it.qty }) }
                    items(removed, key = { "r-${u.at}-${it.cardId}-${it.board}" }) { card(it, Follows.MINUS) }
                }
            }
        }
    }
}
