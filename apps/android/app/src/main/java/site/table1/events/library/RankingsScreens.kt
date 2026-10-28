package site.table1.events.library

import android.graphics.Bitmap
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import site.table1.events.ui.components.Avatar
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.Field
import site.table1.events.ui.components.Ghost
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1AlertDialog
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.parseInstant
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/* Cube rankings (contract/cube-rankings-2026-10-21.md, "Where"), the same screens as iOS RankingsViews.swift: a Rankings
   row on each cube, a cube's rankings, one ranking's overview, the picking screen (drag, or tap two to swap), lists with
   each card's history, compare, P1P1 packs, the change log and the top 100 as a picture. */

private fun plural(n: Int, one: String, many: String? = null) = "%,d %s".format(n, if (n == 1) one else many ?: "${one}s")
private fun listTitle(job: RankJob, top: Int) = if (job == RankJob.Final) "Top $top" else job.title
private val dayFmt = DateTimeFormatter.ofPattern("EEE, MMM d", Locale.US)
private val shortFmt = DateTimeFormatter.ofPattern("MMM d", Locale.US)
private fun day(ms: Double?) = ms?.let { Instant.ofEpochMilli(it.toLong()).atZone(ZoneId.systemDefault()).format(dayFmt) } ?: "Earlier"

// ── the row on a cube

private val DEPTH_LABELS = listOf("Top 1/4", "Top 1/3", "Top half", "Every card")

/** What a depth means for this ranking (contract § Depth). */
private fun depthNote(depth: String, top: Int): String =
    if (depth == "full") "Every card of each color is put in order."
    else "Each color is ordered until its ${RankDepth.phrase(depth)} is in order; the rest sit below it. The final top $top still comes out exact: " +
        "if a color has more cards in it than that, the final asks about them itself."

@Composable
fun RankingsRow(listId: String, onOpen: () -> Unit) {
    var detail by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(listId) {
        runCatching { RankingsStore.rankings(listId) }.onSuccess { r ->
            val mine = r.rankings.firstOrNull { it.mine }
            detail = if (r.rankings.isEmpty()) "Rank this cube's cards"
            else listOfNotNull(plural(r.rankings.size, "ranking"), mine?.let { "yours: ${it.sorted}/${it.categories} sorted" }).joinToString(" · ")
        }
    }
    ListRow("Rankings", detail ?: "Stack-rank this cube's cards", onClick = onOpen)
}

// ── a cube's rankings, or all of yours

@Composable
fun RankingsScreen(listId: String?, onBack: () -> Unit, onOpen: (String) -> Unit, onCube: (String) -> Unit = {}) {
    LaunchedEffect(Unit) { Telemetry.screen("rankings") }
    val scope = rememberCoroutineScope()
    var data by remember { mutableStateOf<CubeRankings?>(null) }
    /** Every ranking of yours: other people's cubes you can rank too. */
    var rankable by remember { mutableStateOf<List<RankableCube>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    var creating by remember { mutableStateOf(false) }
    var top by remember { mutableStateOf(100) }
    // Follows the top until the person picks a depth: a quarter of each color for a top 50, a third for a top 100.
    var pickedDepth by remember { mutableStateOf<String?>(null) }
    val depth = pickedDepth ?: RankDepth.suggested(top)
    var sharing by remember { mutableStateOf("cube") }
    var busy by remember { mutableStateOf(false) }
    LaunchedEffect(listId) {
        runCatching { RankingsStore.rankings(listId) }.onSuccess { data = it; error = null }.onFailure { error = it.message }
        if (listId == null) runCatching { RankingsStore.rankable() }.onSuccess { rankable = it }
    }
    val cube = data?.cube
    T1Screen {
        Bar("Rankings", if (listId == null) "Yours, and cubes you can rank" else cube?.let { if (it.mine) it.name else "${it.name} · ${it.owner?.displayName ?: ""}" },
            onBack = onBack)
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            error?.let { Notice(it, error = true) }
            val d = data
            if (d == null) { if (error == null) Notice("Loading rankings…"); return@Column }
            if (listId != null) Notice("Sort each color by putting up to four cards in order at a time, then rank the best cards across the whole cube. " +
                "Everyone who can see this cube can watch and compare the rankings shared with it.")
            if (d.canRank && cube != null) {
                if (creating) {
                    T1Segmented(listOf("Top 100", "Top 50"), if (top == 100) 0 else 1) { top = if (it == 0) 100 else 50 }
                    T1Segmented(DEPTH_LABELS, RankDepth.all.indexOf(depth).coerceAtLeast(0)) { pickedDepth = RankDepth.all[it] }
                    Notice(depthNote(depth, top))
                    T1Segmented(listOf("Shared with the cube", "Only me"), if (sharing == "cube") 0 else 1) { sharing = if (it == 0) "cube" else "private" }
                    Notice(if (sharing == "cube") "Who sees this: everyone who can see ${cube.name}${if (cube.mine) "" else ", including ${cube.owner?.displayName ?: "its owner"}"}."
                           else "Who sees this: only you.")
                    Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                        Ghost("Cancel") { creating = false }
                        Ghost(if (busy) "Starting…" else "Start", accent = true) {
                            if (busy) return@Ghost
                            busy = true
                            scope.launch {
                                runCatching { RankingsStore.create(cube.id, "", depth, top, sharing, cube.mine) }
                                    .onSuccess { creating = false; onOpen(it.id) }.onFailure { error = it.message }
                                busy = false
                            }
                        }
                    }
                } else ListRow(if (cube.mine) "New ranking" else cube.owner?.let { "Rank ${it.displayName}'s cube" } ?: "Rank this cube",
                    if (cube.mine) "Sort each color, then the top 100" else "Your own ranking: each color, then the top 100", onClick = { creating = true })
            }
            val mine = d.rankings.filter { it.mine }; val others = d.rankings.filter { !it.mine }
            @Composable fun row(r: RankingRow) {
                ListRow(r.title, listOfNotNull(if (listId == null) r.cube?.name else null, r.progress).joinToString(" · "),
                    onClick = { onOpen(r.id) }, avatar = if (r.mine) null else ({ Avatar(r.by?.displayName ?: "?", r.by?.userId, 28) })) {
                    parseInstant(r.updatedAt)?.let { Label(Instant.ofEpochMilli(it).atZone(ZoneId.systemDefault()).format(shortFmt)) }
                }
            }
            if (mine.isNotEmpty()) { if (listId != null) Section("Yours"); mine.forEach { row(it) } }
            if (listId != null) {
                Section("Everyone else's")
                if (others.isEmpty()) Notice("Nobody else has ranked this cube yet.")
                others.forEach { row(it) }
            } else {
                if (mine.isEmpty()) Notice("No rankings yet. Open one of your cubes and tap Rankings, or rank a friend's cube below.")
                Section("Cubes you can rank")
                if (rankable.isEmpty()) Notice("When a friend, or someone you've played with, shares a cube with you, it shows here. " +
                    "You can also open any cube shared with you on someone's profile and tap Rankings.")
                rankable.forEach { c ->
                    ListRow(c.name, listOfNotNull(c.owner?.displayName, plural(c.cards, "card"), if (c.rankings == 0) "no rankings yet" else plural(c.rankings, "ranking"),
                        if (c.mine > 0) "${c.mine} yours" else null).joinToString(" · "), onClick = { onCube(c.id) },
                        avatar = { Avatar(c.owner?.displayName ?: "?", c.owner?.userId, 28) })
                }
            }
        }
    }
}

// ── shared pieces

@Composable
private fun rememberRanking(id: String, watch: Boolean = true): RankingModel {
    val m = remember(id) { RankingsStore.model(id) }
    m.version.collectAsState().value
    val cat by CatalogStore.state.collectAsState()
    LaunchedEffect(id, cat.generation) { if (m.state == null) m.load() }
    if (watch) LaunchedEffect(id) { m.watch() }
    return m
}

@Composable
private fun rememberOthers(m: RankingModel): List<RankingRow> {
    var others by remember { mutableStateOf<List<RankingRow>>(emptyList()) }
    LaunchedEffect(m.row?.listId) {
        val list = m.row?.listId ?: return@LaunchedEffect
        runCatching { RankingsStore.rankings(list) }.onSuccess { r -> others = r.rankings.filter { it.id != m.id } }
    }
    return others
}

@Composable
private fun Frame(title: String, m: RankingModel, onBack: () -> Unit, subtitle: String? = null, content: @Composable ColumnScope.(RankingState) -> Unit) {
    T1Screen {
        Bar(title, subtitle ?: m.row?.title, onBack = onBack)
        m.error?.let { Notice(it, error = true) }
        m.notice?.let { Notice(it) }
        val st = m.state
        if (st == null) { if (m.error == null) Notice("Loading the ranking…") } else content(st)
    }
}

@Composable
private fun ProgressBar(fraction: Float) {
    Box(Modifier.fillMaxWidth().height(3.dp).background(T1.bg)) {
        Box(Modifier.fillMaxWidth(fraction.coerceIn(0f, 1f)).height(3.dp).background(if (fraction >= 1f) T1.accent else T1.text))
    }
}

@Composable
private fun Tile(title: String, state: String, done: Boolean, fraction: Float, note: String, buttons: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().background(T1.surface).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title.uppercase(), Modifier.weight(1f), color = T1.text, fontFamily = T1.mono, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.5.sp)
            Label(state, color = if (done) T1.accent else T1.muted)
        }
        ProgressBar(fraction)
        Text(note, color = T1.muted, fontFamily = T1.mono, fontSize = 12.sp, lineHeight = 18.sp)
        Row(horizontalArrangement = Arrangement.spacedBy(1.dp), content = buttons)
    }
}

@Composable
private fun Tabs(st: RankingState, shown: RankJob?, all: Boolean = false, onSelect: (RankJob?) -> Unit) {
    Row(Modifier.fillMaxWidth().background(T1.bg).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
        @Composable fun tab(label: String, on: Boolean, j: RankJob?) {
            Box(Modifier.background(if (on) T1.text else T1.surface).clickable { onSelect(j) }.padding(horizontal = 14.dp, vertical = 12.dp)) {
                Label(label, color = if (on) T1.ink else T1.text)
            }
        }
        if (all) tab("All", shown == null, null)
        (listOf(RankJob.Final) + st.jobs).forEach { tab(listTitle(it, st.top), it == shown, it) }
    }
}

// ── one ranking

/** The cube changed since this ranking caught up: what's new and gone, and (yours) Re-rank, which asks only about the
 *  new cards. Your order stays; removed cards are already off the lists. */
@Composable
private fun CubeChanged(m: RankingModel, row: RankingRow, go: (String) -> Unit) {
    val change = m.cubeChange
    if (change.isEmpty) return
    fun names(ids: List<String>): String {
        val ns = ids.mapNotNull { m.card(it)?.name }
        return if (ns.size > 3) "${ns.take(3).joinToString(", ")} and ${ns.size - 3} more" else ns.joinToString(", ")
    }
    val parts = listOfNotNull(
        if (change.added.isEmpty()) null else "${plural(change.added.size, "card")} joined (${names(change.added)})",
        if (change.removed.isEmpty()) null else "${plural(change.removed.size, "card")} left (${names(change.removed)})",
    ).joinToString(" and ")
    val cube = m.cube?.name ?: "This cube"
    if (!row.mine) {
        Notice("$cube changed since ${row.by?.displayName ?: "they"} last ranked it: $parts." +
            if (change.added.isEmpty()) "" else " The new cards wait outside the lists until they're placed.")
        return
    }
    val job = m.reRankJob
    Notice("$cube changed since you ranked it: $parts." + (if (change.removed.isEmpty()) "" else " Removed cards are off your lists.") +
        if (job == null) "" else " Re-rank to place the new cards: you're only asked about them, and your order stays as it is.")
    Row {
        if (job != null) Ghost("Re-rank", accent = true) { Telemetry.capture("ranking_rerank", mapOf("list" to job.key)); go("screen/${job.key}") }
        else Ghost("OK") { m.catchUp() }
    }
}

@Composable
fun RankingScreen(id: String, onBack: () -> Unit, go: (String) -> Unit) {
    LaunchedEffect(Unit) { Telemetry.screen("ranking") }
    val m = rememberRanking(id)
    val others = rememberOthers(m)
    var menu by remember { mutableStateOf<List<T1MenuItem>?>(null) }
    var confirmDelete by remember { mutableStateOf(false) }
    var imaging by remember { mutableStateOf(false) }
    var newName by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val row = m.row
    Frame(row?.title ?: "Ranking", m, onBack, m.cube?.name) { st ->
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (m.cubeGone) Notice("This cube isn't shared with you any more, so only its lists show.")
            if (row != null) CubeChanged(m, row, go)
            if (row != null && !row.mine) Notice("You're watching ${row.by?.displayName ?: "someone"}'s ranking. It updates live as they pick.")
            if (row != null && row.depth != "full") Notice("This ranking orders only the ${RankDepth.phrase(row.depth)} of each color.")
            for (job in st.jobs) {
                val s = st.session(job); val used = st.knowledge.perJob[job.key] ?: 0; val size = st.size(job)
                val note = when {
                    s.done -> if (s.target < size) "Top ${s.target} of $size sorted in ${plural(used, "screen")}." else "All $size sorted in ${plural(used, "screen")}."
                    s.waiting.isNotEmpty() -> "${s.top.size} of the top ${s.target} placed · ${plural(s.waiting.size, "new card")} to place"
                    used == 0 -> "${plural(size, "card")} · about ${plural(st.expected(job), "screen")}"
                    else -> "${s.top.size} of the top ${s.target} placed · about ${plural(maxOf(1, st.expected(job) - used), "screen")} to go"
                }
                Tile(job.title, if (s.done) "Sorted" else if (used > 0) "In progress" else "Not started", s.done, s.top.size / maxOf(1, s.target).toFloat(), note) {
                    if (!s.done) Ghost(if (m.mine) (if (used > 0) "Continue" else "Start") else "Watch", accent = m.mine) { go("screen/${job.key}") }
                    Ghost("List") { go("lists/${job.key}") }
                }
            }
            val f = st.session(RankJob.Final); val usedF = st.knowledge.perJob["F"] ?: 0
            val unsorted = st.jobs.count { !st.session(it).done }
            val noteF = if (f.done) "All ${f.target} places ranked in ${plural(usedF, "screen")}." else
                "${f.top.size} of ${f.target} ranked · about ${plural(maxOf(1, st.expected(RankJob.Final) - usedF), "screen")} left once every color is sorted." +
                    if (unsorted > 0) " ${if (unsorted == 1) "1 color is" else "$unsorted colors are"} not fully sorted yet; the final works anyway but will also ask about cards inside ${if (unsorted == 1) "it" else "them"}." else ""
            Tile("Final · Top ${f.target}", if (f.done) "Complete" else if (usedF > 0) "In progress" else "Not started", f.done, f.top.size / maxOf(1, f.target).toFloat(), noteF) {
                if (!f.done) Ghost(if (m.mine) (if (usedF > 0) "Continue the final" else "Start the final") else "Watch", accent = m.mine) { go("screen/F") }
                Ghost("Top ${f.target} list") { go("lists/F") }
            }
            val picks = m.picks; val disagreed = picks.count { it.disagreed > 0 || it.won }
            Tile("P1P1", if (picks.isEmpty()) "" else plural(picks.size, "pick"), false, 0f,
                if (picks.isEmpty()) "Refine ${if (m.mine) "your" else "this"} ranking: pick one card from a 15-card pack, like the first pick of a draft."
                else "${plural(picks.size, "pick")} · ${if (disagreed == 0) "all agreed with the ranking" else "$disagreed disagreed with the ranking"}") {
                Ghost(if (m.mine) "Open a pack" else "Pick history", accent = m.mine) { go("pack") }
            }
            ListRow("Changes", if (m.changes.isEmpty()) "Every move of every card, as it happens" else "${plural(m.changes.size, "change")} so far", onClick = { go("changes") })
            ListRow("Compare with another ranking…", if (others.isEmpty()) "No other rankings of this cube yet" else plural(others.size, "other ranking"), onClick = {
                if (others.isNotEmpty()) menu = others.map { o -> T1MenuItem(o.title) { go("compare/${o.id}/F") } }
            })
            ListRow("Top ${row?.top ?: 100} image", "The final as a picture, to save or share", onClick = { imaging = true })
            if (row?.mine == true) {
                Section("Settings")
                Field("Label (optional)", newName ?: row.label ?: "", { newName = it })
                val n = newName?.trim()
                // The server takes no blank name; its default is what reads as no label.
                if (n != null && n != (row.label ?: "")) Row {
                    Ghost(if (n.isEmpty()) "Remove label" else "Save label", accent = true) { m.update(name = n.ifEmpty { RankingName.UNNAMED }); newName = null }
                }
                Notice("Rankings are titled by who ranked them. A label tells your rankings of this cube apart.")
                T1Segmented(DEPTH_LABELS, RankDepth.all.indexOf(row.depth).coerceAtLeast(0)) { m.update(depth = RankDepth.all[it]) }
                Notice(depthNote(row.depth, row.top))
                T1Segmented(listOf("Top 100", "Top 50"), if (row.top == 100) 0 else 1) { m.update(top = if (it == 0) 100 else 50) }
                T1Segmented(listOf("Shared with the cube", "Only me"), if (row.sharing == "cube") 0 else 1) { m.update(sharing = if (it == 0) "cube" else "private") }
                ListRow("Delete this ranking", "Every pick, on every device", onClick = { confirmDelete = true })
            }
        }
    }
    menu?.let { T1Menu("Compare with", it) { menu = null } }
    if (confirmDelete && row != null) T1AlertDialog("Delete this ranking?", onDismiss = { confirmDelete = false },
        confirm = { TextButton({ confirmDelete = false; scope.launch { runCatching { RankingsStore.delete(id) }.onSuccess { onBack() }.onFailure { m.error = it.message } } }) {
            Text("Yes, delete it", color = T1.danger, fontFamily = T1.mono) } },
        dismiss = { TextButton({ confirmDelete = false }) { Text("Cancel", color = T1.text, fontFamily = T1.mono) } },
        body = { Text("This removes every pick in it, on every device. It can't be undone.", fontFamily = T1.mono, color = T1.muted) })
    if (imaging) RankingImageScreen(m) { imaging = false }
}

// ── the picking screen

@Composable
fun RankingPickScreen(id: String, job: RankJob, onBack: () -> Unit, go: (String) -> Unit) {
    LaunchedEffect(Unit) { Telemetry.screen("ranking_screen") }
    val m = rememberRanking(id)
    val q = m.question(job)
    val key = q?.let { "${m.log.size}|${it.cards}|${it.pinned}" } ?: ""
    var order by remember { mutableStateOf<List<Int>>(emptyList()) }
    var picked by remember { mutableStateOf<Int?>(null) }
    var drag by remember { mutableStateOf<Triple<Int, Float, Float>?>(null) }
    LaunchedEffect(key) { q?.let { order = it.cards; picked = null } }
    val pinned = q?.pinned?.toSet() ?: emptySet()
    fun move(x: Int, to: Int) { order = order.filter { it != x }.toMutableList().also { it.add(minOf(to, it.size), x) } }
    fun tap(x: Int) {
        if (!m.mine) return
        val p = picked
        if (p == null) {
            if (x !in pinned) picked = x else order.firstOrNull { it !in pinned }?.let { move(it, order.indexOf(x)) }
            return
        }
        picked = null
        if (p == x) return
        if (pinned.isEmpty()) order = order.toMutableList().also { val i = it.indexOf(p); val j = it.indexOf(x); it[i] = x; it[j] = p }
        else move(p, order.indexOf(x))
    }
    Frame(listTitle(job, m.row?.top ?: 100).let { if (job == RankJob.Final) "Final" else it }, m, onBack) { st ->
        val qq = q ?: return@Frame
        val s = qq.session; val used = st.knowledge.perJob[job.key] ?: 0; val label = if (job == RankJob.Final) "Final" else job.title
        val placing = s.waiting.isNotEmpty()
        Column(Modifier.fillMaxWidth().background(T1.surface).padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (!m.mine) Label("Watching ${m.row?.by?.displayName ?: "someone"}'s ranking live")
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Text(if (s.done) "✓" else if (placing) "+${s.waiting.size}" else "#${s.top.size + 1}", color = T1.accent, fontFamily = T1.mono, fontSize = 44.sp, fontWeight = FontWeight.Bold)
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Label(if (s.done) "$label · done" else if (placing) "$label · placing new cards" else "$label · deciding #${s.top.size + 1} of the top ${s.target}", color = T1.text)
                    Text(if (placing) "${plural(s.waiting.size, "new card")} to place; your order stays as it is" else "${s.top.size} of the top ${s.target} (${plural(s.size, "card")}) placed",
                        color = T1.muted, fontFamily = T1.mono, fontSize = 12.sp)
                    Text(if (s.done) "Done in ${plural(used, "screen")}"
                         else if (placing) "Screen ${st.knowledge.screens + 1} of this ranking · only the new cards are asked about"
                         else "Screen ${st.knowledge.screens + 1} of this ranking · about ${maxOf(1, st.expected(job) - used)} to go in $label",
                        color = T1.muted, fontFamily = T1.mono, fontSize = 11.sp)
                }
            }
            ProgressBar(s.top.size / maxOf(1, s.target).toFloat())
        }
        if (s.done) {
            Notice(if (job == RankJob.Final) "Top ${s.target} complete. All ${s.target} places are ranked." else "$label sorted.")
            val next = if (m.mine) m.reRankJob?.takeIf { it != job } else null
            // In place of this screen, so Back still returns to the ranking.
            if (next != null) Row { Ghost("Next: place new cards in ${if (next == RankJob.Final) "the final" else next.title}", accent = true) { onBack(); go("screen/${next.key}") } }
            Row { Ghost(if (job == RankJob.Final) "Top ${s.target} list" else "$label list", accent = next == null) { go("lists/${job.key}") } }
            Row { Ghost("Back to the ranking") { onBack() } }
            return@Frame
        }
        if (m.mine) {
            if (pinned.isNotEmpty()) Notice("Locked cards keep the order you already gave them. Move the free card to where it belongs.")
            else if (m.log.none { it.s == job.key }) Notice("Drag the cards into order, best in spot 1, then lock it in. You can also tap two cards to swap them.")
        }
        BoxWithConstraints(Modifier.weight(1f).fillMaxWidth().background(T1.bg)) {
            val cols = if (maxWidth > 600.dp) 4 else 2
            val rows = maxOf(1, (order.size + cols - 1) / cols)
            val gap = 12.dp; val label = 40.dp
            val w = minOf((maxWidth - 32.dp - gap * (cols - 1)) / cols, ((maxHeight - 24.dp - gap * (rows - 1)) / rows - label) * CARD_ASPECT)
            val h = w / CARD_ASPECT + label
            val left = (maxWidth - (w * cols + gap * (cols - 1))) / 2
            order.forEachIndexed { i, x ->
                val c = m.cardAt(x)
                val up = picked == x || drag?.first == x
                val dx = if (drag?.first == x) drag!!.second else 0f; val dy = if (drag?.first == x) drag!!.third else 0f
                Column(
                    Modifier.offset(left + (w + gap) * (i % cols), 12.dp + (h + gap) * (i / cols))
                        .offset { IntOffset(dx.toInt(), dy.toInt()) }
                        .width(w)
                        .semantics { contentDescription = "Spot ${i + 1}: ${c?.name ?: ""}" }
                        .clickable(enabled = m.mine) { tap(x) }
                        .let { mod ->
                            if (!m.mine || x in pinned) mod else mod.pointerInput(x, order, w) {
                                val stepX = (w + gap).toPx(); val stepY = h.toPx() + gap.toPx()
                                var sx = 0f; var sy = 0f
                                detectDragGestures(
                                    onDragStart = { picked = null; sx = 0f; sy = 0f; drag = Triple(x, 0f, 0f) },
                                    onDragEnd = { drag = null }, onDragCancel = { drag = null },
                                ) { change, amount ->
                                    change.consume()
                                    sx += amount.x; sy += amount.y
                                    val from = order.indexOf(x)
                                    val col = ((from % cols) + Math.round(sx / stepX)).coerceIn(0, cols - 1)
                                    val row = ((from / cols) + Math.round(sy / stepY)).coerceIn(0, rows - 1)
                                    val to = minOf(order.size - 1, row * cols + col)
                                    if (to != from) {
                                        sx -= (to % cols - from % cols) * stepX; sy -= (to / cols - from / cols) * stepY
                                        move(x, to)
                                    }
                                    drag = Triple(x, sx, sy)
                                }
                            }
                        },
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Box(Modifier.let { if (up) it.border(3.dp, T1.text) else it }) {
                        CardArt(c?.printing, w)
                        Box(Modifier.size(28.dp).background(if (up) T1.text else T1.surface), contentAlignment = Alignment.Center) {
                            Text("${i + 1}", color = if (up) T1.ink else T1.text, fontFamily = T1.mono, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                        }
                        if (x in pinned) Box(Modifier.align(Alignment.TopEnd).size(28.dp).background(T1.surface), contentAlignment = Alignment.Center) {
                            Text("🔒", fontSize = 12.sp)
                        }
                    }
                    Text(c?.name ?: "", color = T1.text, fontFamily = T1.mono, fontSize = 11.sp, maxLines = 2, overflow = TextOverflow.Ellipsis, lineHeight = 14.sp)
                }
            }
        }
        if (m.mine) Row(Modifier.padding(bottom = 1.dp), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            Ghost("Undo", enabled = m.log.any { it.s == job.key }) { m.undo(job) }
            Ghost("Lock in", accent = true) { if (order.size >= 2) m.lockIn(job, order) }
        }
    }
}

// ── lists

@Composable
fun RankingListsScreen(id: String, job: RankJob, onBack: () -> Unit, go: (String) -> Unit) {
    LaunchedEffect(Unit) { Telemetry.screen("ranking_lists") }
    val m = rememberRanking(id)
    val others = rememberOthers(m)
    var tab by remember { mutableStateOf(job) }
    var copied by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf<List<T1MenuItem>?>(null) }
    val clipboard = LocalClipboardManager.current
    Frame(listTitle(tab, m.row?.top ?: 100), m, onBack) { st ->
        val l = m.list(tab) ?: return@Frame
        val s = l.session
        Tabs(st, tab) { tab = it ?: RankJob.Final; copied = false }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Notice(when {
                s.top.isEmpty() -> "Nothing ranked yet."
                tab == RankJob.Final -> if (s.done) "Final order, #1 down." else "${s.top.size} of ${s.target} ranked so far, #1 down."
                s.done && s.target < s.size -> "The top ${s.target} of ${s.size}, best first. The other ${s.size - s.target} are below them, in no particular order."
                s.done -> "All ${s.size}, best first."
                else -> "${s.top.size} of the top ${s.target} placed so far, best first."
            })
            l.placed.forEachIndexed { i, c -> CardRow(c.printing, "${i + 1}. ${c.name}", onClick = { go("card/${c.oracleId}/${tab.key}") }) }
            l.waitingTitle?.let { Section(it) }
            l.waiting.forEach { c -> CardRow(c.printing, c.name, onClick = { go("card/${c.oracleId}/${tab.key}") }) }
            l.restTitle?.let { Section(it) }
            l.rest.forEach { c -> CardRow(c.printing, c.name, onClick = { go("card/${c.oracleId}/${tab.key}") }) }
            Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                Ghost(if (copied) "Copied" else "Copy list") {
                    clipboard.setText(AnnotatedString(m.listText(tab))); copied = true
                    Telemetry.capture("ranking_list_copied", mapOf("list" to tab.key))
                }
                Ghost("Compare…") {
                    if (others.isNotEmpty()) menu = others.map { o -> T1MenuItem(o.title) { go("compare/${o.id}/${tab.key}") } }
                }
            }
        }
    }
    menu?.let { T1Menu("Compare this list with", it) { menu = null } }
}

/** A list row led by a card thumbnail. */
@Composable
private fun CardRow(printing: CatalogPrinting?, title: String, detail: String? = null, onClick: (() -> Unit)? = null, trailing: @Composable () -> Unit = {}) {
    Row(Modifier.fillMaxWidth().background(T1.surface).let { if (onClick != null) it.clickable(onClick = onClick) else it }.padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        CardArt(printing, 36.dp)
        Column(Modifier.weight(1f)) {
            Text(title, color = T1.text, fontFamily = T1.mono, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            detail?.let { Label(it) }
        }
        trailing()
    }
}

// ── one card's history

private fun moveText(c: RankChange) = when {
    c.f == null && c.to != null -> "#${c.to} new"
    c.f != null && c.to == null -> "#${c.f} → out"
    else -> "#${c.f} → #${c.to}"
}

private fun causeText(c: RankChange) = when (c.by) {
    "undo" -> "undo"; "redo" -> "redo screen ${c.n ?: 0}"; "pick" -> "P1P1 pick"; "pick_win" -> "a pick won"; "settings" -> "settings"
    else -> c.n?.let { "screen $it" } ?: "screen"
}

@Composable
fun RankingCardScreen(id: String, oracleId: String, job: RankJob, onBack: () -> Unit, go: (String) -> Unit) {
    LaunchedEffect(Unit) { Telemetry.screen("ranking_card") }
    val m = rememberRanking(id)
    var against by remember { mutableStateOf<String?>(null) }
    var menu by remember { mutableStateOf<List<T1MenuItem>?>(null) }
    var redo by remember { mutableStateOf<Int?>(null) }
    val card = m.card(oracleId)
    Frame(card?.name ?: "Card", m, onBack) { st ->
        val x = st.knowledge.indexOf(oracleId)
        if (x == null) { Notice("That card isn't in this cube any more."); return@Frame }
        val s = st.session(job); val fin = st.session(RankJob.Final)
        val i = s.top.indexOf(x)
        val place = when {
            i >= 0 -> "#${i + 1} in ${if (job == RankJob.Final) "the top ${s.target}" else job.title}"
            s.done -> if (job == RankJob.Final) "Not in the top ${s.target}" else "Below the top ${s.target} in ${job.title}"
            else -> if (job == RankJob.Final) "Not in the top ${s.target} yet" else "Not placed yet in ${job.title}"
        }
        val me = st.id(x)
        val other = against ?: when { i > 0 -> st.id(s.top[i - 1]); i == 0 && s.top.size > 1 -> st.id(s.top[1]); s.top.isNotEmpty() -> st.id(s.top.last()); else -> null }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Row(Modifier.fillMaxWidth().background(T1.surface).padding(16.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                CardArt(card?.printing, 120.dp)
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(place, color = T1.text, fontFamily = T1.mono, fontSize = 15.sp)
                    if (job != RankJob.Final && x in fin.top) Label("#${fin.top.indexOf(x) + 1} in the top ${fin.target}")
                }
            }
            Section("Why")
            ListRow(other?.let { "Against ${m.card(it)?.name ?: "?"}" } ?: "Pick a card to compare", "Change", onClick = {
                val inTop = s.top.toSet()
                val rest = st.scope(job).members.filter { it != x && it !in inTop }.sortedBy { m.cardAt(it)?.name ?: "" }
                menu = (s.top.filter { it != x } + rest).take(150).map { y ->
                    T1MenuItem((if (y in inTop) "#${s.top.indexOf(y) + 1} " else "") + (m.cardAt(y)?.name ?: "")) { against = st.id(y) }
                }
            })
            if (other != null) {
                val up = CubeRanking.why(st.knowledge, m.log, me, other)
                val down = if (up == null) CubeRanking.why(st.knowledge, m.log, other, me) else null
                val chain = up ?: down
                if (chain == null) Notice("No screen has settled these two yet, directly or through other cards.") else {
                    Notice("${card?.name} is ${if (up != null) "above" else "below"} ${m.card(other)?.name}:")
                    chain.forEach { l -> ListRow("${m.card(l.winner)?.name ?: "?"} above ${m.card(l.loser)?.name ?: "?"}", "Screen ${l.screen}") }
                }
            }
            val changes = m.changes.filter { it.c.lowercase() == me }.reversed()
            if (changes.isNotEmpty()) {
                Section("Rank changes · ${changes.size}")
                changes.forEach { c -> ListRow("${listTitle(RankJob.of(c.s) ?: RankJob.Final, st.top)}: ${moveText(c)}", listOfNotNull(causeText(c), c.t?.let(::day)).joinToString(" · ")) }
            }
            val hits = m.log.withIndex().filter { (_, sc) -> sc.o.any { it.lowercase() == me } }
            Section("Screens with this card · ${hits.size}")
            if (hits.isEmpty()) Notice("It has not been on a screen yet.")
            hits.forEach { (k, sc) ->
                Row(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Label("Screen ${k + 1} · ${when (sc.s) { "P" -> "P1P1 pick (first card picked)"; "F" -> "Final"; else -> RankJob.of(sc.s)?.title ?: sc.s }}")
                        Text(if (sc.s == "P") "Picked ${m.card(sc.o[0])?.name ?: "?"} over ${sc.o.drop(1).joinToString(", ") { m.card(it)?.name ?: "?" }}"
                             else sc.o.mapIndexed { n, o -> "${n + 1}. ${m.card(o)?.name ?: "?"}" }.joinToString("\n"),
                            color = T1.text, fontFamily = T1.mono, fontSize = 13.sp, lineHeight = 18.sp)
                    }
                    if (m.mine) Label("Redo", Modifier.clickable { redo = k }.padding(4.dp), color = T1.text)
                }
            }
        }
    }
    menu?.let { T1Menu("Compare with", it) { menu = null } }
    redo?.let { k ->
        val sc = m.log.getOrNull(k)
        val nothing = m.redoChangesNothing(k)
        T1AlertDialog("Remove screen ${k + 1}?", onDismiss = { redo = null },
            confirm = { TextButton({ val j = sc?.s; m.redo(k); redo = null; if (j != null && j != "P") go("screen/$j") }) { Text("Remove and re-ask", color = T1.danger, fontFamily = T1.mono) } },
            dismiss = { TextButton({ redo = null }) { Text("Cancel", color = T1.text, fontFamily = T1.mono) } },
            body = { Text(when { nothing -> "Removing it changes nothing: other screens settle every order it did."; sc?.s == "P" -> "The pick comes out of the ranking."
                                 else -> "It comes out of the ranking and ${if (sc?.s == "F") "the final" else RankJob.of(sc?.s ?: "F")?.title} asks about those cards again." },
                         fontFamily = T1.mono, color = T1.muted) })
    }
}

// ── compare

@Composable
fun RankingCompareScreen(id: String, otherId: String, job: RankJob, onBack: () -> Unit, go: (String) -> Unit) {
    LaunchedEffect(Unit) { Telemetry.screen("ranking_compare") }
    var a by remember { mutableStateOf(id) }
    var b by remember { mutableStateOf(otherId) }
    var tab by remember { mutableStateOf(job) }
    val ma = rememberRanking(a, watch = false); val mb = rememberRanking(b, watch = false)
    var all by remember { mutableStateOf<List<RankingRow>>(emptyList()) }
    var menu by remember { mutableStateOf<Pair<String, List<T1MenuItem>>?>(null) }
    LaunchedEffect(ma.row?.listId) { ma.row?.listId?.let { l -> runCatching { RankingsStore.rankings(l) }.onSuccess { all = it.rankings } } }
    LaunchedEffect(a, b, tab) { Telemetry.capture("ranking_compared", mapOf("list" to tab.key)) }
    var brief by remember { mutableStateOf<RankingBrief?>(null) }
    var briefError by remember { mutableStateOf<String?>(null) }
    var briefTry by remember { mutableStateOf(0) }
    val bothReady = ma.state != null && mb.state != null
    LaunchedEffect(a, b, tab, briefTry, bothReady) {
        if (!bothReady) return@LaunchedEffect
        brief = null; briefError = null
        runCatching { RankingsStore.brief(a, b, tab) }.onSuccess { brief = it }.onFailure { briefError = it.message }
    }
    fun label(r: RankingRow?) = if (r?.mine == true) "You" else r?.by?.displayName ?: "Someone"
    fun named(r: RankingRow?) = listOfNotNull(label(r), r?.label).joinToString(" · ")
    T1Screen {
        Bar("Compare", listTitle(tab, ma.row?.top ?: 100), onBack = onBack)
        (ma.error ?: mb.error)?.let { Notice(it, error = true) }
        val sa = ma.state; val sb = mb.state
        if (sa == null || sb == null) { Notice("Loading both rankings…"); return@T1Screen }
        Tabs(sa, tab) { tab = it ?: RankJob.Final }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                @Composable fun picker(title: String, r: RankingRow?, set: (String) -> Unit) {
                    Column(Modifier.weight(1f).background(T1.surface).clickable { menu = title to all.map { o -> T1MenuItem(named(o)) { set(o.id) } } }.padding(12.dp)) {
                        Label(title)
                        Text(named(r), color = T1.text, fontFamily = T1.mono, fontSize = 13.sp, maxLines = 2)
                    }
                }
                picker("Ranking", ma.row) { a = it }
                Box(Modifier.background(T1.surface).clickable { val x = a; a = b; b = x }.padding(horizontal = 14.dp, vertical = 20.dp)) { Label("Swap", color = T1.text) }
                picker("Compared with", mb.row) { b = it }
            }
            Section("In brief")
            val text = brief?.brief
            when {
                text != null -> Column(Modifier.fillMaxWidth().background(T1.surface).padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(text, color = T1.text, fontFamily = T1.mono, fontSize = 13.sp, lineHeight = 20.sp)
                    Label("Written by Claude from both rankings")
                }
                brief?.reason != null -> Notice(brief!!.reason!!)
                briefError != null -> ListRow("No brief yet", "$briefError Tap to try again.", onClick = { briefTry++ })
                else -> Notice("Writing a brief…")
            }
            val tb = sb.session(tab)
            val translated = RankSession(tb.top.mapNotNull { sa.knowledge.indexOf(sb.id(it)) }, tb.done, tb.target, tb.size, null, emptyList(), RankBits(sa.knowledge.size))
            val c = CubeRanking.compare(sa.knowledge, sa.session(tab), translated, sa.scope(tab))
            val na = label(ma.row); val nb = label(mb.row)
            fun side(n: String, p: Int, out: Boolean) = if (out) "$n: below the top ${p - 1}" else "$n #$p"
            @Composable fun gapRow(g: CubeRanking.Gap) {
                val card = ma.card(g.card)
                CardRow(card?.printing, card?.name ?: "?", "${side(na, g.a, g.aOut)} · ${side(nb, g.b, g.bOut)}", onClick = { go("card/${g.card}/${tab.key}") }) {
                    Text("${if (g.atLeast) "≥" else ""}${g.gap}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                }
            }
            if (c.compared == 0) Notice("Nothing to compare yet: these two rankings have no ${if (tab == RankJob.Final) "cards" else "${tab.title.lowercase()} cards"} placed in common.")
            else {
                Section(if (tab == RankJob.Final) "Biggest differences" else "${tab.title}: biggest differences")
                Notice("Comparing ${plural(c.compared, if (tab == RankJob.Final) "card" else "${tab.title.lowercase()} card")} both rankings have placed. " +
                    "On average they sit ${if (c.atLeast) "at least " else ""}${c.avgTenths / 10}.${c.avgTenths % 10} places apart; these ${c.biggest.size} differ the most." +
                    if (tab != RankJob.Final && ((ma.row?.depth ?: "full") != "full" || (mb.row?.depth ?: "full") != "full")) " A ranking that sorts only part of each color puts a card below its cut at the first place past it, so its gap is at least what's shown." else "")
                c.biggest.forEach { gapRow(it) }
                if (c.oneSide.isNotEmpty()) {
                    Section(if (tab == RankJob.Final) "In one top ${sa.top}, not the other" else "In one top half, not the other")
                    Notice("${plural(c.oneSide.size, "card")} ${if (c.oneSide.size == 1) "is" else "are"} in one ranking's list but below the other's cut.")
                    c.oneSide.forEach { gapRow(it) }
                }
            }
        }
    }
    menu?.let { (t, items) -> T1Menu(t, items) { menu = null } }
}

// ── P1P1

@Composable
fun RankingPackScreen(id: String, onBack: () -> Unit, go: (String) -> Unit) {
    LaunchedEffect(Unit) { Telemetry.screen("ranking_pack") }
    val m = rememberRanking(id)
    var pack by remember { mutableStateOf<List<String>>(emptyList()) }
    var picked by remember { mutableStateOf<String?>(null) }
    var disagree by remember { mutableStateOf<Triple<String, List<String>, Int>?>(null) }
    var saved by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(m.state != null) { if (m.state != null && pack.isEmpty()) pack = m.pack }
    fun placeOf(cid: String): String {
        val st = m.state ?: return "not ranked"
        val x = st.knowledge.indexOf(cid) ?: return "not ranked"
        val f = st.session(RankJob.Final).top.indexOf(x)
        if (f >= 0) return "#${f + 1} in the top ${st.top}"
        val job = st.category[cid.lowercase()] ?: return "not placed yet"
        val k = st.session(job).top.indexOf(x)
        return if (k >= 0) "#${k + 1} in ${job.title}" else "not placed yet"
    }
    fun save(p: String, wins: Boolean) {
        val disagreed = m.disagreements(p, pack).size; val settles = m.newOrders(p, pack)
        m.pick(p, pack, wins)
        val name = m.card(p)?.name ?: "That pick"
        disagree = null
        saved = when {
            disagreed > 0 -> if (wins) "$name now sits above the rest of that pack. Saved." else "Kept your ranking; the rest of the pick is saved."
            settles > 0 -> "$name: this pick settles ${plural(settles, "order")} your ranking hadn't. Saved."
            else -> "$name agrees with your ranking. Saved."
        }
    }
    Frame(if (m.row != null && !m.mine) "Pick history" else "P1P1", m, onBack) { _ ->
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (m.mine) {
                val d = disagree
                when {
                    d != null -> {
                        Section("Your ranking disagrees")
                        Notice("You picked ${m.card(d.first)?.name} (${placeOf(d.first)}), but your ranking puts ${if (d.second.size == 1) "this card" else "these ${d.second.size} cards"} above it:")
                        d.second.forEach { cid -> CardRow(m.card(cid)?.printing, m.card(cid)?.name ?: "?", placeOf(cid)) }
                        Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                            Ghost("Keep my ranking") { save(d.first, false) }
                            Ghost("Let the pick win", accent = true) { save(d.first, true) }
                        }
                        Notice(if (d.third == 0) "Letting the pick win changes nothing else."
                               else "Letting the pick win takes out ${plural(d.third, "screen")} behind that order; those cards are asked about again.")
                    }
                    saved != null -> {
                        Notice(saved!!)
                        Row { Ghost("Next pack", accent = true) { saved = null; picked = null; pack = m.pack } }
                    }
                    else -> Notice("Pick the card you'd take first from this pack. Each pick refines your ranking: the card you take counts as better than the other ${maxOf(0, pack.size - 1)}.")
                }
                BoxWithConstraints(Modifier.fillMaxWidth().background(T1.bg).padding(16.dp)) {
                    val w = (maxWidth - 16.dp) / 3
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        pack.chunked(3).forEach { rowCards ->
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                rowCards.forEach { cid ->
                                    val flagged = d != null && (cid == d.first || cid in d.second)
                                    Box(Modifier.let { if (picked == cid) it.border(3.dp, T1.accent) else if (flagged) it.border(3.dp, T1.warning) else it }
                                        .clickable(enabled = d == null && saved == null) { picked = cid }
                                        .semantics { contentDescription = m.card(cid)?.name ?: "Card" }) {
                                        CardArt(m.card(cid)?.printing, w)
                                    }
                                }
                            }
                        }
                    }
                }
                if (d == null && saved == null) Row {
                    val p = picked
                    Ghost(p?.let { "Pick ${m.card(it)?.name ?: ""}" } ?: "Tap a card to pick it", enabled = p != null, accent = p != null) {
                        val c = p ?: return@Ghost
                        val above = m.disagreements(c, pack)
                        if (above.isEmpty()) save(c, false) else disagree = Triple(c, above, m.pickWinRemovals(c, pack).size)
                    }
                }
            } else if (m.picks.isEmpty()) Notice("No P1P1 picks yet.")
            val picks = m.picks
            if (picks.isNotEmpty()) {
                Section("Pick history · ${picks.size}")
                picks.forEach { p ->
                    val cid = p.screen.o[0]
                    CardRow(m.card(cid)?.printing, m.card(cid)?.name ?: "?",
                        "Screen ${p.index + 1} · ${if (p.won) "won over your ranking" else if (p.disagreed > 0) "disagreed with ${plural(p.disagreed, "card")}, ranking kept" else "agreed"} · ${placeOf(cid)}",
                        onClick = { go("card/$cid/F") })
                }
            }
        }
    }
}

// ── change log

@Composable
fun RankingChangesScreen(id: String, onBack: () -> Unit, go: (String) -> Unit) {
    LaunchedEffect(Unit) { Telemetry.screen("ranking_changes") }
    val m = rememberRanking(id)
    var filter by remember { mutableStateOf<RankJob?>(null) }
    LaunchedEffect(Unit) { Telemetry.capture("ranking_changes_opened") }
    Frame("Changes", m, onBack) { st ->
        Tabs(st, filter, all = true) { filter = it }
        val rows = m.changes.filter { filter == null || it.s == filter!!.key }.reversed().take(2000)
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (rows.isEmpty()) Notice("Nothing has moved yet.")
            rows.groupBy { day(it.t) }.forEach { (d, list) ->
                Section(d)
                list.forEach { c ->
                    val card = m.card(c.c)
                    CardRow(card?.printing, card?.name ?: "?", "${listTitle(RankJob.of(c.s) ?: RankJob.Final, st.top)} · ${causeText(c)}",
                        onClick = { go("card/${c.c}/${c.s}") }) {
                        Text(moveText(c), color = if (c.to != null && (c.f == null || c.to < c.f)) T1.text else T1.muted, fontFamily = T1.mono, fontSize = 13.sp)
                    }
                }
            }
        }
    }
}

// ── the top 100 as a picture

/** Piles of ten in rank order, each card over the one above so only its name bar shows (the last in a pile whole). */
internal object RankingImageDrawing {
    fun draw(title: String, byline: String, cards: List<RankCard>, art: Map<String, Bitmap>): Bitmap {
        val s = 2f; val cw = 168f; val ch = cw * 680f / 488f; val peek = 26f; val gap = 14f; val pad = 32f; val per = 10; val head = 90f
        val piles = maxOf(1, (cards.size + per - 1) / per)
        val w = pad * 2 + piles * (cw + gap) - gap; val h = pad + head + 24f + (per - 1) * peek + ch + pad
        val bmp = Bitmap.createBitmap((w * s).toInt(), (h * s).toInt(), Bitmap.Config.ARGB_8888)
        val g = android.graphics.Canvas(bmp).apply { scale(s, s) }
        g.drawColor(0xFF171725.toInt())
        val mono = Typeface.MONOSPACE
        val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = Typeface.create(mono, Typeface.BOLD); textSize = 30f; color = 0xFFFFFFFF.toInt() }
        g.drawText(title, pad, pad + 28f, text)
        val muted = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = mono; textSize = 14f; color = 0xFFC4C4CA.toInt() }
        g.drawText(byline, pad, pad + 56f, muted)
        val small = Paint(muted).apply { textSize = 11f; textAlign = Paint.Align.RIGHT }
        g.drawText("TABLE-1.SITE", w - pad, pad + 20f, small)
        val label = Paint(muted).apply { textSize = 12f }
        val badge = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFFFFFFFF.toInt() }
        val badgeText = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = Typeface.create(mono, Typeface.BOLD); textSize = 11f; color = 0xFF171725.toInt(); textAlign = Paint.Align.CENTER }
        val tile = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFF33334A.toInt() }
        val name = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = mono; textSize = 11f; color = 0xFFFFFFFF.toInt() }
        cards.forEachIndexed { i, c ->
            val pile = i / per; val k = i % per
            val x = pad + pile * (cw + gap); val y = pad + head + 24f + k * peek
            if (k == 0) g.drawText("#${i + 1}–${minOf(i + per, cards.size)}", x, pad + head + 12f, label)
            val r = cw * CardCorners.ratio(c.printing?.set ?: "")
            val rect = RectF(x, y, x + cw, y + ch)
            g.save()
            g.clipPath(android.graphics.Path().apply { addRoundRect(rect, r, r, android.graphics.Path.Direction.CW) })
            val img = c.printing?.cardId?.let { art[it] }
            if (img != null) g.drawBitmap(img, null, rect, Paint(Paint.FILTER_BITMAP_FLAG)) else { g.drawRect(rect, tile); g.drawText(c.name, x + 8f, y + 16f, name) }
            g.restore()
            g.drawRect(x + cw - 26f, y + 4f, x + cw - 2f, y + 22f, badge)
            g.drawText("${i + 1}", x + cw - 14f, y + 17f, badgeText)
        }
        return bmp
    }
}

@Composable
private fun RankingImageScreen(m: RankingModel, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var image by remember { mutableStateOf<Bitmap?>(null) }
    var progress by remember { mutableStateOf(0 to 0) }
    var note by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val cards = remember(m.version.value) { m.state?.session(RankJob.Final)?.top?.mapNotNull(m::cardAt) ?: emptyList() }
    val name = m.row?.title ?: "Top 100"
    LaunchedEffect(cards) {
        if (cards.isEmpty()) return@LaunchedEffect
        val printings = cards.mapNotNull { it.printing }.associateBy { it.cardId }
        progress = 0 to printings.size
        var done = 0
        val loaded = coroutineScope {
            printings.values.map { p ->
                async {
                    val bmp = p.imageUrl("normal")?.let { CardImageLoader.load(it, 340) }?.asAndroidBitmap()
                    done += 1; progress = done to printings.size
                    p.cardId to bmp
                }
            }.awaitAll()
        }.mapNotNull { (id, b) -> b?.let { id to it } }.toMap()
        if (loaded.size < printings.size) note = "${printings.size - loaded.size} card images couldn't be loaded; their names show instead."
        val row = m.row
        val partial = if (m.state?.session(RankJob.Final)?.done == true) null else "${cards.size} of ${row?.top ?: 100} ranked so far"
        val byline = listOfNotNull(row?.let { "Ranking of ${m.cube?.name ?: "a cube"}" },
            partial, "Ranked on Table 1", java.time.LocalDate.now().format(DateTimeFormatter.ofPattern("MMM d, yyyy", Locale.US))).joinToString(" · ")
        image = withContext(Dispatchers.Default) { RankingImageDrawing.draw(name, byline, cards, loaded) }
    }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(T1.bg)) {
            T1Screen {
                Bar("Top ${m.row?.top ?: 100} image", name, onBack = onClose)
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    error?.let { Notice(it, error = true) }
                    note?.let { Notice(it) }
                    val img = image
                    when {
                        cards.isEmpty() -> Notice("Nothing ranked in the final yet.")
                        img != null -> ZoomablePreview(img, "Top ${m.row?.top ?: 100} image", name, "ranking_image")
                        else -> Notice("Getting card images… ${progress.first} of ${progress.second}")
                    }
                }
                Row(Modifier.fillMaxWidth().padding(bottom = 1.dp), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    Ghost("Save to Photos", enabled = image != null, accent = true) {
                        val img = image ?: return@Ghost
                        scope.launch {
                            runCatching { saveToPhotos(context, img, DeckImage.fileName(name)) }
                                .onSuccess { note = "Saved to Photos (Pictures/Table 1)."; error = null; Telemetry.capture("ranking_image", mapOf("how" to "photos")) }
                                .onFailure { error = "Couldn't save: ${it.message}. Use Share instead." }
                        }
                    }
                    Ghost("Share", enabled = image != null) {
                        val img = image ?: return@Ghost
                        scope.launch {
                            runCatching { shareImage(context, img, DeckImage.fileName(name)) }
                                .onSuccess { error = null; Telemetry.capture("ranking_image", mapOf("how" to "share")) }
                                .onFailure { error = it.message }
                        }
                    }
                }
            }
        }
    }
}
