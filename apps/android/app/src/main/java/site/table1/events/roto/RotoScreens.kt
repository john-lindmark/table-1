package site.table1.events.roto

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import site.table1.events.library.CardArt
import site.table1.events.library.CatalogStore
import site.table1.events.library.ListKind
import site.table1.events.library.ListsStore
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Ghost
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1AlertDialog
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Panel
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1Stepper
import site.table1.events.ui.components.T1Switch
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry

/* The roto draft on Android (contract/roto-2026-10-16.md § Views): a one-line summary, then Grid / Cube / Picks / My
   list in a Table 1 segmented control; organizers also get Pick for, Undo last pick and the pick clock. Plus the
   pieces inside the event screens: Pairing, the cube and picks in Details, Pick order, Start draft and the round robin
   schedule. Same layout and behaviour as iOS RotoDraftView / RotoSetup and web RotoDraft / RotoSetup. */

private val COLOR_HEX = mapOf("W" to Color(0xFFF5EDCC), "U" to Color(0xFF408CF2), "B" to Color(0xFF8C8094), "R" to Color(0xFFEB5445),
    "G" to Color(0xFF40B366), "C" to Color(0xFF9E9EA8), "L" to Color(0xFF9E9EA8))

@Composable
private fun ColorBar(card: RotoCard?, vertical: Boolean, modifier: Modifier) {
    val list = card?.colors?.takeIf { it.isNotEmpty() } ?: listOf(if (card?.isLand == true) "L" else "C")
    if (vertical) Column(modifier) { list.forEach { Box(Modifier.weight(1f).fillMaxWidth().background(COLOR_HEX[it]!!)) } }
    else Row(modifier) { list.forEach { Box(Modifier.weight(1f).fillMaxHeight().background(COLOR_HEX[it]!!)) } }
}

private fun typeDetail(c: RotoCard): String {
    val type = c.typeLine.split(" — ").first()
    return if (c.isLand) type else "$type · ${c.manaValue}"
}

/** The Draft once it has started (or is done); before that, [setup]. Keeps the draft live while shown. */
@Composable
fun RotoDraftGate(eventId: String, title: String, isOrganizer: Boolean, onBack: () -> Unit, pairRound1: (suspend () -> Unit)?,
                  onOpenDeck: (String) -> Unit, setup: @Composable () -> Unit) {
    val store = remember(eventId) { RotoStore.of(eventId) }
    val v by store.view.collectAsState()
    LaunchedEffect(eventId) { store.load() }
    if (!v.loaded && v.error == null) { T1Screen { Bar(title, "Loading draft…", onBack = onBack) }; return }
    if (v.phase == "setup") { setup(); return }
    RotoDraftScreen(store, title, isOrganizer, readOnly = false, onBack = onBack, pairRound1 = pairRound1, onOpenDeck = onOpenDeck)
}

@Composable
fun RotoDraftScreen(store: RotoStore, title: String, isOrganizer: Boolean, readOnly: Boolean, onBack: () -> Unit,
                    pairRound1: (suspend () -> Unit)? = null, pairing: String? = null, onOpenDeck: (String) -> Unit = {}) {
    val v by store.view.collectAsState()
    val scope = rememberCoroutineScope()
    var tab by remember { mutableStateOf("grid") }
    var panel by remember { mutableStateOf<Pair<Int, String>?>(null) }
    var menu by remember { mutableStateOf(false) }
    var clockPanel by remember { mutableStateOf(false) }
    var confirmUndo by remember { mutableStateOf(false) }
    var pairBusy by remember { mutableStateOf(false) }
    var pairError by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(store) { store.load() }
    LaunchedEffect(store) { store.listen() }
    val tabs = if (v.me != null) listOf("grid", "cube", "picks", "list") else listOf("grid", "cube", "picks")
    val shown = if (tab in tabs) tab else "grid"
    LaunchedEffect(shown) { Telemetry.screen("roto_$shown") }
    fun openDeck(from: String) {
        val id = v.me?.deckListId ?: return
        Telemetry.capture("roto_deck_opened", mapOf("from" to from))
        onOpenDeck(id)
    }
    val organizerLive = isOrganizer && !readOnly && v.phase == "drafting"
    val pickFor = organizerLive && v.onClock != null && v.onClock?.participantId != v.me?.participantId
    T1Screen {
        Bar(title, listOf(if (readOnly && pairing != null) (if (pairing == "round_robin") "Round robin" else "Swiss") else "Draft", "${v.players} players",
            "${v.draft.picksPerPlayer} picks each", if (v.draft.snake) "Snake" else "Same order").joinToString(" · "), onBack = onBack) {
            if (organizerLive) BarAction("More") { menu = true }
        }
        Summary(store, v, if (pickFor) ({ tab = "cube" }) else null)
        (pairError ?: v.error)?.let { Notice(it, error = true) }
        v.notice?.let { Notice(it) }
        T1Segmented(tabs.map { mapOf("grid" to "Grid", "cube" to "Cube", "picks" to "Picks", "list" to "My list")[it]!! }, tabs.indexOf(shown)) { i ->
            if (shown == "list" && tabs[i] != "list") store.dismissTaken()  // "Taken by …" shows once
            tab = tabs[i]
        }
        Box(Modifier.weight(1f)) {
            when (shown) {
                "grid" -> Grid(v, interactive = !readOnly, onCell = { panel = it to "grid" }, onNext = { tab = "cube" })
                "cube" -> Cube(v) { panel = it to "cube" }
                "picks" -> Picks(v, onOpen = { panel = it to "detail" }, onOpenDeck = { openDeck("picks") })
                else -> MyList(store, v, readOnly, onOpen = { panel = it to "list" }, onAdd = { store.dismissTaken(); tab = "cube" })
            }
        }
        if (pairRound1 != null && v.phase == "done" && !readOnly) {
            BigAction("Pair round 1", busy = pairBusy, accent = true) {
                pairBusy = true; pairError = null
                scope.launch { runCatching { pairRound1() }.onFailure { pairError = it.message }; pairBusy = false }
            }
        } else if (v.phase == "done" && v.me?.deckListId != null && !readOnly) {
            BigAction("Open deck", accent = true) { openDeck("event") }
        }
    }
    panel?.let { (slot, from) -> CardPanel(store, v, slot, from, isOrganizer, readOnly) { panel = null } }
    if (menu) T1Menu("Draft", listOfNotNull(
        v.onClock?.takeIf { pickFor }?.let { c -> T1MenuItem("Pick for ${v.name(c.seat)}") { tab = "cube" } },
        T1MenuItem("Undo last pick", enabled = v.picksMade > 0) { confirmUndo = true },
        if (!v.draft.clock.isNullOrEmpty()) T1MenuItem(if (v.draft.clockPaused) "Resume clock" else "Pause clock") {
            scope.launch { store.setClock(null, !v.draft.clockPaused) }
        } else null,
        T1MenuItem("Pick clock · " + (v.draft.clock?.size?.takeIf { it > 0 }?.let { "$it range${if (it == 1) "" else "s"}" } ?: "Off")) { clockPanel = true },
    )) { menu = false }
    if (clockPanel) T1Panel(if (v.draft.clockPaused) "Pick clock · paused" else "Pick clock", { clockPanel = false }) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            ClockEditor(v.draft.clock.orEmpty(), v.draft.picksPerPlayer) { r -> store.setClock(r) }
            if (!v.draft.clock.isNullOrEmpty()) Row { Ghost(if (v.draft.clockPaused) "Resume clock" else "Pause clock") { scope.launch { store.setClock(null, !v.draft.clockPaused) } } }
            Notice("Changes apply from the next turn; the current turn keeps its time.")
            v.error?.let { Notice(it, error = true) }
        }
    }
    if (confirmUndo) T1AlertDialog("Undo the last pick?", onDismiss = { confirmUndo = false },
        confirm = { TextButton(onClick = { scope.launch { store.undo(); confirmUndo = false } }) { Label("Undo", color = T1.danger) } },
        dismiss = { TextButton(onClick = { confirmUndo = false }) { Label("Keep it", color = T1.text) } },
        body = { Text("Removes the last pick a person made and any automatic picks after it. Their decks follow.", color = T1.muted, fontFamily = T1.mono, fontSize = 13.sp) })
}

/** `ON THE CLOCK · ANNA · PICK 37/360`, then `YOU PICK IN 3` / `YOUR PICK` (accent) and the clock. */
@Composable
private fun Summary(store: RotoStore, v: RotoView, onPickFor: (() -> Unit)?) {
    val ticking = v.phase == "drafting" && !v.draft.clock.isNullOrEmpty() && !v.draft.clockPaused
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(ticking) { while (ticking) { now = System.currentTimeMillis(); store.expireIfDue(now); delay(1000) } }
    val c = v.onClock
    val head = when {
        v.phase == "done" -> "Draft done · ${v.picksMade} picks"
        v.pending != null -> "Picking · ${v.card(v.pending.slot)?.name ?: "card"} · pick ${v.pending.pickNo}/${v.total}"
        c != null -> "On the clock · ${v.name(c.seat)} · pick ${c.pickNo}/${v.total}"
        else -> "Draft not started"
    }
    val until = v.picksUntilMine
    val turn = if (v.phase != "drafting") null else when {
        until == 0 -> "Your pick"
        until != null -> "You pick in $until"
        v.me != null -> "Your picks are done"
        else -> "Watching"
    }
    val clock = if (v.phase == "drafting" && !v.draft.clock.isNullOrEmpty() && v.pending == null && c != null) {
        val left = v.secondsLeft(now)
        when {
            v.draft.clockPaused -> " · Paused"
            c.overdue || left == 0 -> " · Overdue"
            left != null -> " · " + RotoMath.countdownText(left)
            else -> ""
        }
    } else ""
    Row(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Label(head, color = T1.text)
            turn?.let { Label(it + clock, color = if (until == 0) T1.accent else if (clock.contains("Overdue")) T1.danger else T1.muted) }
        }
        onPickFor?.let { Box(Modifier.background(T1.surfaceHover).clickable(onClick = it).padding(horizontal = 12.dp, vertical = 10.dp)) { Label("Pick for", color = T1.text) } }
    }
}

private val CELL_W = 108.dp
private val CELL_H = 46.dp
private val COL_W = 44.dp

/** The classic roto sheet: seats across, rounds down (with the snake direction); lazy rows, so 12 × 45 scrolls smoothly. */
@Composable
private fun Grid(v: RotoView, interactive: Boolean, onCell: (Int) -> Unit, onNext: () -> Unit) {
    val seats = v.orderedSeats
    if (seats.isEmpty()) { Notice("No one is seated yet."); return }
    val n = maxOf(1, v.players)
    val rounds = maxOf(1, v.draft.picksPerPlayer)
    val next = if (v.phase == "drafting" && v.pending == null) v.picksMade + 1 else null
    val current = RotoMath.round(n, minOf(v.total, maxOf(1, v.picksMade + 1)))
    val list = rememberLazyListState(initialFirstVisibleItemIndex = maxOf(0, current - 3))
    val h = rememberScrollState()
    val width = COL_W + 1.dp + (CELL_W + 1.dp) * n
    Box(Modifier.fillMaxSize().horizontalScroll(h)) {
        LazyColumn(Modifier.width(width).fillMaxHeight(), state = list, verticalArrangement = Arrangement.spacedBy(1.dp)) {
            stickyHeaderRow(seats)
            items(rounds, key = { it }) { i ->
                val round = i + 1
                Row(Modifier.height(CELL_H), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    Column(Modifier.width(COL_W).fillMaxHeight().background(if (round == current) T1.surfaceHover else T1.surface),
                        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                        Text("$round", color = if (round == current) T1.text else T1.muted, fontFamily = T1.mono, fontSize = 11.sp)
                        Text(if (v.draft.snake && round % 2 == 0) "←" else "→", color = T1.muted, fontFamily = T1.mono, fontSize = 10.sp)
                    }
                    for (seat in 1..n) {
                        val no = RotoMath.pickNo(seat, round, n, v.draft.snake)
                        val p = if (no <= v.total) v.pick(no) else null
                        val card = p?.let { v.card(it.slot) }
                        val isNext = next == no
                        Column(Modifier.width(CELL_W).fillMaxHeight().background(T1.surface)
                            .let { if (isNext) it.border(1.dp, T1.accent) else it }
                            .clickable { if (p != null) onCell(p.slot) else if (isNext && interactive) onNext() }) {
                            if (card != null) ColorBar(card, false, Modifier.fillMaxWidth().height(3.dp))
                            Column(Modifier.padding(horizontal = 6.dp, vertical = 4.dp)) {
                                when {
                                    card != null -> {
                                        Text(card.name, color = if (v.pending?.pickNo == no) T1.muted else T1.text, fontFamily = T1.mono, fontSize = 10.sp,
                                            lineHeight = 12.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                        if (p.automatic) Text("AUTO", color = T1.muted, fontFamily = T1.mono, fontSize = 8.sp)
                                    }
                                    isNext -> Text("#$no", color = T1.accent, fontFamily = T1.mono, fontSize = 10.sp)
                                    no <= v.total -> Text("$no", color = T1.disabled, fontFamily = T1.mono, fontSize = 9.sp)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
private fun androidx.compose.foundation.lazy.LazyListScope.stickyHeaderRow(seats: List<RotoSeat>) {
    stickyHeader(key = "head") {
        Row(Modifier.height(34.dp).background(T1.bg), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            Box(Modifier.width(COL_W).fillMaxHeight().background(T1.surface), contentAlignment = Alignment.Center) { Label("Rd") }
            seats.forEach { s ->
                Box(Modifier.width(CELL_W).fillMaxHeight().background(T1.surface).padding(horizontal = 6.dp), contentAlignment = Alignment.CenterStart) {
                    Label(if (s.me) "You" else s.displayName, color = if (s.me) T1.accent else T1.muted)
                }
            }
        }
    }
}

/** Every card in the pool by colour, with search and Available · All · Picked; picked ones carry `#23 · ANNA`. */
@Composable
private fun Cube(v: RotoView, onOpen: (Int) -> Unit) {
    var query by remember { mutableStateOf("") }
    var filter by remember { mutableStateOf(0) } // available, all, picked
    val q = query.trim().lowercase()
    val groups = remember(v.poolOrder, v.picks, v.pending, v.cards, q, filter) {
        val by = LinkedHashMap<String, MutableList<Int>>()
        for (slot in v.poolOrder) {
            val taken = v.takenBy(slot) != null
            if ((filter == 0 && taken) || (filter == 2 && !taken)) continue
            val card = v.card(slot) ?: continue
            if (q.isNotEmpty() && !card.name.lowercase().contains(q)) continue
            by.getOrPut(card.group) { mutableListOf() }.add(slot)
        }
        RotoCard.GROUPS.filter { by.containsKey(it) }.map { it to by[it]!! }
    }
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Box(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 10.dp)) {
            T1TextField(query, { query = it }, placeholder = "Search the cube")
        }
        T1Segmented(listOf("Available", "All", "Picked"), filter) { filter = it }
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (v.pool.isEmpty()) item { Notice(if (v.loaded) "The pool appears when the draft starts." else "Loading…") }
            for ((g, slots) in groups) {
                item(key = "g$g") { Section("$g · ${slots.size}") }
                items(slots, key = { it }) { slot ->
                    val card = v.card(slot)
                    val taken = v.takenBy(slot)
                    val listed = v.inList(slot)
                    Row(Modifier.fillMaxWidth().background(T1.surface).clickable { onOpen(slot) }.padding(horizontal = 16.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        ColorBar(card, true, Modifier.width(3.dp).height(28.dp))
                        Column(Modifier.weight(1f)) {
                            Text(card?.name ?: "Card", color = if (taken != null) T1.muted else T1.text, fontFamily = T1.mono, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Label(card?.let(::typeDetail) ?: "")
                        }
                        when {
                            taken != null -> Box(Modifier.background(T1.disabled).padding(horizontal = 8.dp, vertical = 4.dp)) { Label("#${taken.pickNo} · ${v.name(taken.seat)}", color = Color.White) }
                            listed != null -> Label("Listed #$listed")
                        }
                    }
                }
            }
            if (v.pool.isNotEmpty() && groups.isEmpty()) item { Notice(if (q.isNotEmpty()) "No card matches “${query.trim()}”" else "Nothing here.") }
        }
    }
}

/** One player's picks: You first, then seat order. Colour counts, a mana-value curve, creatures; Open deck for you. */
@Composable
private fun Picks(v: RotoView, onOpen: (Int) -> Unit, onOpenDeck: () -> Unit) {
    val seated = v.orderedSeats.filter { it.seat != null }
    val choices = seated.filter { it.me } + seated.filter { !it.me }
    var seat by remember { mutableStateOf<Int?>(null) }
    val chosen = seat ?: choices.firstOrNull()?.seat ?: 1
    val slots = v.picksOf(chosen).map { it.slot }
    val cards = slots.mapNotNull { v.card(it) }
    val mine = v.seat(chosen)?.me == true
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            choices.forEach { x ->
                val on = x.seat == chosen
                Box(Modifier.background(if (on) T1.text else T1.surface).clickable { seat = x.seat }.padding(horizontal = 14.dp, vertical = 14.dp)) {
                    Label(if (x.me) "You" else x.displayName, color = if (on) T1.bg else T1.text)
                }
            }
        }
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            item { PickStats(cards) }
            if (mine && v.me?.deckListId != null) item { ListRow("Open deck", "Your picks land in Main as you draft", onClick = onOpenDeck) { Label("›", color = T1.text) } }
            item { Section("${cards.size} pick${if (cards.size == 1) "" else "s"}") }
            if (cards.isEmpty()) item { Notice("No picks yet.") }
            for (g in RotoCard.GROUPS) {
                val inGroup = slots.filter { v.card(it)?.group == g }
                if (inGroup.isEmpty()) continue
                item(key = "pg$g") { Section("$g · ${inGroup.size}") }
                items(inGroup, key = { "p$it" }) { slot ->
                    val c = v.card(slot)!!
                    val p = v.takenBy(slot)
                    ListRow(c.name, typeDetail(c), onClick = { onOpen(slot) }) { p?.let { Label("#${it.pickNo}" + if (it.automatic) " · auto" else "", color = T1.text) } }
                }
            }
        }
    }
}

@Composable
private fun PickStats(cards: List<RotoCard>) {
    val spells = cards.filter { !it.isLand }
    val curve = (0..7).map { mv -> spells.count { if (mv == 7) it.manaValue >= 7 else it.manaValue == mv } }
    val top = maxOf(1, curve.max())
    val creatures = spells.count { it.isCreature }
    Column(Modifier.fillMaxWidth().background(T1.surface).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            listOf("W", "U", "B", "R", "G").forEach { c ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Box(Modifier.size(8.dp).background(COLOR_HEX[c]!!))
                    Text("${cards.count { c in it.colors }}", color = T1.text, fontFamily = T1.mono, fontSize = 13.sp)
                }
            }
        }
        Row(Modifier.fillMaxWidth().height(70.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.Bottom) {
            curve.forEachIndexed { i, n ->
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text("$n", color = T1.muted, fontFamily = T1.mono, fontSize = 9.sp)
                    Box(Modifier.fillMaxWidth().height(maxOf(1f, n.toFloat() / top * 40f).dp).background(T1.text))
                    Text(if (i == 7) "7+" else "$i", color = T1.muted, fontFamily = T1.mono, fontSize = 9.sp)
                }
            }
        }
        Label("$creatures creatures · ${spells.size - creatures} other spells · ${cards.size - spells.size} lands")
    }
}

/** Your ranked pick order: ↑ ↓ to reorder, × to remove, the auto-pick switch. Saved ~600 ms after the last change. */
@Composable
private fun MyList(store: RotoStore, v: RotoView, readOnly: Boolean, onOpen: (Int) -> Unit, onAdd: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        ListRow("Auto-pick from my list", if (v.autoPick) "When it's your turn, the top card still there is picked for you" else "Off: the draft waits for you") {
            T1Switch(v.autoPick, enabled = !readOnly) { store.setAutoPick(it) }
        }
        v.takenFromList.forEach { (slot, p) -> Notice("${v.card(slot)?.name ?: "A card"} · taken by ${v.name(p.seat)} (#${p.pickNo})") }
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (v.queue.isEmpty()) item {
                Notice("Nothing listed. Add cards from the cube in the order you want them; with auto-pick on they're picked for you when your turn comes.")
            }
            itemsIndexed(v.queue, key = { _, s -> s }) { i, slot ->
                val c = v.card(slot)
                Row(Modifier.fillMaxWidth().height(48.dp).background(T1.surface).padding(start = 12.dp), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("${i + 1}", Modifier.width(24.dp), color = T1.muted, fontFamily = T1.mono, fontSize = 12.sp)
                    ColorBar(c, true, Modifier.width(3.dp).height(24.dp))
                    Text(c?.name ?: "Card", Modifier.weight(1f).clickable { onOpen(slot) }, color = T1.text, fontFamily = T1.mono, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    if (!readOnly) Row {
                        Arrow("↑", i > 0) { store.moveInList(i, i - 1) }
                        Arrow("↓", i < v.queue.size - 1) { store.moveInList(i, i + 1) }
                        Arrow("×", true) { store.removeFromList(slot) }
                    }
                }
            }
        }
        if (!readOnly) Row { Ghost("Add from the cube", onClick = onAdd) }
    }
}

@Composable
private fun Arrow(text: String, enabled: Boolean, onClick: () -> Unit) =
    Box(Modifier.size(40.dp, 48.dp).clickable(enabled = enabled, onClick = onClick), contentAlignment = Alignment.Center) {
        Text(text, color = if (enabled) T1.muted else T1.disabled, fontFamily = T1.mono, fontSize = if (text == "×") 18.sp else 14.sp)
    }

/** A card from the pool: picture, who took it, and Pick (your turn; organizers: Pick for) / your list. */
@Composable
private fun CardPanel(store: RotoStore, v: RotoView, slot: Int, from: String, isOrganizer: Boolean, readOnly: Boolean, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    var confirm by remember { mutableStateOf(false) }
    val card = v.card(slot)
    val taken = v.takenBy(slot)
    val clock = v.onClock
    val canPick = !readOnly && taken == null && v.phase == "drafting" && v.pending == null && (v.isMyTurn || (isOrganizer && clock != null))
    val forWhom = clock?.takeIf { it.participantId != v.me?.participantId }?.let { v.name(it.seat) }
    val listed = v.inList(slot)
    val printing by produceState<site.table1.events.library.CatalogPrinting?>(null, slot) {
        value = v.pool[slot]?.cardId?.let { id -> CatalogStore.db?.printings(listOf(id))?.get(id) }
    }
    T1Panel(card?.name ?: "Card", onClose) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            card?.typeLine?.takeIf { it.isNotEmpty() }?.let { Section(it) }
            Box(Modifier.fillMaxWidth().background(T1.surface).padding(vertical = 16.dp), contentAlignment = Alignment.Center) {
                CardArt(printing, 220.dp, finish = v.pool[slot]?.finish ?: "nonfoil")
            }
            if (taken != null) ListRow("Picked #${taken.pickNo} by ${v.name(taken.seat)}",
                when (taken.how) { "player" -> null; "organizer" -> "Picked by the organizer"; else -> "Picked from their list" })
            else ListRow("Available", listed?.let { "On your list at #$it" })
            if (!readOnly && taken == null && v.me != null && v.phase != "done") Row {
                Ghost(if (listed != null) "Remove from my list" else "Add to my list") { if (listed != null) store.removeFromList(slot) else store.addToList(slot) }
            }
            Spacer(Modifier.height(8.dp))
        }
        if (canPick) BigAction(forWhom?.let { "Pick for $it" } ?: "Pick", accent = true) { confirm = true }
    }
    if (confirm) T1AlertDialog(forWhom?.let { "Pick ${card?.name ?: "this card"} for $it?" } ?: "Pick ${card?.name ?: "this card"}?",
        onDismiss = { confirm = false },
        confirm = { TextButton(onClick = { confirm = false; onClose(); scope.launch { store.pick(slot, from) } }) { Label("Pick", color = T1.accent) } },
        dismiss = { TextButton(onClick = { confirm = false }) { Label("Not yet", color = T1.text) } },
        body = { Text(if (forWhom != null) "Recorded as an organizer pick." else "It goes into your deck. Picks can't be taken back (the organizer can undo).",
            color = T1.muted, fontFamily = T1.mono, fontSize = 13.sp) })
}

/**
 * Optional time per pick on a schedule that quickens: ranges of rounds, each with a time (30 s to 24 h). Add a range
 * splits the last one. Saved ~600 ms after the last change.
 */
@Composable
fun ClockEditor(ranges: List<RotoClockRange>, rounds: Int, save: suspend (List<RotoClockRange>) -> Boolean) {
    var local by remember { mutableStateOf<List<RotoClockRange>?>(null) }
    var pick by remember { mutableStateOf<Int?>(null) }
    LaunchedEffect(local) {
        val next = local ?: return@LaunchedEffect
        delay(600)
        if (save(next)) local = null
    }
    val shown = local ?: ranges
    fun change(next: List<RotoClockRange>) { local = next }
    Section("Pick clock")
    ListRow("Pick clock", if (shown.isNotEmpty()) "Time per pick, by round" else "Off: no time limit") {
        T1Switch(shown.isNotEmpty()) { on -> change(if (on) listOf(RotoClockRange(1, 14400)) else emptyList()) }
    }
    shown.forEachIndexed { i, r ->
        val end = if (i + 1 < shown.size) shown[i + 1].fromRound - 1 else maxOf(rounds, r.fromRound)
        val low = if (i > 0) shown[i - 1].fromRound + 1 else 1
        val high = maxOf(low, (if (i + 1 < shown.size) shown[i + 1].fromRound else rounds + 1) - 1)
        ListRow(if (end > r.fromRound) "Rounds ${r.fromRound}–$end" else "Round ${r.fromRound}", if (i == 0) "From the first pick" else null, onClick = { pick = i }) {
            Label(RotoMath.durationText(r.seconds), color = T1.accent)
        }
        if (i > 0) Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            Box(Modifier.weight(1f)) {
                T1Stepper("Starts at round", r.fromRound, low..high) { v -> change(shown.mapIndexed { j, x -> if (j == i) x.copy(fromRound = v) else x }) }
            }
            Box(Modifier.width(84.dp).height(56.dp).background(T1.surface).clickable { change(shown.filterIndexed { j, _ -> j != i }) }, contentAlignment = Alignment.Center) {
                Label("Remove", color = T1.danger)
            }
        }
    }
    if (shown.isNotEmpty() && shown.size < 10 && rounds - shown.last().fromRound >= 1) Row { Ghost("Add a range") { change(RotoMath.addClockRange(shown, rounds)) } }
    if (shown.isNotEmpty()) Notice("Your time starts when your turn does. When it runs out, the first card on your list is picked; with nothing listed the draft waits and the organizer can pick for you.")
    pick?.let { i ->
        T1Menu("Time per pick", RotoMath.CLOCK_DURATIONS.map { d ->
            T1MenuItem(RotoMath.durationText(d), selected = shown.getOrNull(i)?.seconds == d) { change(shown.mapIndexed { j, x -> if (j == i) x.copy(seconds = d) else x }) }
        }) { pick = null }
    }
}

/* ── inside the event screens ─────────────────────────────────────── */

/** Roto only: Swiss · Round robin. Round robin hides the Rounds stepper. */
@Composable
fun RotoPairingFields(pairing: String, players: Int, onPairing: (String) -> Unit) {
    val n = RotoMath.roundRobinRounds(maxOf(2, players))
    Label("Pairing")
    T1Segmented(listOf("Swiss", "Round robin"), if (pairing == "round_robin") 1 else 0) { onPairing(if (it == 1) "round_robin" else "swiss") }
    if (pairing == "round_robin") Notice("$n round${if (n == 1) "" else "s"} · everyone plays everyone" +
        (if (players % 2 == 1 && players > 1) ", one bye a round" else "") + ". Set from the players when round 1 is paired.")
}

/** Setup → Pick order: seat 1 picks first. Start draft draws it at random unless the organizer draws it first. */
@Composable
fun RotoPickOrder(seated: List<Pair<Int, String>>, busy: Boolean, onSeat: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Row { Ghost(if (busy) "Working…" else if (seated.isNotEmpty()) "Re-draw" else "Draw pick order", enabled = !busy, accent = seated.isEmpty(), onClick = onSeat) }
        if (seated.isEmpty()) Notice("Seat 1 picks first. Draw the order now, or Start draft draws it at random.")
        else {
            Section("Pick order · snake: 1 → ${seated.size}, then back")
            seated.forEach { (seat, name) -> ListRow(name) { Text("$seat", color = T1.text, fontFamily = T1.mono, fontSize = 15.sp) } }
        }
    }
}

/** Setup → Details: the cube (one of your Library cubes, or a Cube Cobra link imported first), picks per player, order, clock. */
@Composable
fun RotoSetupFields(eventId: String, players: Int, onChanged: () -> Unit) {
    val store = remember(eventId) { RotoStore.of(eventId) }
    val v by store.view.collectAsState()
    val lists by ListsStore.state.collectAsState()
    val scope = rememberCoroutineScope()
    var link by remember { mutableStateOf("") }
    var working by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var maxPicks by remember { mutableStateOf<Int?>(null) }
    LaunchedEffect(eventId) { store.load() }
    val cubes = lists.lists.filter { it.kind == ListKind.Cube }
    val n = maxOf(1, players)
    val maxPer = minOf(100, maxPicks ?: if (v.draft.poolCount > 0) v.draft.poolCount / n else 100)
    val picks = maxOf(1, minOf(v.planPicks, maxPer))
    fun use(key: String, from: String, load: (suspend () -> String)?) {
        working = key; error = null
        scope.launch {
            try {
                val id = load?.invoke() ?: key
                val r = RotoApi.setCube(eventId, id, from)
                maxPicks = r.maxPicksPerPlayer
                if (store.view.value.planPicks > r.maxPicksPerPlayer) store.setPlan(picks = r.maxPicksPerPlayer)
                if (load != null) link = ""
                store.refresh(full = true)
                onChanged()
            } catch (e: Exception) {
                error = RotoStore.message(e)
            } finally { working = null }
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Section("Cube for the draft")
        if (cubes.isEmpty()) Notice(if (lists.ready) "No cubes in your Library yet. Paste a Cube Cobra link below to import one." else "Loading your cubes…")
        cubes.forEach { c ->
            val chosen = v.draft.sourceListId == c.id
            ListRow(c.name, "${c.entries.filter { it.board == "main" }.sumOf { it.qty }} cards · Library", onClick = if (working == null) ({ use(c.id, "library", null) }) else null) {
                Label(if (chosen) "Selected" else "Use", color = if (chosen) T1.accent else T1.text)
            }
        }
        Box(Modifier.fillMaxWidth().background(T1.surface).padding(16.dp)) {
            T1TextField(link, { link = it }, label = "Or a Cube Cobra link", placeholder = "https://cubecobra.com/cube/overview/…")
        }
        if (link.isNotBlank()) Row {
            Ghost(if (working == "import") "Importing…" else "Import into Library and use", enabled = working == null) {
                val url = link.trim()
                if (!url.startsWith("https://", ignoreCase = true)) error = "Paste a Cube Cobra link (https://cubecobra.com/…)"
                else use("import", "cube_cobra") { RotoApi.importCube(url) }
            }
        }
        if (working != null && working != "import") Notice("Setting the cube…")
        error?.let { Notice(it, error = true) }
        if (v.draft.poolCount > 0) Notice("${v.draft.poolCount} cards in the pool · up to $maxPer picks each for $n players.")
        Section("Picks")
        T1Stepper("Picks per player", picks, 1..maxOf(1, maxPer)) { store.setPlan(picks = it) }
        T1Segmented(listOf("Snake", "Same order"), if (v.planOrder == "fixed") 1 else 0) { store.setPlan(order = if (it == 1) "fixed" else "snake") }
        Notice(if (v.planOrder == "snake") "1 → $n, then $n → 1, and so on." else "Seat 1 picks first every round.")
        ClockEditor(v.draft.clock.orEmpty(), picks) { r -> store.setClock(r) }
    }
}

/** Setup's big action for a roto: Start draft (roto_start) instead of Pair round 1. */
@Composable
fun RotoStartAction(eventId: String, activePlayers: Int, onStarted: () -> Unit) {
    val store = remember(eventId) { RotoStore.of(eventId) }
    val v by store.view.collectAsState()
    val scope = rememberCoroutineScope()
    var confirm by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(eventId) { store.load() }
    val blocker = if (activePlayers < 2) "Add at least 2 players" else if (v.draft.sourceListId == null) "Choose a cube in Details" else null
    val maxPer = if (v.draft.poolCount > 0) v.draft.poolCount / maxOf(1, activePlayers) else 100
    val picks = maxOf(1, minOf(v.planPicks, maxPer, 100))
    BigAction(blocker ?: "Start draft", enabled = blocker == null, busy = busy, accent = true) { error = null; confirm = true }
    if (confirm) T1AlertDialog("Start the draft?", onDismiss = { confirm = false },
        confirm = { TextButton(enabled = !busy, onClick = {
            busy = true
            scope.launch {
                try {
                    RotoApi.start(eventId, picks, v.planOrder, v.draft.clock?.size ?: 0)
                    store.refresh(full = true)
                    confirm = false
                    onStarted()
                } catch (e: Exception) { error = RotoStore.message(e) } finally { busy = false }
            }
        }) { Label(if (busy) "Starting…" else "Start", color = T1.accent) } },
        dismiss = { TextButton(onClick = { confirm = false }) { Label("Not yet", color = T1.text) } },
        body = {
            Text((error?.let { "$it\n\n" } ?: "") + "$activePlayers players, $picks picks each, ${if (v.planOrder == "snake") "snake order" else "the same order every round"}. " +
                "Players and seats lock until the draft is done; everyone gets a deck in their Library that fills as they pick.",
                color = if (error != null) T1.danger else T1.muted, fontFamily = T1.mono, fontSize = 13.sp)
        })
}

/** Round robin: each player's opponents by round, played rounds with scores, the current one marked. */
@Composable
fun RotoSchedule(roster: List<Pair<String, String>>, meId: String?, rounds: Int, current: Int, result: (String, Int) -> String) {
    var player by remember { mutableStateOf<String?>(null) }
    val chosen = player ?: roster.firstOrNull { it.first == meId }?.first ?: roster.firstOrNull()?.first
    val total = maxOf(rounds, RoundRobin.rounds(roster.size))
    val names = roster.toMap()
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Section("Round ${maxOf(1, current)} of $total · everyone plays everyone")
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            roster.forEach { (id, name) ->
                val on = id == chosen
                Box(Modifier.background(if (on) T1.text else T1.surface).clickable { player = id }.padding(14.dp)) {
                    Label(if (id == meId) "You" else name, color = if (on) T1.bg else T1.text)
                }
            }
        }
        if (chosen != null) (1..maxOf(1, total)).forEach { r ->
            val opp = RoundRobin.pairs(roster.map { it.first }, r).firstNotNullOfOrNull { (a, b) -> if (a == chosen) b ?: "" else if (b == chosen) a ?: "" else null }
            ListRow(opp?.takeIf { it.isNotEmpty() }?.let { names[it] } ?: "Bye", if (r == current) "Round $r · playing now" else "Round $r") {
                Label(result(chosen, r), color = T1.text)
            }
        }
        if (roster.size < 2) Notice("The schedule appears once round 1 is paired.")
    }
}

/** The read-only Draft over Live / Results (players look at each other's picks during the matches), full screen. */
@Composable
fun RotoDraftOverlay(eventId: String, title: String, isOrganizer: Boolean, pairing: String, onOpenDeck: (String) -> Unit, onClose: () -> Unit) {
    val store = remember(eventId) { RotoStore.of(eventId) }
    androidx.compose.ui.window.Dialog(onDismissRequest = onClose, properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(T1.bg)) {
            RotoDraftScreen(store, title, isOrganizer, readOnly = true, onBack = onClose, pairing = pairing, onOpenDeck = { onClose(); onOpenDeck(it) })
        }
    }
}

/** The round robin schedule in a panel, from the event bundle (the engine's circle method over the pick order). */
@Composable
fun RotoScheduleSheet(b: site.table1.events.data.EventBundle, meId: String?, onClose: () -> Unit) {
    val roster = b.participants.filter { it.seat != null && (it.status == "active" || (it.droppedInRound ?: 0) >= 1) }.sortedBy { it.seat }
    val active = b.rounds.firstOrNull { it.status == "active" }
    val current = active?.number ?: (b.rounds.maxOfOrNull { it.number } ?: 0)
    T1Panel("Schedule", onClose) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            RotoSchedule(roster.map { it.id to it.displayName }, meId, b.event.numberOfRounds, current) { id, r ->
                val m = b.rounds.firstOrNull { it.number == r }?.matches?.firstOrNull { x -> x.sides.any { it.participantId == id } }
                when {
                    m != null && m.isBye -> "Bye"
                    m != null && m.status != "pending" -> {
                        val mine = m.sides.firstOrNull { it.participantId == id }?.gameWins ?: 0
                        val theirs = m.sides.firstOrNull { it.participantId != id }?.gameWins ?: 0
                        "${if (mine > theirs) "W" else if (mine < theirs) "L" else "D"} $mine–$theirs"
                    }
                    r < current -> "No result"
                    else -> ""
                }
            }
        }
    }
}
