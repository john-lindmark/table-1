package site.table1.events.library

import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.items as gridItems
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.foundation.layout.RowScope
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
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Panel
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1TextField
import androidx.compose.material3.TextButton
import site.table1.events.ui.components.T1AlertDialog
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry
import java.text.DateFormat
import java.util.Date

/* Decks and cubes on Android (contract/lists-2026-10-15.md): the same lists, sections, groups and version
   history as iOS and the web, read from and written to the database. */

/* Groups: CardGrouping.kt (decks start on Type, cubes on Color; Group by in the View menu). */

data class ListLine(val cardId: String, val printing: CatalogPrinting?, val oracleId: String?, val name: String,
                    val group: String, val board: String, val qty: Int, val legal: String = "", val finish: String = "nonfoil",
                    val points: Int = 0, val basic: Boolean = false, val type: String = "",
                    /** Its group under each grouping (Group by in the View menu). */
                    val keys: GroupKeys = GroupKeys(), val lang: String = "en",
                    /** Who it shares the command zone with ([CommandZone.Mate]), null when the catalog doesn't say. */
                    val pair: String? = null) {
    val ownKey get() = ownKey(cardId, finish)
    val key get() = "$board|$cardId|$finish|$lang"
    /** "Foil" / "Etched"; null for non-foil. */
    val finishLabel get() = if (finish == "nonfoil") null else finish.replaceFirstChar { it.uppercase() }
    /** "JA" for a non-English line; null for English. */
    val langLabel get() = if (lang == "en") null else lang.uppercase()
}

private data class CardMeta(val printing: CatalogPrinting?, val oracleId: String?, val name: String, val type: String,
                            val legal: String, val points: Int = 0, val keys: GroupKeys = GroupKeys(), val pair: String? = null)

private fun resolve(ids: Set<String>, db: CatalogDb): Map<String, CardMeta> {
    val ps = db.printings(ids)
    val os = db.oracles(ps.values.map { it.oracleIdx }.toSet())
    return ids.associateWith { id ->
        val p = ps[id]
        val o = p?.let { os[it.oracleIdx] }
        CardMeta(p, o?.oracleId, o?.name ?: "Unknown card", o?.typeLine ?: "", o?.legal ?: "", o?.points ?: 0, GroupKeys.of(o), o?.pair)
    }
}

private fun lines(l: CardList, meta: Map<String, CardMeta>, by: CardGrouping): List<ListLine> = lines(l.entries, meta, by)

/** Entries as lines with card details, by name, each under its group for `by`. */
private fun lines(entries: List<ListEntry>, meta: Map<String, CardMeta>, by: CardGrouping): List<ListLine> = entries.mapNotNull { e ->
    val m = meta[e.cardId] ?: return@mapNotNull null
    val type = m.type.substringBefore(" // ")
    ListLine(e.cardId, m.printing, m.oracleId, m.name, m.keys[by], e.board, e.qty, m.legal, e.finish, m.points, "Basic" in type, m.type, m.keys, e.lang, m.pair)
}.sortedBy { it.name }

/** A shared deck's or cube's entries as lines (ProfileCardsScreen), resolved off the main thread. */
internal fun resolveLines(entries: List<ListEntry>, db: CatalogDb, by: CardGrouping): List<ListLine> =
    lines(entries, resolve(entries.map { it.cardId }.toSet(), db), by)

/**
 * Why each card can't be played in the deck's format, by oracle id: banned, not legal, or a restricted card
 * with more than one copy across the main deck and sideboard. Cubes and unchecked formats have none.
 */
internal fun legalityIssues(lines: List<ListLine>, l: CardList): Map<String, String> {
    if (l.kind != ListKind.Deck) return emptyMap()
    val copies = HashMap<String, Int>()
    lines.filter { it.board != "maybe" }.forEach { copies.merge(it.oracleId ?: it.cardId, it.qty, Int::plus) }
    val out = HashMap<String, String>()
    for (x in lines) {
        val key = x.oracleId ?: x.cardId
        when (CatalogPack.legality(x.legal, l.format)) {
            "banned" -> out[key] = "Banned"
            "not_legal" -> out[key] = "Not legal"
            "restricted" -> if ((copies[key] ?: 0) > 1) out[key] = "Restricted to 1"
            else -> if (l.format == "canlander" && !x.basic && (copies[key] ?: 0) > 1) out[key] = "Singleton"
        }
    }
    return out
}

/** Canadian Highlander points in the main deck and sideboard (Considering doesn't count), highest first. */
internal fun canlanderPoints(lines: List<ListLine>): Pair<Int, List<Pair<String, Int>>> {
    val by = HashMap<String, Int>()
    lines.filter { it.board != "maybe" && it.points > 0 }.forEach { by.merge(it.name, it.points * it.qty, Int::plus) }
    val cards = by.toList().sortedWith(compareBy<Pair<String, Int>>({ -it.second }, { it.first }))
    return cards.sumOf { it.second } to cards
}

internal fun groups(lines: List<ListLine>, by: CardGrouping): List<String> = by.sorted(lines.map { it.group })

/** Card details for a list's printings, looked up once per card; quantities always come from the live list. */
@Composable
private fun rememberMeta(ids: Set<String>): Map<String, CardMeta> {
    val cat by CatalogStore.state.collectAsState()
    var meta by remember { mutableStateOf<Map<String, CardMeta>>(emptyMap()) }
    val missing = ids - meta.keys
    LaunchedEffect(missing.size, cat.generation) {
        CatalogStore.load(userInitiated = true)
        val db = CatalogStore.db ?: return@LaunchedEffect
        if (missing.isEmpty()) return@LaunchedEffect
        val found = withContext(Dispatchers.Default) { resolve(missing, db) }
        meta = meta + found
    }
    return meta
}

/** The collection per printing + finish and per card; any printing of a card covers its lines
 *  (contract/owned-by-card-2026-10-31.md). [listing]: the printings the screen's lists name. */
@Composable
fun rememberHoldings(listing: Collection<String>): Holdings {
    val col by CollectionStore.state.collectAsState()
    val cat by CatalogStore.state.collectAsState()
    return remember(col.items, cat.generation, listing.toSet()) {
        Holdings.of(col.items.values.groupBy { ownKey(it.cardId, it.finish) }.mapValues { (_, v) -> v.sumOf { it.qty } }, listing)
    }
}

/** Copies owned of each printing in each finish and language ("card_id|finish|lang"), for Add to collection. */
@Composable
private fun ownedByLanguage(): Map<String, Int> {
    val col by CollectionStore.state.collectAsState()
    return remember(col.items) { col.items.values.groupBy { "${it.cardId}|${it.finish}|${it.lang}" }.mapValues { (_, v) -> v.sumOf { it.qty } } }
}

private fun fmtDate(epoch: Double): String = DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date((epoch * 1000).toLong()))

@Composable
internal fun BoardHeader(title: String, count: Int) {
    Row(Modifier.fillMaxWidth().background(T1.surfaceHover).padding(horizontal = 16.dp, vertical = 14.dp)) {
        Text(title.uppercase(), Modifier.weight(1f), color = T1.text, fontFamily = T1.mono, fontSize = 13.sp, letterSpacing = 2.sp)
        Text("$count", color = T1.text, fontFamily = T1.mono, fontSize = 15.sp)
    }
}

@Composable
private fun StatRow(stats: List<Pair<String, Int>>) {
    Row(Modifier.fillMaxWidth().background(T1.surface).padding(vertical = 16.dp)) {
        stats.forEach { (label, value) ->
            Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                Label(label)
                Text("$value", color = T1.text, fontFamily = T1.mono, fontSize = 22.sp)
            }
        }
    }
}

/* ── lists of one kind ────────────────────────────────────────────────── */

private val DECK_FORMATS = listOf("modern", "pioneer", "standard", "legacy", "vintage", "pauper", "canlander", "other", "commander", "oathbreaker")
private val CUBE_FORMATS = listOf("vintage", "legacy", "pauper", "peasant", "other")

@Composable
fun ListsScreen(kind: ListKind, onBack: () -> Unit, onOpen: (String) -> Unit, onFind: () -> Unit = {}, onImport: () -> Unit = {},
                onRankings: (() -> Unit)? = null) {
    val s by ListsStore.state.collectAsState()
    val owned = rememberHoldings(s.lists.filter { it.kind == kind }.flatMap { l -> l.entries.map { it.cardId } })
    val scope = rememberCoroutineScope()
    var creating by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { ListsStore.sync() }
    val mine = s.lists.filter { it.kind == kind }
    val heroes by HeroesStore.state.collectAsState()
    val cat by CatalogStore.state.collectAsState()
    /** Each list's hero cards, as the printings it holds. */
    var heroArt by remember { mutableStateOf<Map<String, List<CatalogPrinting>>>(emptyMap()) }
    LaunchedEffect(heroes, cat.generation, mine.map { "${it.id}${it.current.number}" }) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        val wanted = mine.mapNotNull { l ->
            val h = heroes.heroes(HeroScope.InList(l.id))
            if (h.isEmpty()) null else Triple(l.id, h, l.entries.sortedByDescending { it.qty }.map { it.cardId })
        }
        heroArt = withContext(Dispatchers.Default) { wanted.associate { (id, h, held) -> id to HeroArt.printings(h, held, db) } }
    }
    T1Screen {
        Bar(if (kind == ListKind.Deck) "Decks" else "Cubes", subtitle = "${mine.size}", onBack = onBack)
        s.error?.let { Notice(it, error = true) }
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            item { ListRow(if (kind == ListKind.Deck) "New deck" else "New cube", "Name it, then add cards", onClick = { creating = true }) }
            if (kind == ListKind.Cube && onRankings != null) item { ListRow("Rankings", "Yours, and friends' cubes you can rank", onClick = onRankings) }
            items(mine, key = { it.id }) { l ->
                val miss = l.missing(owned, CatalogStore.basics)
                val side = l.count("side"); val maybe = l.count("maybe")
                val detail = listOfNotNull(l.format, if (side > 0) "$side sideboard" else null, if (maybe > 0) "$maybe considering" else null,
                    if (miss == 0) "All owned" else "$miss missing", "v${l.current.number}").joinToString(" · ")
                HeroListRow(heroArt[l.id] ?: emptyList(), l.name, detail, onClick = { onOpen(l.id) }) {
                    Text("${l.count("main")}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                }
            }
        }
    }
    if (creating) NewListPanel(kind, onDismiss = { creating = false }, onCreated = onOpen, onFind = onFind, onImport = onImport)
}

/** New deck or cube: a name and a format; Commander and Oathbreaker decks also pick their command zone
 *  (contract/command-zone-2026-10-27.md). Opened from Decks/Cubes and from the Collection home's +. */
@Composable
fun NewListPanel(kind: ListKind, onDismiss: () -> Unit, onCreated: (String) -> Unit, onFind: () -> Unit = {}, onImport: () -> Unit = {}) {
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf("") }
    val formats = if (kind == ListKind.Deck) DECK_FORMATS else CUBE_FORMATS
    var format by remember { mutableStateOf(0) }
    var busy by remember { mutableStateOf(false) }
    var zone by remember { mutableStateOf<List<CommandZone.Line>>(emptyList()) }
    var zoneCards by remember { mutableStateOf<Map<String, Pair<String, CatalogPrinting>>>(emptyMap()) }
    var choosing by remember { mutableStateOf<CommandZone.Slot?>(null) }
    val zoned = kind == ListKind.Deck && formats[format] in CommandZone.FORMATS
    val slots = if (zoned) CommandZone.slots(formats[format], zone) else emptyList()
    val commander = zone.firstOrNull()?.let { CommandZone.Mate(it.typeLine, it.pair, zoneCards[it.cardId]?.first ?: "") }
    T1Panel(if (kind == ListKind.Deck) "New deck" else "New cube", onDismiss = onDismiss) {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Box(Modifier.fillMaxWidth().background(T1.surface).padding(16.dp)) { T1TextField(name, { name = it }, label = "Name") }
            // Decks: four across, the command-zone formats on their own row.
            formats.chunked(if (kind == ListKind.Deck) 4 else 5).forEachIndexed { r, row ->
                val base = r * (if (kind == ListKind.Deck) 4 else 5)
                T1Segmented(row, if (format - base in row.indices) format - base else -1) { format = base + it }
            }
            if (zoned) {
                CommandZoneCards(slots, commander = commander, card = { sl -> sl.cardId?.let { zoneCards[it] }?.let { it.first to it.second } },
                    onChoose = { choosing = it }, onRemove = { sl -> zone = zone.filter { it.cardId != sl.cardId } })
            }
            BigAction(if (kind == ListKind.Deck) "Create deck" else "Create cube", enabled = name.isNotBlank(), busy = busy) {
                busy = true
                val entries = slots.mapNotNull { sl -> sl.cardId?.let { ListEntry(it, CommandZone.BOARD, 1) } }
                scope.launch {
                    runCatching { ListsStore.create(kind, name.trim().take(60), formats[format], entries) }
                        .onSuccess { id ->
                            if (entries.isNotEmpty()) Telemetry.capture("command_zone_set", mapOf("format" to formats[format], "cards" to entries.size, "from" to "new"))
                            onDismiss(); onCreated(id)
                        }
                    busy = false
                }
            }
            ListRow("Import from a link or list", if (kind == ListKind.Deck) "Moxfield, ManaBox, Archidekt, MTGGoldfish" else "Cube Cobra, or a pasted list",
                onClick = { onDismiss(); onImport() })
            if (kind == ListKind.Deck) ListRow("Find a deck online", "Describe it; we load a recent tournament list",
                onClick = { onDismiss(); onFind() })
        }
    }
    choosing?.let { slot ->
        CommandZonePicker(slot.role, onDismiss = { choosing = null }, partnerOf = if (slot.role == CommandZone.Role.Partner) commander else null) { o, p ->
            zoneCards = zoneCards + (p.cardId to (o.name to p))
            zone = CommandZone.filling(zone, slot.cardId, CommandZone.Line(p.cardId, o.typeLine, pair = o.pair))
        }
    }
}

/* ── one list ─────────────────────────────────────────────────────────── */

@Composable
fun ListDetailScreen(listId: String, onBack: () -> Unit, onCard: (String) -> Unit, onAdd: () -> Unit, onVersions: () -> Unit,
                     onOpen: (String) -> Unit, onPrinting: (cardId: String, board: String, finish: String, lang: String) -> Unit = { _, _, _, _ -> },
                     onStats: () -> Unit = {}, onRankings: (() -> Unit)? = null, onSync: (() -> Unit)? = null,
                     onInsights: ((format: String, archetype: Int) -> Unit)? = null) {
    val s by ListsStore.state.collectAsState()
    val list = s.lists.firstOrNull { it.id == listId }
    val owned = rememberHoldings(list?.entries?.map { it.cardId } ?: emptyList())
    // What each line still needs once any printing of its card covers it (contract/owned-by-card-2026-10-31.md).
    val shortBy = remember(list, owned) {
        val m = HashMap<String, Int>()
        if (list != null) {
            val ns = OwnedByCard.needs(list)
            OwnedByCard.shorts(ns, owned, CatalogStore.basics).forEachIndexed { i, n ->
                if (n > 0) ns[i].let { e -> m.merge("${e.board}|${e.cardId}|${e.finish}|${e.lang}", n, Int::plus) }
            }
        }
        m
    }
    fun shortOf(x: ListLine) = shortBy[x.key] ?: 0
    val meta = rememberMeta(list?.entries?.map { it.cardId }?.toSet() ?: emptySet())
    val scope = rememberCoroutineScope()
    val layout = rememberCardLayout("list.layout", "list.grid")
    var viewMenu by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    var moving by remember { mutableStateOf<ListLine?>(null) }
    var confirmDelete by remember { mutableStateOf(false) }
    var exporting by remember { mutableStateOf(false) }
    var imaging by remember { mutableStateOf(false) }
    var adding by remember { mutableStateOf(false) }
    var choosingZone by remember { mutableStateOf<CommandZone.Slot?>(null) }
    var choosingFormat by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf(false) }
    val grouping = rememberListGrouping(list?.kind)
    val sort = rememberListSort(list?.kind)
    var query by rememberSaveable { mutableStateOf("") }
    val printings = rememberPrintingsDisclosure()
    val heroes by HeroesStore.state.collectAsState()
    val heroScope = HeroScope.InList(listId)
    var heroFull by remember { mutableStateOf<String?>(null) }
    SearchUsed(query, if (list?.kind == ListKind.Deck) "deck" else "cube")
    // Read so the Export row appears once a pack is opened.
    val catalog by CatalogStore.state.collectAsState()
    val catalogReady = catalog.generation >= 0 && CatalogStore.db != null

    if (list == null) {
        T1Screen { Bar("List", onBack = onBack); Notice(if (s.ready) "That list isn't here anymore." else "Loading…") }
        return
    }
    val unsavedWhy = s.unsaved[list.id]
    // Card details are looked up again each time the screen is drawn; the scroll position goes back once they're in.
    val rowsReady = list.entries.all { it.cardId in meta }
    val rows = sort.value.apply(lines(list, meta, grouping.value)) { SortKey.of(it.name, it.keys, it.printing) }
    val issues = legalityIssues(rows, list)
    val searching = CardName.norm(query).isNotEmpty()
    val shown = if (searching) rows.filter { CardSearch.matches(query, it.name, it.type) } else rows
    // Commander and Oathbreaker decks show their command zone at the top, in every layout (not while searching).
    val showsZone = list.kind == ListKind.Deck && list.format in CommandZone.FORMATS && !searching
    val zone = rows.filter { it.board == CommandZone.BOARD }
    val zoneCommander = zone.firstOrNull()?.let { CommandZone.Mate(it.type, it.pair, it.name) }
    // While searching, matches come first: the summary rows would push them under the keyboard.
    val boards = list.boards.filter { b -> (!searching || shown.any { it.board == b }) && !(b == CommandZone.BOARD && showsZone) }

    // Summary, Add cards, Version history: the same block above both the list and the grid.
    val top: @Composable () -> Unit = {
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            // Made on this device and not on the account yet (contract/offline-2026-10-31.md § 4).
            if (unsavedWhy != null) Notice(unsavedNotice(list, unsavedWhy), error = unsavedWhy.isNotEmpty())
            // Considering cards are flagged on their rows but don't make the deck unplayable.
            val bad = rows.filter { it.board != "maybe" && issues.containsKey(it.oracleId ?: it.cardId) }.map { it.name }.distinct().sorted()
            if (bad.isNotEmpty()) {
                val names = bad.take(3).joinToString(", ") + if (bad.size > 3) " and ${bad.size - 3} more" else ""
                Notice("${if (bad.size == 1) "1 card isn't" else "${bad.size} cards aren't"} legal in ${CatalogPack.formatName(list.format)}: $names", error = true)
            }
            if (list.kind == ListKind.Deck && list.format == "canlander") {
                val (total, cards) = canlanderPoints(rows)
                val limit = CatalogPack.CANLANDER_POINT_LIMIT
                val detail = cards.take(6).joinToString(", ") { "${it.first} ${it.second}" } + if (cards.size > 6) ", …" else ""
                if (total > limit) Notice("Over the points limit: $total of $limit. $detail", error = true)
                else if (total > 0) Notice("Points: $total of $limit. $detail")
                val main = list.count("main")
                if (main < 100) Notice("Canadian Highlander decks need at least 100 cards: $main so far.")
            }
            if (showsZone) {
                val lineOf = { slot: CommandZone.Slot -> zone.firstOrNull { it.cardId == slot.cardId && it.finish == slot.finish && it.lang == slot.lang } }
                CommandZoneCards(CommandZone.slots(list.format, zone.map { CommandZone.Line(it.cardId, it.type, it.finish, it.lang, it.pair) }),
                    commander = zoneCommander,
                    card = { sl -> lineOf(sl)?.let { it.name to it.printing } }, onChoose = { choosingZone = it },
                    onRemove = { sl -> sl.cardId?.let { id -> scope.launch { ListsStore.remove(list.id, id, CommandZone.BOARD, sl.finish, sl.lang) } } },
                    onOpen = { sl -> lineOf(sl)?.oracleId?.let(onCard) })
            }
            if (editing) ListRow("Name", list.name, onClick = { renaming = true }) { Label("Change", color = T1.text) }
            if (editing) ListRow("Format", CatalogPack.formatName(list.format), onClick = { choosingFormat = true }) { Label("Change", color = T1.text) }
            if (editing) ListRow(if (list.kind == ListKind.Deck) "Duplicate deck" else "Duplicate cube", "A new list with these cards", onClick = {
                scope.launch { runCatching { ListsStore.duplicate(list.id) }.getOrNull()?.let { editing = false; onOpen(it) } }
            })
            if (editing) ListRow(if (list.kind == ListKind.Deck) "Delete deck" else "Delete cube", "From every device", onClick = { confirmDelete = true })
            if (!editing) ListStatsRow(list.id, onStats)
            if (!editing && list.kind == ListKind.Deck && onInsights != null) DeckMetaRows(list.id, onInsights)
            if (!editing && list.kind == ListKind.Cube && list.entries.isNotEmpty() && onRankings != null) RankingsRow(list.id, onRankings)
            ListRow("Add, remove or replace", if (list.kind == ListKind.Deck) "Main deck, sideboard or considering" else "Search the catalog, or this cube's own cards", onClick = onAdd)
            ListRow("Version history", "v${list.current.number} · ${list.current.note} · ${fmtDate(list.current.at)}", onClick = onVersions) {
                Text("${list.versions.size}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
            }
            if (!editing) WhoSeesRow(list.kind.wire, list.id, list.name)
            if (!editing) ShareRow(ShareTarget(list.kind.wire, list.id, list.name), list.kind.wire,
                onExport = if (list.entries.isNotEmpty() && catalogReady) ({ exporting = true }) else null,
                onImage = if (list.entries.isNotEmpty() && catalogReady && list.kind == ListKind.Deck) ({ imaging = true }) else null)
            if (list.entries.isNotEmpty() && !editing && catalogReady) {
                ListRow("Export", if (list.kind == ListKind.Deck) "Text, Arena, MTGO, download or copy" else "Text, Cube Cobra, download or copy",
                    onClick = { exporting = true })
                if (list.kind == ListKind.Deck) ListRow("Deck image", "The cards as a picture, to save or share", onClick = { imaging = true })
                // The exact printings and languages listed, unlike the deck's own Missing, which goes by card.
                val short = ListToCollection.copies(ListToCollection.ops(list.entries, list.kind, ownedByLanguage(), ListToCollection.Mode.Missing,
                                                                         basics = CatalogStore.basics))
                ListRow("Add to collection", if (short > 0) "Missing $short · or every card" else "You own every card · add more copies", onClick = { adding = true })
            }
            if (!editing && list.kind == ListKind.Cube && onSync != null) {
                ListRow("Sync with Cube Cobra", CubeSync.cubeId(list.sourceUrl)?.let { "cubecobra.com · $it" } ?: "Get the latest from a Cube Cobra link",
                    onClick = onSync)
            }
            if (list.entries.isEmpty()) ListRow("No cards yet", "Add cards to start this list")
        }
    }

    val lineRow: @Composable (ListLine, Boolean) -> Unit = { x, sub ->
        // A printing's own sub-row counts that printing; a card's row, every printing of it.
        val have = if (sub) owned.ownedPrinting(x.cardId, x.finish) else owned.ownedCard(x.cardId)
        val considering = x.board == "maybe"
        val need = shortOf(x)
        val short = need > 0 // basics are never missing
        val issue = issues[x.oracleId ?: x.cardId]
        val owns = if (considering) (if (have > 0) "Owned $have" else "Not owned") else if (short) "Owned $have · missing $need"
            else if (x.basic && have == 0) null else "Owned $have"
        val pts = if (x.points > 0 && list.format == "canlander") "${x.points} pt${if (x.points == 1) "" else "s"}" else null
        CardRow(x.printing, if (sub) x.printing?.setLabel ?: x.name else x.name, listOfNotNull(if (sub) null else issue, pts, x.finishLabel, x.langLabel, owns).joinToString(" · "),
            onClick = { x.oracleId?.let(onCard) }, finish = x.finish, hero = !sub && heroes.isHero(x.oracleId, heroScope), indent = sub) {
            Text("${x.qty}", color = if (short || issue != null) T1.error else T1.text, fontFamily = T1.mono, fontSize = 17.sp)
        }
    }
    /** A card with several lines: a summary row with a chevron that opens one row per printing and finish. */
    val groupRow: @Composable (LineGroup, Boolean) -> Unit = { cg, open ->
        val lead = cg.lead
        val hero = heroes.isHero(lead.oracleId, heroScope)
        val considering = lead.board == "maybe"
        val issue = issues[cg.key]
        // Basics are never missing (contract/basics-2026-10-24.md).
        val short = cg.lines.sumOf { shortOf(it) }
        val have = owned.ownedCard(lead.cardId)
        val haveText = if (considering) (if (have > 0) "Owned $have" else "Not owned")
            else if (lead.basic) (if (have > 0) "Owned $have" else null) else if (short > 0) "Missing $short" else "All owned"
        WithChevron(cg.lines.size, open, hero, {
            printings.value = printings.value.toggle(cg.id)
            Telemetry.capture("printings_toggled", mapOf("expanded" to !open, "all" to false, "screen" to "list"))
        }) {
            CardRow(lead.printing, lead.name, listOfNotNull(issue, "${cg.lines.size} ${if (cg.lines.map { it.cardId }.toSet().size == cg.lines.size) "printings" else "versions"}", haveText).joinToString(" · "),
                onClick = { lead.oracleId?.let(onCard) }, finish = lead.finish, hero = hero) {
                Text("${cg.qty}", color = if ((!considering && short > 0) || issue != null) T1.error else T1.text, fontFamily = T1.mono, fontSize = 17.sp)
            }
        }
    }
    /** Grid and stack cards for one group: one per card, or with every printing expanded, one per line. */
    fun tiles(inGroup: List<ListLine>): List<StackCard> = LineGroup.of(inGroup).flatMap { cg ->
        val hero = heroes.isHero(cg.lead.oracleId, heroScope)
        val open = { cg.lead.oracleId?.let(onCard); Unit }
        fun warn(ls: List<ListLine>) = ls.any { shortOf(it) > 0 } || issues.containsKey(cg.key)
        if (!printings.value.all || cg.lines.size < 2) listOf(StackCard(cg.id, cg.lead.printing, cg.lead.name, cg.qty, warn(cg.lines), cg.lead.finish, hero, open))
        else cg.lines.map { l -> StackCard(l.key, l.printing, l.name, l.qty, warn(listOf(l)), l.finish, hero, open) }
    }

    T1Screen {
        Bar(list.name, subtitle = "${CatalogPack.formatName(list.format)} ${list.kind.wire} · v${list.current.number}", onBack = onBack) {
            BarAction(if (editing) "Done" else "Edit") { editing = !editing }
            if (!editing) BarAction("View") { viewMenu = true }
        }
        (s.error ?: heroFull)?.let { Notice(it, error = true) }
        if (list.entries.isNotEmpty()) SearchBand(query, if (list.kind == ListKind.Cube) "Search this cube" else "Search this deck") { query = it }
        if (searching && shown.isEmpty()) ListRow("No cards match")
        if (layout.value == CardLayout.Stacks && !editing) {
            // Stacks keep the organization too: section header, then a stack per type (decks) or color (cubes).
            BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
                val (cols, width) = stackColumns(maxWidth)
                LazyColumn(Modifier.fillMaxSize(), rememberKeptListState(rowsReady)) {
                    if (!searching) item(key = "top") { top() }
                    for (board in boards) {
                        val inBoard = shown.filter { it.board == board }
                        item(key = "b-$board") { Box(Modifier.padding(top = 1.dp)) { BoardHeader(list.boardTitle(board), inBoard.sumOf { it.qty }) } }
                        val stacks = groups(inBoard, grouping.value).map { g ->
                            val inGroup = inBoard.filter { it.group == g }
                            CardStackSpec("${grouping.value.wire}|$g|${printings.value.all}", "${grouping.value.label(g)} · ${inGroup.sumOf { it.qty }}", tiles(inGroup))
                        }
                        stackRows("s-$board", stacks, cols, width)
                    }
                }
            }
        } else if (layout.value == CardLayout.Grid && !editing) {
            // The grid keeps the organization: section header, then type (decks) or color (cubes) headers.
            CardGrid(Modifier.weight(1f), rememberKeptGridState(rowsReady)) { tile ->
                if (!searching) gridHeader("top") { top() }
                for (board in boards) {
                    val inBoard = shown.filter { it.board == board }
                    gridHeader("b-$board") { BoardHeader(list.boardTitle(board), inBoard.sumOf { it.qty }) }
                    for (g in groups(inBoard, grouping.value)) {
                        val inGroup = inBoard.filter { it.group == g }
                        gridHeader("g-$board-$g") { Section("${grouping.value.label(g)} · ${inGroup.sumOf { it.qty }}") }
                        gridItems(tiles(inGroup), key = { "t-${it.key}" }) { t ->
                            CardTile(t.printing, t.qty, tile, warn = t.warn, onClick = t.onClick, finish = t.finish, hero = t.hero)
                        }
                    }
                }
            }
        } else {
            LazyColumn(Modifier.weight(1f), rememberKeptListState(rowsReady), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                if (!searching) item(key = "top") { top() }
                for (board in boards) {
                    val inBoard = shown.filter { it.board == board }
                    item(key = "b-$board") { BoardHeader(list.boardTitle(board), inBoard.sumOf { it.qty }) }
                    for (g in groups(inBoard, grouping.value)) {
                        val inGroup = inBoard.filter { it.group == g }
                        item(key = "g-$board-$g") { Section("${grouping.value.label(g)} · ${inGroup.sumOf { it.qty }}") }
                        if (!editing) {
                            for (cg in LineGroup.of(inGroup)) {
                                if (cg.lines.size == 1) item(key = "r-${cg.lead.key}") { lineRow(cg.lead, false) }
                                else {
                                    val open = printings.value.open(cg.id)
                                    item(key = "cg-${cg.id}") { groupRow(cg, open) }
                                    if (open) items(cg.lines, key = { "s-${it.key}" }) { x -> lineRow(x, true) }
                                }
                            }
                        } else items(inGroup, key = { "r-${it.key}" }) { x ->
                            if (editing) {
                                Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                                    Box(Modifier.weight(1f)) {
                                        CardRow(x.printing, x.name, listOfNotNull(x.finishLabel, x.langLabel, "Tap to move, change or remove").joinToString(" · "), onClick = { moving = x },
                                            finish = x.finish, hero = heroes.isHero(x.oracleId, heroScope)) {
                                            Text("${x.qty}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                                        }
                                    }
                                    Step("−") { scope.launch { runCatching { ListsStore.add(list.id, x.cardId, x.board, -1, x.finish, x.lang) } } }
                                    Step("+") { scope.launch { runCatching { ListsStore.add(list.id, x.cardId, x.board, 1, x.finish, x.lang) } } }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    moving?.let { x ->
        val zoneSection = if (list.kind == ListKind.Deck && list.format in CommandZone.FORMATS && x.board != CommandZone.BOARD) listOf(CommandZone.BOARD) else emptyList()
        T1Menu(x.name, (zoneSection + list.sections).filter { it != x.board }.map { b ->
            T1MenuItem("Move to ${list.boardTitle(b)}") { scope.launch { runCatching { ListsStore.move(list.id, x.cardId, x.board, b, x.finish, x.lang) } } }
        } + T1MenuItem("Change printing or finish") { onPrinting(x.cardId, x.board, x.finish, x.lang) } +
            listOfNotNull(x.oracleId?.let { o ->
                val on = heroes.isHero(o, heroScope)
                T1MenuItem(if (on) "Not a hero card" else "Make it a hero card") {
                    if (!HeroesStore.toggle(o, heroScope)) heroFull = "${list.name} has ${HeroesStore.LIMIT} hero cards already."
                }
            }) +
            T1MenuItem("Remove from ${list.boardTitle(x.board)}", danger = true) {
            scope.launch { runCatching { ListsStore.remove(list.id, x.cardId, x.board, x.finish, x.lang) } }
        }, onDismiss = { moving = null })
    }
    if (confirmDelete) {
        T1Menu("Delete ${list.name}? It goes from every device.", listOf(
            T1MenuItem(if (list.kind == ListKind.Deck) "Delete deck" else "Delete cube", danger = true) {
                scope.launch { runCatching { ListsStore.delete(list.id) }.onSuccess { onBack() } }
            },
        ), onDismiss = { confirmDelete = false })
    }
    choosingZone?.let { slot ->
        val deck = rows.filter { it.board != CommandZone.BOARD }.map {
            ZoneDeckCard(CommandZone.DeckLine(it.cardId, it.board, it.type, it.finish, it.lang, it.qty, it.pair), it.name, it.printing)
        }
        CommandZonePicker(slot.role, onDismiss = { choosingZone = null }, deck = deck,
            partnerOf = if (slot.role == CommandZone.Role.Partner) zoneCommander else null, onPickDeck = { d ->
            scope.launch {
                runCatching {
                    ListsStore.editMany(list.id, CommandZone.movingIn(d.line, slot).map { op ->
                        when (op) {
                            is CommandZone.Op.Move -> buildJsonObject {
                                put("card_id", op.cardId); put("finish", op.finish); put("lang", op.lang); put("from", op.from); put("to", op.to)
                            }
                            is CommandZone.Op.Delta -> buildJsonObject {
                                put("card_id", op.cardId); put("board", op.board); put("finish", op.finish); put("lang", op.lang); put("delta", op.by)
                            }
                        }
                    })
                }
            }
            Telemetry.capture("command_zone_set", mapOf("format" to list.format, "role" to slot.role.wire, "from" to "deck"))
        }) { _, p ->
            scope.launch {
                val id = slot.cardId
                if (id != null) ListsStore.swap(list.id, id, CommandZone.BOARD, slot.finish, p.cardId, "nonfoil", null, slot.lang, "en")
                else ListsStore.add(list.id, p.cardId, CommandZone.BOARD, 1)
            }
            Telemetry.capture("command_zone_set", mapOf("format" to list.format, "role" to slot.role.wire, "from" to if (slot.cardId == null) "add" else "change"))
        }
    }
    if (renaming) ListNameDialog(list) { renaming = false }
    if (choosingFormat) {
        T1Menu("Format", (if (list.kind == ListKind.Deck) DECK_FORMATS else CUBE_FORMATS).map { f ->
            T1MenuItem(CatalogPack.formatName(f), selected = f == list.format) { scope.launch { runCatching { ListsStore.setFormat(list.id, f) } } }
        }, onDismiss = { choosingFormat = false })
    }
    if (exporting) ListExportScreen(list.name, list.kind, list.entries, "own") { exporting = false }
    if (imaging) DeckImageScreen(list.name, list.format, list.entries, owner = null, from = "own") { imaging = false }
    if (adding) ListToCollectionScreen(list, ownedByLanguage()) { adding = false }
    if (viewMenu) CardLayoutMenu(layout, if (list.kind == ListKind.Cube) "cube" else "deck", printings, grouping, list = true, sort = sort) { viewMenu = false }
}

@Composable
private fun Step(glyph: String, onClick: () -> Unit) {
    Box(Modifier.width(52.dp).fillMaxHeight().background(T1.surfaceHover).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Text(glyph, color = T1.text, fontFamily = T1.mono, fontSize = 22.sp)
    }
}

/* ── adding cards to a list ───────────────────────────────────────────── */

/**
 * Add, remove or replace, like Cube Cobra's edit panel (contract/library-polish-2026-10-19.md): an Add box (the catalog,
 * Scryfall syntax, or the scanner) and a Remove or replace box (only the list's own cards) on one screen. Pick a card in
 * either box; with only Remove picked the button removes one copy, with both picked it replaces that copy with the added
 * card in the same section, as one edit (so the history shows a swap). Each card goes in as its original paper printing
 * unless a search or scan named another; change it from the card page.
 */
@Composable
fun ListAddScreen(listId: String, onDone: () -> Unit, @Suppress("UNUSED_PARAMETER") onCard: (String) -> Unit) {
    val s by ListsStore.state.collectAsState()
    val list = s.lists.firstOrNull { it.id == listId } ?: run { T1Screen { Bar("Add cards") { BarAction("Done", onDone) } }; return }
    val scope = rememberCoroutineScope()
    var addQuery by remember { mutableStateOf("") }
    var removeQuery by remember { mutableStateOf("") }
    var board by remember { mutableStateOf(0) }
    var addPick by remember { mutableStateOf<Pair<CatalogOracle, CatalogPrinting>?>(null) }
    var removePick by remember { mutableStateOf<ListLine?>(null) }
    /** Which box was typed in last: the list below follows it. */
    var removeFocus by remember { mutableStateOf(false) }
    var note by remember { mutableStateOf<String?>(null) }
    var scanning by remember { mutableStateOf(false) }
    val meta = rememberMeta(list.entries.map { it.cardId }.toSet())
    val result = rememberCardSearch(if (addPick == null) addQuery else "")
    val b = list.sections[board.coerceIn(0, list.sections.size - 1)]
    // Remove or replace searches only the list's own cards; their groups don't show here.
    val lines = lines(list, meta, CardGrouping.Type)
    val removeHits = CardSearch.matchingLines(lines, removeQuery, { it.name }, { it.type }, { it.board }, { it.finish })
    val showingRemove = removePick == null && removeFocus
    fun finishOf(p: CatalogPrinting) = p.finishList.firstOrNull()?.wire ?: "nonfoil"
    fun reset() { addPick = null; removePick = null; addQuery = ""; removeQuery = ""; removeFocus = false }
    fun pickAdd(o: CatalogOracle, p: CatalogPrinting) { addPick = o to p; addQuery = o.name }
    fun pickRemove(x: ListLine) { removePick = x; removeQuery = x.name; removeFocus = false }
    fun add() {
        val (o, p) = addPick ?: return
        scope.launch { runCatching { ListsStore.add(list.id, p.cardId, b, 1, finishOf(p), p.lang) } }
        Telemetry.capture("list_card_added", mapOf("kind" to list.kind.wire, "from" to "edit"))
        note = "Added 1 ${o.name} to ${list.boardTitle(b)}"
        reset()
    }
    fun removeOrReplace() {
        val r = removePick ?: return
        val a = addPick
        if (a != null) {
            scope.launch { runCatching { ListsStore.swap(list.id, r.cardId, r.board, r.finish, a.second.cardId, finishOf(a.second), 1, r.lang, a.second.lang) } }
            Telemetry.capture("list_card_replaced", mapOf("kind" to list.kind.wire))
            note = "Replaced ${r.name} with ${a.first.name} in ${list.boardTitle(r.board)}"
        } else {
            scope.launch { runCatching { ListsStore.add(list.id, r.cardId, r.board, -1, r.finish, r.lang) } }
            Telemetry.capture("list_card_removed", mapOf("kind" to list.kind.wire))
            note = "Removed 1 ${r.name} from ${list.boardTitle(r.board)}"
        }
        reset()
    }
    @Composable
    fun picked(p: CatalogPrinting?, name: String, detail: String, finish: String = "nonfoil", clear: () -> Unit) {
        Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            Box(Modifier.weight(1f)) { CardRow(p, name, detail, finish = finish) }
            Box(Modifier.fillMaxHeight().background(T1.surface).clickable(onClick = clear).padding(horizontal = 16.dp), contentAlignment = Alignment.Center) {
                Label("Clear", color = T1.text)
            }
        }
    }
    @Composable
    fun RowScope.action(text: String, enabled: Boolean, run: () -> Unit) {
        Box(Modifier.weight(1f).background(if (enabled) T1.text else T1.disabled).clickable(enabled = enabled, onClick = run).padding(vertical = 16.dp),
            contentAlignment = Alignment.Center) {
            Text(text.uppercase(), color = T1.ink, fontFamily = T1.mono, fontSize = 13.sp, fontWeight = FontWeight.Bold, letterSpacing = 3.sp)
        }
    }
    T1Screen {
        Bar("Edit ${list.name}", subtitle = "v${list.current.number}") { BarAction("Done", onDone) }
        note?.let { Notice(it) }
        Section("Add to")
        T1Segmented(list.sections.map { list.boardTitle(it) }, board) { board = it }
        val ap = addPick
        if (ap != null) picked(ap.second, ap.first.name, list.boardTitle(removePick?.board ?: b)) { addPick = null; addQuery = "" }
        else CardSearchBar(addQuery, { addQuery = it; removeFocus = false }, placeholder = "Card to add", onScan = { scanning = true },
            onSubmit = { result?.hits?.firstOrNull()?.let { o -> result.covers[o.idx]?.let { pickAdd(o, it) } } })
        Section("Remove or replace")
        val rp = removePick
        if (rp != null) picked(rp.printing, rp.name, listOfNotNull(list.boardTitle(rp.board), rp.finishLabel).joinToString(" · "), rp.finish) {
            removePick = null; removeQuery = ""; removeFocus = true
        } else Box(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp)) {
            T1TextField(removeQuery, { removeQuery = it; removeFocus = true }, placeholder = if (list.kind == ListKind.Cube) "Card in this cube" else "Card in this deck",
                onClick = if (removeFocus) null else ({ removeFocus = true }), onSubmit = { removeHits.firstOrNull()?.let { pickRemove(it) } })
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            action("Add", addPick != null) { add() }
            action(if (addPick != null && removePick != null) "Replace" else "Remove", removePick != null) { removeOrReplace() }
        }
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (showingRemove) {
                if (CardName.norm(removeQuery).isEmpty()) item {
                    Notice("Search the cards in ${list.name}. Remove takes one copy out; with a card picked to add, Replace swaps it in the same section.")
                } else if (removeHits.isEmpty()) item { ListRow("No card in ${list.name} matches") }
                items(removeHits, key = { "l-${it.key}" }) { x ->
                    CardRow(x.printing, x.name, listOfNotNull(list.boardTitle(x.board), x.finishLabel, x.langLabel, if (x.qty > 1) "${x.qty} copies" else null).joinToString(" · "),
                        onClick = { pickRemove(x) }, finish = x.finish)
                }
            } else if (addPick == null) {
                item { CardSearchStatus(addQuery, result) }
                if (addQuery.isEmpty() && removeQuery.isEmpty()) item {
                    Notice("Pick a card to add, a card to remove, or both: with both, Replace swaps them in the same section. + adds a card at once. Scan adds what you scan to ${list.boardTitle(b)}.")
                }
                items(if (addQuery.isBlank()) emptyList() else result?.hits ?: emptyList(), key = { it.idx }) { o ->
                    val p = result?.covers?.get(o.idx)
                    val inList = p?.let { pc -> list.entries.filter { it.cardId == pc.cardId && it.board == b }.sumOf { it.qty } } ?: 0
                    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                        Box(Modifier.weight(1f)) {
                            CardRow(p, o.name, if (inList > 0) "$inList in ${list.boardTitle(b)}" else o.typeLine, onClick = { p?.let { pickAdd(o, it) } })
                        }
                        Box(Modifier.width(52.dp).fillMaxHeight().background(T1.surfaceHover).clickable(enabled = p != null) {
                            val pc = p ?: return@clickable
                            scope.launch { runCatching { ListsStore.add(list.id, pc.cardId, b, 1, finishOf(pc), pc.lang) } }
                            Telemetry.capture("list_card_added", mapOf("kind" to list.kind.wire, "from" to "quick"))
                            note = "Added 1 ${o.name} to ${list.boardTitle(b)}"
                        }.semantics { contentDescription = "Add ${o.name}" }, contentAlignment = Alignment.Center) {
                            Text("+", color = if (p == null) T1.disabled else T1.text, fontFamily = T1.mono, fontSize = 22.sp)
                        }
                    }
                }
            }
        }
    }
    // Scanned cards go into the chosen section as one edit, each in the printing and finish the scanner read.
    if (scanning) {
        val target = b
        CardScanOverlay("Scan into ${list.boardTitle(target)}", "Add", owned = null, onDone = { cards ->
            scanning = false
            Telemetry.capture("scan_session_ended", mapOf("context" to list.kind.wire, "cards" to cards.size, "exact" to cards.count { it.exact }, "cancelled" to false))
            if (cards.isNotEmpty()) {
                scope.launch { runCatching { ListsStore.addMany(list.id, target, cards.map { Triple(it.printing.cardId, it.finish, it.lang) }) } }
                note = "Added ${cards.size} scanned card${if (cards.size == 1) "" else "s"} to ${list.boardTitle(target)}"
            }
        }, onCancel = {
            scanning = false
            Telemetry.capture("scan_session_ended", mapOf("context" to list.kind.wire, "cards" to 0, "exact" to 0, "cancelled" to true))
        })
    }
}

/* ── version history ──────────────────────────────────────────────────── */

@Composable
fun ListVersionsScreen(listId: String, onBack: () -> Unit, onOpen: (Int) -> Unit) {
    val s by ListsStore.state.collectAsState()
    val list = s.lists.firstOrNull { it.id == listId }
    T1Screen {
        Bar("Version history", subtitle = list?.name, onBack = onBack)
        if (list != null) {
            LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                items(list.versions.indices.reversed().toList(), key = { list.versions[it].number }) { i ->
                    val v = list.versions[i]
                    val ch = CardList.diff(if (i > 0) list.versions[i - 1] else null, v)
                    val added = ch.filter { it.delta > 0 }.sumOf { it.delta }
                    val removed = -ch.filter { it.delta < 0 }.sumOf { it.delta }
                    val detail = listOfNotNull(fmtDate(v.at), if (i == 0) "first version" else "+$added −$removed",
                        if (i == list.versions.size - 1) "current" else null).joinToString(" · ")
                    ListRow("v${v.number} · ${v.note}", detail, onClick = { onOpen(v.number) })
                }
            }
        }
    }
}

@Composable
fun ListVersionScreen(listId: String, number: Int, onBack: () -> Unit, onCard: (String) -> Unit) {
    val s by ListsStore.state.collectAsState()
    val list = s.lists.firstOrNull { it.id == listId }
    val i = list?.versions?.indexOfFirst { it.number == number } ?: -1
    val scope = rememberCoroutineScope()
    var restored by remember { mutableStateOf<String?>(null) }
    val v = if (list != null && i >= 0) list.versions[i] else null
    val prev = if (list != null && i > 0) list.versions[i - 1] else null
    val changes = if (v != null && prev != null) CardList.diff(prev, v) else emptyList()
    val meta = rememberMeta(changes.map { it.cardId }.toSet())
    T1Screen {
        Bar("v$number · ${v?.note ?: ""}", subtitle = list?.name, onBack = onBack)
        restored?.let { Notice(it) }
        if (list == null || v == null) return@T1Screen
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            item {
                val c = { b: String -> v.entries.filter { it.board == b }.sumOf { it.qty } }
                StatRow(listOfNotNull((if (list.kind == ListKind.Deck) "Main" else "Cards") to c("main"),
                    if (list.kind == ListKind.Deck) "Side" to c("side") else null, "Considering" to c("maybe")))
            }
            item { ListRow(fmtDate(v.at), prev?.let { "Changes from v${it.number}" } ?: "First version") }
            if (prev != null && changes.isEmpty()) item { ListRow("No card changes") }
            for (b in CardList.BOARD_ORDER.filter { b -> changes.any { it.board == b } }) {
                item(key = "s-$b") { Section(list.boardTitle(b)) }
                items(changes.filter { it.board == b }, key = { "c-$b-${it.cardId}-${it.finish}" }) { c ->
                    val m = meta[c.cardId]
                    CardRow(m?.printing, m?.name ?: "…",
                        listOfNotNull(if (c.delta > 0) "Added" else "Removed", if (c.finish == "nonfoil") null else c.finish.replaceFirstChar { it.uppercase() }).joinToString(" · "), onClick = { m?.oracleId?.let(onCard) }) {
                        Text(if (c.delta > 0) "+${c.delta}" else "−${-c.delta}", color = if (c.delta > 0) T1.text else T1.error,
                            fontFamily = T1.mono, fontSize = 17.sp)
                    }
                }
            }
            if (i != list.versions.size - 1) item {
                BigAction("Restore v$number") {
                    scope.launch { runCatching { ListsStore.restore(list.id, number) }.onSuccess { restored = "Restored as a new version. Every earlier version is still here." } }
                }
            }
        }
    }
}

/** Renames a deck or cube from its Edit section. */
@Composable
private fun ListNameDialog(list: CardList, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf(list.name) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    T1AlertDialog(
        title = if (list.kind == ListKind.Deck) "Rename deck" else "Rename cube",
        onDismiss = onClose,
        confirm = {
            TextButton(enabled = name.isNotBlank() && !busy, onClick = {
                busy = true
                scope.launch {
                    runCatching { ListsStore.rename(list.id, name) }.onSuccess { onClose() }.onFailure { error = it.message }
                    busy = false
                }
            }) { Label("Save", color = T1.text) }
        },
        dismiss = { TextButton(onClick = onClose) { Label("Cancel", color = T1.text) } },
        body = { T1TextField(name, { name = it.take(60) }, label = "Name", error = error) },
    )
}
