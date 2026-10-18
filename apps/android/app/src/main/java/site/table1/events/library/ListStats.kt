package site.table1.events.library

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1Stepper
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry
import java.util.Locale

/*
 * Deck and cube stats, one tap below the list (contract/lists-2026-10-15.md, "Stats"). The list screen shows a one-line
 * summary (ListStatsRow); the Stats screen has the detail, and the sample hand, draw odds and sample pack are each one
 * more tap. Same screens as iOS ListStats.swift and web ListStats.tsx; all math is in DeckStats.kt.
 */

/** A list line read for stats, with the printing to draw it. */
data class StatLine(val card: StatCard, val cardId: String, val finish: String, val printing: CatalogPrinting)

private fun resolveStatLines(list: CardList, db: CatalogDb): List<StatLine> {
    val ps = db.printings(list.entries.map { it.cardId }.toSet())
    val os = db.oracles(ps.values.map { it.oracleIdx }.toSet())
    val tokenCards = db.oracles(os.values.flatMap { it.tokens }.toSet())
    return list.entries.mapNotNull { e ->
        val p = ps[e.cardId] ?: return@mapNotNull null
        val o = os[p.oracleIdx] ?: return@mapNotNull null
        val tokens = o.tokens.mapNotNull { tokenCards[it] }.map { StatToken(it.oracleId, it.name, it.typeLine) }
        StatLine(StatCard(o.name, e.qty, e.board, o.typeLine, o.manaCost, o.cmc, o.colors, o.legal, p.rarity, produced = o.produced, tokens = tokens),
            e.cardId, e.finish, p)
    }
}

/** The list and its stat lines with prices, re-read when the list, the catalog or prices change. */
@Composable
private fun rememberStatLines(listId: String): Pair<CardList?, List<StatLine>?> {
    val s by ListsStore.state.collectAsState()
    val cat by CatalogStore.state.collectAsState()
    val prices by PriceBook.version.collectAsState()
    val list = s.lists.firstOrNull { it.id == listId }
    var lines by remember { mutableStateOf<List<StatLine>?>(null) }
    LaunchedEffect(list?.current?.number, list?.entries, cat.generation) {
        CatalogStore.load(userInitiated = true)
        val db = CatalogStore.db ?: return@LaunchedEffect
        val l = list ?: return@LaunchedEffect
        lines = withContext(Dispatchers.Default) { resolveStatLines(l, db) }
        PriceBook.load(l.entries.map { it.cardId })
    }
    val priced = remember(lines, prices) { lines?.map { it.copy(card = it.card.copy(usd = PriceBook.usd(it.cardId, it.finish))) } }
    return list to priced
}

private fun pct(x: Double) = String.format(Locale.US, "%.1f%%", x * 100)
private fun dec(x: Double) = String.format(Locale.US, "%.2f", x)
private fun usd(x: Double) = PriceBook.text(x) ?: ""
private fun List<StatCard>.qty() = sumOf { it.qty }

/** The frame every stats page shares: bar, then loading or the content. */
@Composable
private fun StatsFrame(title: String, subtitle: String?, onBack: () -> Unit, list: CardList?, lines: List<StatLine>?,
                       content: @Composable ColumnScope.(CardList, List<StatLine>) -> Unit) {
    T1Screen {
        Bar(title, subtitle = subtitle ?: list?.name, onBack = onBack)
        when {
            list == null -> Notice("That list isn't here anymore.")
            lines == null -> Notice("Loading card data…")
            else -> content(list, lines)
        }
    }
}

// ── the summary row on the list screen

@Composable
fun ListStatsRow(listId: String, onOpen: () -> Unit) {
    val (list, lines) = rememberStatLines(listId)
    if (list == null || list.entries.isEmpty()) return
    val cards = lines?.map { it.card }
    val detail = when {
        cards == null -> "Reading cards…"
        list.kind == ListKind.Cube -> {
            val b = DeckStats.colorBalance(cards.filter { it.board == "main" })
            listOf("W", "U", "B", "R", "G", "M", "C", "L").zip(b).filter { it.second > 0 }.joinToString(" · ") { "${it.first} ${it.second}" }
        }
        else -> {
            val lands = DeckStats.deck(cards).filter(DeckStats::isLand).qty()
            val total = DeckStats.price(cards).first
            listOfNotNull("$lands lands", "avg MV ${dec(DeckStats.averageMV(cards, false))}", if (total > 0) usd(total) else null).joinToString(" · ")
        }
    }
    ListRow("Stats", detail, onClick = onOpen)
}

// ── shared pieces

@Composable
private fun Cells(cells: List<Pair<String, String>>) {
    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
        cells.forEach { (label, value) ->
            Column(Modifier.weight(1f).fillMaxHeight().background(T1.surface).padding(vertical = 14.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Label(label)
                Text(value, color = T1.text, fontFamily = T1.mono, fontSize = 20.sp, maxLines = 1)
            }
        }
    }
}

/** A plain table on the hairline grid: header row, then rows; the first column takes the rest of the width. */
@Composable
private fun StatTable(header: List<String>, rows: List<List<String>>, cell: Dp = 72.dp) {
    @Composable
    fun line(cells: List<String>, label: Boolean) {
        Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            cells.forEachIndexed { i, x ->
                val m = (if (i == 0) Modifier.weight(1f) else Modifier.width(cell)).fillMaxHeight().background(T1.surface)
                    .padding(start = if (i == 0) 16.dp else 0.dp, end = if (i == 0) 8.dp else 6.dp, top = if (label) 8.dp else 12.dp, bottom = if (label) 8.dp else 12.dp)
                if (label) Label(x, m, color = T1.muted)
                else Text(x, m, color = T1.text, fontFamily = T1.mono, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    textAlign = if (i == 0) TextAlign.Start else TextAlign.End)
            }
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        line(header, true)
        rows.forEach { line(it, false) }
    }
}

/** Stacked bars per mana value: creatures solid, other spells muted. Drawn with boxes, no chart library. */
@Composable
private fun CurveBars(creatures: List<Int>, other: List<Int>) {
    val top = maxOf(1, creatures.zip(other).maxOf { it.first + it.second })
    val h = 120.dp
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            for (i in 0 until 8) {
                val total = creatures[i] + other[i]
                Column(Modifier.weight(1f).height(h + 30.dp).background(T1.surface).padding(start = 6.dp, end = 6.dp, top = 8.dp),
                    verticalArrangement = Arrangement.Bottom, horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(if (total == 0) "" else "$total", Modifier.padding(bottom = 4.dp), color = T1.text, fontFamily = T1.mono, fontSize = 12.sp)
                    Box(Modifier.fillMaxWidth().height(h * other[i] / top).background(T1.muted))
                    Box(Modifier.fillMaxWidth().height(h * creatures[i] / top).background(T1.text))
                }
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            DeckStats.BUCKETS.forEach { b -> Box(Modifier.weight(1f).background(T1.surface).padding(vertical = 8.dp), contentAlignment = Alignment.Center) { Label(b) } }
        }
        Row(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 10.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Legend(T1.text, "Creatures ${creatures.sum()}")
            Legend(T1.muted, "Other spells ${other.sum()}")
        }
    }
}

@Composable
private fun Legend(color: androidx.compose.ui.graphics.Color, text: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.size(10.dp).background(color)); Label(text)
    }
}

/** A text-only button; disabled is a flat fill, never dimmed. */
@Composable
private fun androidx.compose.foundation.layout.RowScope.StatsButton(text: String, enabled: Boolean = true, onClick: () -> Unit) {
    Box(Modifier.weight(1f).background(if (enabled) T1.surface else T1.disabled).clickable(enabled = enabled, onClick = onClick).padding(vertical = 16.dp),
        contentAlignment = Alignment.Center) { Label(text, color = if (enabled) T1.text else T1.ink) }
}

@Composable
private fun Trailing(text: String, accent: Boolean = false) =
    Text(text, color = if (accent) T1.accent else T1.text, fontFamily = T1.mono, fontSize = 17.sp)

// ── the Stats screen

private val CHECKED = CatalogPack.LEGALITY_FORMATS + "canlander"
private fun shortFormat(f: String) = if (f == "canlander") "Canlander" else CatalogPack.formatName(f)
private const val PACK_KEY = "cube.packSize"
private fun packPrefs(c: Context) = c.getSharedPreferences("library", Context.MODE_PRIVATE)

@Composable
fun ListStatsScreen(listId: String, onBack: () -> Unit, onHand: () -> Unit, onOdds: () -> Unit, onPack: () -> Unit) {
    val (list, lines) = rememberStatLines(listId)
    LaunchedEffect(list?.kind) { list?.let { Telemetry.screen(if (it.kind == ListKind.Cube) "cube_stats" else "deck_stats") } }
    StatsFrame("Stats", null, onBack, list, lines) { l, ls ->
        val cards = ls.map { it.card }
        LazyColumn(Modifier.fillMaxWidth().weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (l.kind == ListKind.Deck) deckStats(l, cards, onHand, onOdds) else cubeStats(cards.filter { it.board == "main" }, onPack)
        }
    }
}

private fun LazyListScope.deckStats(list: CardList, cards: List<StatCard>, onHand: () -> Unit, onOdds: () -> Unit) {
    val deck = DeckStats.deck(cards)
    val size = deck.qty()
    val lands = deck.filter(DeckStats::isLand).qty()
    val (creatures, other) = DeckStats.curve(cards)
    val types = DeckStats.typeCounts(deck)
    val pips = DeckStats.pipTotals(cards)
    val src = DeckStats.sources(cards)
    val unread = src.unread
    val olderPack = deck.any { it.produced == null }
    val made = DeckStats.tokens(cards)
    val pipSum = maxOf(1, pips.sum())
    // The deck's colors; a fetch land's other land type (Bloodstained Mire in Boros) isn't one.
    val shown = (0 until 5).filter { if (pips.sum() > 0) pips[it] > 0 else src.colors[it] > 0 }
    val (total, unpriced) = DeckStats.price(cards)
    item("cells") { Cells(listOf("Cards" to "$size", "Lands" to "$lands", "Spells" to "${size - lands}", "Avg MV" to dec(DeckStats.averageMV(cards, false)))) }
    item("curve-h") { Section("Mana curve · spells by mana value") }
    item("curve") { CurveBars(creatures, other) }
    item("types-h") { Section("Types") }
    DeckStats.TYPES.forEachIndexed { i, t -> if (types[i] > 0) item("type-$t") { ListRow(t) { Trailing("${types[i]}") } } }
    item("avg") {
        ListRow("Average mana value", "With lands ${dec(DeckStats.averageMV(cards, true))} · without ${dec(DeckStats.averageMV(cards, false))}")
    }
    if (types.sum() > size) item("types-note") { Notice("A card counts once for each of its types: an artifact creature is in both.") }
    item("colors-h") { Section("Colors · pips in costs vs sources") }
    item("colors") {
        if (shown.isEmpty()) ListRow("Colorless", "No colored mana symbols or colored sources")
        else StatTable(listOf("Color", "Pips", "Share", "Sources", "Share"), shown.map { i ->
            listOf(DeckStats.COLOR_GROUPS[i], "${pips[i]}", pct(pips[i].toDouble() / pipSum), "${src.colors[i]}",
                pct(src.colors[i].toDouble() / maxOf(1, src.total)))
        })
    }
    item("sources") {
        val detail = (listOf("Lands and permanents that make mana") +
            (if (src.nonLand > 0) listOf("${src.nonLand} not lands") else emptyList()) +
            (if (src.colorless > 0) listOf("${src.colorless} colorless") else emptyList())).joinToString(" · ")
        ListRow("Mana sources", detail) { Trailing("${src.total}") }
    }
    if (unread > 0) item("unread") {
        val one = unread == 1
        Notice(
            if (olderPack) "Card data is still updating, so lands count by their basic land types: $unread land${if (one) "" else "s"} without one (fetch or utility lands) ${if (one) "isn't" else "aren't"} counted."
            else "$unread land${if (one) " makes" else "s make"} no mana and ${if (one) "isn't" else "aren't"} counted.",
        )
    }
    item("legal-h") { Section("Legality · ${CatalogPack.formatName(list.format)}") }
    if (list.format in CHECKED) {
        val issues = DeckStats.legality(cards, list.format)
        if (issues.isEmpty()) item("legal") { ListRow("Legal in ${CatalogPack.formatName(list.format)}", "Main deck and sideboard") { Label("Legal", color = T1.accent) } }
        else issues.forEach { (name, reason) -> item("issue-$name") { ListRow(name) { Label(reason, color = T1.error) } } }
    } else item("legal") { ListRow("Not checked", "${CatalogPack.formatName(list.format)} has no legality list") }
    item("others") {
        val cells = CHECKED.filter { it != list.format }.map { shortFormat(it) to DeckStats.legality(cards, it).size }
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            cells.chunked(4).forEach { row ->
                Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    row.forEach { (name, n) ->
                        Column(Modifier.weight(1f).fillMaxHeight().background(T1.surface).padding(vertical = 10.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                            Label(name)
                            Text(if (n == 0) "Legal" else "$n card${if (n == 1) "" else "s"}", color = if (n == 0) T1.text else T1.muted, fontFamily = T1.mono, fontSize = 12.sp)
                        }
                    }
                    repeat(4 - row.size) { Spacer(Modifier.weight(1f).fillMaxHeight().background(T1.surface)) }
                }
            }
        }
    }
    item("tokens-h") { Section("Tokens") }
    if (made.isEmpty()) item("tokens") {
        ListRow("None", if (cards.any { it.produced == null }) "Card data is still updating" else "No card here makes tokens")
    }
    made.forEach { u ->
        item("token-${u.token.key}") {
            Column(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(u.token.name, Modifier.weight(1f), color = T1.text, fontFamily = T1.mono, fontSize = 14.sp, maxLines = 1)
                    Label(u.token.type.replace("Token ", ""))
                }
                Text("Made by " + u.makers.joinToString(", ") { (name, qty) -> if (qty > 1) "$name ×$qty" else name },
                    color = T1.muted, fontFamily = T1.mono, fontSize = 12.sp)
            }
        }
    }
    item("price-h") { Section("Price") }
    item("price") { ListRow(if (total > 0) usd(total) else "No prices yet", if (unpriced > 0) "TCGplayer market · $unpriced unpriced" else "TCGplayer market · main and side") }
    item("try-h") { Section("Try it") }
    item("hand") { ListRow("Sample hand", "Draw seven, mulligan, draw the next card", onClick = onHand) }
    item("odds") { ListRow("Draw odds", "Chance to see cards by a turn", onClick = onOdds) }
}

private fun LazyListScope.cubeStats(cards: List<StatCard>, onPack: () -> Unit) {
    val size = cards.qty()
    val balance = DeckStats.colorBalance(cards)
    val byColor = DeckStats.curveByColor(cards)
    val types = DeckStats.typeCounts(cards)
    item("cells") { Cells(listOf("Cards" to "$size", "Lands" to "${balance[7]}", "Avg MV" to dec(DeckStats.averageMV(cards, false)))) }
    item("balance-h") { Section("Color balance") }
    item("balance") {
        StatTable(listOf("Color", "Cards", "Share"), DeckStats.COLOR_GROUPS.indices.filter { balance[it] > 0 }.map { i ->
            listOf(DeckStats.COLOR_GROUPS[i], "${balance[i]}", pct(balance[i].toDouble() / maxOf(1, size)))
        })
    }
    item("curve-h") { Section("Curve per color · mana value") }
    // One letter per color so nine columns fit a phone: W U B R G, M multicolor, C colorless.
    item("curve") {
        StatTable(listOf("Color") + DeckStats.BUCKETS, byColor.indices.filter { byColor[it].sum() > 0 }.map { i ->
            listOf(listOf("W", "U", "B", "R", "G", "M", "C")[i]) + byColor[i].map { if (it == 0) "·" else "$it" }
        }, cell = 34.dp)
    }
    item("types-h") { Section("Type mix") }
    DeckStats.TYPES.forEachIndexed { i, t ->
        if (types[i] > 0) item("type-$t") { ListRow(t, pct(types[i].toDouble() / maxOf(1, size))) { Trailing("${types[i]}") } }
    }
    item("asfan") { Asfan(cards) }
    item("try-h") { Section("Try it") }
    item("pack") {
        val ctx = LocalContext.current
        ListRow("Sample pack", "${packPrefs(ctx).getInt(PACK_KEY, 15)} random cards from the cube", onClick = onPack)
    }
}

@Composable
private fun Asfan(cards: List<StatCard>) {
    val ctx = LocalContext.current
    var by by remember { mutableStateOf(DeckStats.AsfanBy.Color) }
    var pack by remember { mutableIntStateOf(packPrefs(ctx).getInt(PACK_KEY, 15)) }
    val values = DeckStats.asfan(cards, pack, by)
    val labels = DeckStats.asfanLabels(by)
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Section("Asfan · expected per pack")
        T1Segmented(listOf("Color", "Type", "Mana value"), by.ordinal) {
            by = DeckStats.AsfanBy.entries[it]
            Telemetry.capture("cube_asfan_changed", mapOf("by" to by.key, "pack" to pack))
        }
        T1Stepper("Pack size", pack, 1..30, Modifier.fillMaxWidth()) { pack = it; packPrefs(ctx).edit().putInt(PACK_KEY, it).apply() }
        labels.indices.filter { values[it] > 0 }.forEach { i -> ListRow(labels[i]) { Trailing(dec(values[i]), accent = true) } }
    }
}

// ── sample hand

@Composable
private fun CardsGrid(modifier: Modifier, cards: List<Pair<StatLine, String?>>, onTap: (Int) -> Unit) {
    CardGrid(modifier) { tile ->
        itemsIndexed(cards) { i, (line, tag) ->
            Box(Modifier.width(tile).clickable { onTap(i) }) {
                CardArt(line.printing, tile)
                if (tag != null) Label(tag, Modifier.align(Alignment.BottomStart).padding(tile * 0.05f).background(T1.text).padding(horizontal = 6.dp, vertical = 3.dp), color = T1.ink)
            }
        }
    }
}

@Composable
fun SampleHandScreen(listId: String, onBack: () -> Unit) {
    val (list, lines) = rememberStatLines(listId)
    val main = remember(lines) { lines?.filter { it.card.board == "main" } }
    val library = remember(main) { main?.let { DeckStats.expand(it.map { l -> l.card }) } ?: emptyList() }
    var hand by remember { mutableStateOf<SampleHand?>(null) }
    val counts = remember { IntArray(3) } // hands, mulligans, draws
    LaunchedEffect(Unit) { Telemetry.screen("sample_hand") }
    LaunchedEffect(library.size, main != null) {
        if (main != null && hand?.size != library.size) { hand = SampleHand.deal(library.size, StatsRng.randomSeed()); counts[0]++ }
    }
    DisposableEffect(Unit) {
        onDispose { if (counts[0] > 0) Telemetry.capture("sample_hand_used", mapOf("hands" to counts[0], "mulligans" to counts[1], "draws" to counts[2])) }
    }
    val h = hand
    val subtitle = h?.let {
        listOfNotNull("${it.hand.size} in hand", "library ${it.library.size}", if (it.mulligans > 0) "${it.mulligans} mulligan${if (it.mulligans == 1) "" else "s"}" else null,
            if (it.drawn > 0) "drew ${it.drawn}" else null).joinToString(" · ")
    }
    StatsFrame("Sample hand", subtitle, onBack, list, lines) { _, _ ->
        if (main == null || h == null) return@StatsFrame
        if (library.isEmpty()) { Notice("The main deck is empty."); return@StatsFrame }
        if (h.toBottom > 0) Notice("Mulligan to ${7 - h.mulligans}: tap ${if (h.toBottom == 1) "a card" else "${h.toBottom} cards"} to put on the bottom.")
        CardsGrid(Modifier.weight(1f), h.hand.mapIndexed { i, pos -> main[library[pos]] to (if (i >= h.hand.size - h.drawn) "Drawn" else null) }) { i ->
            hand = h.bottom(i)
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            StatsButton("New hand") { hand = SampleHand.deal(library.size, StatsRng.randomSeed()); counts[0]++ }
            StatsButton(if (h.canMulligan) "Mulligan to ${6 - h.mulligans}" else "Mulligan", enabled = h.canMulligan) { hand = h.mulligan(); counts[1]++ }
            StatsButton("Draw", enabled = h.canDraw) { hand = h.draw(); counts[2]++ }
        }
    }
}

// ── draw odds

@Composable
fun DrawOddsScreen(listId: String, onBack: () -> Unit) {
    val (list, lines) = rememberStatLines(listId)
    var group by remember { mutableStateOf("type:Land") }
    var atLeast by remember { mutableIntStateOf(1) }
    var turn by remember { mutableIntStateOf(3) }
    var onPlay by remember { mutableStateOf(true) }
    LaunchedEffect(Unit) { Telemetry.screen("draw_odds") }
    val touched = remember { BooleanArray(1) }
    val latest by rememberUpdatedState(mapOf<String, Any>("group" to if (group.startsWith("card:")) "card" else group.removePrefix("type:").lowercase(),
        "turn" to turn, "on_play" to onPlay, "at_least" to atLeast))
    DisposableEffect(Unit) { onDispose { if (touched[0]) Telemetry.capture("draw_odds_used", latest) } }
    StatsFrame("Draw odds", null, onBack, list, lines) { _, ls ->
        val main = ls.map { it.card }.filter { it.board == "main" }
        val n = main.qty()
        if (n == 0) { Notice("The main deck is empty."); return@StatsFrame }
        val types = DeckStats.typeCounts(main)
        val byName = main.groupBy { it.name }.mapValues { (_, v) -> v.qty() }
        val groups = DeckStats.TYPES.indices.filter { types[it] > 0 }.map { i ->
            val t = DeckStats.TYPES[i]
            Triple("type:$t", if (t == "Sorcery") "Sorceries" else "${t}s", types[i])
        } + byName.entries.sortedWith(compareBy({ -it.value }, { it.key })).map { Triple("card:${it.key}", it.key, it.value) }
        val chosen = groups.firstOrNull { it.first == group } ?: groups.first()
        val k = chosen.third
        val draws = DeckStats.drawsByTurn(turn, onPlay)
        val p = DeckStats.hypergeometric(n, k, draws, atLeast)
        LazyColumn(Modifier.fillMaxWidth().weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            item("result") {
                Column(Modifier.fillMaxWidth().background(T1.surface).padding(vertical = 20.dp), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Label("At least $atLeast of $k ${chosen.second} by turn $turn")
                    Text(pct(p), color = T1.accent, fontFamily = T1.mono, fontSize = 44.sp)
                    Label("$draws of $n cards seen ${if (onPlay) "on the play" else "on the draw"}")
                }
            }
            item("play") { T1Segmented(listOf("On the play", "On the draw"), if (onPlay) 0 else 1) { onPlay = it == 0; touched[0] = true } }
            item("k") { T1Stepper("At least", atLeast, 1..maxOf(1, minOf(k, 22)), Modifier.fillMaxWidth()) { atLeast = it; touched[0] = true } }
            item("turn") { T1Stepper("By turn", turn, 1..15, Modifier.fillMaxWidth()) { turn = it; touched[0] = true } }
            item("by-h") { Section("By turn") }
            item("by") {
                StatTable(listOf("Turn", "Seen", "Chance"), (1..8).map { t ->
                    val d = DeckStats.drawsByTurn(t, onPlay)
                    listOf("Turn $t", "${minOf(d, n)}", pct(DeckStats.hypergeometric(n, k, d, atLeast)))
                })
            }
            item("groups-h") { Section("Card group") }
            groups.forEach { (id, title, count) ->
                item("g-$id") {
                    ListRow(title, "$count in the main deck", onClick = { group = id; atLeast = minOf(atLeast, maxOf(1, count)); touched[0] = true }) {
                        if (id == chosen.first) Label("Selected", color = T1.accent)
                    }
                }
            }
        }
    }
}

// ── sample pack

@Composable
fun SamplePackScreen(listId: String, onBack: () -> Unit) {
    val (list, lines) = rememberStatLines(listId)
    val ctx = LocalContext.current
    val packSize = remember { packPrefs(ctx).getInt(PACK_KEY, 15) }
    val main = remember(lines) { lines?.filter { it.card.board == "main" } }
    val pool = remember(main) { main?.let { DeckStats.expand(it.map { l -> l.card }) } ?: emptyList() }
    var pack by remember { mutableStateOf<List<Int>>(emptyList()) }
    val packs = remember { IntArray(1) }
    fun open() { pack = StatsRng(StatsRng.randomSeed()).shuffle(pool.size).take(packSize); packs[0]++ }
    LaunchedEffect(Unit) { Telemetry.screen("sample_pack") }
    LaunchedEffect(pool.size) { if (pool.isNotEmpty()) open() }
    DisposableEffect(Unit) { onDispose { if (packs[0] > 0) Telemetry.capture("sample_pack_used", mapOf("packs" to packs[0], "size" to packSize)) } }
    StatsFrame("Sample pack", "${pack.size} cards", onBack, list, lines) { _, _ ->
        if (main == null) return@StatsFrame
        if (pool.isEmpty()) { Notice("The cube is empty."); return@StatsFrame }
        CardsGrid(Modifier.weight(1f), pack.map { main[pool[it]] to null }) {}
        Row(Modifier.fillMaxWidth()) { StatsButton("Another pack") { open() } }
    }
}
