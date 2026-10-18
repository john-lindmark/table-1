package site.table1.events.library

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1AlertDialog
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Switch
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry

/* Binders and wants (contract/binders-wants-2026-10-17.md). Library → Binders: Unsorted and each binder; a binder
   lists its cards and can be renamed, flagged for trade or deleted. Library → Wants: the wishlist, then everything
   a deck or cube is missing. Card detail moves copies with BinderMoveFlow. Same screens as the iOS app. */

/** The route id for copies no binder holds. */
const val UNSORTED = "unsorted"

/** Market value (USD) of the given copies; null when none has a price. */
private fun value(items: List<CollectionItem>): Double? =
    items.mapNotNull { it -> PriceBook.usd(it.cardId, it.finish)?.let { p -> p * it.qty } }.takeIf { it.isNotEmpty() }?.sum()

@Composable
fun BindersScreen(onBack: () -> Unit, onOpen: (String) -> Unit) {
    val col by CollectionStore.state.collectAsState()
    val b by BindersStore.state.collectAsState()
    val pricesVersion by PriceBook.version.collectAsState()
    var creating by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { Telemetry.screen("binders") }
    LaunchedEffect(col.version) { PriceBook.load(col.items.values.map { it.cardId }.toSet()) }
    val (by, unsorted) = remember(col.version, b.version) { b.totals(col.items) }
    T1Screen {
        Bar("Binders", subtitle = "${b.binders.size} · ${b.binders.count { it.forTrade }} for trade", onBack = onBack)
        (b.error ?: col.error)?.let { Notice(it, error = true) }
        Hairlines(Modifier.weight(1f)) {
            item { ListRow("New binder", "A box, a deck box, a trade binder", onClick = { creating = true }) }
            item {
                ListRow("Unsorted", "Copies not in a binder", onClick = { onOpen(UNSORTED) }) {
                    Text(count(unsorted), color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                }
            }
            items(b.binders, key = { it.id }) { x ->
                val v = remember(col.version, b.version, pricesVersion) { value(b.itemsIn(x.id, col.items)) }
                ListRow(x.name, listOfNotNull(if (x.forTrade) "For trade" else null, PriceBook.text(v)).joinToString(" · ").ifEmpty { null },
                    onClick = { onOpen(x.id) }) {
                    Text(count(by[x.id] ?: 0), color = if (x.forTrade) T1.accent else T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                }
            }
            if (b.binders.isEmpty()) item { Notice("Binders say where your copies are. Flag one for trade and Trades offers its cards first when you give.") }
        }
    }
    if (creating) BinderEditDialog(null, onClose = { creating = false }) { onOpen(it.id) }
}

/** Name and "for trade" for a new binder or an existing one. */
@Composable
fun BinderEditDialog(binder: Binder?, onClose: () -> Unit, onSaved: (Binder) -> Unit = {}) {
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf(binder?.name ?: "") }
    var trade by remember { mutableStateOf(binder?.forTrade ?: false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    T1AlertDialog(
        title = if (binder == null) "New binder" else "Edit binder",
        onDismiss = onClose,
        confirm = {
            TextButton(enabled = name.isNotBlank() && !busy, onClick = {
                busy = true
                scope.launch {
                    runCatching { BindersStore.save(binder?.id, name.trim().take(60), trade) }
                        .onSuccess { onClose(); onSaved(it) }.onFailure { error = it.message }
                    busy = false
                }
            }) { Label(if (binder == null) "Create" else "Save", color = T1.text) }
        },
        dismiss = { TextButton(onClick = onClose) { Label("Cancel", color = T1.text) } },
        body = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                T1TextField(name, { name = it.take(60) }, label = "Name", placeholder = "Trade binder", error = error)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("For trade", color = T1.text, fontFamily = T1.mono, fontSize = 14.sp)
                        Label("Trades offers these copies first when you give")
                    }
                    T1Switch(trade) { trade = it }
                }
            }
        },
    )
}

/** One binder's cards (or Unsorted's), grouped by card, most copies first. */
@Composable
fun BinderScreen(id: String, onBack: () -> Unit, onCard: (String) -> Unit) {
    val col by CollectionStore.state.collectAsState()
    val b by BindersStore.state.collectAsState()
    val cat by CatalogStore.state.collectAsState()
    val pricesVersion by PriceBook.version.collectAsState()
    val scope = rememberCoroutineScope()
    val unsorted = id == UNSORTED
    val binder = if (unsorted) null else b.binder(id)
    var groups by remember { mutableStateOf<List<CardGroup>>(emptyList()) }
    var query by remember { mutableStateOf("") }
    var menu by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    var askDelete by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val items = remember(col.version, b.version, id) { b.itemsIn(if (unsorted) null else id, col.items) }
    LaunchedEffect(Unit) {
        Telemetry.screen("binder")
        CatalogStore.load(userInitiated = true)
    }
    LaunchedEffect(items, cat.generation) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        groups = withContext(Dispatchers.Default) { CardGroup.build(items, db).sortedWith(compareByDescending<CardGroup> { it.qty }.thenBy { it.norm }) }
        PriceBook.load(items.map { it.cardId }.toSet())
    }
    val copies = items.sumOf { it.qty }
    val v = remember(items, pricesVersion) { value(items) }
    T1Screen {
        Bar(if (unsorted) "Unsorted" else binder?.name ?: "Binder",
            subtitle = listOfNotNull("${count(copies)} cards", if (binder?.forTrade == true) "For trade" else null, PriceBook.text(v)).joinToString(" · "),
            onBack = onBack) { if (binder != null) BarAction("Edit") { menu = true } }
        if (!unsorted && binder == null) Notice("This binder was deleted.")
        (error ?: b.error)?.let { Notice(it, error = true) }
        CatalogStatus(cat)
        Box(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp)) {
            T1TextField(query, { query = it }, placeholder = "Name or type")
        }
        val n = CardName.norm(query)
        val shown = if (n.isEmpty()) groups else groups.filter { it.norm.contains(n) || CardName.norm(it.type).contains(n) }
        Hairlines(Modifier.weight(1f)) {
            if (groups.isEmpty() && cat.phase == "ready") item {
                Notice(if (unsorted) "Every copy is in a binder." else "No cards here yet. Open a card and move copies here, or add copies straight into this binder from a trade or an import.")
            }
            items(shown, key = { it.id }) { g ->
                CardRow(g.cover, g.name, "${g.printings} printing${if (g.printings == 1) "" else "s"} · ${g.type}", onClick = { if (g.known) onCard(g.id) }) {
                    Text("${g.qty}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                }
            }
        }
    }
    if (menu && binder != null) {
        T1Menu(binder.name, listOf(
            T1MenuItem("Rename") { editing = true },
            T1MenuItem(if (binder.forTrade) "Not for trade" else "For trade") {
                scope.launch { runCatching { BindersStore.save(binder.id, binder.name, !binder.forTrade) }.onFailure { error = it.message } }
            },
            T1MenuItem("Delete binder", danger = true) { askDelete = true },
        )) { menu = false }
    }
    if (editing && binder != null) BinderEditDialog(binder, onClose = { editing = false })
    if (askDelete && binder != null) {
        T1AlertDialog(
            title = "Delete ${binder.name}?",
            onDismiss = { askDelete = false },
            confirm = {
                TextButton(onClick = {
                    askDelete = false
                    scope.launch { runCatching { BindersStore.delete(binder) }.onSuccess { onBack() }.onFailure { error = it.message } }
                }) { Label("Delete", color = T1.danger) }
            },
            dismiss = { TextButton(onClick = { askDelete = false }) { Label("Cancel", color = T1.text) } },
            body = { Text("Its ${count(copies)} cards stay in your collection, Unsorted. This can't be undone.", color = T1.muted, fontFamily = T1.mono, fontSize = 13.sp) },
        )
    }
}

/**
 * Card detail → an owned item → Move: pick where from (when copies are in more than one place), how many, then where
 * to (a binder, Unsorted, or a new binder).
 */
@Composable
fun BinderMoveFlow(item: CollectionItem, label: String, onClose: () -> Unit, onMoved: (String) -> Unit) {
    val b by BindersStore.state.collectAsState()
    val scope = rememberCoroutineScope()
    val (held, unsortedQty) = remember(b.version, item) { b.placement(item) }
    val sources = remember(b.version, item) {
        held.map { Triple<String?, String, Int>(it.first.id, it.first.name, it.second) } +
            (if (unsortedQty > 0) listOf(Triple<String?, String, Int>(null, "Unsorted", unsortedQty)) else emptyList())
    }
    var from by remember { mutableStateOf(sources.singleOrNull()) }
    var qty by remember { mutableStateOf(if (from?.third == 1) 1 else null) }
    var creating by remember { mutableStateOf(false) }
    // T1Menu dismisses itself before running the picked item; a pick in the same tap cancels that close.
    var closing by remember { mutableStateOf(false) }
    LaunchedEffect(closing) { if (closing) onClose() }
    fun run(to: String?, toName: String) {
        val f = from ?: return
        val n = qty ?: return
        scope.launch {
            runCatching { BindersStore.move(listOf(BinderMove(item, f.first, to, n))) }
                .onSuccess { onMoved("Moved $n $label to $toName") }
                .onFailure { e -> onMoved("Couldn't move them: ${e.message}") }
        }
    }
    val f = from
    val n = qty
    when {
        creating -> BinderEditDialog(null, onClose = { creating = false }) { nb -> run(nb.id, nb.name) }
        f == null -> T1Menu("Move $label from", sources.map { s ->
            T1MenuItem("${s.second} · ${s.third} here") { closing = false; from = s; if (s.third == 1) qty = 1 }
        }) { closing = true }
        n == null -> T1Menu("How many?", listOf(1, f.third / 2, f.third).filter { it >= 1 }.distinct().sorted().map { k ->
            T1MenuItem(if (k == f.third) "All $k" else "$k") { closing = false; qty = k }
        }) { closing = true }
        else -> T1Menu("Move $n to", b.binders.filter { it.id != f.first }.map { x ->
            T1MenuItem(if (x.forTrade) "${x.name} · for trade" else x.name) { closing = false; run(x.id, x.name) }
        } + listOfNotNull(
            if (f.first != null) T1MenuItem("Unsorted") { closing = false; run(null, "Unsorted") } else null,
            T1MenuItem("New binder…") { closing = false; creating = true },
        )) { closing = true }
    }
}

/* ── wants ────────────────────────────────────────────────────────────── */

private data class WantRowView(val want: Want, val name: String, val printing: CatalogPrinting?)
private data class MissingRowView(val line: MissingLine, val printing: CatalogPrinting?, val name: String, val oracleId: String?)

@Composable
fun WantsScreen(onBack: () -> Unit, onCard: (String) -> Unit) {
    val col by CollectionStore.state.collectAsState()
    val b by BindersStore.state.collectAsState()
    val lists by ListsStore.state.collectAsState()
    val cat by CatalogStore.state.collectAsState()
    val scope = rememberCoroutineScope()
    var rows by remember { mutableStateOf<List<WantRowView>>(emptyList()) }
    var missing by remember { mutableStateOf<List<MissingRowView>>(emptyList()) }
    var adding by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<WantRowView?>(null) }
    var pricing by remember { mutableStateOf<Want?>(null) }
    var showAll by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        Telemetry.screen("wants")
        CatalogStore.load(userInitiated = true)
    }
    LaunchedEffect(b.version, col.version, lists.lists, cat.generation) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        val wants = b.liveWants
        val owned = col.items.values.groupBy { ownKey(it.cardId, it.finish) }.mapValues { (_, v) -> v.sumOf { it.qty } }
        val ls = lists.lists
        val out = withContext(Dispatchers.Default) {
            val printings = db.printings(wants.mapNotNull { it.cardId }.toSet())
            val shown = wants.map { w ->
                val o = db.oracle(w.oracleId)
                WantRowView(w, o?.name ?: "Card not in local data yet", w.cardId?.let { printings[it] } ?: o?.let { db.covers(listOf(it.idx))[it.idx] })
            }
            val lines = MissingView.lines(ls, owned)
            val mp = db.printings(lines.map { it.cardId }.toSet())
            val mo = db.oracles(mp.values.map { it.oracleIdx }.toSet())
            shown to lines.map { l -> val o = mp[l.cardId]?.let { mo[it.oracleIdx] }; MissingRowView(l, mp[l.cardId], o?.name ?: "Card not in local data yet", o?.oracleId) }
        }
        rows = out.first
        missing = out.second
        PriceBook.load(wants.mapNotNull { it.cardId }.toSet())
    }
    fun run(ops: List<WantOp>, event: String? = null, props: Map<String, Any> = emptyMap()) {
        scope.launch { runCatching { BindersStore.applyWants(ops, event, props) }.onFailure { error = it.message } }
    }
    val wanted = rows.sumOf { it.want.qty }
    val short = missing.sumOf { it.line.short }
    T1Screen {
        Bar("Wants", subtitle = "$wanted wanted · $short missing", onBack = onBack)
        (error ?: b.error)?.let { Notice(it, error = true) }
        CatalogStatus(cat)
        Hairlines(Modifier.weight(1f)) {
            item { ListRow("Add a want", "Any printing, or one in particular", onClick = { adding = true }) }
            item { Section("Wanted · ${rows.size}") }
            if (rows.isEmpty()) item { Notice("Cards you're after. Gets in a trade that match are marked, and confirming takes them off.") }
            items(rows, key = { "w-" + it.want.key }) { r ->
                val w = r.want
                val which = if (w.cardId == null) "Any printing" else listOfNotNull(r.printing?.setLabel, w.finish?.let { Finish.of(it)?.label }).joinToString(" · ")
                val now = w.cardId?.let { PriceBook.usd(it, w.finish ?: "nonfoil") }
                CardRow(r.printing, r.name, listOfNotNull(which, w.maxUsd?.let { "Max $$it" }, now?.let { "Now $$it" }).joinToString(" · "),
                    onClick = { editing = r }) {
                    Text("${w.qty}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                }
            }
            item { Section("Missing from decks and cubes · $short") }
            if (missing.isEmpty() && cat.phase == "ready") item { Notice("Your decks and cubes have every card they need.") }
            items(if (showAll) missing else missing.take(60), key = { "m-" + it.line.key }) { m ->
                Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    Box(Modifier.weight(1f)) {
                        CardRow(m.printing, m.name, listOfNotNull(if (m.line.finish == "nonfoil") null else m.line.finish, m.line.lists.joinToString(", ")).joinToString(" · "),
                            onClick = { m.oracleId?.let(onCard) }) {
                            Text("${m.line.short}", color = T1.error, fontFamily = T1.mono, fontSize = 17.sp)
                        }
                    }
                    val o = m.oracleId
                    if (o != null && rows.none { it.want.oracleId == o }) {
                        Box(Modifier.fillMaxHeight().background(T1.surfaceHover).clickable {
                            run(listOf(WantOp(o, delta = m.line.short)), "want_added", mapOf("any_printing" to true, "has_max" to false, "from" to "missing"))
                        }.padding(horizontal = 14.dp), contentAlignment = Alignment.Center) { Label("Want", color = T1.text) }
                    }
                }
            }
            if (!showAll && missing.size > 60) item { ListRow("Show all ${missing.size}", onClick = { showAll = true }) }
        }
    }
    editing?.let { r ->
        val w = r.want
        T1Menu(r.name, buildList {
            add(T1MenuItem("One more") { run(listOf(WantOp(w.oracleId, w.cardId, w.finish, delta = 1)), "want_changed") })
            add(T1MenuItem("One fewer", enabled = w.qty > 1) { run(listOf(WantOp(w.oracleId, w.cardId, w.finish, delta = -1)), "want_changed") })
            add(T1MenuItem("Max price · ${w.maxUsd?.let { "$$it" } ?: "none"}") { pricing = w })
            val p = r.printing
            if (w.cardId == null && p != null) add(T1MenuItem("Only ${p.setLabel}") {
                run(listOf(WantOp(w.oracleId, qty = 0), WantOp(w.oracleId, p.cardId, qty = w.qty, setMax = true, maxUsd = w.maxUsd)))
            }) else if (w.cardId != null) add(T1MenuItem("Any printing") {
                run(listOf(WantOp(w.oracleId, w.cardId, w.finish, qty = 0), WantOp(w.oracleId, delta = w.qty, setMax = true, maxUsd = w.maxUsd)))
            })
            add(T1MenuItem("Open card") { onCard(w.oracleId) })
            add(T1MenuItem("Remove", danger = true) { run(listOf(WantOp(w.oracleId, w.cardId, w.finish, qty = 0)), "want_removed") })
        }) { editing = null }
    }
    pricing?.let { w ->
        var text by remember(w) { mutableStateOf(w.maxUsd?.toString() ?: "") }
        val price = text.trim().replace(",", ".").toDoubleOrNull()?.takeIf { it >= 0 }
        T1AlertDialog(
            title = "Max price",
            onDismiss = { pricing = null },
            confirm = {
                TextButton(enabled = text.isBlank() || price != null, onClick = {
                    pricing = null
                    run(listOf(WantOp(w.oracleId, w.cardId, w.finish, setMax = true, maxUsd = if (text.isBlank()) null else price)), "want_changed")
                }) { Label("Save", color = T1.text) }
            },
            dismiss = { TextButton(onClick = { pricing = null }) { Label("Cancel", color = T1.text) } },
            body = { T1TextField(text, { text = it.take(10) }, label = "Most you'd pay, USD (empty for none)", keyboardType = KeyboardType.Decimal) },
        )
    }
    if (adding) WantPickOverlay(onClose = { adding = false }) { o ->
        run(listOf(WantOp(o.oracleId, delta = 1)), "want_added", mapOf("any_printing" to true, "has_max" to false, "from" to "search"))
    }
}

/** Search for a card to want (any printing). */
@Composable
private fun WantPickOverlay(onClose: () -> Unit, onPick: (CatalogOracle) -> Unit) {
    var query by remember { mutableStateOf("") }
    var hits by remember { mutableStateOf<List<CatalogOracle>>(emptyList()) }
    var covers by remember { mutableStateOf<Map<Int, CatalogPrinting>>(emptyMap()) }
    var added by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(query) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        delay(120)
        val q = query
        val found = withContext(Dispatchers.Default) { db.search(q).let { h -> h to db.covers(h.map { it.idx }) } }
        hits = found.first
        covers = found.second
    }
    androidx.compose.ui.window.Dialog(onDismissRequest = onClose,
        properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(T1.bg)) {
            T1Screen {
                Bar("Add a want", subtitle = added, onBack = onClose)
                Box(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp)) {
                    T1TextField(query, { query = it }, placeholder = "Lightning Bolt")
                }
                Hairlines(Modifier.weight(1f)) {
                    items(hits, key = { it.idx }) { o ->
                        CardRow(covers[o.idx], o.name, o.typeLine, onClick = { onPick(o); added = "Wanted ${o.name}" }) { Label("Want", color = T1.text) }
                    }
                }
                BigAction("Done") { onClose() }
            }
        }
    }
}
