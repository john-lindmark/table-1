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
                      onCubes: () -> Unit, onTrades: () -> Unit, onBinders: () -> Unit, onWants: () -> Unit, onMatches: () -> Unit,
                      onFollowing: () -> Unit = {}) {
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
                    Label(s?.let { "${count(it.uniqueCards)} distinct · ${money(it.valueUsd, "USD")}" } ?: " ")
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
                val missing = remember(col.version, lists.lists, cat.generation) {
                    MissingView.lines(lists.lists, col.items.values.groupBy { ownKey(it.cardId, it.finish) }.mapValues { (_, v) -> v.sumOf { it.qty } }, CatalogStore.basics).sumOf { it.short }
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
            item { FollowingRow(onFollowing) }
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
    /** The finish of the copies shown as the picture. */
    val coverFinish: String = "nonfoil",
    /** Copies per printing and finish (over conditions and languages), oldest printing first: the rows a card opens into. */
    val parts: List<Part> = emptyList(),
) {
    /** `condition`: the best among these copies, which prices the row. */
    data class Part(val cardId: String, val finish: String, val qty: Int, val printing: CatalogPrinting?, val condition: String = "NM") {
        val id get() = "$cardId|$finish"
        val finishLabel get() = Finish.of(finish)?.label ?: finish
    }

    /** The most a single owned copy is worth (market in its condition, USD). */
    fun price(): Double? = parts.mapNotNull { PriceBook.usd(it.cardId, it.finish, it.condition) }.maxOrNull()

    companion object {
        fun build(items: Collection<CollectionItem>, db: CatalogDb): List<CardGroup> {
            val printings = db.printings(items.map { it.cardId }.toSet())
            val oracles = db.oracles(printings.values.map { it.oracleIdx }.toSet())
            return items.groupBy { it.cardId.let { id -> printings[id]?.let { p -> oracles[p.oracleIdx]?.oracleId } } ?: it.cardId }
                .map { (key, group) ->
                    val o = printings[group[0].cardId]?.let { oracles[it.oracleIdx] }
                    val coverItem = group.filter { printings[it.cardId] != null }.maxByOrNull { it.qty }
                    val parts = group.groupBy { it.cardId to it.finish }.map { (k, its) ->
                        Part(k.first, k.second, its.sumOf { it.qty }, printings[k.first],
                            its.map { it.condition }.reduce { a, b -> if (Conditions.better(b, a)) b else a })
                    }
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
                        coverItem?.let { printings[it.cardId] }, coverItem?.finish ?: "nonfoil", parts)
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
            PriceBook.text(PriceBook.usd(part.cardId, part.finish, part.condition)), onClick = tap, finish = part.finish, indent = true) {
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
    var keys by remember { mutableStateOf<Map<String, GroupKeys>>(emptyMap()) }
    var query by remember { mutableStateOf("") }
    val grouping = rememberCardGrouping(GroupingKey.ALL_CARDS, CardGrouping.None, list = false)
    val sortState = rememberCardSort(SortPref.ALL_CARDS, CardSort.Screen.AllCards)
    val sort = sortState.value
    val pricesVersion by PriceBook.version.collectAsState()
    val layout = rememberCardLayout("allCards.layout", "allCards.grid")
    var viewMenu by remember { mutableStateOf(false) }
    var sharing by remember { mutableStateOf(false) }
    val printings = remember { mutableStateOf(PrintingsDisclosure()) }
    val heroes by HeroesStore.state.collectAsState()
    LaunchedEffect(Unit) { CatalogStore.load(userInitiated = true) }
    LaunchedEffect(col.version, cat.generation) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        val items = col.items.values.toList()
        val (g, k) = withContext(Dispatchers.Default) { CardGroup.build(items, db).let { it to GroupKeys.forGroups(it, db) } }
        groups = g
        keys = k
        PriceBook.load(items.map { it.cardId })
    }
    val shown = remember(groups, keys, query, sort, pricesVersion) {
        val n = CardName.norm(query)
        val list = (groups ?: emptyList()).let { g -> if (n.isEmpty()) g else g.filter { it.norm.contains(n) || CardName.norm(it.type).contains(n) } }
        when (sort) {
            CardSort.Price -> {
                // No price yet reads as the most valuable: those are the cards worth checking first.
                val p = list.associate { it.id to priceRank(it.price()) }
                list.sortedWith(compareByDescending<CardGroup> { p[it.id] }.thenBy { it.norm })
            }
            // Newest set first, then collector number; spells by mana value, then lands; or by name.
            CardSort.Name, CardSort.ManaValue, CardSort.Set -> sort.apply(list) { SortKey.of(it.name, keys[it.id], it.cover) }
            else -> list.sortedWith(compareByDescending<CardGroup> { it.lastSeq }.thenBy { it.norm })
        }
    }
    /** Group by: the sorted cards in sections, the sort kept inside each. */
    val sections = remember(shown, grouping.value, keys) { groupSections(shown, grouping.value) { keys[it.id] } }
    fun title(key: String, cards: List<CardGroup>) = "${grouping.value.label(key)} · ${cards.sumOf { it.qty }}"
    fun detail(g: CardGroup): String {
        val price = PriceBook.text(g.price())
        if (sort == CardSort.Set && g.cover != null) return listOfNotNull(g.cover.setLabel, price).joinToString(" · ")
        return listOfNotNull(price, "${g.printings} printing${if (g.printings == 1) "" else "s"}", g.type).joinToString(" · ")
    }
    T1Screen {
        Bar("All cards", subtitle = col.summary?.let { "${count(it.totalQty)} cards" }, onBack = onBack) {
            BarAction("Share") {
                Telemetry.capture("share_opened", mapOf("part" to "all_cards", "from" to "all_cards"))
                sharing = true
            }
            BarAction("View") { viewMenu = true }
        }
        if (sharing) ShareScreen(ShareTarget.AllCards, onClose = { sharing = false })
        col.error?.let { Notice(it, error = true) }
        CatalogStatus(cat)
        Box(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp)) {
            T1TextField(query, { query = it }, placeholder = "Name or type")
        }
        val bar = listOf(CardSort.Recent, CardSort.Price, CardSort.Name, CardSort.ManaValue, CardSort.Set)
        T1Segmented(listOf("Recent", "Price", "Name", "MV", "Set"), bar.indexOf(sort), scroll = true) { sortState.value = bar[it] }
        val g = groups
        if (cat.phase == "ready" && g != null) {
            if (g.isEmpty() && col.ready) ListRow("No cards yet", "Add your first card", onClick = onAdd)
            if (g.isNotEmpty() && shown.isEmpty()) ListRow("No matches", "Nothing in your collection by that name or type")
            if (layout.value == CardLayout.Stacks) {
                // Stacks follow Group by (one per group), else the sort: one per set when sorted by set, otherwise runs of
                // ten in sort order.
                val stacks = remember(sections, sort, printings.value.all, heroes) {
                    fun tiles(cards: List<CardGroup>) =
                        groupTiles(cards, printings.value.all, { heroes.isHero(it.id, HeroScope.Collection) }) { if (it.known) onOpen(it.id) }
                    if (grouping.value != CardGrouping.None) sections.map { (key, cards) ->
                        CardStackSpec("${grouping.value.wire}|$key|${sort.wire}|${printings.value.all}", title(key, cards), tiles(cards))
                    } else runStacks(tiles(shown), sort == CardSort.Set, { it.printing?.set ?: "" }, "${sort.wire}|${printings.value.all}|").map { (key, title, run) ->
                        CardStackSpec(key, title, run)
                    }
                }
                BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
                    val (cols, width) = stackColumns(maxWidth)
                    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = 1.dp)) { stackRows("all", stacks, cols, width) }
                }
            } else if (layout.value == CardLayout.Grid) {
                CardGrid(Modifier.weight(1f)) { tile ->
                    for ((key, cards) in sections) {
                        if (grouping.value != CardGrouping.None) gridHeader("h-$key") { Section(title(key, cards)) }
                        val tiles = groupTiles(cards, printings.value.all, { heroes.isHero(it.id, HeroScope.Collection) }) { if (it.known) onOpen(it.id) }
                        gridItems(tiles, key = { it.key }) { t ->
                            CardTile(t.printing, t.qty, tile, onClick = t.onClick, finish = t.finish, hero = t.hero)
                        }
                    }
                }
            } else {
                Hairlines(Modifier.weight(1f)) {
                    for ((key, cards) in sections) {
                        if (grouping.value != CardGrouping.None) item(key = "h-$key") { Section(title(key, cards)) }
                        for (row in cards) {
                            val open = printings.value.open(row.id)
                            cardGroupRows(row, detail(row), heroes.isHero(row.id, HeroScope.Collection), open,
                                toggle = {
                                    printings.value = printings.value.toggle(row.id)
                                    Telemetry.capture("printings_toggled", mapOf("expanded" to !open, "all" to false, "screen" to "all_cards"))
                                }) { if (row.known) onOpen(row.id) }
                        }
                    }
                }
            }
        } else {
            Filler()
        }
    }
    if (viewMenu) CardLayoutMenu(layout, "all_cards", printings, grouping, sort = sortState, sorts = CardSort.Screen.AllCards) { viewMenu = false }
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
                runCatching { CollectionStore.apply(cards.map { CollectionOp(it.printing.cardId, it.finish, it.condition, it.lang, delta = 1) }, source = "scan") }
                    .onSuccess { scanned = it.batchId to "Added ${cards.size} scanned card${if (cards.size == 1) "" else "s"}"; error = null }
                    .onFailure { error = it.message }
            }
        }, onCancel = {
            scanning = false
            Telemetry.capture("scan_session_ended", mapOf("context" to "add", "cards" to 0, "exact" to 0, "cancelled" to true))
        })
    }
}

/* ── card detail (CardDetailScreen.kt, contract/card-detail-2026-10-23.md) ── */

/** The scope card detail was opened in; null is the collection. */
sealed interface CardContext {
    data class InList(val listId: String) : CardContext
    data class InBinder(val binderId: String) : CardContext
    /** Nothing of yours in view (wants, Missing, a friend's or shared card): the bottom bar is Add to. */
    data object Search : CardContext
}
