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
import androidx.compose.foundation.lazy.grid.items as gridItems
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.layout.BoxWithConstraints
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
import site.table1.events.T1App
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry

/* Binders and wants (contract/binders-wants-2026-10-17.md). Library → Binders: Unsorted and each binder; a binder
   lists its cards and can be renamed, flagged for trade or deleted. Library → Wants: the wishlist, then everything
   a deck or cube is missing. Card detail moves copies with BinderMoveFlow. Same screens as the iOS app. */

/** `library_searched` once per visit, when the screen's search is first used (never the text). */
@Composable
fun SearchUsed(query: String, screen: String) {
    var sent by remember { mutableStateOf(false) }
    LaunchedEffect(query.isEmpty()) {
        if (query.isNotEmpty() && !sent) { sent = true; Telemetry.capture("library_searched", mapOf("screen" to screen)) }
    }
}

/** A search field on the surface band, as on the binder screen. */
@Composable
fun SearchBand(query: String, placeholder: String, onChange: (String) -> Unit) {
    Box(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp)) {
        T1TextField(query, onChange, placeholder = placeholder)
    }
}

/** The route id for copies no binder holds. */
const val UNSORTED = "unsorted"

/** Market value (USD) of the given copies; null when none has a price. */
private fun value(items: List<CollectionItem>): Double? =
    items.mapNotNull { it -> PriceBook.usd(it.cardId, it.finish, it.condition)?.let { p -> p * it.qty } }.takeIf { it.isNotEmpty() }?.sum()

@Composable
fun BindersScreen(onBack: () -> Unit, onOpen: (String) -> Unit, onCard: (String) -> Unit = {}) {
    val col by CollectionStore.state.collectAsState()
    val b by BindersStore.state.collectAsState()
    val cat by CatalogStore.state.collectAsState()
    val pricesVersion by PriceBook.version.collectAsState()
    var creating by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf("") }
    // Owned cards matching the search, most copies first, each saying where its copies are.
    var found by remember { mutableStateOf<List<Pair<CardGroup, String>>>(emptyList()) }
    SearchUsed(query, "binders")
    LaunchedEffect(query, col.version, b.version, cat.generation) {
        val q = query
        if (CardName.norm(q).isEmpty()) { found = emptyList(); return@LaunchedEffect }
        CatalogStore.load(userInitiated = true)
        val db = CatalogStore.db ?: return@LaunchedEffect
        delay(120)
        val items = col.items.values.toList()
        val (groups, keyOf) = withContext(Dispatchers.Default) {
            val ps = db.printings(items.map { it.cardId }.toSet())
            val os = db.oracles(ps.values.map { it.oracleIdx }.toSet())
            val keyOf = items.associate { it.cardId to (ps[it.cardId]?.let { p -> os[p.oracleIdx]?.oracleId } ?: it.cardId) }
            CardGroup.build(items, db).filter { CardSearch.matches(q, it.name, it.type) }
                .sortedWith(compareByDescending<CardGroup> { it.qty }.thenBy { it.norm }) to keyOf
        }
        val byBinder = mutableMapOf<String, MutableMap<String, Int>>()
        val unsortedBy = mutableMapOf<String, Int>()
        for (it in items) {
            val k = keyOf[it.cardId] ?: continue
            val (held, u) = b.placement(it)
            for ((bd, n) in held) byBinder.getOrPut(k) { mutableMapOf() }.merge(bd.name, n, Int::plus)
            unsortedBy.merge(k, u, Int::plus)
        }
        found = groups.map { g ->
            val named = (byBinder[g.id] ?: emptyMap<String, Int>()).entries.sortedBy { it.key.lowercase() }.map { "${it.key} ${it.value}" }
            val u = unsortedBy[g.id] ?: 0
            g to (named + listOfNotNull(if (u > 0) "Unsorted $u" else null)).joinToString(" · ")
        }
    }
    LaunchedEffect(Unit) { Telemetry.screen("binders") }
    LaunchedEffect(col.version) { PriceBook.load(col.items.values.map { it.cardId }.toSet()) }
    val heroes by HeroesStore.state.collectAsState()
    /** Each binder's hero cards, as the printings it holds. */
    var heroArt by remember { mutableStateOf<Map<String, List<CatalogPrinting>>>(emptyMap()) }
    LaunchedEffect(heroes, cat.generation, b.version, col.version) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        val wanted = b.binders.mapNotNull { x ->
            val h = heroes.heroes(HeroScope.InBinder(x.id))
            if (h.isEmpty()) null else Triple(x.id, h, b.itemsIn(x.id, col.items).sortedByDescending { it.qty }.map { it.cardId })
        }
        heroArt = withContext(Dispatchers.Default) { wanted.associate { (id, h, held) -> id to HeroArt.printings(h, held, db) } }
    }
    val (by, unsorted) = remember(col.version, b.version) { b.totals(col.items) }
    T1Screen {
        Bar("Binders", subtitle = "${b.binders.size} · ${b.binders.count { it.forTrade }} for trade", onBack = onBack)
        (b.error ?: col.error)?.let { Notice(it, error = true) }
        if (col.items.isNotEmpty()) SearchBand(query, "Find a card in your binders") { query = it }
        if (CardName.norm(query).isNotEmpty()) Hairlines(Modifier.weight(1f)) {
            item { Section("Cards · ${found.size}") }
            if (found.isEmpty()) item { ListRow("No cards you own match") }
            items(found, key = { it.first.id }) { (g, place) ->
                CardRow(g.cover, g.name, place, onClick = { if (g.known) onCard(g.id) }) {
                    Text("${g.qty}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                }
            }
        } else Hairlines(Modifier.weight(1f)) {
            item { ListRow("New binder", "A box, a deck box, a trade binder", onClick = { creating = true }) }
            item {
                ListRow("Unsorted", "Copies not in a binder", onClick = { onOpen(UNSORTED) }) {
                    Text(count(unsorted), color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                }
            }
            if (b.binders.any { it.forTrade }) item(key = "share") { ShareRow(ShareTarget.ForTrade, "binders") }
            items(b.binders, key = { it.id }) { x ->
                val v = remember(col.version, b.version, pricesVersion) { value(b.itemsIn(x.id, col.items)) }
                HeroListRow(heroArt[x.id] ?: emptyList(), x.name, listOfNotNull(if (x.forTrade) "For trade" else null, PriceBook.text(v)).joinToString(" · ").ifEmpty { null },
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
    var keys by remember { mutableStateOf<Map<String, GroupKeys>>(emptyMap()) }
    val grouping = rememberCardGrouping(GroupingKey.BINDER, CardGrouping.None, list = false)
    val sort = rememberCardSort(SortPref.BINDER, CardSort.Screen.Binder)
    var query by remember { mutableStateOf("") }
    var menu by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    var askDelete by remember { mutableStateOf(false) }
    var adding by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val printingsState = remember { mutableStateOf(PrintingsDisclosure()) }
    var printings by printingsState
    val layout = rememberCardLayout("binder.layout", "binder.grid")
    var viewMenu by remember { mutableStateOf(false) }
    val heroes by HeroesStore.state.collectAsState()
    SearchUsed(query, "binder")
    val items = remember(col.version, b.version, id) { b.itemsIn(if (unsorted) null else id, col.items) }
    LaunchedEffect(Unit) {
        Telemetry.screen("binder")
        CatalogStore.load(userInitiated = true)
    }
    LaunchedEffect(items, cat.generation) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        val (g, k) = withContext(Dispatchers.Default) {
            CardGroup.build(items, db).sortedWith(compareByDescending<CardGroup> { it.qty }.thenBy { it.norm }).let { it to GroupKeys.forGroups(it, db) }
        }
        groups = g
        keys = k
        PriceBook.load(items.map { it.cardId }.toSet())
    }
    val copies = items.sumOf { it.qty }
    val v = remember(items, pricesVersion) { value(items) }
    T1Screen {
        Bar(if (unsorted) "Unsorted" else binder?.name ?: "Binder",
            subtitle = listOfNotNull("${count(copies)} cards", if (binder?.forTrade == true) "For trade" else null, PriceBook.text(v)).joinToString(" · "),
            onBack = onBack) {
            BarAction("View") { viewMenu = true }
            if (binder != null) BarAction("Edit") { menu = true }
        }
        if (!unsorted && binder == null) Notice("This binder was deleted.")
        (error ?: b.error)?.let { Notice(it, error = true) }
        CatalogStatus(cat)
        Box(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp)) {
            T1TextField(query, { query = it }, placeholder = "Name or type")
        }
        // Built most copies first; Sort can reorder.
        val shown = sort.value.apply(if (CardName.norm(query).isEmpty()) groups else groups.filter { CardSearch.matches(query, it.name, it.type) }) {
            SortKey.of(it.name, keys[it.id], it.cover)
        }
        // Add cards and the empty notes stay at the top in every view.
        val top: @Composable () -> Unit = {
            Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                if (binder != null) ShareRow(ShareTarget("binder", binder.id, binder.name, binder.forTrade), "binder")
                if (unsorted || binder != null) {
                    ListRow("Add cards", if (unsorted) "New copies, or copies out of a binder" else "Move in copies you own, or add new ones", onClick = { adding = true })
                }
                if (shown.isEmpty() && groups.isNotEmpty()) ListRow("No cards match")
                if (groups.isEmpty() && cat.phase == "ready") {
                    Notice(if (unsorted) "Every copy is in a binder." else "No cards here yet. Add cards moves in copies you own or adds new ones; trades and imports can fill it too.")
                }
            }
        }
        // Group by: most copies first inside each group.
        val sections = groupSections(shown, grouping.value) { keys[it.id] }
        val grouped = grouping.value != CardGrouping.None
        fun title(key: String, cards: List<CardGroup>) = "${grouping.value.label(key)} · ${cards.sumOf { it.qty }}"
        fun tiles(cards: List<CardGroup>) = groupTiles(cards, printings.all, { !unsorted && heroes.isHero(it.id, HeroScope.InBinder(id)) }) { if (it.known) onCard(it.id) }
        if (layout.value == CardLayout.Grid) {
            CardGrid(Modifier.weight(1f)) { tile ->
                gridHeader("top") { top() }
                for ((key, cards) in sections) {
                    if (grouped) gridHeader("h-$key") { Section(title(key, cards)) }
                    gridItems(tiles(cards), key = { "t-${it.key}" }) { t -> CardTile(t.printing, t.qty, tile, onClick = t.onClick, finish = t.finish, hero = t.hero) }
                }
            }
        } else if (layout.value == CardLayout.Stacks) {
            BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
                val (cols, width) = stackColumns(maxWidth)
                // Grouped: one stack per group; None: stacks of ten.
                val stacks = if (grouped) sections.map { (key, cards) -> CardStackSpec("st|$key|${printings.all}", title(key, cards), tiles(cards)) }
                    else runStacks(tiles(shown), false, { "" }, "st|${printings.all}|").map { (key, title, run) -> CardStackSpec(key, title, run) }
                LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    item(key = "top") { top() }
                    stackRows("binder", stacks, cols, width)
                }
            }
        } else Hairlines(Modifier.weight(1f)) {
            item(key = "top") { top() }
            for ((key, cards) in sections) {
                if (grouped) item(key = "h-$key") { Section(title(key, cards)) }
                for (g in cards) {
                    val open = printings.open(g.id)
                    cardGroupRows(g, "${g.printings} printing${if (g.printings == 1) "" else "s"} · ${g.type}",
                        !unsorted && heroes.isHero(g.id, HeroScope.InBinder(id)), open,
                        toggle = {
                            printings = printings.toggle(g.id)
                            Telemetry.capture("printings_toggled", mapOf("expanded" to !open, "all" to false, "screen" to "binder"))
                        }) { if (g.known) onCard(g.id) }
                }
            }
        }
    }
    if (viewMenu) CardLayoutMenu(layout, "binder", printingsState, grouping, sort = sort, sorts = CardSort.Screen.Binder) { viewMenu = false }
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
    if (adding) BinderAddOverlay(if (unsorted) null else id, onClose = { adding = false })
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
 * Binder → Add cards: search the catalog; Move in takes one copy you own from elsewhere (`moveInSource`), + New adds a
 * new copy of the card's original printing straight into the binder (`binderId` null = Unsorted).
 */
@Composable
private fun BinderAddOverlay(binderId: String?, onClose: () -> Unit) {
    val col by CollectionStore.state.collectAsState()
    val b by BindersStore.state.collectAsState()
    val scope = rememberCoroutineScope()
    var query by remember { mutableStateOf("") }
    val result = rememberCardSearch(query)
    val hits = if (query.isBlank()) emptyList() else result?.hits ?: emptyList()
    val covers = result?.covers ?: emptyMap()
    var scanning by remember { mutableStateOf(false) }
    var addLang by remember { mutableStateOf(Languages.addLang) }
    var owned by remember { mutableStateOf<Map<Int, List<CollectionItem>>>(emptyMap()) }
    var last by remember { mutableStateOf<Pair<String, String>?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val condition = remember { T1App.instance.getSharedPreferences("library", android.content.Context.MODE_PRIVATE).getString("addCondition", "NM") ?: "NM" }
    val target = b.binder(binderId)?.name ?: "Unsorted"
    LaunchedEffect(Unit) { Telemetry.screen("binder_add") }
    LaunchedEffect(col.version) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        val items = col.items.values.toList()
        owned = withContext(Dispatchers.Default) {
            val ps = db.printings(items.map { it.cardId }.toSet())
            items.groupBy { ps[it.cardId]?.oracleIdx ?: -1 }
        }
    }
    fun run(label: String, work: suspend () -> String) {
        busy = true
        error = null
        scope.launch {
            runCatching { work() }.onSuccess { batch -> last = if (batch.isEmpty()) null else batch to label }.onFailure { error = it.message }
            busy = false
        }
    }
    androidx.compose.ui.window.Dialog(onDismissRequest = onClose,
        properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(T1.bg)) {
            T1Screen {
                Bar("Add to $target", onBack = onClose)
                error?.let { Notice(it, error = true) }
                last?.let { (batch, label) ->
                    Row(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Label(label, modifier = Modifier.weight(1f))
                        BarAction("Undo") { run("") { CollectionStore.undo(batch); "" } }
                    }
                }
                CardSearchBar(query, { query = it }, placeholder = "Card name, or Scryfall syntax", onScan = { scanning = true })
                CardSearchStatus(query, result)
                NewCopiesLanguageRow { addLang = it }
                Hairlines(Modifier.weight(1f)) {
                    if (query.isEmpty()) item {
                        Notice("Move in takes a copy you own from Unsorted or another binder. + New adds a new copy ($condition, original printing) to your collection, in $target. Scan adds the cards you scan, new, in $target.")
                    }
                    items(hits, key = { it.idx }) { o ->
                        val places = b.places(owned[o.idx] ?: emptyList())
                        val here = places.filter { it.from?.id == binderId }.sumOf { it.qty }
                        val where = places.filter { it.from?.id != binderId }.groupBy { it.from?.name ?: "Unsorted" }.mapValues { (_, v) -> v.sumOf { it.qty } }
                        val detail = if (places.isEmpty()) "Not in your collection"
                            else (listOfNotNull(if (here > 0) "$here here" else null) + where.entries.sortedBy { it.key }.map { "${it.key} ${it.value}" }).joinToString(" · ")
                        val source = moveInSource(places, binderId)
                        val p = covers[o.idx]
                        Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                            Box(Modifier.weight(1f)) { CardRow(p, o.name, detail) }
                            if (source != null) {
                                Box(Modifier.fillMaxHeight().background(T1.surfaceHover).clickable(enabled = !busy) {
                                    run("Moved 1 ${o.name} from ${b.binder(source.second)?.name ?: "Unsorted"}") {
                                        BindersStore.move(listOf(BinderMove(source.first, source.second, binderId, 1)))
                                    }
                                }.padding(horizontal = 12.dp), contentAlignment = Alignment.Center) { Label("Move in", color = T1.text) }
                            }
                            if (p != null) {
                                Box(Modifier.fillMaxHeight().background(T1.surfaceHover).clickable(enabled = !busy) {
                                    val finish = p.finishList.firstOrNull()?.wire ?: "nonfoil"
                                    val lang = Languages.forNew(p.lang, addLang)
                                    run("Added 1 ${o.name} · $condition${if (lang == "en") "" else " · ${lang.uppercase()}"}") {
                                        CollectionStore.apply(listOf(CollectionOp(p.cardId, finish, condition, lang, delta = 1, binderId = binderId))).batchId
                                    }
                                }.padding(horizontal = 12.dp), contentAlignment = Alignment.Center) { Label("+ New", color = T1.text) }
                            }
                        }
                    }
                }
                BigAction("Done") { onClose() }
            }
        }
    }
    // Scanned cards go in new, straight into this binder, as one batch (source "scan") that one Undo takes back.
    if (scanning) {
        CardScanOverlay("Scan into $target", "Add", owned = null, onDone = { cards ->
            scanning = false
            Telemetry.capture("scan_session_ended", mapOf("context" to "binder", "cards" to cards.size, "exact" to cards.count { it.exact }, "cancelled" to false))
            if (cards.isNotEmpty()) run("Added ${cards.size} scanned card${if (cards.size == 1) "" else "s"}") {
                CollectionStore.apply(cards.map { CollectionOp(it.printing.cardId, it.finish, it.condition, it.lang, delta = 1, binderId = binderId) }, source = "scan").batchId
            }
        }, onCancel = {
            scanning = false
            Telemetry.capture("scan_session_ended", mapOf("context" to "binder", "cards" to 0, "exact" to 0, "cancelled" to true))
        })
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

private data class WantRowView(val want: Want, val name: String, val printing: CatalogPrinting?, val type: String = "")
private data class MissingRowView(val line: MissingLine, val printing: CatalogPrinting?, val name: String, val oracleId: String?, val type: String = "")

@Composable
fun WantsScreen(onBack: () -> Unit, onCard: (String) -> Unit) {
    val col by CollectionStore.state.collectAsState()
    val b by BindersStore.state.collectAsState()
    val lists by ListsStore.state.collectAsState()
    val cat by CatalogStore.state.collectAsState()
    val prices by WantPricesStore.state.collectAsState()
    val scope = rememberCoroutineScope()
    var rows by remember { mutableStateOf<List<WantRowView>>(emptyList()) }
    var missing by remember { mutableStateOf<List<MissingRowView>>(emptyList()) }
    var adding by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<WantRowView?>(null) }
    var pricing by remember { mutableStateOf<Want?>(null) }
    var showAll by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var query by remember { mutableStateOf("") }
    var repointing by remember { mutableStateOf<Want?>(null) }
    SearchUsed(query, "wants")
    val context = androidx.compose.ui.platform.LocalContext.current
    var tcgplayer by remember { mutableStateOf(false) }
    var parts by remember { mutableStateOf<List<String>?>(null) }
    LaunchedEffect(Unit) { tcgplayer = TCGplayerCart.enabled() }
    fun open(url: String) {
        runCatching { context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url))) }
            .onFailure { error = it.message }
    }
    // Buy on TCGplayer (contract/tcgplayer-cart-2026-10-26.md): one part opens in the browser, several are a menu.
    fun buy(items: List<TCGplayerCart.Item>, from: String) {
        scope.launch {
            runCatching { TCGplayerCart.links(items) }
                .onSuccess { a ->
                    Telemetry.capture("tcgplayer_cart_opened", mapOf("from" to from, "lines" to a.lines, "parts" to a.urls.size))
                    when (a.urls.size) {
                        0 -> error = "Nothing to buy"
                        1 -> open(a.urls[0])
                        else -> parts = a.urls
                    }
                }
                .onFailure { error = it.message }
        }
    }
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
                WantRowView(w, o?.name ?: "Card not in local data yet", w.cardId?.let { printings[it] } ?: o?.let { db.covers(listOf(it.idx))[it.idx] }, o?.typeLine ?: "")
            }
            val lines = MissingView.lines(ls, owned, db.basicCardIds())
            val mp = db.printings(lines.map { it.cardId }.toSet())
            val mo = db.oracles(mp.values.map { it.oracleIdx }.toSet())
            shown to lines.map { l -> val o = mp[l.cardId]?.let { mo[it.oracleIdx] }; MissingRowView(l, mp[l.cardId], o?.name ?: "Card not in local data yet", o?.oracleId, o?.typeLine ?: "") }
        }
        rows = out.first
        missing = out.second
        PriceBook.load(wants.mapNotNull { it.cardId }.toSet())
        WantPricesStore.load()
    }
    fun run(ops: List<WantOp>, event: String? = null, props: Map<String, Any> = emptyMap()) {
        scope.launch { runCatching { BindersStore.applyWants(ops, event, props) }.onFailure { error = it.message } }
    }
    val wanted = rows.sumOf { it.want.qty }
    val short = missing.sumOf { it.line.short }
    val searching = CardName.norm(query).isNotEmpty()
    val shownWants = if (searching) rows.filter { CardSearch.matches(query, it.name, it.type) } else rows
    val shownMissing = if (searching) missing.filter { CardSearch.matches(query, it.name, it.type) } else missing
    T1Screen {
        Bar("Wants", subtitle = "$wanted wanted · $short missing", onBack = onBack)
        (error ?: b.error)?.let { Notice(it, error = true) }
        CatalogStatus(cat)
        if (rows.isNotEmpty() || missing.isNotEmpty()) SearchBand(query, "Name or type") { query = it }
        Hairlines(Modifier.weight(1f)) {
            item { ListRow("Add a want", "Any printing, or one in particular", onClick = { adding = true }) }
            prices.alerts?.let { on ->
                item(key = "alerts") {
                    ListRow("Price alerts", "A push when a want gets 15% cheaper or reaches your max") {
                        T1Switch(on) { scope.launch { WantPricesStore.setAlerts(it) } }
                    }
                }
            }
            if (tcgplayer && rows.isNotEmpty() && !searching) item(key = "tcgplayer") {
                ListRow("Buy on TCGplayer", "${rows.sumOf { it.want.qty }} cards into a cart, then Optimize", onClick = {
                    buy(rows.map { TCGplayerCart.Item(it.want.oracleId, it.want.cardId, it.want.qty) }, "wants")
                })
            }
            if (rows.isNotEmpty() && !searching) item(key = "share") { ShareRow(ShareTarget.Wants, "wants") }
            item { Section("Wanted · ${shownWants.size}") }
            if (shownWants.isEmpty() && searching) item { ListRow("No wants match") }
            else if (rows.isEmpty()) item { Notice("Cards you're after. Gets in a trade that match are marked, and confirming takes them off.") }
            items(shownWants, key = { "w-" + it.want.key }) { r ->
                val w = r.want
                val which = if (w.cardId == null) "Any printing" else listOfNotNull(r.printing?.setLabel, w.finish?.let { Finish.of(it)?.label }).joinToString(" · ")
                // contract/want-prices-2026-10-26.md: Now (From for any printing) and the week's trend on its own line.
                val now = prices.items[w.key]?.now ?: w.cardId?.let { PriceBook.usd(it, w.finish ?: "nonfoil") }
                val trend = prices.trend(w)
                CardRow(r.printing, r.name, WantPrices.detail(which, w.maxUsd, now, w.cardId == null),
                    note = trend?.text, noteAccent = trend?.dir == "down", onClick = { editing = r }) {
                    Text("${w.qty}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                }
            }
            item { Section(if (searching) "Missing from decks and cubes · ${shownMissing.size} match" else "Missing from decks and cubes · $short") }
            if (tcgplayer && missing.isNotEmpty() && !searching) item(key = "tcgplayer-missing") {
                ListRow("Buy missing on TCGplayer", "${missing.sumOf { it.line.short }} cards into a cart, then Optimize", onClick = {
                    buy(missing.map { TCGplayerCart.Item(cardId = it.line.cardId, qty = it.line.short) }, "missing")
                })
            }
            if (shownMissing.isEmpty() && searching) item { ListRow("Nothing missing matches") }
            else if (missing.isEmpty() && cat.phase == "ready") item { Notice("Your decks and cubes have every card they need.") }
            items(if (showAll) shownMissing else shownMissing.take(60), key = { "m-" + it.line.key }) { m ->
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
                            run(listOf(WantOp(o, delta = m.line.short)), "want_added", mapOf("any_printing" to true, "finish" to false, "has_max" to false, "from" to "missing"))
                        }.padding(horizontal = 14.dp), contentAlignment = Alignment.Center) { Label("Want", color = T1.text) }
                    }
                }
            }
            if (!showAll && shownMissing.size > 60) item { ListRow("Show all ${shownMissing.size}", onClick = { showAll = true }) }
        }
    }
    editing?.let { r ->
        val w = r.want
        T1Menu(r.name, buildList {
            add(T1MenuItem("One more") { run(listOf(WantOp(w.oracleId, w.cardId, w.finish, delta = 1)), "want_changed") })
            add(T1MenuItem("One fewer", enabled = w.qty > 1) { run(listOf(WantOp(w.oracleId, w.cardId, w.finish, delta = -1)), "want_changed") })
            add(T1MenuItem("Max price · ${w.maxUsd?.let { "$$it" } ?: "none"}") { pricing = w })
            add(T1MenuItem("Change printing · ${if (w.cardId == null) "any" else r.printing?.setLabel ?: "one"}") { repointing = w })
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
    if (adding) WantPickOverlay(onClose = { adding = false }, onScanned = { cards ->
        // Each scanned card is wanted once, any printing.
        run(cards.map { WantOp(it.oracle.oracleId, delta = 1) }, "want_added", mapOf("any_printing" to true, "finish" to false, "has_max" to false, "from" to "scan"))
    }) { o ->
        run(listOf(WantOp(o.oracleId, delta = 1)), "want_added", mapOf("any_printing" to true, "finish" to false, "has_max" to false, "from" to "search"))
    }
    parts?.let { urls ->
        T1Menu("Buy on TCGplayer · each adds to the same cart", urls.mapIndexed { i, u -> T1MenuItem(TCGplayerCart.partTitle(i, urls.size)) { open(u) } }) { parts = null }
    }
    repointing?.let { w -> WantPrintingOverlay(w.oracleId, replacing = w, onClose = { repointing = null }) { error = it } }
}

/** Search for a card to want: Want adds any printing; tapping the card picks one printing or finish. */
@Composable
private fun WantPickOverlay(onClose: () -> Unit, onScanned: (List<ScannedCard>) -> Unit, onPick: (CatalogOracle) -> Unit) {
    var query by remember { mutableStateOf("") }
    val result = rememberCardSearch(query)
    val hits = if (query.isBlank()) emptyList() else result?.hits ?: emptyList()
    val covers = result?.covers ?: emptyMap()
    var added by remember { mutableStateOf<String?>(null) }
    var picking by remember { mutableStateOf<CatalogOracle?>(null) }
    var scanning by remember { mutableStateOf(false) }
    androidx.compose.ui.window.Dialog(onDismissRequest = onClose,
        properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(T1.bg)) {
            T1Screen {
                Bar("Add a want", subtitle = added, onBack = onClose)
                CardSearchBar(query, { query = it }, placeholder = "Lightning Bolt, or Scryfall syntax", onScan = { scanning = true })
                CardSearchStatus(query, result)
                Hairlines(Modifier.weight(1f)) {
                    if (query.isEmpty()) item { Notice("Want adds any printing. Tap a card to want one printing or finish. Scan wants each card you scan, any printing.") }
                    items(hits, key = { it.idx }) { o ->
                        Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                            Box(Modifier.weight(1f)) {
                                CardRow(covers[o.idx], o.name, o.typeLine, onClick = { picking = o }) { Label("Printing") }
                            }
                            Box(Modifier.fillMaxHeight().background(T1.surfaceHover).clickable { onPick(o); added = "Wanted ${o.name}" }
                                .padding(horizontal = 14.dp), contentAlignment = Alignment.Center) { Label("Want", color = T1.text) }
                        }
                    }
                }
                BigAction("Done") { onClose() }
            }
        }
    }
    picking?.let { o -> WantPrintingOverlay(o.oracleId, from = "search", onClose = { picking = null }, onDone = { added = it }) { added = it } }
    if (scanning) {
        CardScanOverlay("Scan what you want", "Want", owned = null, onDone = { cards ->
            scanning = false
            Telemetry.capture("scan_session_ended", mapOf("context" to "wants", "cards" to cards.size, "exact" to cards.count { it.exact }, "cancelled" to false))
            if (cards.isNotEmpty()) {
                onScanned(cards)
                added = "Wanted ${cards.size} scanned card${if (cards.size == 1) "" else "s"}"
            }
        }, onCancel = {
            scanning = false
            Telemetry.capture("scan_session_ended", mapOf("context" to "wants", "cards" to 0, "exact" to 0, "cancelled" to true))
        })
    }
}

/**
 * Which printing of a card to want: any printing, one printing in any finish (tap the printing), or one printing in
 * one finish (its finish buttons). Adds one copy, or with `replacing` points that want at the pick, keeping its count
 * and max price.
 */
@Composable
fun WantPrintingOverlay(oracleId: String, replacing: Want? = null, from: String = "search", onClose: () -> Unit,
                        onDone: (String) -> Unit = {}, onFail: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    val pricesVersion by PriceBook.version.collectAsState()
    var name by remember { mutableStateOf("") }
    var printings by remember { mutableStateOf<List<CatalogPrinting>>(emptyList()) }
    var query by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { Telemetry.screen("want_printing") }
    LaunchedEffect(oracleId) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        val found = withContext(Dispatchers.Default) { db.oracle(oracleId)?.let { o -> o.name to db.printings(o.idx) } }
        name = found?.first ?: ""
        printings = found?.second ?: emptyList()
        PriceBook.load(printings.map { it.cardId }.toSet())
    }
    fun pick(p: CatalogPrinting?, finish: String?) {
        val label = p?.let { listOfNotNull(it.setLabel, finish?.let { f -> Finish.of(f)?.label }).joinToString(" ") } ?: name
        val ops: List<WantOp>
        val event: String
        val props = mutableMapOf<String, Any>("any_printing" to (p == null), "finish" to (finish != null))
        if (replacing != null) {
            ops = repointWant(replacing, p?.cardId, finish) ?: run { onClose(); return }
            event = "want_changed"
            props["printing"] = true
        } else {
            ops = listOf(WantOp(oracleId, p?.cardId, finish, delta = 1))
            event = "want_added"
            props["has_max"] = false
            props["from"] = from
        }
        busy = true
        scope.launch {
            runCatching { BindersStore.applyWants(ops, event, props) }
                .onSuccess { onClose(); onDone(if (replacing == null) "Wanted 1 $label" else "Now wanting $label") }
                .onFailure { onFail(it.message ?: "Couldn't save that want"); onClose() }
            busy = false
        }
    }
    val shown = if (query.isEmpty()) printings else printings.filter { CardSearch.matchesPrinting(query, it.set, it.cn, it.releasedAt) }
    val anyNow = replacing != null && replacing.cardId == null
    androidx.compose.ui.window.Dialog(onDismissRequest = onClose,
        properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(T1.bg)) {
            T1Screen {
                Bar(if (replacing == null) "Want which printing" else "Change printing", subtitle = name, onBack = onClose)
                if (printings.size > 8) SearchBand(query, "Set, number or year") { query = it }
                Hairlines(Modifier.weight(1f)) {
                    item {
                        ListRow("Any printing", "A get of any printing meets it", onClick = if (anyNow || busy) null else ({ pick(null, null) })) {
                            if (anyNow) Label("Current", color = T1.disabled)
                        }
                    }
                    item { Section(if (query.isEmpty()) "One printing · ${printings.size}" else "One printing · ${shown.size} of ${printings.size}") }
                    if (shown.isEmpty() && query.isNotEmpty()) item { ListRow("No printings match") }
                    items(shown, key = { it.cardId }) { p ->
                        val samePrinting = replacing?.cardId == p.cardId
                        val price = remember(pricesVersion, p.cardId) { PriceBook.usd(p.cardId, p.finishList.firstOrNull()?.wire ?: "nonfoil") }
                        val detail = listOfNotNull(if (samePrinting && replacing?.finish == null) "Current" else null, CatalogPack.RARITY_NAME[p.rarity],
                            p.releasedAt.take(4).ifEmpty { null }, if (p.original) "Original" else null, if (p.lang == "en") null else p.lang.uppercase(),
                            PriceBook.text(price)).joinToString(" · ")
                        Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                            Box(Modifier.weight(1f)) {
                                CardRow(p, p.setLabel, detail, onClick = if (busy || (samePrinting && replacing?.finish == null)) null else ({ pick(p, null) }))
                            }
                            // A finish button only matters when the printing comes in more than one.
                            if (p.finishList.size > 1) p.finishList.forEach { f ->
                                val same = samePrinting && replacing?.finish == f.wire
                                Box(Modifier.fillMaxHeight().background(T1.surfaceHover).clickable(enabled = !same && !busy) { pick(p, f.wire) }
                                    .padding(horizontal = 10.dp), contentAlignment = Alignment.Center) {
                                    Label(if (same) "Current" else f.label, color = if (same) T1.disabled else T1.text)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
