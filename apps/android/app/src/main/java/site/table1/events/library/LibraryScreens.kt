package site.table1.events.library

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.items as gridItems
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import site.table1.events.T1App
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry
import java.text.NumberFormat
import java.util.Currency

/* Library (Collection tab). Progressive disclosure: the home screen is a summary; the list, a card's
   printings and its history are each one tap deeper. Built ahead of the Figma Library screens on the
   existing kit (same as the web client); restyle once those land. */

internal fun money(n: Double?, code: String): String {
    if (n == null) return "—"
    val f = NumberFormat.getCurrencyInstance()
    f.currency = Currency.getInstance(code)
    f.maximumFractionDigits = 0
    return f.format(n)
}

internal fun count(n: Int) = NumberFormat.getIntegerInstance().format(n)

@Composable
internal fun QuietRow(text: String) {
    Box(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 16.dp)) { Label(text) }
}

/** The catalog's state as a row, or nothing once it's ready. */
@Composable
internal fun CatalogStatus(state: CatalogState) {
    when (state.phase) {
        "ready" -> {}
        "failed" -> Notice(state.error ?: "Couldn't load card data", error = true)
        else -> QuietRow("Loading card data…")
    }
}

@Composable
internal fun Hairlines(modifier: Modifier = Modifier, content: LazyListScope.() -> Unit) {
    LazyColumn(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(1.dp), content = content)
}

@Composable
private fun ColumnScope.Filler() = Box(Modifier.weight(1f))

/* ── home ─────────────────────────────────────────────────────────────── */

@Composable
fun LibraryHomeScreen(foregrounds: Int, onAllCards: () -> Unit, onAdd: () -> Unit, onImportExport: () -> Unit, onDecks: () -> Unit,
                      onCubes: () -> Unit, onTrades: () -> Unit, onBinders: () -> Unit, onWants: () -> Unit, onMatches: () -> Unit) {
    val lists by ListsStore.state.collectAsState()
    val col by CollectionStore.state.collectAsState()
    val binders by BindersStore.state.collectAsState()
    val trades by TradesStore.state.collectAsState()
    val heroes by HeroesStore.state.collectAsState()
    val cat by CatalogStore.state.collectAsState()
    // Syncs on open and on every return to the Library or to the app.
    LaunchedEffect(foregrounds) {
        CollectionStore.sync()
        ListsStore.sync()
        TradesStore.load()
    }
    /** The collection's hero cards, shown on the All cards row. */
    var heroArt by remember { mutableStateOf<List<CatalogPrinting>>(emptyList()) }
    LaunchedEffect(heroes.heroes(HeroScope.Collection), cat.generation, col.version) {
        val db = CatalogStore.db ?: run { heroArt = emptyList(); return@LaunchedEffect }
        val ids = heroes.heroes(HeroScope.Collection)
        val held = col.items.values.sortedByDescending { it.qty }.map { it.cardId }
        heroArt = withContext(Dispatchers.Default) { HeroArt.printings(ids, held, db) }
    }
    val s = col.summary
    T1Screen {
        Bar("Collection", subtitle = if (col.syncing) "Syncing…" else null)
        col.error?.let { Notice(it, error = true) }
        Hairlines(Modifier.weight(1f)) {
            item {
                Column(Modifier.fillMaxWidth().background(T1.surface).padding(vertical = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Label("Cards")
                    Text(s?.let { count(it.totalQty) } ?: if (col.ready) "0" else "…", color = T1.text, fontFamily = T1.mono,
                        fontSize = 48.sp, letterSpacing = 4.sp)
                    Label(s?.let { "${count(it.uniqueCards)} distinct · ${money(it.valueUsd, "USD")} · ${money(it.valueEur, "EUR")}" } ?: " ")
                }
            }
            item {
                HeroListRow(heroArt, "All cards", s?.let { "${count(it.uniquePrintings)} printings" }, onClick = onAllCards) {
                    if (s != null) Text(count(s.uniqueCards), color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                }
            }
            item { ListRow("Add cards", "Search, Scryfall syntax or scan", onClick = onAdd) }
            item { ListRow("Import and export", "CSV from ManaBox, Moxfield and others", onClick = onImportExport) }
            item {
                val (by, unsorted) = remember(col.version, binders.version) { binders.totals(col.items) }
                val forTrade = binders.binders.filter { it.forTrade }.sumOf { by[it.id] ?: 0 }
                ListRow("Binders", if (binders.binders.isEmpty()) "Where your copies are, and what's for trade"
                    else "${count(forTrade)} cards for trade · ${count(unsorted)} unsorted", onClick = onBinders) {
                    Text("${binders.binders.size}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                }
            }
            item {
                val wanted = binders.liveWants.sumOf { it.qty }
                val missing = remember(col.version, lists.lists) {
                    MissingView.lines(lists.lists, col.items.values.groupBy { ownKey(it.cardId, it.finish) }.mapValues { (_, v) -> v.sumOf { it.qty } }).sumOf { it.short }
                }
                ListRow("Wants", "${count(wanted)} wanted · ${count(missing)} missing", onClick = onWants) {
                    Text(count(wanted), color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                }
            }
            item {
                val decks = lists.lists.filter { it.kind == ListKind.Deck }
                ListRow("Decks", if (decks.isEmpty()) "Build and track decks" else decks.take(3).joinToString(" · ") { it.name }, onClick = onDecks) {
                    Text("${decks.size}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                }
            }
            item {
                val cubes = lists.lists.filter { it.kind == ListKind.Cube }
                ListRow("Cubes", if (cubes.isEmpty()) "Build and track cubes" else cubes.joinToString(" · ") { it.name }, onClick = onCubes) {
                    Text("${cubes.size}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                }
            }
            item { TradeMatchesRow(onMatches) }
            item {
                val open = trades.trades.count { !it.confirmed }
                ListRow("Trades", if (open > 0) "$open open" else "Give and get, then confirm", onClick = onTrades) {
                    if (trades.loaded) Text("${trades.trades.size}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                }
            }
        }
    }
}

/* ── all cards ────────────────────────────────────────────────────────── */

/** One Oracle card in the collection, summed over its printings and copies. */
data class CardGroup(
    /** Oracle id, or the printing id when the card is newer than the local catalog. */
    val id: String, val known: Boolean, val name: String, val norm: String, val type: String,
    val qty: Int, val printings: Int, val lastSeq: Long,
    /** The printing shown as the card's picture: the one owned most. */
    val cover: CatalogPrinting? = null,
    /** Owned (printing id, finish) pairs, for prices. */
    val owned: List<Pair<String, String>> = emptyList(),
    /** The finish of the copies shown as the picture. */
    val coverFinish: String = "nonfoil",
    /** Copies per printing and finish (over conditions and languages), oldest printing first: the rows a card opens into. */
    val parts: List<Part> = emptyList(),
) {
    data class Part(val cardId: String, val finish: String, val qty: Int, val printing: CatalogPrinting?) {
        val id get() = "$cardId|$finish"
        val finishLabel get() = Finish.of(finish)?.label ?: finish
    }

    /** The most a single owned copy is worth (market, USD). */
    fun price(): Double? = owned.mapNotNull { (id, f) -> PriceBook.usd(id, f) }.maxOrNull()

    companion object {
        fun build(items: Collection<CollectionItem>, db: CatalogDb): List<CardGroup> {
            val printings = db.printings(items.map { it.cardId }.toSet())
            val oracles = db.oracles(printings.values.map { it.oracleIdx }.toSet())
            return items.groupBy { it.cardId.let { id -> printings[id]?.let { p -> oracles[p.oracleIdx]?.oracleId } } ?: it.cardId }
                .map { (key, group) ->
                    val o = printings[group[0].cardId]?.let { oracles[it.oracleIdx] }
                    val coverItem = group.filter { printings[it.cardId] != null }.maxByOrNull { it.qty }
                    val parts = group.groupBy { it.cardId to it.finish }.map { (k, its) -> Part(k.first, k.second, its.sumOf { it.qty }, printings[k.first]) }
                        .sortedWith { a, b ->
                            val pa = a.printing; val pb = b.printing
                            when {
                                pa == null || pb == null -> if (pa == null && pb == null) 0 else if (pa == null) 1 else -1
                                pa.cardId != pb.cardId -> CatalogPrinting.oldestFirst.compare(pa, pb)
                                else -> (Finish.of(a.finish)?.ordinal ?: 9) - (Finish.of(b.finish)?.ordinal ?: 9)
                            }
                        }
                    CardGroup(key, o != null, o?.name ?: "Card not in local data yet", o?.norm ?: "", o?.typeLine ?: group[0].cardId,
                        group.sumOf { it.qty }, group.map { it.cardId }.toSet().size, group.maxOf { it.seq },
                        coverItem?.let { printings[it.cardId] }, group.map { it.cardId to it.finish }, coverItem?.finish ?: "nonfoil", parts)
                }
        }
    }
}

/** A card's collapsed row (and, open, one row per printing and finish under it) in All cards and binders. */
fun LazyListScope.cardGroupRows(g: CardGroup, detail: String, hero: Boolean, open: Boolean, toggle: () -> Unit, tap: () -> Unit) {
    item(key = g.id) {
        WithChevron(g.parts.size, open, hero, toggle) {
            CardRow(g.cover, g.name, detail, onClick = tap, finish = g.coverFinish, hero = hero) {
                Text("${g.qty}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
            }
        }
    }
    if (open && g.parts.size > 1) items(g.parts, key = { "${g.id}|${it.id}" }) { part ->
        CardRow(part.printing, listOfNotNull(part.printing?.setLabel, if (part.finish == "nonfoil") null else part.finishLabel).joinToString(" · "),
            PriceBook.text(PriceBook.usd(part.cardId, part.finish)), onClick = tap, finish = part.finish, indent = true) {
            Text("${part.qty}", color = T1.muted, fontFamily = T1.mono, fontSize = 15.sp)
        }
    }
}

/** Grid and stacks: one card per Oracle card, or with every printing expanded, one per printing and finish. */
internal fun groupTiles(shown: List<CardGroup>, all: Boolean, isHero: (CardGroup) -> Boolean, open: (CardGroup) -> Unit): List<StackCard> =
    shown.flatMap { g ->
        val hero = isHero(g)
        if (!all || g.parts.size < 2) listOf(StackCard(g.id, g.cover, g.name, g.qty, finish = g.coverFinish, hero = hero) { open(g) })
        else g.parts.map { StackCard("${g.id}|${it.id}", it.printing, g.name, it.qty, finish = it.finish, hero = hero) { open(g) } }
    }

@Composable
fun AllCardsScreen(onBack: () -> Unit, onOpen: (String) -> Unit, onAdd: () -> Unit) {
    val col by CollectionStore.state.collectAsState()
    val cat by CatalogStore.state.collectAsState()
    var groups by remember { mutableStateOf<List<CardGroup>?>(null) }
    var query by remember { mutableStateOf("") }
    val prefs = remember { T1App.instance.getSharedPreferences("library", android.content.Context.MODE_PRIVATE) }
    // 0 recent, 1 price, 2 set
    var sort by remember { mutableStateOf(prefs.getInt("allCards.sort", 0)) }
    val pricesVersion by PriceBook.version.collectAsState()
    val layout = rememberCardLayout("allCards.layout", "allCards.grid")
    var viewMenu by remember { mutableStateOf(false) }
    val printings = remember { mutableStateOf(PrintingsDisclosure()) }
    val heroes by HeroesStore.state.collectAsState()
    LaunchedEffect(Unit) { CatalogStore.load(userInitiated = true) }
    LaunchedEffect(col.version, cat.generation) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        val items = col.items.values.toList()
        groups = withContext(Dispatchers.Default) { CardGroup.build(items, db) }
        PriceBook.load(items.map { it.cardId })
    }
    val shown = remember(groups, query, sort, pricesVersion) {
        val n = CardName.norm(query)
        val list = (groups ?: emptyList()).let { g -> if (n.isEmpty()) g else g.filter { it.norm.contains(n) || CardName.norm(it.type).contains(n) } }
        when (sort) {
            1 -> {
                // No price yet reads as the most valuable: those are the cards worth checking first.
                val p = list.associate { it.id to priceRank(it.price()) }
                list.sortedWith(compareByDescending<CardGroup> { p[it.id] }.thenBy { it.norm })
            }
            // Newest set first; within a set, collector number order.
            2 -> list.sortedWith(compareByDescending<CardGroup> { it.cover?.releasedAt ?: "" }.thenBy { it.cover?.set ?: "" }
                .thenBy { it.cover?.cn?.trim { c -> c.isLetter() }?.toIntOrNull() ?: Int.MAX_VALUE }.thenBy { it.norm })
            else -> list.sortedWith(compareByDescending<CardGroup> { it.lastSeq }.thenBy { it.norm })
        }
    }
    fun detail(g: CardGroup): String {
        val price = PriceBook.text(g.price())
        if (sort == 2 && g.cover != null) return listOfNotNull(g.cover.setLabel, price).joinToString(" · ")
        return listOfNotNull(price, "${g.printings} printing${if (g.printings == 1) "" else "s"}", g.type).joinToString(" · ")
    }
    T1Screen {
        Bar("All cards", subtitle = col.summary?.let { "${count(it.totalQty)} cards" }, onBack = onBack) {
            BarAction("View") { viewMenu = true }
        }
        col.error?.let { Notice(it, error = true) }
        CatalogStatus(cat)
        Box(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp)) {
            T1TextField(query, { query = it }, placeholder = "Name or type")
        }
        T1Segmented(listOf("Recent", "Price", "Set"), sort) { sort = it; prefs.edit().putInt("allCards.sort", it).apply() }
        val g = groups
        if (cat.phase == "ready" && g != null) {
            if (g.isEmpty() && col.ready) ListRow("No cards yet", "Add your first card", onClick = onAdd)
            if (g.isNotEmpty() && shown.isEmpty()) ListRow("No matches", "Nothing in your collection by that name or type")
            if (layout.value == CardLayout.Stacks) {
                // Stacks follow the sort: one per set when sorted by set, otherwise runs of ten in sort order.
                val stacks = remember(shown, sort, printings.value.all, heroes) {
                    val tiles = groupTiles(shown, printings.value.all, { heroes.isHero(it.id, HeroScope.Collection) }) { if (it.known) onOpen(it.id) }
                    runStacks(tiles, sort == 2, { it.printing?.set ?: "" }, "$sort|${printings.value.all}|").map { (key, title, run) ->
                        CardStackSpec(key, title, run)
                    }
                }
                BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
                    val (cols, width) = stackColumns(maxWidth)
                    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = 1.dp)) { stackRows("all", stacks, cols, width) }
                }
            } else if (layout.value == CardLayout.Grid) {
                CardGrid(Modifier.weight(1f)) { tile ->
                    val tiles = groupTiles(shown, printings.value.all, { heroes.isHero(it.id, HeroScope.Collection) }) { if (it.known) onOpen(it.id) }
                    gridItems(tiles, key = { it.key }) { t ->
                        CardTile(t.printing, t.qty, tile, onClick = t.onClick, finish = t.finish, hero = t.hero)
                    }
                }
            } else {
                Hairlines(Modifier.weight(1f)) {
                    for (row in shown) {
                        val open = printings.value.open(row.id)
                        cardGroupRows(row, detail(row), heroes.isHero(row.id, HeroScope.Collection), open,
                            toggle = {
                                printings.value = printings.value.toggle(row.id)
                                Telemetry.capture("printings_toggled", mapOf("expanded" to !open, "all" to false, "screen" to "all_cards"))
                            }) { if (row.known) onOpen(row.id) }
                    }
                }
            }
        } else {
            Filler()
        }
    }
    if (viewMenu) CardLayoutMenu(layout, "all_cards", printings) { viewMenu = false }
}

/* ── add (search) ─────────────────────────────────────────────────────── */

@Composable
fun AddCardsScreen(onBack: () -> Unit, onOpen: (String) -> Unit) {
    val cat by CatalogStore.state.collectAsState()
    val scope = rememberCoroutineScope()
    var scanning by remember { mutableStateOf(false) }
    var scanned by remember { mutableStateOf<Pair<String, String>?>(null) } // batch id, label
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf("") }
    val result = rememberCardSearch(query)
    val hits = if (query.isBlank()) emptyList() else result?.hits ?: emptyList()
    val covers = result?.covers ?: emptyMap()
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) {
        CatalogStore.load(userInitiated = true)
        runCatching { focus.requestFocus() }
    }
    T1Screen {
        Bar("Add cards", onBack = onBack)
        CatalogStatus(cat)
        error?.let { Notice(it, error = true) }
        scanned?.let { (batchId, label) ->
            Row(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Label(label, Modifier.weight(1f))
                BarAction(if (busy) "Undoing…" else "Undo") {
                    if (busy) return@BarAction
                    busy = true
                    scope.launch {
                        runCatching { CollectionStore.undo(batchId) }.onSuccess { scanned = null }.onFailure { error = it.message }
                        busy = false
                    }
                }
            }
        }
        Box(Modifier.focusRequester(focus)) {
            CardSearchBar(query, { query = it }, placeholder = "Lightning Bolt, or t:dragon c:r", label = "Card", onScan = { scanning = true },
                onSubmit = { hits.firstOrNull()?.let { onOpen(it.oracleId) } })
        }
        CardSearchStatus(query, result)
        Hairlines(Modifier.weight(1f)) {
            if (cat.phase == "ready" && result != null && CardName.norm(query).length >= 2 && hits.isEmpty() && !CardQuery.hasSyntax(query)) item { QuietRow("No card by that name") }
            items(hits, key = { it.idx }) { o ->
                CardRow(covers[o.idx], o.name, if (o.manaCost.isEmpty()) o.typeLine else "${o.typeLine} · ${o.manaCost}", onClick = { onOpen(o.oracleId) }) {
                    Text("${o.printings}", color = T1.muted, fontFamily = T1.mono, fontSize = 15.sp)
                }
            }
        }
    }
    // Scan session: every card goes in as one batch (source "scan") when it's done, so one Undo takes it back.
    if (scanning) {
        CardScanOverlay("Scan cards", "Add", owned = null, onDone = { cards ->
            scanning = false
            Telemetry.capture("scan_session_ended", mapOf("context" to "add", "cards" to cards.size, "exact" to cards.count { it.exact }, "cancelled" to false))
            scope.launch {
                runCatching { CollectionStore.apply(cards.map { CollectionOp(it.printing.cardId, it.finish, it.condition, delta = 1) }, source = "scan") }
                    .onSuccess { scanned = it.batchId to "Added ${cards.size} scanned card${if (cards.size == 1) "" else "s"}"; error = null }
                    .onFailure { error = it.message }
            }
        }, onCancel = {
            scanning = false
            Telemetry.capture("scan_session_ended", mapOf("context" to "add", "cards" to 0, "exact" to 0, "cancelled" to true))
        })
    }
}

/* ── card detail ──────────────────────────────────────────────────────── */

@Serializable
private data class PrintingPrice(
    val id: String,
    @SerialName("set_name") val setName: String? = null,
    val usd: Double? = null,
    @SerialName("usd_foil") val usdFoil: Double? = null,
    val eur: Double? = null,
    @SerialName("eur_foil") val eurFoil: Double? = null,
) {
    fun text(finish: String): String? {
        val nonfoil = finish == Finish.Nonfoil.wire
        val parts = listOfNotNull((if (nonfoil) usd else usdFoil)?.let { "$$it" }, (if (nonfoil) eur else eurFoil)?.let { "€$it" })
        return parts.ifEmpty { null }?.joinToString(" · ")
    }
}

/** Where card detail was opened from: that deck/cube's lines or that binder's copies (or Unsorted's) come first, each
 *  with Change printing (contract/change-printing-2026-10-18.md). */
sealed interface CardContext {
    data class InList(val listId: String) : CardContext
    data class InBinder(val binderId: String) : CardContext
}

@Composable
fun CardDetailScreen(oracleId: String, onBack: () -> Unit, context: CardContext? = null) {
    val col by CollectionStore.state.collectAsState()
    val lists by ListsStore.state.collectAsState()
    /** The Change printing screen over this one, and its screen name. */
    var changing by remember { mutableStateOf<Pair<PrintingTarget, String>?>(null) }
    val cat by CatalogStore.state.collectAsState()
    val scope = rememberCoroutineScope()
    var oracle by remember { mutableStateOf<CatalogOracle?>(null) }
    var printings by remember { mutableStateOf<List<CatalogPrinting>>(emptyList()) }
    var looked by remember { mutableStateOf(false) }
    var prices by remember { mutableStateOf<Map<String, PrintingPrice>>(emptyMap()) }
    var busy by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var last by remember { mutableStateOf<Pair<String, String>?>(null) } // batch id, label
    var showAll by remember { mutableStateOf(false) }
    var open by remember { mutableStateOf<String?>(null) }
    var history by remember { mutableStateOf<List<HistoryEntry>?>(null) }
    /** A printing tapped in the list, shown large in place of the owned one. */
    var preview by remember { mutableStateOf<CatalogPrinting?>(null) }
    val prefs = remember { T1App.instance.getSharedPreferences("library", android.content.Context.MODE_PRIVATE) }
    /** Condition new copies go in as (remembered; the scanner uses it too). */
    var addCondition by remember { mutableStateOf(prefs.getString("addCondition", "NM") ?: "NM") }
    /** Moving copies of one owned item to another condition, when there's more than one copy. */
    var moving by remember { mutableStateOf<Pair<CollectionItem, String>?>(null) }
    val binders by BindersStore.state.collectAsState()
    /** Moving copies of one owned item between binders, and wanting the card. */
    var sorting by remember { mutableStateOf<CollectionItem?>(null) }
    var wanting by remember { mutableStateOf(false) }
    var pickingPrinting by remember { mutableStateOf(false) }
    var note by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) { CatalogStore.load(userInitiated = true) }
    LaunchedEffect(cat.generation) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        val found = withContext(Dispatchers.Default) { db.oracle(oracleId)?.let { it to db.printings(it.idx) } }
        oracle = found?.first
        printings = found?.second?.sortedWith(CatalogPrinting.oldestFirst) ?: emptyList()
        looked = true
    }
    LaunchedEffect(oracleId) {
        runCatching {
            T1App.supabase.postgrest.rpc("card_printings", buildJsonObject { put("p_oracle_id", oracleId) }).decodeAs<List<PrintingPrice>>()
        }.onSuccess { rows -> prices = rows.associateBy { it.id } }
    }
    LaunchedEffect(open, col.version) {
        val id = open ?: run { history = null; return@LaunchedEffect }
        runCatching { CollectionStore.history(id) }.onSuccess { history = it }.onFailure { error = it.message }
    }

    val byId = remember(printings) { printings.associateBy { it.cardId } }
    val owned = remember(byId, col.version) {
        col.items.values.mapNotNull { it -> byId[it.cardId]?.let { p -> it to p } }
            .sortedWith { a, b -> if (a.second.cardId != b.second.cardId) CatalogPrinting.oldestFirst.compare(a.second, b.second) else a.first.key.compareTo(b.first.key) }
    }
    val total = owned.sumOf { it.first.qty }

    fun change(key: String, label: String, ops: List<CollectionOp>) {
        busy = key
        error = null
        scope.launch {
            runCatching { CollectionStore.apply(ops) }
                .onSuccess { last = it.batchId to label }
                .onFailure { error = it.message }
            busy = null
        }
    }

    fun moveCondition(it: CollectionItem, p: CatalogPrinting, to: String, n: Int) {
        moving = null
        change(it.key, "Moved $n ${p.setLabel} to $to", listOf(
            CollectionOp(it.cardId, it.finish, it.condition, it.lang, delta = -n),
            CollectionOp(it.cardId, it.finish, to, it.lang, delta = n),
        ))
    }
    moving?.let { (it, to) ->
        val p = byId[it.cardId]
        if (p != null) {
            T1Menu("Mark as ${Conditions.name(to).lowercase()}", listOf(
                T1MenuItem("One copy") { moveCondition(it, p, to, 1) },
                T1MenuItem("All ${it.qty} copies") { moveCondition(it, p, to, it.qty) },
            )) { moving = null }
        }
    }

    sorting?.let { it ->
        BinderMoveFlow(it, byId[it.cardId]?.setLabel ?: "card", onClose = { sorting = null }) { label -> sorting = null; note = label; last = null }
    }
    if (wanting) {
        val o = oracle
        val shown = preview ?: owned.firstOrNull()?.second ?: printings.firstOrNull()
        fun want(p: CatalogPrinting?) {
            if (o == null) return
            scope.launch {
                runCatching {
                    BindersStore.applyWants(listOf(WantOp(o.oracleId, cardId = p?.cardId, delta = 1)), "want_added",
                        mapOf("any_printing" to (p == null), "finish" to false, "has_max" to false, "from" to "card"))
                }.onSuccess { note = "Wanted 1 ${p?.setLabel ?: o.name}"; last = null }.onFailure { error = it.message }
            }
        }
        T1Menu("Want ${o?.name ?: "this card"}", listOfNotNull(
            T1MenuItem("Any printing") { want(null) },
            shown?.let { p -> T1MenuItem("Only ${p.setLabel}") { want(p) } },
            T1MenuItem("Pick a printing…") { pickingPrinting = true },
        )) { wanting = false }
    }
    changing?.let { (target, screen) ->
        ChangePrintingOverlay(target, screen, onClose = { changing = null }) { batch, label -> last = batch to label; note = null; error = null }
    }
    // Opened from a deck/cube: this card's lines there; from a binder (or Unsorted): this card's copies there.
    val ctxList = (context as? CardContext.InList)?.let { c -> lists.lists.firstOrNull { it.id == c.listId } }
    val ctxLines = ctxList?.entries?.mapNotNull { e -> byId[e.cardId]?.let { e to it } }
        ?.sortedBy { CardList.BOARD_ORDER.indexOf(it.first.board) } ?: emptyList()
    val ctxBinder = (context as? CardContext.InBinder)?.binderId
    val ctxCopies = ctxBinder?.let { b ->
        owned.mapNotNull { (it, p) -> PrintingChange.places(it, binders).firstOrNull { pl -> pl.place == b }?.qty?.let { q -> Triple(it, p, q) } }
    } ?: emptyList()
    val ctxPrinting = ctxLines.firstOrNull()?.second ?: ctxCopies.firstOrNull()?.second
    fun changeOwned(it: CollectionItem, place: String?) { changing = PrintingTarget.Owned(it, place) to "item_printing" }

    if (pickingPrinting) oracle?.let { o ->
        WantPrintingOverlay(o.oracleId, from = "card", onClose = { pickingPrinting = false }, onDone = { note = it; last = null }) { error = it }
    }

    T1Screen {
        Bar(oracle?.name ?: "Card", subtitle = oracle?.let { "$total in collection" }, onBack = onBack)
        (error ?: col.error ?: binders.error)?.let { Notice(it, error = true) }
        note?.takeIf { last == null }?.let { Notice(it) }
        CatalogStatus(cat)
        if (looked && oracle == null && cat.phase == "ready") Notice("That card isn't in the card data.", error = true)
        last?.let { (batchId, label) ->
            Row(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Label(label, Modifier.weight(1f))
                BarAction(if (busy == "undo") "Undoing…" else "Undo") {
                    if (busy == "undo") return@BarAction
                    busy = "undo"
                    scope.launch {
                        runCatching { CollectionStore.undo(batchId) }.onSuccess { last = null }.onFailure { error = it.message }
                        busy = null
                    }
                }
            }
        }
        val o = oracle
        if (o == null) {
            Filler()
            return@T1Screen
        }
        Hairlines(Modifier.weight(1f)) {
            item { Hero(o, preview ?: ctxPrinting ?: owned.firstOrNull()?.second ?: printings.firstOrNull()) }
            if (context is CardContext.InList) {
                item { Section("In ${ctxList?.name ?: "this list"} · ${ctxLines.sumOf { it.first.qty }}") }
                if (ctxLines.isEmpty()) item { QuietRow("Not in this ${if (ctxList?.kind == ListKind.Cube) "cube" else "deck"} any more.") }
                if (ctxList != null) items(ctxLines, key = { (e, _) -> "line|${e.board}|${e.cardId}|${e.finish}" }) { (e, p) ->
                    CardRow(p, "${p.setLabel} · ${Finish.of(e.finish)?.label ?: e.finish}", ctxList.boardTitle(e.board), finish = e.finish,
                        onClick = { changing = PrintingTarget.ListLine(ctxList.id, e.cardId, e.board, e.finish) to "list_printing" }) { ChangeCount(e.qty) }
                }
            }
            if (ctxBinder != null) {
                item { Section("In ${if (ctxBinder == UNSORTED) "Unsorted" else binders.binder(ctxBinder)?.name ?: "Binder"} · ${ctxCopies.sumOf { it.third }}") }
                if (ctxCopies.isEmpty()) item { QuietRow("None here any more.") }
                // Keys apart from In collection's below, which lists the same items.
                items(ctxCopies, key = { "in|" + it.first.key }) { (it, p, q) ->
                    CardRow(p, "${p.setLabel} · ${it.finishLabel}", listOfNotNull(it.condition, if (it.lang == "en") null else it.lang.uppercase()).joinToString(" · "),
                        finish = it.finish, onClick = { changeOwned(it, ctxBinder) }) { ChangeCount(q) }
                }
            }
            item { Section("In collection · ${owned.size}") }
            if (owned.isEmpty()) item { QuietRow("None yet. Pick a printing below.") }
            items(owned, key = { it.first.key }) { (it, p) ->
                val price = prices[it.cardId]
                val detail = listOfNotNull(price?.setName, it.condition, it.lang.uppercase(), price?.text(it.finish)).joinToString(" · ")
                Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min).background(T1.surface), horizontalArrangement = Arrangement.spacedBy(1.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Row(Modifier.weight(1f).clickable { open = if (open == it.cardId) null else it.cardId; preview = p }
                            .padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp),
                            verticalAlignment = Alignment.CenterVertically) {
                            CardArt(p, 36.dp, finish = it.finish)
                            Column {
                                Text("${p.setLabel} · ${it.finishLabel}", color = T1.text, fontFamily = T1.mono, fontSize = 13.sp,
                                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Label(detail)
                                binders.placementText(it)?.let { t -> Label(t, color = if (binders.forTrade(it.key).first > 0) T1.accent else T1.muted) }
                            }
                        }
                        Text("${it.qty}", Modifier.padding(horizontal = 12.dp), color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                        StepSquare("−", busy != it.key) {
                            change(it.key, "Removed 1 ${p.setLabel}", listOf(CollectionOp(it.cardId, it.finish, it.condition, it.lang, delta = -1)))
                        }
                        StepSquare("+", busy != it.key) {
                            change(it.key, "Added 1 ${p.setLabel}", listOf(CollectionOp(it.cardId, it.finish, it.condition, it.lang, delta = 1)))
                        }
                    }
                    if (open == it.cardId) {
                        // Condition of these copies: pick another to move one copy (or all of them) there.
                        T1Segmented(Conditions.all, Conditions.all.indexOf(it.condition), enabled = busy != it.key) { i ->
                            val to = Conditions.all[i]
                            if (to != it.condition) {
                                if (it.qty == 1) moveCondition(it, p, to, 1) else moving = it to to
                            }
                        }
                        ListRow("Change printing", "Or finish · keeps condition and binder", onClick = { changeOwned(it, null) }) { Label(p.setLabel, color = T1.text) }
                        ListRow("Move", binders.placementText(it) ?: "Unsorted ${it.qty}", onClick = { sorting = it }) { Label("Binders", color = T1.text) }
                        Column(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Label("History · ${p.setLabel}")
                            val h = history
                            when {
                                h == null -> Label("Loading…")
                                h.isEmpty() -> Label("No changes yet")
                                else -> h.forEach { e ->
                                    Text("${e.at.take(10)} · ${if (e.delta > 0) "+${e.delta}" else "${e.delta}"} ${Finish.of(e.finish)?.label ?: e.finish} · ${e.source} → ${e.qtyAfter}",
                                        color = if (e.undone) T1.disabled else T1.text, fontFamily = T1.mono, fontSize = 12.sp,
                                        textDecoration = if (e.undone) TextDecoration.LineThrough else null)
                                }
                            }
                        }
                    }
                }
            }
            item {
                val n = binders.liveWants.filter { it.oracleId == o.oracleId }.sumOf { it.qty }
                ListRow(if (n > 0) "Wanted · $n" else "Add to wants", if (n > 0) "Want one more" else "Trades marks it when you get one",
                    onClick = { wanting = true })
            }
            HeroScope.of(context)?.let { hs -> item { HeroToggleRow(o, hs, lists.lists) { error = it } } }
            item { Section("Add a printing · ${printings.size}") }
            item {
                T1Segmented(Conditions.all, Conditions.all.indexOf(addCondition).coerceAtLeast(0)) { i ->
                    addCondition = Conditions.all[i]
                    prefs.edit().putString("addCondition", addCondition).apply()
                }
            }
            items(if (showAll) printings else printings.take(12), key = { "add-" + it.cardId }) { p ->
                val price = prices[p.cardId]
                val detail = listOfNotNull(price?.setName, CatalogPack.RARITY_NAME[p.rarity], p.releasedAt.take(4).ifEmpty { null }).joinToString(" · ")
                Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min).background(T1.surface), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    // Tapping the art or name shows this printing large at the top.
                    Row(Modifier.weight(1f).clickable { preview = p }.padding(horizontal = 16.dp, vertical = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        CardArt(p, 36.dp)
                        Column {
                            Text(if (p.lang == "en") p.setLabel else "${p.setLabel} · ${p.lang.uppercase()}", color = T1.text, fontFamily = T1.mono,
                                fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Label(detail)
                        }
                    }
                    p.finishList.forEach { f ->
                        val k = "${p.cardId}|${f.wire}"
                        Box(Modifier.fillMaxHeight().background(T1.surfaceHover)
                            .clickable(enabled = busy != k) {
                                change(k, "Added 1 ${p.setLabel} ${f.label} · $addCondition", listOf(CollectionOp(p.cardId, f.wire, addCondition, delta = 1)))
                            }
                            .padding(horizontal = 12.dp), contentAlignment = Alignment.Center) {
                            Label("+ ${if (f == Finish.Nonfoil) "Card" else f.label}", color = if (busy == k) T1.disabled else T1.text)
                        }
                    }
                }
            }
            if (!showAll && printings.size > 12) item { ListRow("Show all ${printings.size} printings", onClick = { showAll = true }) }
        }
    }
}

/** Makes the card a hero of where it was opened from: the deck or cube, the binder, or (from anywhere else) the
 *  collection. */
@Composable
private fun HeroToggleRow(o: CatalogOracle, scope: HeroScope, lists: List<CardList>, onFull: (String) -> Unit) {
    val heroes by HeroesStore.state.collectAsState()
    val binders by BindersStore.state.collectAsState()
    val on = heroes.isHero(o.oracleId, scope)
    val place = when (scope) {
        HeroScope.Collection -> "your collection"
        is HeroScope.InList -> lists.firstOrNull { it.id == scope.id }?.name ?: "this list"
        is HeroScope.InBinder -> binders.binder(scope.id)?.name ?: "this binder"
    }
    ListRow(if (on) "Hero of $place" else "Make it a hero", if (on) "Tap to stop highlighting it" else "Highlighted in $place and where it's listed",
        onClick = { if (!HeroesStore.toggle(o.oracleId, scope)) onFull("${place.replaceFirstChar { it.uppercase() }} has ${HeroesStore.LIMIT} hero cards already.") }) {
        if (on) Label("Hero", color = T1.text)
    }
}

/** A context row's count, with "Change" so the row says what a tap does. */
@Composable
private fun ChangeCount(qty: Int) {
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        Label("Change", color = T1.text)
        Text("$qty", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
    }
}

@Composable
private fun Hero(o: CatalogOracle, p: CatalogPrinting?) {
    Row(Modifier.fillMaxWidth().background(T1.surface).padding(16.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        CardArt(p, 146.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(o.typeLine, color = T1.text, fontFamily = T1.mono, fontSize = 13.sp)
            if (o.manaCost.isNotEmpty()) Label(o.manaCost)
            Label("${o.printings} printings")
        }
    }
}

@Composable
private fun StepSquare(text: String, enabled: Boolean, onClick: () -> Unit) {
    Box(Modifier.size(52.dp).background(T1.surfaceHover).clickable(enabled = enabled, onClick = onClick), contentAlignment = Alignment.Center) {
        Text(text, color = if (enabled) T1.text else T1.disabled, fontFamily = T1.mono, fontSize = 22.sp)
    }
}
