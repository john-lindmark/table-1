package site.table1.events.library

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import site.table1.events.T1App
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Panel
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1
import java.text.DateFormat
import java.util.Date

/* Decks and cubes on Android (contract/lists-2026-10-15.md): the same lists, sections, groups and version
   history as iOS and the web, read from and written to the database. */

private val TYPE_ORDER = listOf("Creatures", "Planeswalkers", "Instants", "Sorceries", "Artifacts", "Enchantments", "Battles", "Lands", "Other")
private val COLOR_ORDER = listOf("White", "Blue", "Black", "Red", "Green", "Multicolor", "Colorless", "Lands")

private fun typeGroup(t: String) = when {
    "Creature" in t -> "Creatures"
    "Planeswalker" in t -> "Planeswalkers"
    "Land" in t -> "Lands"
    "Instant" in t -> "Instants"
    "Sorcery" in t -> "Sorceries"
    "Artifact" in t -> "Artifacts"
    "Enchantment" in t -> "Enchantments"
    "Battle" in t -> "Battles"
    else -> "Other"
}

private fun colorGroup(cost: String): String {
    val colors = listOf('W' to "White", 'U' to "Blue", 'B' to "Black", 'R' to "Red", 'G' to "Green").filter { cost.contains(it.first) }
    return if (colors.size > 1) "Multicolor" else colors.firstOrNull()?.second ?: "Colorless"
}

data class ListLine(val cardId: String, val printing: CatalogPrinting?, val oracleId: String?, val name: String,
                    val group: String, val board: String, val qty: Int, val legal: String = "", val finish: String = "nonfoil") {
    val ownKey get() = ownKey(cardId, finish)
    val key get() = "$board|$cardId|$finish"
    /** "Foil" / "Etched"; null for non-foil. */
    val finishLabel get() = if (finish == "nonfoil") null else finish.replaceFirstChar { it.uppercase() }
}

private data class CardMeta(val printing: CatalogPrinting?, val oracleId: String?, val name: String, val type: String, val cost: String,
                            val legal: String)

private fun resolve(ids: Set<String>, db: CatalogDb): Map<String, CardMeta> {
    val ps = db.printings(ids)
    val os = db.oracles(ps.values.map { it.oracleIdx }.toSet())
    return ids.associateWith { id ->
        val p = ps[id]
        val o = p?.let { os[it.oracleIdx] }
        CardMeta(p, o?.oracleId, o?.name ?: "Unknown card", o?.typeLine ?: "", o?.manaCost ?: "", o?.legal ?: "")
    }
}

private fun lines(l: CardList, meta: Map<String, CardMeta>): List<ListLine> = l.entries.mapNotNull { e ->
    val m = meta[e.cardId] ?: return@mapNotNull null
    val type = m.type.substringBefore(" // ")
    val group = if (l.kind == ListKind.Deck) typeGroup(type) else if ("Land" in type) "Lands" else colorGroup(m.cost)
    ListLine(e.cardId, m.printing, m.oracleId, m.name, group, e.board, e.qty, m.legal, e.finish)
}.sortedBy { it.name }

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
        }
    }
    return out
}

private fun groups(lines: List<ListLine>, kind: ListKind): List<String> {
    val order = if (kind == ListKind.Deck) TYPE_ORDER else COLOR_ORDER
    return lines.map { it.group }.distinct().sortedBy { order.indexOf(it) }
}

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

@Composable
private fun ownedByPrinting(): Map<String, Int> {
    val col by CollectionStore.state.collectAsState()
    // Per printing and finish ("card_id|finish"): a foil line is covered only by foil copies of that printing.
    return remember(col.items) { col.items.values.groupBy { ownKey(it.cardId, it.finish) }.mapValues { (_, v) -> v.sumOf { it.qty } } }
}

private fun fmtDate(epoch: Double): String = DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date((epoch * 1000).toLong()))

@Composable
private fun BoardHeader(title: String, count: Int) {
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

private val DECK_FORMATS = listOf("modern", "pioneer", "standard", "legacy", "vintage", "pauper", "commander", "other")
private val CUBE_FORMATS = listOf("vintage", "legacy", "pauper", "peasant", "other")

@Composable
fun ListsScreen(kind: ListKind, onBack: () -> Unit, onOpen: (String) -> Unit, onFind: () -> Unit = {}, onImport: () -> Unit = {}) {
    val s by ListsStore.state.collectAsState()
    val owned = ownedByPrinting()
    val scope = rememberCoroutineScope()
    var creating by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    val formats = if (kind == ListKind.Deck) DECK_FORMATS else CUBE_FORMATS
    var format by remember { mutableStateOf(0) }
    var busy by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { ListsStore.sync() }
    val mine = s.lists.filter { it.kind == kind }
    T1Screen {
        Bar(if (kind == ListKind.Deck) "Decks" else "Cubes", subtitle = "${mine.size}") { BarAction("Back", onBack) }
        s.error?.let { Notice(it, error = true) }
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            item { ListRow(if (kind == ListKind.Deck) "New deck" else "New cube", "Name it, then add cards", onClick = { creating = true }) }
            items(mine, key = { it.id }) { l ->
                val miss = l.missing(owned)
                val side = l.count("side"); val maybe = l.count("maybe")
                val detail = listOfNotNull(l.format, if (side > 0) "$side sideboard" else null, if (maybe > 0) "$maybe considering" else null,
                    if (miss == 0) "All owned" else "$miss missing", "v${l.current.number}").joinToString(" · ")
                ListRow(l.name, detail, onClick = { onOpen(l.id) }) {
                    Text("${l.count("main")}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                }
            }
        }
    }
    if (creating) {
        T1Panel(if (kind == ListKind.Deck) "New deck" else "New cube", onDismiss = { creating = false }) {
            Box(Modifier.fillMaxWidth().background(T1.surface).padding(16.dp)) { T1TextField(name, { name = it }, label = "Name") }
            T1Segmented(formats.take(4), if (format < 4) format else -1) { format = it }
            if (formats.size > 4) T1Segmented(formats.drop(4), if (format >= 4) format - 4 else -1) { format = it + 4 }
            BigAction(if (kind == ListKind.Deck) "Create deck" else "Create cube", enabled = name.isNotBlank(), busy = busy) {
                busy = true
                scope.launch {
                    runCatching { ListsStore.create(kind, name.trim().take(60), formats[format]) }
                        .onSuccess { id -> creating = false; name = ""; onOpen(id) }
                    busy = false
                }
            }
            ListRow("Import from a link or list", if (kind == ListKind.Deck) "Moxfield, ManaBox, Archidekt, MTGGoldfish" else "Cube Cobra, or a pasted list",
                onClick = { creating = false; onImport() })
            if (kind == ListKind.Deck) ListRow("Find a deck online", "Describe it; we load a recent tournament list",
                onClick = { creating = false; onFind() })
        }
    }
}

/* ── one list ─────────────────────────────────────────────────────────── */

@Composable
fun ListDetailScreen(listId: String, onBack: () -> Unit, onCard: (String) -> Unit, onAdd: () -> Unit, onVersions: () -> Unit,
                     onOpen: (String) -> Unit, onPrinting: (cardId: String, board: String, finish: String) -> Unit = { _, _, _ -> }) {
    val s by ListsStore.state.collectAsState()
    val list = s.lists.firstOrNull { it.id == listId }
    val owned = ownedByPrinting()
    val meta = rememberMeta(list?.entries?.map { it.cardId }?.toSet() ?: emptySet())
    val scope = rememberCoroutineScope()
    val prefs = remember { T1App.instance.getSharedPreferences("library", android.content.Context.MODE_PRIVATE) }
    var grid by remember { mutableStateOf(prefs.getBoolean("list.grid", false)) }
    var editing by remember { mutableStateOf(false) }
    var moving by remember { mutableStateOf<ListLine?>(null) }
    var confirmDelete by remember { mutableStateOf(false) }

    if (list == null) {
        T1Screen { Bar("List") { BarAction("Back", onBack) }; Notice(if (s.ready) "That list isn't here anymore." else "Loading…") }
        return
    }
    val rows = lines(list, meta)
    val issues = legalityIssues(rows, list)

    // Summary, Add cards, Version history: the same block above both the list and the grid.
    val top: @Composable () -> Unit = {
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            StatRow(listOfNotNull((if (list.kind == ListKind.Deck) "Main" else "Cards") to list.count("main"),
                if (list.kind == ListKind.Deck) "Side" to list.count("side") else null,
                "Considering" to list.count("maybe"), "Missing" to list.missing(owned)))
            // Considering cards are flagged on their rows but don't make the deck unplayable.
            val bad = rows.filter { it.board != "maybe" && issues.containsKey(it.oracleId ?: it.cardId) }.map { it.name }.distinct().sorted()
            if (bad.isNotEmpty()) {
                val names = bad.take(3).joinToString(", ") + if (bad.size > 3) " and ${bad.size - 3} more" else ""
                Notice("${if (bad.size == 1) "1 card isn't" else "${bad.size} cards aren't"} legal in ${list.format.replaceFirstChar { it.uppercase() }}: $names", error = true)
            }
            if (editing) ListRow(if (list.kind == ListKind.Deck) "Duplicate deck" else "Duplicate cube", "A new list with these cards", onClick = {
                scope.launch { runCatching { ListsStore.duplicate(list.id) }.getOrNull()?.let { editing = false; onOpen(it) } }
            })
            if (editing) ListRow(if (list.kind == ListKind.Deck) "Delete deck" else "Delete cube", "From every device", onClick = { confirmDelete = true })
            ListRow("Add cards", if (list.kind == ListKind.Deck) "To the main deck, sideboard or considering" else "To the cube or considering", onClick = onAdd)
            ListRow("Version history", "v${list.current.number} · ${list.current.note} · ${fmtDate(list.current.at)}", onClick = onVersions) {
                Text("${list.versions.size}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
            }
            if (list.entries.isEmpty()) ListRow("No cards yet", "Add cards to start this list")
        }
    }

    T1Screen {
        Bar(list.name, subtitle = "${list.format} ${list.kind.wire} · v${list.current.number}") {
            BarAction(if (editing) "Done" else "Edit") { editing = !editing }
            if (!editing) BarAction(if (grid) "List" else "Grid") { grid = !grid; prefs.edit().putBoolean("list.grid", grid).apply() }
            BarAction("Back", onBack)
        }
        s.error?.let { Notice(it, error = true) }
        if (grid && !editing) {
            // The grid keeps the organization: section header, then type (decks) or color (cubes) headers.
            CardGrid(Modifier.weight(1f)) { tile ->
                gridHeader("top") { top() }
                for (board in list.boards) {
                    val inBoard = rows.filter { it.board == board }
                    gridHeader("b-$board") { BoardHeader(list.boardTitle(board), inBoard.sumOf { it.qty }) }
                    for (g in groups(inBoard, list.kind)) {
                        val inGroup = inBoard.filter { it.group == g }
                        gridHeader("g-$board-$g") { Section("$g · ${inGroup.sumOf { it.qty }}") }
                        gridItems(inGroup, key = { "t-${it.key}" }) { x ->
                            CardTile(x.printing, x.qty, tile, warn = (board != "maybe" && (owned[x.ownKey] ?: 0) < x.qty) || issues.containsKey(x.oracleId ?: x.cardId),
                                onClick = { x.oracleId?.let(onCard) })
                        }
                    }
                }
            }
        } else {
            LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                item(key = "top") { top() }
                for (board in list.boards) {
                    val inBoard = rows.filter { it.board == board }
                    item(key = "b-$board") { BoardHeader(list.boardTitle(board), inBoard.sumOf { it.qty }) }
                    for (g in groups(inBoard, list.kind)) {
                        val inGroup = inBoard.filter { it.group == g }
                        item(key = "g-$board-$g") { Section("$g · ${inGroup.sumOf { it.qty }}") }
                        items(inGroup, key = { "r-${it.key}" }) { x ->
                            val have = owned[x.ownKey] ?: 0
                            val considering = x.board == "maybe"
                            val short = !considering && have < x.qty
                            if (editing) {
                                Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                                    Box(Modifier.weight(1f)) {
                                        CardRow(x.printing, x.name, listOfNotNull(x.finishLabel, "Tap to move, change or remove").joinToString(" · "), onClick = { moving = x }) {
                                            Text("${x.qty}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                                        }
                                    }
                                    Step("−") { scope.launch { runCatching { ListsStore.add(list.id, x.cardId, x.board, -1, x.finish) } } }
                                    Step("+") { scope.launch { runCatching { ListsStore.add(list.id, x.cardId, x.board, 1, x.finish) } } }
                                }
                            } else {
                                val issue = issues[x.oracleId ?: x.cardId]
                                val owns = if (considering) (if (have > 0) "Owned $have" else "Not owned") else if (short) "Owned $have · missing ${x.qty - have}" else "Owned $have"
                                CardRow(x.printing, x.name, listOfNotNull(issue, x.finishLabel, owns).joinToString(" · "),
                                    onClick = { x.oracleId?.let(onCard) }) {
                                    Text("${x.qty}", color = if (short || issue != null) T1.error else T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    moving?.let { x ->
        T1Menu(x.name, list.sections.filter { it != x.board }.map { b ->
            T1MenuItem("Move to ${list.boardTitle(b)}") { scope.launch { runCatching { ListsStore.move(list.id, x.cardId, x.board, b, x.finish) } } }
        } + T1MenuItem("Change printing or finish") { onPrinting(x.cardId, x.board, x.finish) } +
            T1MenuItem("Remove from ${list.boardTitle(x.board)}", danger = true) {
            scope.launch { runCatching { ListsStore.remove(list.id, x.cardId, x.board, x.finish) } }
        }, onDismiss = { moving = null })
    }
    if (confirmDelete) {
        T1Menu("Delete ${list.name}? It goes from every device.", listOf(
            T1MenuItem(if (list.kind == ListKind.Deck) "Delete deck" else "Delete cube", danger = true) {
                scope.launch { runCatching { ListsStore.delete(list.id) }.onSuccess { onBack() } }
            },
        ), onDismiss = { confirmDelete = false })
    }
}

@Composable
private fun Step(glyph: String, onClick: () -> Unit) {
    Box(Modifier.width(52.dp).fillMaxHeight().background(T1.surfaceHover).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Text(glyph, color = T1.text, fontFamily = T1.mono, fontSize = 22.sp)
    }
}

/* ── adding cards to a list ───────────────────────────────────────────── */

@Composable
fun ListAddScreen(listId: String, onDone: () -> Unit, onCard: (String) -> Unit) {
    val s by ListsStore.state.collectAsState()
    val cat by CatalogStore.state.collectAsState()
    val list = s.lists.firstOrNull { it.id == listId } ?: run { T1Screen { Bar("Add cards") { BarAction("Done", onDone) } }; return }
    val scope = rememberCoroutineScope()
    var query by remember { mutableStateOf("") }
    var board by remember { mutableStateOf(0) }
    var hits by remember { mutableStateOf<List<CatalogOracle>>(emptyList()) }
    var covers by remember { mutableStateOf<Map<Int, CatalogPrinting>>(emptyMap()) }
    LaunchedEffect(query, cat.generation) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        delay(120)
        val q = query
        val found = withContext(Dispatchers.Default) { db.search(q).let { h -> h to db.covers(h.map { it.idx }) } }
        hits = found.first; covers = found.second
    }
    val b = list.sections[board.coerceIn(0, list.sections.size - 1)]
    T1Screen {
        Bar("Add to ${list.name}", subtitle = "v${list.current.number}") { BarAction("Done", onDone) }
        T1Segmented(list.sections.map { list.boardTitle(it) }, board) { board = it }
        Box(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp)) {
            T1TextField(query, { query = it }, label = "Card name")
        }
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            items(hits, key = { it.idx }) { o ->
                val p = covers[o.idx]
                val inList = p?.let { pc -> list.entries.filter { it.cardId == pc.cardId && it.board == b }.sumOf { it.qty } } ?: 0
                Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    Box(Modifier.weight(1f)) {
                        CardRow(p, o.name, if (inList > 0) "$inList in ${list.boardTitle(b)}" else o.typeLine, onClick = { onCard(o.oracleId) })
                    }
                    Box(Modifier.fillMaxHeight().background(T1.surfaceHover).clickable(enabled = p != null) {
                        p?.let { scope.launch { runCatching { ListsStore.add(list.id, it.cardId, b, 1) } } }
                    }.padding(horizontal = 16.dp), contentAlignment = Alignment.Center) {
                        Label("+ Add", color = if (p == null) T1.disabled else T1.text)
                    }
                }
            }
        }
    }
}

/* ── version history ──────────────────────────────────────────────────── */

@Composable
fun ListVersionsScreen(listId: String, onBack: () -> Unit, onOpen: (Int) -> Unit) {
    val s by ListsStore.state.collectAsState()
    val list = s.lists.firstOrNull { it.id == listId }
    T1Screen {
        Bar("Version history", subtitle = list?.name) { BarAction("Back", onBack) }
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
        Bar("v$number · ${v?.note ?: ""}", subtitle = list?.name) { BarAction("Back", onBack) }
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

/* ── a line's printing and finish ─────────────────────────────────────── */

/**
 * Moves some or all copies of one line to another printing or finish. Splitting 4 non-foil into 2 non-foil
 * and 2 foil is "move 2" to the foil finish of the same printing.
 */
@Composable
fun LinePrintingScreen(listId: String, cardId: String, board: String, finish: String, onDone: () -> Unit) {
    val s by ListsStore.state.collectAsState()
    val cat by CatalogStore.state.collectAsState()
    val scope = rememberCoroutineScope()
    val list = s.lists.firstOrNull { it.id == listId }
    val have = list?.entries?.firstOrNull { it.cardId == cardId && it.board == board && it.finish == finish }?.qty ?: 0
    var count by remember { mutableStateOf(0) }
    var name by remember { mutableStateOf("") }
    var printings by remember { mutableStateOf<List<CatalogPrinting>>(emptyList()) }
    LaunchedEffect(cat.generation) {
        CatalogStore.load(userInitiated = true)
        val db = CatalogStore.db ?: return@LaunchedEffect
        val found = withContext(Dispatchers.Default) {
            val p = db.printings(listOf(cardId))[cardId] ?: return@withContext null
            val o = db.oracles(listOf(p.oracleIdx))[p.oracleIdx] ?: return@withContext null
            o.name to db.printings(o.idx)
        }
        if (found != null) { name = found.first; printings = found.second }
    }
    val n = minOf(maxOf(if (count == 0) have else count, 1), have)
    val fin = { f: String -> f.replaceFirstChar { it.uppercase() }.let { if (f == "nonfoil") "Non-foil" else it } }
    T1Screen {
        Bar("Printing", subtitle = name) { BarAction("Done", onDone) }
        if (list == null || have == 0) { Notice("This line has no copies left."); return@T1Screen }
        val current = printings.firstOrNull { it.cardId == cardId }
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            item {
                CardRow(current, name, listOfNotNull(current?.setLabel, fin(finish), list.boardTitle(board)).joinToString(" · ")) {
                    Text("$have", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                }
            }
            item {
                Row(Modifier.fillMaxWidth().height(52.dp).background(T1.surface), horizontalArrangement = Arrangement.spacedBy(1.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f).padding(horizontal = 16.dp)) { Label("Change $n of $have") }
                    Step("−") { count = maxOf(1, n - 1) }
                    Step("+") { count = minOf(have, n + 1) }
                }
            }
            item { Section("Move them to") }
            items(printings, key = { it.cardId }) { p ->
                Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min).background(T1.surface), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    Box(Modifier.weight(1f)) {
                        CardRow(p, p.setLabel, listOfNotNull(CatalogPack.RARITY_NAME[p.rarity], p.releasedAt.take(4).ifEmpty { null },
                            if (p.original) "Original" else null, if (p.lang != "en") p.lang.uppercase() else null).joinToString(" · "))
                    }
                    p.finishList.forEach { f ->
                        val same = p.cardId == cardId && f.wire == finish
                        Box(Modifier.fillMaxHeight().background(T1.surfaceHover)
                            .clickable(enabled = !same) {
                                scope.launch { runCatching { ListsStore.swap(listId, cardId, board, finish, p.cardId, f.wire, n) } }
                                onDone()
                            }.padding(horizontal = 12.dp), contentAlignment = Alignment.Center) {
                            Label(if (same) "Current" else fin(f.wire), color = if (same) T1.disabled else T1.text)
                        }
                    }
                }
            }
        }
    }
}
