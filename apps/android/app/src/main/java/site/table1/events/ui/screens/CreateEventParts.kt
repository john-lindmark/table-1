package site.table1.events.ui.screens

import androidx.compose.ui.layout.layout
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import coil3.request.ImageRequest
import coil3.svg.SvgDecoder
import kotlinx.coroutines.delay
import site.table1.events.data.RecentCube
import site.table1.events.data.Repo
import site.table1.events.data.SeatingPod
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1Switch
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

/** A set's Scryfall symbol (SVG), tinted to the text color. draftable_sets rows carry the exact URL. */
@Composable
internal fun SetIcon(code: String, uri: String? = null, size: Dp = 20.dp, color: Color = T1.text) {
    val context = LocalContext.current
    AsyncImage(
        model = ImageRequest.Builder(context)
            .data(uri ?: "https://svgs.scryfall.io/sets/${code.lowercase()}.svg")
            .decoderFactory(SvgDecoder.Factory())
            .build(),
        contentDescription = null,
        colorFilter = ColorFilter.tint(color),
        modifier = Modifier.size(size),
    )
}

/** "Round timer · 50 min": on shows clocks to everyone; off hides them. Rounds run 50 minutes either way. */
@Composable
internal fun RoundTimerRow(on: Boolean, onChange: (Boolean) -> Unit) {
    ListRow("Round timer · 50 min", if (on) "Clocks shown" else "Clocks hidden", onClick = { onChange(!on) }) {
        T1Switch(on) { onChange(it) }
    }
}

/** Trimmed, inner whitespace collapsed. */
internal fun tidyName(s: String) = s.trim().replace(Regex("\\s+"), " ")

/** A name field with an Add button beside it; the keyboard's Done adds too. */
@Composable
internal fun AddByNameRow(value: String, onChange: (String) -> Unit, enabled: Boolean, onAdd: () -> Unit) {
    Row(Modifier.fillMaxWidth().height(androidx.compose.foundation.layout.IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
        Column(Modifier.weight(1f).background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Label("Add a player by name")
            BasicTextField(
                value = value, onValueChange = { onChange(it.take(40)) }, singleLine = true,
                textStyle = TextStyle(color = T1.text, fontFamily = T1.mono, fontSize = 15.sp),
                cursorBrush = SolidColor(T1.accent),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done, capitalization = androidx.compose.ui.text.input.KeyboardCapitalization.Words),
                keyboardActions = KeyboardActions(onDone = { if (enabled) onAdd() }),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        Box(
            Modifier.width(76.dp).fillMaxSize().background(if (enabled) T1.accent else T1.disabled)
                .clickable(enabled = enabled, onClick = onAdd),
            contentAlignment = Alignment.Center,
        ) { Label("Add", color = if (enabled) T1.ink else T1.muted) }
    }
}

/** Create: you (on by default) plus players by name only. People with accounts are invited after. */
@Composable
internal fun PlayersBlock(includeMe: Boolean, onIncludeMe: (Boolean) -> Unit, myName: String?, guests: List<String>, onGuests: (List<String>) -> Unit) {
    var draft by remember { mutableStateOf("") }
    val name = tidyName(draft)
    val dup = name.isNotEmpty() &&
        (guests.any { it.equals(name, ignoreCase = true) } || (includeMe && myName?.equals(name, ignoreCase = true) == true))
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Section("Players · ${guests.size + if (includeMe) 1 else 0}")
        ListRow(myName?.let { "You · $it" } ?: "You", if (includeMe) "Playing" else "Not playing", onClick = { onIncludeMe(!includeMe) }) {
            T1Switch(includeMe) { onIncludeMe(it) }
        }
        guests.forEachIndexed { i, g ->
            ListRow(g, "Guest · no account") {
                Label("Remove", Modifier.clickable { onGuests(guests.filterIndexed { j, _ -> j != i }) }, color = T1.danger)
            }
        }
        AddByNameRow(draft, { draft = it }, enabled = name.isNotEmpty() && !dup) {
            if (name.isNotEmpty() && !dup) {
                onGuests(guests + name.take(40))
                draft = ""
            }
        }
        if (dup) Notice("$name is already on the list.", error = true)
        Notice("Add people with accounts on the next screen; they get an invitation.")
    }
}

/**
 * Cube: your recent cubes, a Cube Cobra link (the name fills in from Cube Cobra), and the name.
 * Picking a recent cube hides the link and name; "Another cube" brings them back.
 * (Your Table 1 cubes join this list once the Library keeps cubes.) [onLookedUp] lets Details save at once.
 */
@Composable
internal fun CubeFields(
    cubeName: String,
    onCubeName: (String) -> Unit,
    cubeUrl: String,
    onCubeUrl: (String) -> Unit,
    onLookedUp: (name: String, url: String) -> Unit = { n, u -> onCubeName(n); onCubeUrl(u) },
) {
    var recent by remember { mutableStateOf<List<RecentCube>>(emptyList()) }
    var status by remember { mutableStateOf<String?>(null) }
    var failed by remember { mutableStateOf(false) }
    var settled by remember { mutableStateOf<String?>(null) }
    // A recent cube is the choice, so the link and name fields stay hidden.
    var picked by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        recent = Repo.recentCubes()
        picked = recent.any { it.cubeName == cubeName.trim() && (it.cubeUrl ?: "") == cubeUrl.trim() }
    }
    LaunchedEffect(cubeUrl) {
        val link = cubeUrl.trim()
        if (link.isEmpty()) { status = null; return@LaunchedEffect }
        if (link == settled) return@LaunchedEffect
        delay(450)
        status = "Looking it up on Cube Cobra…"
        failed = false
        runCatching { Repo.lookupCube(link) }
            .onSuccess { c ->
                settled = c.url
                onLookedUp(c.name ?: cubeName, c.url ?: link)
                status = "Found on Cube Cobra" + (c.cardCount?.let { " · $it cards" } ?: "") + "."
            }
            .onFailure { status = it.message ?: "Couldn't reach Cube Cobra"; failed = true }
    }
    val urlBad = cubeUrl.isNotBlank() && !cubeUrl.trim().startsWith("https://") && status?.startsWith("Looking") != true
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (recent.isNotEmpty()) {
            Label("Recent cubes")
            recent.forEach { c ->
                val current = c.cubeName == cubeName.trim() && (c.cubeUrl ?: "") == cubeUrl.trim()
                ListRow(c.cubeName, onClick = {
                    settled = c.cubeUrl ?: ""
                    status = null
                    picked = true
                    onLookedUp(c.cubeName, c.cubeUrl ?: "")
                }) { Label(if (current) "Selected" else "Use", color = if (current) T1.accent else T1.text) }
            }
            if (picked) ListRow("Another cube", onClick = { picked = false }) { Label("Enter", color = T1.text) }
        }
        if (!picked) {
            T1TextField(cubeUrl, { onCubeUrl(it.take(300)) }, label = "Cube Cobra link", placeholder = "https://cubecobra.com/…",
                keyboardType = KeyboardType.Uri, error = if (urlBad) "Paste a Cube Cobra link (https://cubecobra.com/…)" else null)
            status?.let { Text(it, color = if (failed) T1.danger else T1.muted, fontFamily = T1.mono, fontSize = 12.sp) }
            T1TextField(cubeName, { onCubeName(it.take(80)) }, label = "Cube name")
        }
    }
}

/* ── seating as a table ──────────────────────────────────────────────────────── */

/** Round 1 pairs as seat numbers: across the table, or (team draft) A slot i v B slot i+1. */
internal fun roundOneSeatPairs(pod: SeatingPod, teamDraft: Boolean): List<Pair<Int, Int>> {
    val seats = pod.seats.map { it.seat }.sorted()
    if (teamDraft) {
        val a = seats.filterIndexed { i, _ -> i % 2 == 0 }
        val b = seats.filterIndexed { i, _ -> i % 2 == 1 }
        if (a.isEmpty() || a.size != b.size) return emptyList()
        return a.indices.map { a[it] to b[(it + 1) % a.size] }
    }
    val half = (seats.size - seats.size % 2) / 2
    return (0 until half).map { seats[it] to seats[it + half] }
}

/**
 * Where each seat goes around one long table drawn upright (contract/event-night-2026-10-16.md § 3): `right` seats
 * down the right side, then `left` seats up the left side, with an end seat before each side when the ends are seated
 * (4+ players; an odd side count puts the extra player on the right). Dp values. Same as iOS TableLayout.
 */
internal class TableLayout(val count: Int, ends: Boolean) {
    val ends = ends && count >= 4
    val right: Int
    val left: Int
    init {
        val sides = count - if (this.ends) 2 else 0
        right = (sides + 1) / 2
        left = sides - right
    }

    val rows get() = maxOf(right, left, 1)
    private val step get() = CHIP_H + GAP
    /** Height of the drawing: the side rows, plus a row above and below for the ends. */
    val height get() = (rows + if (ends) 2 else 0) * step - GAP + 8f
    private val firstRowY get() = 4f + CHIP_H / 2 + if (ends) step else 0f

    /** The table between the two columns, reaching up to the end seats: x, y, w, h. */
    fun tableRect(width: Float, chipW: Float): List<Float> {
        val x0 = chipW + 12; val x1 = width - chipW - 12
        val y0 = firstRowY - CHIP_H / 2 - if (ends) GAP / 2 else 0f
        val y1 = firstRowY + (rows - 1) * step + CHIP_H / 2 + if (ends) GAP / 2 else 0f
        return listOf(x0, y0, maxOf(x1 - x0, 40f), y1 - y0)
    }

    /** Seat centres in seat order (clockwise from the top end, or from the right side's first seat). */
    fun positions(width: Float, chipW: Float): List<Pair<Float, Float>> {
        if (count == 0) return emptyList()
        val mid = width / 2; val rightX = width - chipW / 2 - 4; val leftX = chipW / 2 + 4
        fun rowY(r: Int) = firstRowY + r * step
        val out = mutableListOf<Pair<Float, Float>>()
        if (ends) out += mid to 4f + CHIP_H / 2
        for (r in 0 until right) out += rightX to rowY(r)
        if (ends) out += mid to rowY(rows - 1) + step
        for (r in (0 until left).reversed()) out += leftX to rowY(r + rows - left)
        return out
    }

    companion object {
        const val CHIP_H = 46f
        const val GAP = 10f
    }
}

/**
 * Each pod drawn the way a draft table really seats people: one long table, players along both long sides and (when
 * the organizer turns it on) one at each end. Lines join round 1 opponents; the middle says which way each pack passes
 * (left = clockwise, to the next seat number: packs 1 and 3; pack 2 goes right). Only the drawing changes.
 */
internal fun LazyListScope.seatingItems(pods: List<SeatingPod>, highlight: String?, teamDraft: Boolean, seatEnds: Boolean = false) {
    item(key = "seating-tables") { SeatingTables(pods, highlight, teamDraft, seatEnds) }
}

@Composable
private fun SeatingTables(pods: List<SeatingPod>, highlight: String?, teamDraft: Boolean, seatEnds: Boolean) {
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        pods.forEach { pod ->
            Section("${if (pods.size > 1) pod.name ?: "Pod" else "Seating"} · ${pod.seats.size} players")
            PodTable(pod, roundOneSeatPairs(pod, teamDraft), highlight, seatEnds)
            Notice(roundOneText(pod, teamDraft))
        }
    }
}

private fun roundOneText(pod: SeatingPod, teamDraft: Boolean): String {
    val pairs = roundOneSeatPairs(pod, teamDraft)
    if (pairs.isEmpty()) return if (teamDraft) "Round 1 pairs each player with the other team." else "Round 1 pairs across the table."
    val text = pairs.joinToString(", ") { "${it.first} v ${it.second}" }
    if (teamDraft) return "Round 1 pairs: $text."
    val seats = pod.seats.map { it.seat }.sorted()
    val bye = if (seats.size % 2 == 1) " Seat ${seats.last()} has the bye." else ""
    return "Round 1 pairs across the table: $text.$bye"
}

@Composable
private fun PodTable(pod: SeatingPod, pairs: List<Pair<Int, Int>>, highlight: String?, seatEnds: Boolean) {
    val seats = pod.seats.sortedBy { it.seat }
    val index = seats.withIndex().associate { (i, s) -> s.seat to i }
    val mySeat = seats.firstOrNull { it.participantId == highlight }?.seat
    val byeSeat = if (seats.size % 2 == 1 && pairs.size * 2 < seats.size) seats.lastOrNull()?.seat else null
    val layout = TableLayout(seats.size, seatEnds)
    BoxWithConstraints(
        Modifier.fillMaxWidth().background(T1.surface).padding(vertical = 12.dp)
            .semantics { contentDescription = "Table${if (layout.ends) " with players at the ends" else ""}. Packs 1 and 3 pass left, pack 2 passes right" },
    ) {
        val w = maxWidth.value
        val chipW = min(140f, (w - 24) * 0.36f)
        val pos = layout.positions(w, chipW)
        val (tx, ty, tw, th) = layout.tableRect(w, chipW)
        val density = LocalDensity.current
        Box(Modifier.fillMaxWidth().height(layout.height.dp)) {
            Box(Modifier.offset(tx.dp, ty.dp).size(tw.dp, th.dp).background(T1.bg).border(1.dp, T1.disabled))
            Canvas(Modifier.fillMaxSize()) {
                pairs.forEach { (a, b) ->
                    val i = index[a] ?: return@forEach
                    val j = index[b] ?: return@forEach
                    val mine = mySeat == a || mySeat == b
                    drawLine(
                        color = if (mine) T1.accent else T1.disabled,
                        start = Offset(pos[i].first.dp.toPx(), pos[i].second.dp.toPx()),
                        end = Offset(pos[j].first.dp.toPx(), pos[j].second.dp.toPx()),
                        strokeWidth = (if (mine) 2.dp else 1.dp).toPx(),
                    )
                }
            }
            Column(
                Modifier.offset((tx + tw / 2).dp, (ty + th / 2).dp).layout { m, c ->
                    val p = m.measure(c); layout(p.width, p.height) { p.place(-p.width / 2, -p.height / 2) }
                }.background(T1.bg).padding(horizontal = 10.dp, vertical = 6.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text("↻ 1·3 left", color = T1.text, fontFamily = T1.mono, fontSize = 12.sp, fontWeight = FontWeight.Bold, maxLines = 1)
                Text("↺ 2 right", color = T1.muted, fontFamily = T1.mono, fontSize = 12.sp, maxLines = 1)
            }
            seats.forEachIndexed { i, s ->
                val mine = s.participantId == highlight
                val x = (pos[i].first - chipW / 2).dp
                val y = (pos[i].second - TableLayout.CHIP_H / 2).dp
                Column(
                    Modifier.offset { with(density) { IntOffset(x.roundToPx(), y.roundToPx()) } }
                        .size(chipW.dp, TableLayout.CHIP_H.dp)
                        .background(if (mine) T1.surfaceHover else T1.bg)
                        .border(1.dp, if (mine) T1.accent else T1.disabled)
                        .padding(horizontal = 8.dp)
                        .semantics { contentDescription = "Seat ${s.seat}, ${s.displayName}" + (s.team?.let { ", $it" } ?: "") + if (s.seat == byeSeat) ", bye" else "" },
                    verticalArrangement = Arrangement.Center,
                ) {
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text("${s.seat}", color = T1.accent, fontFamily = T1.mono, fontSize = 13.sp, fontWeight = FontWeight.Bold)
                        s.team?.let { Label(it) }
                        if (s.seat == byeSeat) Label("Bye", color = T1.warning)
                    }
                    Text(s.displayName, color = T1.text, fontFamily = T1.mono, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}
