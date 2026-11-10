package site.table1.events.insights

import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import site.table1.events.ui.components.BigAction
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavGraphBuilder
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import site.table1.events.T1App
import site.table1.events.library.CatalogDb
import site.table1.events.library.CatalogStatus
import site.table1.events.library.CatalogStore
import site.table1.events.library.PresetCards
import site.table1.events.library.ProfileCard
import site.table1.events.library.ProfileCardsScreen
import site.table1.events.library.ListEntry
import site.table1.events.library.ListKind
import site.table1.events.library.ListsStore
import site.table1.events.library.LimitedPicker
import site.table1.events.library.CardArt
import site.table1.events.library.SearchBand
import androidx.compose.foundation.layout.width
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.Field
import site.table1.events.ui.components.Ghost
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.Stat
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1Switch
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry
import androidx.compose.foundation.layout.size
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import kotlinx.coroutines.delay
import site.table1.events.library.IconGlyph
import site.table1.events.library.T1Icon
import site.table1.events.library.SearchBand
import site.table1.events.util.rethrowIfCancelled

/** Where Insights screens go: the app's NavHost routes (AppRoot). */
object InsightsRoutes {
    fun archetype(f: String, id: Int) = "insights/arch/$f/$id"
    fun finish(f: String, id: Int, i: Int) = "insights/finish/$f/$id/$i"
    fun card(f: String, id: String, n: String) = "insights/card/$f/$id?n=${Uri.encode(n)}"
    fun cardSearch(f: String) = "insights/cards/$f"
    fun cardList(f: String, id: String, i: Int) = "insights/cardlist/$f/$id/$i"
    fun ban(f: String, id: Int) = "insights/ban/$f/$id"
    fun matchups(f: String) = "insights/matchups/$f"
    fun part(f: String, key: String) = "insights/part/$f/$key"
    fun pair(s: String, e: String, g: String, p: String) = "insights/pair/$s/$e/$g/$p"
    fun limitedCard(s: String, e: String, g: String, n: String) = "insights/lcard/$s/$e/$g/${Uri.encode(n)}"
    /** A set's or Arena cube version's Rankings (contract/cube-rankings-2026-10-21.md § Sets), on the Collection routes. */
    fun rankSet(key: String) = site.table1.events.data.PushRoutes.rankSetRoute(key)
    const val REVIEW = "insights/review"
}

private fun openUrl(context: android.content.Context, url: String) =
    runCatching { context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, Uri.parse(url))) }

@Composable
private fun Brief(text: String?, scope: String, thin: Boolean = false, credit: Pair<String, String>? = null) {
    val context = LocalContext.current
    Column(Modifier.fillMaxWidth().background(T1.surface).padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Label("In brief · $scope")
        if (text != null) Text(text, color = T1.text, fontFamily = T1.mono, fontSize = 14.sp, lineHeight = 21.sp)
        else Text(if (thin) "Too few results in this window to say much yet." else "The summary is on its way.", color = T1.muted, fontFamily = T1.mono, fontSize = 13.sp)
        if (credit != null) {
            Text(credit.first.uppercase(), Modifier.clickable { Telemetry.capture("insights_source_opened", mapOf("source" to credit.first)); openUrl(context, credit.second) },
                color = T1.muted, fontFamily = T1.mono, fontSize = 11.sp, letterSpacing = 1.5.sp, textDecoration = TextDecoration.Underline)
        }
    }
}

@Composable
private fun Stats(vararg items: Pair<String, String>) {
    Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
        items.forEach { (l, v) -> Row(Modifier.weight(1f).background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp)) { Stat(l, v) } }
    }
}

@Composable
private fun Scroll(content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
        content()
        Spacer(Modifier.height(24.dp))
    }
}

/** The Insights tab: Constructed | Limited. */
@Composable
fun InsightsHomeScreen(navigate: (String) -> Unit, moderator: Boolean) {
    val s = InsightsStore
    LaunchedEffect(Unit) { s.load() }
    LaunchedEffect(s.section) { Telemetry.screen(if (s.section == "limited") "insights_limited" else "insights_constructed") }
    T1Screen {
        Bar("Insights", if (s.section == "limited") "Arena draft" else "Constructed metagame") {
            if (s.section != "limited") {
                Box(Modifier.size(50.dp).clickable {
                    Telemetry.capture("insights_card_search_opened", mapOf("format" to s.format))
                    navigate(InsightsRoutes.cardSearch(s.format))
                }.semantics { contentDescription = "Search cards" }, contentAlignment = Alignment.Center) { IconGlyph(T1Icon.Search) }
            }
        }
        T1Segmented(listOf("Constructed", "Limited"), if (s.section == "limited") 1 else 0) { s.pickSection(if (it == 1) "limited" else "constructed") }
        Scroll {
            if (s.section == "limited") LimitedHome(navigate) else ConstructedHome(navigate)
            if (moderator) ListRow("Review", "Proposed archetypes and bans", onClick = { navigate(InsightsRoutes.REVIEW) })
        }
    }
}

/** Insights → Edit: a switch per format or set; the last one shown can't be hidden. Kept on this device. */
@Composable
private fun ShownEditor(title: String, items: List<Triple<String, String, String?>>, hidden: List<String>, set: (String, Boolean) -> Unit, done: () -> Unit) {
    Section(title)
    val all = items.map { it.first }
    items.forEach { (key, label, detail) ->
        val on = key !in hidden
        ListRow(label, detail) { T1Switch(on, enabled = !on || Insights.canHide(all, hidden, key)) { set(key, !it) } }
    }
    ListRow("Done", onClick = done)
}

/** Big events | All events, then the window (7–90 days) unless the part doesn't depend on it; the picks are the
 *  format page's. */
@Composable
private fun WindowPickers(tier: String, days: Boolean = true) {
    FilterRow(if (days) listOf(tierCell(tier), daysCell()) else listOf(tierCell(tier)))
}

/** Big events | All events as a filter cell. */
private fun tierCell(tier: String) = FilterCell("Events", if (tier == "big") "Big events" else "All events",
    listOf(Triple("big", "Big events", null), Triple("all", "All events", null)), tier) { InsightsStore.pickTier(it) }

/** The window, 7–90 days, as a filter cell. */
private fun daysCell() = FilterCell("Window", "${InsightsStore.days} days", Insights.windows.map { Triple("$it", "Last $it days", null) },
    "${InsightsStore.days}") { v -> v.toIntOrNull()?.let { InsightsStore.pickDays(it) } }

/** The format page: Meta over time and the matchup grid first, then the brief, and a row for each part, which opens
 *  on its own screen (ConstructedPartScreen). */
@Composable
private fun ConstructedHome(navigate: (String) -> Unit) {
    val s = InsightsStore
    val retryScope = rememberCoroutineScope()
    var hl by remember { mutableStateOf<Int?>(null) }
    val keys = s.shownFormats
    var editing by remember { mutableStateOf(false) }
    val tierNow = s.pack?.let { s.tier(it) } ?: "big"
    FilterRow(listOf(
        FilterCell("Format", Insights.formats.firstOrNull { it.first == s.format }?.second ?: s.format,
            keys.map { k -> Triple(k, Insights.formats.first { it.first == k }.second, null) } + Triple(FilterCell.EDIT, "Shown formats…", null), s.format) { v ->
            if (v == FilterCell.EDIT) editing = true else s.pickFormat(v)
        },
        tierCell(tierNow), daysCell(),
    ))
    if (editing) ShownEditor("Shown formats", Insights.formats.map { Triple(it.first, it.second, null) }, s.hiddenFormats, { k, hide -> s.setHidden(true, k, hide) }) { editing = false }
    LaunchedEffect(s.format) { s.ensure("constructed", s.format) }
    s.stale?.let { Notice(it) }
    val pack = s.pack
    if (pack == null) {
        Notice(s.error ?: if (s.loading || s.index.isEmpty()) "Loading the metagame…" else "No results for this format yet.", error = s.error != null)
        if (s.error != null) BigAction("Try again") { retryScope.launch { s.load(force = true) } }
        return
    }
    val tier = s.tier(pack)
    val view = pack.tiers[tier] ?: return
    val w = view.windows[s.days.toString()] ?: return
    val f = pack.format
    if (w.thin) Notice("Few results in this window: these numbers can swing.")
    Section("Meta over time · 7-day share")
    // The chart covers the picked window; lines with no decks in it are left out.
    val span = InsightCharts.window(view.series.from, view.series.days, s.days)
    val lines = view.series.lines.map { Line(it.a, it.v.drop(span.offset)) }.filter { l -> l.v.any { it != null } }
    val h = hl?.takeIf { x -> lines.any { it.a == x } } ?: lines.firstOrNull()?.a
    // one marker per day: a ban and an unban on May 18 read BAN/UNBAN
    val markers = pack.changes.mapNotNull { c ->
        InsightCharts.daysBetween(span.from, c.on)?.let { ChartMarker(it, if (c.isBan) c.kind.uppercase() else (c.set_code ?: "").uppercase(), c.isBan) }
    }.groupBy { it.index }.map { (i, ms) -> ChartMarker(i, ms.joinToString("/") { it.label }, ms.any { it.ban }) }
    InsightLineChart(lines.map { LineSeries(it.a.toString(), pack.name(it.a).let { n -> if (n.length > 14) n.take(13) + "…" else n }, it.v, it.a == h) },
        span.days, markers, span.labels, height = 300.dp, endLabels = false)
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
        lines.forEach { l ->
            // the picked line's latest share, since the chart has no end labels
            val name = if (l.a == h) listOfNotNull(pack.name(l.a), l.v.lastOrNull { it != null }?.let(InsightCharts::pct)).joinToString(" · ") else pack.name(l.a)
            Label(name, Modifier.background(if (l.a == h) T1.text else T1.surface).clickable { hl = l.a }.padding(horizontal = 12.dp, vertical = 10.dp),
                color = if (l.a == h) T1.ink else T1.text)
        }
    }
    val (grid, scope) = pack.grid(tier, s.days)
    if (grid.cells.isNotEmpty()) {
        Section("Matchups · $scope")
        key(tier, s.days) { MatchupGrid(pack, grid, pack.gridShare(tier, s.days)) }
    }
    Brief(w.brief, "${if (tier == "big") "Big events" else "All events"}, last ${s.days} days", w.thin,
        Insights.sourcesCredit(pack.sources))
    Stats("Decks" to "${w.decks}", "Events" to "${w.events}", "Through" to InsightCharts.shortDay(pack.through))
    Insights.formatParts(pack, tier, s.days).forEach { part ->
        ListRow(part.title, part.detail, onClick = {
            Telemetry.capture("insights_part_opened", mapOf("format" to f, "part" to part.key))
            navigate(InsightsRoutes.part(f, part.key))
        })
    }
}

/** One part of the format page on its own screen: Meta now, Cards rising and falling, New set, bans and their kin, or
 *  events, for the tier and window picked on the format page (changeable here too). */
@Composable
fun ConstructedPartScreen(format: String, part: String, navigate: (String) -> Unit, onBack: () -> Unit) {
    LaunchedEffect(Unit) { Telemetry.screen("insights_part") }
    val s = InsightsStore
    val context = LocalContext.current
    var board by remember { mutableStateOf("main") }
    LaunchedEffect(format) { s.ensure("constructed", format) }
    val pack = s.constructed[format]
    val tier = pack?.let { s.tier(it) } ?: "big"
    val title = pack?.let { p -> Insights.formatParts(p, tier, s.days).firstOrNull { it.key == part }?.title }
        ?: mapOf("meta" to "Meta now", "cards" to "Cards rising and falling", "new_set" to "New set", "changes" to "Bans and unbans",
            "events" to if (tier == "big") "Big events" else "Events")[part] ?: "Insights"
    val scope = "${if (tier == "big") "Big events" else "All events"}, last ${s.days} days"
    T1Screen {
        Bar(title, (pack?.name ?: format) + if (part == "meta" || part == "cards") " · $scope" else "", onBack = onBack)
        if (pack == null) { Notice("Loading the metagame…"); return@T1Screen }
        val view = pack.tiers[tier]
        val w = view?.windows?.get(s.days.toString())
        val f = pack.format
        Scroll {
            when (part) {
                "meta" -> {
                    WindowPickers(tier)
                    if (w != null) {
                        Section("Share of top finishes")
                        val maxShare = w.share.maxOfOrNull { it.share } ?: 0.1
                        val lead = w.share.firstOrNull { it.a != 0 }?.a
                        w.share.forEach { r ->
                            InsightBar(pack.name(r.a), r.share, maxShare, change = r.prev?.let { r.share - it }, highlighted = r.a == lead,
                                detail = InsightCharts.rates(r.wr, r.t8r, r.won, w.won_of).ifEmpty { null },
                                onClick = { navigate(InsightsRoutes.archetype(f, r.a)) })
                        }
                        if (w.share.isEmpty()) Notice("No decks in this window.")
                    }
                }
                "cards" -> {
                    WindowPickers(tier)
                    T1Segmented(listOf("Main deck", "Sideboard"), if (board == "main") 0 else 1) { board = if (it == 0) "main" else "side" }
                    w?.cards?.get(board)?.let { m ->
                        if (m.up.isNotEmpty()) Section("Rising")
                        m.up.forEach { CardMoveRow(f, it, true, navigate) }
                        if (m.down.isNotEmpty()) Section("Falling")
                        m.down.forEach { CardMoveRow(f, it, false, navigate) }
                        if (m.up.isEmpty() && m.down.isEmpty()) Notice("No card moved much in this window.")
                    }
                }
                "new_set" -> {
                    WindowPickers(tier, days = false)
                    val ns = view?.new_set
                    ns?.cards?.forEach { c ->
                        ListRow(c.n, "in ${InsightCharts.pct(c.rate)} of decks" + (c.`in`?.firstOrNull()?.let { " · most in ${pack.name(it)}" } ?: ""),
                            onClick = { navigate(InsightsRoutes.card(f, c.c, c.n)) }) { Text(InsightCharts.pct(c.rate), color = T1.text, fontFamily = T1.mono, fontSize = 13.sp) }
                    }
                    if (ns?.cards.isNullOrEmpty()) Notice("No new set cards played yet.")
                }
                "changes" -> pack.bans.forEach { b ->
                    pack.change(b.change)?.let { ch ->
                        ListRow(ch.words, InsightCharts.shortDay(ch.on) + (b.settled_days?.let { " · settled after $it days" } ?: ""), onClick = { navigate(InsightsRoutes.ban(f, b.change)) })
                    }
                }
                "events" -> {
                    WindowPickers(tier, days = false)
                    val events = pack.events.filter { tier == "all" || it.tier == "major" || it.tier == "large" }
                    events.forEach { e ->
                        ListRow(e.name, listOfNotNull(InsightCharts.shortDay(e.on), e.players?.let { "$it players" }, e.winner?.let { "won by ${pack.name(it)}" }).joinToString(" · "),
                            onClick = { e.url?.let { Telemetry.capture("insights_source_opened", mapOf("source" to e.source)); openUrl(context, it) } }) { Label(e.tier) }
                    }
                    if (events.isEmpty()) Notice("No events in the pack yet.")
                }
                else -> Notice("This part isn't in the pack.")
            }
        }
    }
}

@Composable
private fun CardMoveRow(f: String, c: CardRow, up: Boolean, navigate: (String) -> Unit) {
    ListRow(c.n, "in ${InsightCharts.pct(c.rate)} of decks · was ${InsightCharts.pct(c.prev ?: 0.0)}" + (c.copies?.let { " · %.1f copies".format(it) } ?: ""),
        onClick = { navigate(InsightsRoutes.card(f, c.c, c.n)) }) {
        Text("${if (up) "▲" else "▼"} ${InsightCharts.delta(c.rate - (c.prev ?: 0.0)).drop(1)}", color = if (up) T1.accent else T1.muted, fontFamily = T1.mono, fontSize = 12.sp)
    }
}

/** One list from an archetype or card page, drawn like a deck shared with you (View, Group by, Sort, card art, Export,
 *  Deck image), with Add to my decks. */
@Composable
private fun FinishList(format: String, fin: ArchetypePage.Finish?, title: String, error: String?, added: AddedDeck?,
                       add: (ArchetypePage.Finish) -> Unit, navigate: (String) -> Unit, onBack: () -> Unit) {
    val openDeck = { listId: String -> navigate("collection/list/$listId") }
    val cat by CatalogStore.state.collectAsState()
    val db = CatalogStore.db
    LaunchedEffect(Unit) { CatalogStore.load(userInitiated = true) }
    val resolved = remember(fin, db, cat.generation) { if (fin != null && db != null) finishRows(fin, db) else null }
    if (fin == null || resolved == null) {
        T1Screen {
            Bar(title, fin?.let { "${it.event} · ${InsightCharts.shortDay(it.on)}" }, onBack = onBack)
            CatalogStatus(cat)
            Notice(error ?: "Loading…", error = error != null)
        }
        return
    }
    val byline = (listOfNotNull((fin.rank?.let { "${Insights.place(it)} at " } ?: "") + fin.event, InsightCharts.shortDay(fin.on), fin.players?.let { "$it players" }) +
        listOfNotNull(resolved.second.takeIf { it > 0 }?.let { "$it card${if (it == 1) "" else "s"} not found" })).joinToString(" · ")
    ProfileCardsScreen("", "deck", null, onBack = onBack, onCard = { navigate("collection/card/$it?search=1") }, onList = openDeck,
        preset = PresetCards(resolved.first, title, format, byline) { AddToDecksRow(added, { add(fin) }, openDeck) })
}

@Composable
fun ArchetypeInsightScreen(format: String, id: Int, finish: Int?, navigate: (String) -> Unit, onBack: () -> Unit) {
    val s = InsightsStore
    LaunchedEffect(format) { s.ensure("constructed", format) }
    val pack = s.constructed[format]
    var page by remember { mutableStateOf<ArchetypePage?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var added by remember { mutableStateOf<AddedDeck?>(null) }
    val scope = rememberCoroutineScope()
    fun add(fin: ArchetypePage.Finish, deckName: String, from: String) = scope.launch { added = addToDecks(fin, deckName, format, from) }
    val openDeck = { listId: String -> navigate("collection/list/$listId") }
    LaunchedEffect(format, id) {
        Telemetry.screen(if (finish != null) "insights_finish" else "insights_archetype")
        runCatching { s.archetype(format, id, "all", s.days) }.onSuccess { page = it }.onFailure { error = "This archetype couldn't load: ${it.message}" }
    }
    val name = page?.archetype?.name ?: pack?.name(id) ?: "Archetype"
    if (finish != null) {
        val p = page
        val fin = p?.finishes?.getOrNull(finish)
        // an Other group's example is named for its colors
        val group = if (id == 0) p?.groups?.firstOrNull { it.example == finish } else null
        val title = group?.let { Insights.colorsName(it.colors.ifEmpty { "C" }, "") } ?: name
        FinishList(format, fin, title, error, added, { add(it, title, "finish") }, navigate, onBack)
        return
    }
    T1Screen {
        val p = page
        Bar(name, "${pack?.name ?: format} · all events, last ${s.days} days", onBack = onBack)
        if (p == null || pack == null) { Notice(error ?: "Loading…", error = error != null); return@T1Screen }
        Scroll {
            val share = pack.tiers["all"]?.windows?.get(s.days.toString())?.share?.firstOrNull { it.a == id }
            Brief(p.brief, "last 30 days, all events", p.decks < 20)
            Stats("Share" to InsightCharts.pct(share?.share), "Decks" to "${p.decks}", "Record" to (p.record?.let { "${it.wins}-${it.losses}" } ?: "–"))
            p.record?.let { Notice(if (it.basis == "topdeck") "Record from paper events' rounds." else "Record of players who reached a Challenge's top 32, so it runs high.") }
            val groups = p.groups.orEmpty()
            val ex = Insights.exampleFinish(p.finishes)
            if (id == 0 && groups.isNotEmpty()) {
                Section("Inside Other · by colors")
                Notice("Decks no archetype names yet, grouped by their colors. Open one for an example list.")
                groups.forEach { g ->
                    ListRow(Insights.colorsName(g.colors.ifEmpty { "C" }, ""),
                        (listOf("${g.decks} deck${if (g.decks == 1) "" else "s"}") + listOf(g.cards.joinToString(", ")).filter { it.isNotEmpty() }).joinToString(" · "),
                        onClick = g.example?.let { e -> { navigate(InsightsRoutes.finish(format, id, e)) } }) {
                        Text(InsightCharts.pct(g.share), color = T1.text, fontFamily = T1.mono, fontSize = 13.sp)
                    }
                }
            } else if (id != 0 && ex != null) {
                val f = p.finishes[ex]
                Section("Example list · " + (f.rank?.let { "${Insights.place(it)} at " } ?: "") + f.event)
                ListRow(listOfNotNull(InsightCharts.shortDay(f.on), f.players?.let { "$it players" }, if (f.tier == "major" || f.tier == "large") "big event" else null).joinToString(" · "),
                    "${f.main.sumOf { it.qty }} cards · sideboard ${f.side.sumOf { it.qty }}")
                AddToDecksRow(added, { add(f, name, "example") }, openDeck)
                f.main.take(12).forEach { ListRow(it.name) { Text("${it.qty}", color = T1.text, fontFamily = T1.mono, fontSize = 13.sp) } }
                ListRow("See the whole list", if (f.main.size > 12) "${f.main.size - 12} more cards and the sideboard" else "With the sideboard",
                    onClick = { navigate(InsightsRoutes.finish(format, id, ex)) })
            }
            Section("Share by week")
            InsightLineChart(listOf(LineSeries("a", "", p.series.v, true)), p.series.weeks, height = 140.dp, labelWidth = 40.dp)
            if (id != 0) listOf("Core · in 80%+ of lists" to p.core, "Flex slots" to p.flex, "Sideboard" to p.side).forEach { (title, rows) ->
                if (rows.isNotEmpty()) {
                    Section(title)
                    rows.take(16).forEach { c ->
                        ListRow(c.n, c.copies?.let { "%.1f copies".format(it) }, onClick = { navigate(InsightsRoutes.card(format, c.c, c.n)) }) {
                            Text(InsightCharts.pct(c.rate), color = T1.text, fontFamily = T1.mono, fontSize = 13.sp)
                        }
                    }
                }
            }
            if (p.matchups.isNotEmpty()) {
                Section("Matchups · last 90 days")
                p.matchups.take(8).forEach { m ->
                    val n = m.wins + m.losses
                    val (lo, hi) = InsightCharts.wilson(m.wins, n)
                    ListRow("vs ${pack.name(m.vs)}", if (n >= 30) "${InsightCharts.pct(lo)}–${InsightCharts.pct(hi)} likely" else "Too few matches to say") {
                        Text("${m.wins}-${m.losses}", color = T1.text, fontFamily = T1.mono, fontSize = 13.sp)
                    }
                }
            }
            if (p.finishes.isNotEmpty()) {
                Section("Best finishes")
                p.finishes.forEachIndexed { i, fin ->
                    ListRow(fin.event, listOfNotNull(fin.rank?.let { "#$it" }, InsightCharts.shortDay(fin.on), fin.players?.let { "$it players" }).joinToString(" · "),
                        onClick = { navigate(InsightsRoutes.finish(format, id, i)) })
                }
            }
        }
    }
}

/** What adding a list to the viewer's decks did, and the new deck. */
data class AddedDeck(val text: String, val listId: String? = null)

/** A finish's names in their original printings, non-foil, like Add to my decks; and how many cards it couldn't name. */
fun finishRows(fin: ArchetypePage.Finish, db: CatalogDb): Pair<List<ProfileCard>, Int> {
    val found = db.printingsByName((fin.main + fin.side).map { it.name })
    var missing = 0
    val rows = listOf("main" to fin.main, "side" to fin.side).flatMap { (board, lines) ->
        lines.mapNotNull { l -> found[l.name]?.let { ProfileCard(cardId = it.cardId, board = board, qty = l.qty) } ?: run { missing += l.qty; null } }
    }
    return rows to missing
}

/** A finish's list as a new private deck in the viewer's Library (original printings). */
suspend fun addToDecks(fin: ArchetypePage.Finish, name: String, format: String, from: String): AddedDeck {
    val db = CatalogStore.db ?: return AddedDeck("The card catalog is still loading")
    val found = db.printingsByName((fin.main + fin.side).map { it.name })
    var missing = 0
    val entries = listOf("main" to fin.main, "side" to fin.side).flatMap { (board, lines) ->
        lines.mapNotNull { l -> found[l.name]?.let { ListEntry(it.cardId, board, l.qty) } ?: run { missing += l.qty; null } }
    }
    return runCatching { ListsStore.create(ListKind.Deck, name.take(60), format, entries, "From ${fin.event}, ${fin.on}".take(120), "insights") }
        .map { id ->
            Telemetry.capture("insights_copy_to_library", mapOf("format" to format, "archetype" to name, "from" to from))
            AddedDeck("Added to your decks as ${name.take(60)}" + if (missing > 0) " ($missing card${if (missing == 1) "" else "s"} not found)" else "", id)
        }
        .getOrElse { AddedDeck("Couldn't add it: ${it.message}") }
}

/** Add to my decks, then what happened with Open (the new deck) once it's there. */
@Composable
fun AddToDecksRow(added: AddedDeck?, onAdd: () -> Unit, onOpen: (String) -> Unit) {
    val id = added?.listId
    if (id != null) ListRow(added.text, "A new private deck", onClick = { onOpen(id) }) { Label("Open", color = T1.accent) }
    else ListRow("Add to my decks", added?.text ?: "A new private deck with these cards", onClick = onAdd) { Label("Add", color = T1.accent) }
}

@Composable
fun CardInsightScreen(format: String, oracleId: String, name: String, list: Int?, navigate: (String) -> Unit, onBack: () -> Unit) {
    val s = InsightsStore
    LaunchedEffect(format) { s.ensure("constructed", format) }
    val pack = s.constructed[format]
    val tier = pack?.let { s.tier(it) } ?: "all"
    var page by remember { mutableStateOf<CardPage?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var added by remember { mutableStateOf<AddedDeck?>(null) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { Telemetry.screen(if (list != null) "insights_finish" else "insights_card") }
    LaunchedEffect(format, oracleId, tier, s.days) {
        runCatching { s.card(format, oracleId, tier, s.days) }
            .onSuccess { page = it; error = null }
            .onFailure { it.rethrowIfCancelled(); error = "This card couldn't load: ${it.message}" }
    }
    if (list != null) {
        val f = page?.finishes?.getOrNull(list)
        val deck = f?.let { pack?.name(it.a) } ?: "Deck"
        FinishList(format, f?.asFinish, deck, error, added, { fin -> scope.launch { added = addToDecks(fin, deck, format, "card") } }, navigate, onBack)
        return
    }
    T1Screen {
        Bar(page?.n ?: name, onBack = onBack)
        if (pack != null) WindowPickers(tier)
        val p = page
        if (p == null) { Notice(error ?: "Loading…", error = error != null); return@T1Screen }
        val w = p.window
        val days = w?.days ?: s.days
        Scroll {
            Stats("Main" to InsightCharts.pct(w?.main ?: p.series.main.lastOrNull()), "Side" to InsightCharts.pct(w?.side ?: p.series.side.lastOrNull()),
                "Copies" to ((w?.copies ?: p.copies)?.let { String.format(java.util.Locale.US, "%.1f", it) } ?: "–"))
            Stats("Lists" to (w?.let { "${it.decks}/${it.of}" } ?: "–"), "First seen" to (p.first_seen?.let(InsightCharts::shortDay) ?: "–"),
                "Last seen" to (p.last_seen?.let(InsightCharts::shortDay) ?: "–"))
            Section("Share of ${pack?.name ?: format} lists by week")
            val months = InsightCharts.months(p.series.from, p.series.weeks * 7).map { it.first / 7 to it.second }
            val labels = months.filterIndexed { k, _ -> k % 2 == (if (months.size % 2 == 0) 1 else 0) }
            val marks = pack?.let { CardInsights.markers(it.changes, p.n ?: name, p.series.from, p.series.weeks) }.orEmpty().map { ChartMarker(it.index, it.label, it.ban) }
            InsightLineChart(listOf(LineSeries("m", "Main", p.series.main, true), LineSeries("s", "Side", p.series.side)), p.series.weeks,
                markers = marks, xLabels = labels, height = 190.dp, labelWidth = 60.dp)
            if (w?.decks == 0) Notice("No lists played it in the last $days days.")
            if (p.by_archetype.isNotEmpty()) Section("Played in · last $days days")
            val max = (p.by_archetype.maxOfOrNull { CardInsights.archetypeBar(it) } ?: 1.0).coerceAtLeast(0.01)
            p.by_archetype.forEach { a ->
                InsightBar(pack?.name(a.a) ?: "Other", CardInsights.archetypeBar(a), max, detail = CardInsights.archetypeDetail(a),
                    onClick = { navigate(InsightsRoutes.archetype(format, a.a)) })
            }
            val lists = p.finishes.orEmpty()
            if (lists.isNotEmpty()) Section("Best lists · last $days days")
            lists.forEachIndexed { i, f ->
                ListRow(CardInsights.finishTitle(f), CardInsights.finishDetail(f, pack?.name(f.a) ?: "Other"), onClick = {
                    Telemetry.capture("insights_card_list_opened", mapOf("format" to format, "tier" to f.tier))
                    navigate(InsightsRoutes.cardList(format, oracleId, i))
                })
            }
            ListRow("Open the card", "Prices, printings and your copies", onClick = { navigate("collection/card/$oracleId") })
        }
    }
}

/** Insights → search: cards played in the format this year, by name (meta_card_search), each opening its card page. */
@Composable
fun CardSearchScreen(format: String, navigate: (String) -> Unit, onBack: () -> Unit) {
    val label = Insights.formats.firstOrNull { it.first == format }?.second ?: format
    var query by remember { mutableStateOf("") }
    var hits by remember { mutableStateOf<List<CardHit>>(emptyList()) }
    var answered by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { Telemetry.screen("insights_card_search") }
    val q = query.trim()
    LaunchedEffect(q) {
        if (q.length < 2) { hits = emptyList(); answered = null; error = null; return@LaunchedEffect }
        delay(250)
        // a newer query restarts this effect, so an older answer never lands over a newer one
        runCatching { InsightsStore.searchCards(format, q) }
            .onSuccess { hits = it; answered = q; error = null; Telemetry.capture("insights_card_search", mapOf("format" to format, "results" to it.size)) }
            .onFailure { it.rethrowIfCancelled(); error = "Search didn't work: ${it.message}" }
    }
    T1Screen {
        Bar("$label cards", onBack = onBack)
        SearchBand(query, "Card name") { query = it }
        Scroll {
            error?.let { Notice(it, error = true) }
            if (error == null && q.length >= 2 && answered == q && hits.isEmpty()) Notice("No $label lists played a card called that this year.")
            if (q.length >= 2) hits.forEach { h ->
                ListRow(h.n, CardInsights.hitDetail(h), onClick = {
                    Telemetry.capture("insights_card_opened", mapOf("format" to format, "from" to "search"))
                    navigate(InsightsRoutes.card(format, h.c, h.n))
                })
            }
        }
    }
}

@Composable
fun BanStudyScreen(format: String, changeId: Int, navigate: (String) -> Unit, onBack: () -> Unit) {
    LaunchedEffect(Unit) { Telemetry.screen("insights_ban") }
    LaunchedEffect(format) { InsightsStore.ensure("constructed", format) }
    val pack = InsightsStore.constructed[format]
    val b = pack?.bans?.firstOrNull { it.change == changeId }
    val ch = pack?.change(changeId)
    T1Screen {
        Bar(ch?.words ?: "Format change", ch?.let { "${pack.name} · ${InsightCharts.shortDay(it.on)}" }, onBack = onBack)
        if (b == null || pack == null) { Notice("This change isn't in the pack."); return@T1Screen }
        Scroll {
            Brief(b.brief, "what changed after", b.before.isEmpty() || b.afterWindow == null)
            val aw = b.afterWindow
            if (aw != null) {
                Section("Share before → ${aw.first} days after")
                val ids = (b.before.take(6).map { it.a } + aw.second.take(6).map { it.a }).distinct().take(8)
                val losers = b.losers.map { it.a }.toSet()
                InsightSlopeChart(ids.map { a ->
                    SlopeRow(a, pack.name(a), b.before.firstOrNull { it.a == a }?.share ?: 0.0, aw.second.firstOrNull { it.a == a }?.share ?: 0.0,
                        a in losers || b.gainers.firstOrNull()?.a == a)
                }, "Before", "After")
            } else Notice("No window after the change has ended yet.")
            Stats("Settled" to (b.settled_days?.let { "$it days" } ?: "Not yet"), "Lost most" to (b.losers.firstOrNull()?.let { pack.name(it.a) } ?: "–"),
                "Gained most" to (b.gainers.firstOrNull()?.let { pack.name(it.a) } ?: "–"))
            if (b.replacements.isNotEmpty()) Section(if (ch?.kind == "unban" || ch?.kind == "unrestrict") "Where it's played" else "What replaced it")
            b.replacements.forEach { r ->
                ListRow(r.n, "in ${pack.name(r.`in`)} · ${InsightCharts.pct(r.before)} → ${InsightCharts.pct(r.after)} of lists", onClick = { navigate(InsightsRoutes.card(format, r.c, r.n)) })
            }
        }
    }
}

@Composable
fun MatchupsScreen(format: String, onBack: () -> Unit) {
    LaunchedEffect(Unit) { Telemetry.screen("insights_matchups") }
    LaunchedEffect(format) { InsightsStore.ensure("constructed", format) }
    val pack = InsightsStore.constructed[format]
    T1Screen {
        val tier = pack?.let { InsightsStore.tier(it) } ?: "all"
        val grid = pack?.grid(tier, InsightsStore.days)
        Bar("Matchups", "${pack?.name ?: format} · ${grid?.second ?: "last 90 days"}", onBack = onBack)
        if (pack == null || grid == null) return@T1Screen
        Scroll {
            WindowPickers(tier)
            key(tier, InsightsStore.days) { MatchupGrid(pack, grid.first, pack.gridShare(tier, InsightsStore.days)) }
        }
    }
}

/** The matchup grid (rows against labelled columns) and the record of the square last tapped; on the format page
 *  under Meta over time, and on its own screen for older links. */
@Composable
private fun MatchupGrid(pack: ConstructedPack, m: Matchups, share: List<ShareRow>) {
    var picked by remember(pack.format) { mutableStateOf<Pair<Int, Int>?>(null) }
    var mine by remember(pack.format) { mutableStateOf<Mine?>(null) }
    LaunchedEffect(pack.format) {
        val got = InsightsStore.mine(pack.format) ?: return@LaunchedEffect
        mine = got
        picked = null   // the rows just moved
        Telemetry.capture("insights_yours", mapOf("format" to pack.format, "decks" to got.decks.count { it.a != 0 },
            "close" to yoursFirst(m.rowIds, got).count { it.second?.startsWith("You have") == true }))
    }
    val cols = m.archetypes
    val ordered = yoursFirst(m.rowIds, mine)
    val rows = ordered.map { it.first }
    Notice("Each archetype with 1% of decks (rows) against the 10 most played (columns): the row's match win rate, and first its win rate against every archetype. Your decks come first, then archetypes your collection nearly builds. Faded: fewer than 30 matches, so treat it as a hint. Tap a square for the record. From MTGO top 8 brackets and paper events' rounds.")
    InsightHeatmap(rows.map { pack.name(it) }, cols.map { pack.name(it) }, { r, c -> rows[r] == cols[c] },
                   { r, c -> m.cell(rows[r], cols[c])?.let { it.first to it.second } }, picked = picked, notes = ordered.map { it.second },
                   overall = { r -> LimitedCards.overall(share, m, rows[r])?.let { it.wins to it.losses } }) { r, c ->
        picked = r to c
        Telemetry.capture("insights_matchup_opened", mapOf("format" to pack.format, "overall" to (c < 0)))
    }
    picked?.takeIf { it.first < rows.size && it.second < 0 }?.let { (r, _) ->
        LimitedCards.overall(share, m, rows[r])?.let { o ->
            val n = o.wins + o.losses
            val (lo, hi) = InsightCharts.wilson(o.wins, n)
            ListRow("${pack.name(rows[r])} overall",
                if (n >= 30) "${InsightCharts.pct1(o.wins.toDouble() / n)} · likely ${InsightCharts.pct(lo)}–${InsightCharts.pct(hi)}" else "Only $n matches: too few to say") {
                Text(if (o.draws > 0) "${o.wins}-${o.losses}-${o.draws}" else "${o.wins}-${o.losses}", color = T1.text, fontFamily = T1.mono, fontSize = 13.sp)
            }
        }
    }
    picked?.takeIf { it.first < rows.size && it.second >= 0 && it.second < cols.size }?.let { (r, c) ->
        m.cell(rows[r], cols[c])?.let { (w, l, d) ->
            val n = w + l
            val (lo, hi) = InsightCharts.wilson(w, n)
            ListRow("${pack.name(rows[r])} vs ${pack.name(cols[c])}",
                if (n >= 30) "${InsightCharts.pct1(w.toDouble() / n)} · likely ${InsightCharts.pct(lo)}–${InsightCharts.pct(hi)}" else "Only $n matches: too few to say") {
                Text(if (d > 0) "$w-$l-$d" else "$w-$l", color = T1.text, fontFamily = T1.mono, fontSize = 13.sp)
            }
        }
    }
}

// MARK: limited

@Composable
private fun Credit(url: String) {
    val context = LocalContext.current
    Text("DATA FROM 17LANDS", Modifier.fillMaxWidth().background(T1.surface).clickable { openUrl(context, url) }.padding(horizontal = 16.dp, vertical = 10.dp),
        color = T1.muted, fontFamily = T1.mono, fontSize = 11.sp, letterSpacing = 1.5.sp, textDecoration = TextDecoration.Underline)
}

@Composable
private fun LimitedHome(navigate: (String) -> Unit) {
    val s = InsightsStore
    val retryScope = rememberCoroutineScope()
    var sort by remember { mutableStateOf("gih") }
    var rarity by remember { mutableStateOf("all") }
    var color by remember { mutableStateOf("all") }
    var query by remember { mutableStateOf("") }
    var all by remember { mutableStateOf(false) }
    // The picker waits for the sets to rank (kept on the device after the first visit) so it draws whole.
    val chips = if (s.rankableReady) s.shownChips else emptyList()
    var editing by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { s.loadExtras() }
    fun rank(key: String, kind: String, from: String) {
        Telemetry.capture("insights_rank_opened", mapOf("set" to key, "kind" to kind, "from" to from))
        navigate(InsightsRoutes.rankSet(key))
    }
    /** Sets out (or about to be) with no 17Lands data yet: rank them now. */
    @Composable fun newSets() {
        val fresh = s.rankable.filter { !it.pack }
        if (fresh.isEmpty()) return
        Section("New sets to rank")
        fresh.forEach { r -> ListRow("Rank ${r.name}", r.detail(), onClick = { rank(r.key, r.kind, "new_sets") }) }
    }
    @Composable fun alertsRow() {
        s.alerts?.let { on -> ListRow("New in Insights", "A push when a new set, cube or format arrives") { T1Switch(on) { s.setAlerts(it) } } }
    }
    s.stale?.let { Notice(it) }
    if (chips.isEmpty()) {
        Notice(s.error ?: if (s.loading || !s.rankableReady) "Loading draft data…" else "No set has 17Lands data yet. A new set's numbers arrive about three weeks after it comes out on Arena.", error = s.error != null)
        if (s.error != null) BigAction("Try again") { retryScope.launch { s.load(force = true) } }
        newSets()
        return
    }
    // Sets with no 17Lands data yet (spoiler season, or just out) lead the picker and open Rank this set; Edit hides any.
    val set = s.setCode?.takeIf { k -> chips.any { it.key == k } } ?: (chips.firstOrNull { it.pack } ?: chips.first()).key
    val setCell = FilterCell("Set", chips.firstOrNull { it.key == set }?.label ?: set,
        chips.map { c -> Triple(c.key, c.label, s.limitedName(c.key)?.takeIf { it != c.label }) } + Triple(FilterCell.EDIT, "Shown sets…", null), set) { v ->
        if (v == FilterCell.EDIT) editing = true else { s.pickSet(v); query = ""; all = false }
    }
    @Composable fun editor() {
        if (editing) ShownEditor("Shown sets", s.limitedChips.map { c -> Triple(c.key, c.label, s.limitedName(c.key)?.takeIf { it != c.label }) }, s.hiddenSets,
            { k, hide -> s.setHidden(false, k, hide) }) { editing = false }
    }
    val soon = s.rankable.firstOrNull { r -> r.key == set && chips.any { !it.pack && it.key == r.key } }
    if (soon != null) {
        FilterRow(listOf(setCell))
        editor()
        Notice(LimitedPicker.soonText(soon))
        RankAction("Rank this set", soon.detail()) { rank(soon.key, soon.kind, "soon") }
        alertsRow()
        return
    }
    LaunchedEffect(set) { s.ensure("limited", set) }
    val pack = s.limited[set] ?: run {
        FilterRow(listOf(setCell)); editor()
        Notice(s.error ?: "Loading ${LimitedPicker.label(set, s.limitedName(set))}…", error = s.error != null); return
    }
    val events = s.events(pack)
    val ev = s.currentEvent(pack) ?: return
    val groups = pack.events[ev]?.groups ?: return
    val grp = if (groups.containsKey(s.group)) s.group else "all"
    FilterRow(buildList {
        add(setCell)
        if (events.size > 1) add(FilterCell("Event", Insights.eventLabels[ev] ?: ev, events.map { Triple(it, Insights.eventLabels[it] ?: it, null) }, ev) { s.pickEvent(it) })
        if (groups.containsKey("top")) add(FilterCell("Players", if (grp == "top") "Top players" else "All players",
            listOf(Triple("all", "All players", null), Triple("top", "Top players", "60%+ win rate")), grp) { s.pickGroup(it) })
    })
    editor()
    val v = groups[grp] ?: return

    // Cards first: the best for the sort and filters (ten, then Show all), with search across the set, then every other set.
    val catalog by CatalogStore.state.collectAsState()
    var faces by remember { mutableStateOf<Map<String, LimitedFace>>(emptyMap()) }
    LaunchedEffect(pack.set_code, catalog.generation) {
        CatalogStore.load(userInitiated = true)   // art and mana costs come from the card catalog
        faces = LimitedFace.load(pack.set_code, v.cards)
    }
    val rated = v.cards.any { it.r != null }
    val sortOpt = LimitedCards.sorts.firstOrNull { it.first == sort }
    Section("Top cards · ${sortOpt?.second?.lowercase() ?: sort}")
    FilterRow(buildList {
        add(FilterCell("Sort", sortOpt?.third ?: sort, LimitedCards.sorts.map { Triple(it.first, it.second, it.third) }, sort) {
            sort = it; all = false; Telemetry.capture("insights_sort_changed", mapOf("sort" to it))
        })
        if (rated) add(FilterCell("Rarity", LimitedCards.rarities.firstOrNull { it.first == rarity }?.second ?: rarity,
            LimitedCards.rarities.map { Triple(it.first, it.second, null) }, rarity) { rarity = it; all = false })
        add(FilterCell("Color", LimitedCards.colors.firstOrNull { it.first == color }?.third ?: color,
            LimitedCards.colors.map { Triple(it.first, it.second, null) }, color) { color = it; all = false })
    })
    SearchBand(query, "Search cards") { query = it }
    @Composable fun row(c: LCard, i: Int?) {
        val (value, vs) = LimitedCards.value(c, sort, v.wr)
        LimitedCardRow(i, c, faces[c.n], value, vs) { navigate(InsightsRoutes.limitedCard(pack.set_code, ev, grp, c.n)) }
    }
    if (LimitedCards.norm(query).length >= LimitedCards.MIN_QUERY) {
        val others = s.limited.values.filter { it.set_code != pack.set_code }.sortedByDescending { it.released ?: "" }
            .map { p -> p.set_code to p.events.values.flatMap { e -> e.groups["all"]?.cards?.map { it.n }.orEmpty() }.distinct().sorted() }
        val (here, elsewhere) = LimitedCards.search(query, v.cards.map { it.n }, others)
        here.forEach { n -> v.cards.firstOrNull { it.n == n }?.let { row(it, null) } }
        if (here.isEmpty() && elsewhere.isNotEmpty()) {
            Section("Not in ${LimitedPicker.label(pack.set_code, pack.name)} · in other sets")
            elsewhere.forEach { (k, n) ->
                ListRow(n, LimitedPicker.label(k, s.limitedName(k)), onClick = {
                    Telemetry.capture("insights_card_search_elsewhere", mapOf("set" to k))
                    val e = s.limited[k]?.let { s.currentEvent(it) } ?: "PremierDraft"
                    navigate(InsightsRoutes.limitedCard(k, e, "all", n))
                })
            }
        }
        if (here.isEmpty() && elsewhere.isEmpty()) Notice("No card in any set's draft data is called that.")
    } else {
        val cards = LimitedCards.cards(v.cards, sort, rarity, color)
        (if (all) cards else cards.take(LimitedCards.TOP)).forEachIndexed { i, c -> row(c, i + 1) }
        if (cards.isEmpty()) Notice("No card matches these filters.")
        if (cards.size > LimitedCards.TOP) Row(Modifier.fillMaxWidth()) {
            Ghost(if (all) "Show the top ${LimitedCards.TOP}" else "Show all ${cards.size}") {
                all = !all
                if (all) Telemetry.capture("insights_cards_expanded", mapOf("set" to pack.set_code, "count" to cards.size))
            }
        }
    }
    Notice("GIH WR: win rate with the card in hand · OH: in the opening hand · IWD: improvement when drawn · ATA: average pick taken · under it: points above or below the average")

    val ranked = s.rankable.firstOrNull { it.key == pack.set_code }
    val kind = ranked?.kind ?: if (pack.cube != null) "cube" else "set"
    RankAction("Rank this ${if (kind == "cube") "cube" else "set"}",
        ranked?.takeIf { it.rankings > 0 }?.detail() ?: "Stack-rank its cards by color, then a top 100. Compare with friends.") { rank(pack.set_code, kind, "set") }
    newSets()
    Section("Color pairs · game win rate")
    val shown = v.pairs.filter { it.share >= 0.01 }.sortedByDescending { it.wr }
    val lo = maxOf(0.4, (shown.minOfOrNull { it.wr } ?: 0.5) - 0.02)
    val hi = minOf(0.7, (shown.maxOfOrNull { it.wr } ?: 0.6) + 0.01)
    shown.forEach { p ->
        InsightBar("${Insights.pairNames[p.p] ?: p.p} ${if (p.p == "3C") "" else p.p}", p.wr, hi, lo, "${InsightCharts.pct(p.share)} of games · splash ${InsightCharts.pct(p.splash)}",
            highlighted = p.p == shown.firstOrNull()?.p, format = InsightCharts::pct1, reference = v.wr, onClick = { navigate(InsightsRoutes.pair(pack.set_code, ev, grp, p.p)) })
    }
    if (v.colors.isNotEmpty()) {
        Section("Deck colors · with splashes, most played first")
        val rows = v.colors.take(15)
        val clo = maxOf(0.35, rows.minOf { it.wr } - 0.02); val chi = minOf(0.75, rows.maxOf { it.wr } + 0.01)
        val best = rows.maxByOrNull { it.wr }
        rows.forEach { c ->
            InsightBar(Insights.colorsName(c.m, c.s), c.wr, chi, clo, "${InsightCharts.pct(c.share)} of games · ${"%,d".format(c.games)} games",
                highlighted = c == best, format = InsightCharts::pct1, reference = v.wr)
        }
    }
    if (v.weeks >= 2) {
        Section("Pairs by week · win rate")
        val top = shown.filter { it.p.length == 2 && it.p != "3C" }.take(5)
        InsightLineChart(top.mapIndexed { i, p -> LineSeries(p.p, p.p, p.week_wr, i == 0) }, v.weeks, xLabels = (0 until v.weeks).map { it to "W${it + 1}" },
            height = 160.dp, format = InsightCharts::pct1, labelWidth = 70.dp, fit = true, reference = "AVG" to v.wr)
    }
    val pts = v.cards.filter { it.gih != null && it.ata != null && it.gih_n >= 1000 }.map { ScatterPoint(it.n, it.n, it.ata!!, it.gih!!) }
    if (pts.size >= 20) {
        Section("Taken vs win rate · above the line is taken too late")
        InsightScatter(pts) { navigate(InsightsRoutes.limitedCard(pack.set_code, ev, grp, it.id)) }
    }
    Section("Game facts")
    Stats("On the play" to InsightCharts.pct1(v.facts.play_wr), "On the draw" to InsightCharts.pct1(v.facts.draw_wr), "Turns" to (v.facts.turns?.let { "%.1f".format(it) } ?: "–"))
    Stats("Mulligans" to InsightCharts.pct(v.facts.mull_rate), "Kept 7" to InsightCharts.pct1(v.facts.keep7_wr), "After a mull" to InsightCharts.pct1(v.facts.mull_wr))
    Brief(v.brief, "${pack.name ?: pack.set_code} ${Insights.eventLabels[ev] ?: ev}" + if (grp == "top") ", top players (60%+)" else "", v.games < 20000, "Data from 17Lands" to pack.credit.url)
    Stats("Games" to "%,d".format(v.games), "Average" to InsightCharts.pct1(v.wr), "Weeks" to "${v.weeks}")
    alertsRow()
}

@Composable
fun PairInsightScreen(set: String, event: String, group: String, pair: String, navigate: (String) -> Unit, onBack: () -> Unit) {
    LaunchedEffect(Unit) { Telemetry.screen("insights_pair") }
    LaunchedEffect(set) { InsightsStore.ensure("limited", set) }
    val pack = InsightsStore.limited[set]
    val v = pack?.events?.get(event)?.groups?.get(group)
    val p = v?.pairs?.firstOrNull { it.p == pair }
    T1Screen {
        Bar("${Insights.pairNames[pair] ?: pair} $pair", "${LimitedPicker.label(set, pack?.name)} ${Insights.eventLabels[event] ?: event}", onBack = onBack)
        if (p == null || pack == null) { Notice("This pair isn't in the pack."); return@T1Screen }
        Scroll {
            Credit(pack.credit.url)
            Stats("Win rate" to InsightCharts.pct1(p.wr), "Of games" to InsightCharts.pct(p.share), "Splash" to InsightCharts.pct(p.splash))
            Stats("On the play" to InsightCharts.pct1(p.play_wr), "On the draw" to InsightCharts.pct1(p.draw_wr), "Games" to "%,d".format(p.games))
            if (v.weeks >= 2) {
                Section("Win rate by week")
                InsightLineChart(listOf(LineSeries(pair, pair, p.week_wr, true)), v.weeks, xLabels = (0 until v.weeks).map { it to "W${it + 1}" }, height = 140.dp,
                    format = InsightCharts::pct1, labelWidth = 60.dp)
            }
            Section("Best cards in $pair · win rate in hand")
            v.cards.mapNotNull { c -> c.pair_gih?.get(pair)?.let { c to it } }.sortedByDescending { it.second }.take(20).forEach { (c, wr) ->
                ListRow(c.n, listOfNotNull(c.r?.replaceFirstChar { it.uppercase() }, c.col).joinToString(" · "), onClick = { navigate(InsightsRoutes.limitedCard(set, event, group, c.n)) }) {
                    Text(InsightCharts.pct1(wr), color = T1.text, fontFamily = T1.mono, fontSize = 13.sp)
                }
            }
        }
    }
}

@Composable
fun LimitedCardScreen(set: String, event: String, group: String, name: String, navigate: (String) -> Unit, onBack: () -> Unit) {
    LaunchedEffect(Unit) { Telemetry.screen("insights_limited_card") }
    LaunchedEffect(set) { InsightsStore.ensure("limited", set) }
    val pack = InsightsStore.limited[set]
    val v = pack?.events?.get(event)?.groups?.get(group)
    val c = v?.cards?.firstOrNull { it.n == name }
    T1Screen {
        Bar(name, "${LimitedPicker.label(set, pack?.name)} ${Insights.eventLabels[event] ?: event}", onBack = onBack)
        if (c == null || pack == null) { Notice("This card isn't in the pack."); return@T1Screen }
        val catalog by CatalogStore.state.collectAsState()
        var face by remember { mutableStateOf<LimitedFace?>(null) }
        LaunchedEffect(name, catalog.generation) {
            CatalogStore.load(userInitiated = true)
            face = LimitedFace.load(set, listOf(c)).values.firstOrNull()
        }
        Scroll {
            // the card first: its picture in the set's printing and its mana cost
            Column(Modifier.fillMaxWidth().padding(vertical = 20.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                face?.printing?.let { CardArt(it, 220.dp) } ?: Box(Modifier.width(220.dp).height(306.dp).background(T1.surface))
                face?.cost?.takeIf { it.isNotEmpty() }?.let { ManaCost(it, 16.dp) }
            }
            Credit(pack.credit.url)
            if (c.gih == null) Notice("Fewer than 500 games with this card in hand: no win rates yet.")
            Stats("In hand" to InsightCharts.pct1(c.gih), "Opening hand" to InsightCharts.pct1(c.oh), "Drawn" to InsightCharts.pct1(c.gd))
            Stats("Not seen" to InsightCharts.pct1(c.gns), "IWD" to (c.iwd?.let { InsightCharts.delta(it) } ?: "–"), "Taken at" to (c.ata?.let { "%.1f".format(it) } ?: "–"))
            Stats("In decks" to InsightCharts.pct(c.deck), "Games in hand" to "%,d".format(c.gih_n), "Rarity" to (c.r ?: "–"))
            val wk = c.week_gih
            if (wk != null && v.weeks >= 2) {
                Section("Win rate in hand by week")
                InsightLineChart(listOf(LineSeries("w", "", wk, true)), v.weeks, xLabels = (0 until v.weeks).map { it to "W${it + 1}" }, height = 140.dp,
                    format = InsightCharts::pct1, labelWidth = 50.dp)
            }
            val pairs = c.pair_gih?.entries?.sortedByDescending { it.value }.orEmpty()
            if (pairs.isNotEmpty()) {
                Section("By color pair · in hand")
                val lo = maxOf(0.35, pairs.minOf { it.value } - 0.02); val hi = minOf(0.8, pairs.maxOf { it.value } + 0.01)
                pairs.forEachIndexed { i, (k, wr) ->
                    InsightBar("${Insights.pairNames[k] ?: k} $k", wr, hi, lo, highlighted = i == 0, format = InsightCharts::pct1, reference = c.gih,
                        onClick = { navigate(InsightsRoutes.pair(set, event, group, k)) })
                }
            }
            c.c?.let { id -> ListRow("Open the card", "Prices, printings and your copies", onClick = { navigate("collection/card/$id") }) }
        }
    }
}

// MARK: review (moderators)

@Serializable private data class Review(val archetypes: List<Proposal>, val changes: List<ProposedChange>, val unmatched: List<Unmatched>) {
    @Serializable data class Proposal(val id: Int, val format: String, val name: String, val family: String, val colors: String, val signature: List<String>,
                                      val decks: Int? = null, val missing: List<String>, val blocked: Boolean)
    @Serializable data class ProposedChange(val id: Int, val format: String, val on: String, val kind: String, val cards: List<String>)
    @Serializable data class Unmatched(val source: String, val name: String, val seen: Int, val last_seen: String)
}

@Composable
fun InsightsReviewScreen(onBack: () -> Unit) {
    val json = remember { Json { ignoreUnknownKeys = true } }
    var review by remember { mutableStateOf<Review?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val names = remember { mutableStateMapOf<Int, String>() }
    val scope = rememberCoroutineScope()
    suspend fun load() {
        runCatching { json.decodeFromString<Review>(T1App.supabase.postgrest.rpc("insights_review").data) }
            .onSuccess { review = it; error = null }.onFailure { error = "Review couldn't load: ${it.message}" }
    }
    fun act(fn: String, id: Int, action: String, name: String? = null) = scope.launch {
        runCatching {
            T1App.supabase.postgrest.rpc(fn, buildJsonObject { put("p_id", id); put("p_action", action); if (!name.isNullOrBlank()) put("p_name", name) })
        }.onSuccess { Telemetry.capture("insights_review_action", mapOf("what" to fn, "action" to action)); load() }.onFailure { error = it.message }
    }
    LaunchedEffect(Unit) { Telemetry.screen("insights_review"); load() }
    T1Screen {
        Bar("Review", "Archetypes and bans", onBack = onBack)
        Scroll {
            error?.let { Notice(it, error = true) }
            val r = review ?: run { if (error == null) Notice("Loading…"); return@Scroll }
            Section("Proposed archetypes · ${r.archetypes.size}")
            if (r.archetypes.isEmpty()) Notice("Nothing proposed.")
            r.archetypes.forEach { a ->
                ListRow(a.name, "${a.format} · ${a.family} · ${a.colors.ifEmpty { "colorless" }} · ${a.decks ?: 0} decks")
                Notice(a.signature.take(10).joinToString(", ") + if (a.missing.isNotEmpty()) "\nNot in the catalog: ${a.missing.joinToString(", ")}" else "")
                Field("Name", names[a.id] ?: a.name, { names[a.id] = it })
                Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    Ghost("Approve") { act("insights_review_archetype", a.id, "approve", names[a.id]) }
                    Ghost("Reject") { act("insights_review_archetype", a.id, "reject") }
                }
            }
            Section("Proposed format changes · ${r.changes.size}")
            if (r.changes.isEmpty()) Notice("Nothing proposed.")
            r.changes.forEach { c ->
                ListRow("${c.kind.replaceFirstChar { it.uppercase() }}: ${c.cards.take(4).joinToString(", ")}${if (c.cards.size > 4) "…" else ""}", "${c.format} · ${InsightCharts.shortDay(c.on)}")
                Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    Ghost("Confirm") { act("insights_review_change", c.id, "confirm") }
                    Ghost("Reject") { act("insights_review_change", c.id, "reject") }
                }
            }
            Section("Names the catalog doesn't know")
            r.unmatched.forEach { u -> ListRow(u.name, "${u.source} · seen ${u.seen}× · last ${InsightCharts.shortDay(u.last_seen)}") }
        }
    }
}

/** Every Insights route, for the app's NavHost and the Debug demo. */
fun NavGraphBuilder.insightsGraph(nav: NavHostController, moderator: Boolean) {
    val go: (String) -> Unit = { nav.navigate(it) }
    val back: () -> Unit = { nav.popBackStack() }
    composable("insights") { InsightsHomeScreen(navigate = go, moderator = moderator) }
    composable("insights/arch/{format}/{id}") { e ->
        ArchetypeInsightScreen(e.arguments?.getString("format") ?: "", e.arguments?.getString("id")?.toIntOrNull() ?: 0, null, go, back)
    }
    composable("insights/finish/{format}/{id}/{i}") { e ->
        ArchetypeInsightScreen(e.arguments?.getString("format") ?: "", e.arguments?.getString("id")?.toIntOrNull() ?: 0, e.arguments?.getString("i")?.toIntOrNull() ?: 0, go, back)
    }
    composable("insights/card/{format}/{id}?n={n}") { e ->
        CardInsightScreen(e.arguments?.getString("format") ?: "", e.arguments?.getString("id") ?: "", e.arguments?.getString("n") ?: "Card", null, go, back)
    }
    composable("insights/cardlist/{format}/{id}/{i}") { e ->
        CardInsightScreen(e.arguments?.getString("format") ?: "", e.arguments?.getString("id") ?: "", "Card", e.arguments?.getString("i")?.toIntOrNull() ?: 0, go, back)
    }
    composable("insights/cards/{format}") { e -> CardSearchScreen(e.arguments?.getString("format") ?: "", go, back) }
    composable("insights/ban/{format}/{id}") { e ->
        BanStudyScreen(e.arguments?.getString("format") ?: "", e.arguments?.getString("id")?.toIntOrNull() ?: 0, go, back)
    }
    composable("insights/matchups/{format}") { e -> MatchupsScreen(e.arguments?.getString("format") ?: "", back) }
    composable("insights/part/{format}/{part}") { e -> ConstructedPartScreen(e.arguments?.getString("format") ?: "", e.arguments?.getString("part") ?: "", go, back) }
    composable("insights/pair/{set}/{event}/{group}/{pair}") { e ->
        val a = e.arguments
        PairInsightScreen(a?.getString("set") ?: "", a?.getString("event") ?: "", a?.getString("group") ?: "all", a?.getString("pair") ?: "", go, back)
    }
    composable("insights/lcard/{set}/{event}/{group}/{name}") { e ->
        val a = e.arguments
        LimitedCardScreen(a?.getString("set") ?: "", a?.getString("event") ?: "", a?.getString("group") ?: "all", a?.getString("name") ?: "", go, back)
    }
    composable(InsightsRoutes.REVIEW) { InsightsReviewScreen(back) }
}

/** Debug demo: Insights on the packs in the debug assets, without signing in. */
@Composable
fun InsightsDemoRoot() {
    val nav = rememberNavController()
    NavHost(navController = nav, startDestination = "insights") { insightsGraph(nav, moderator = false) }
}
