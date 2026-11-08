package site.table1.events.library

import android.content.Context
import android.print.PrintAttributes
import android.print.PrintManager
import android.webkit.WebView
import android.webkit.WebViewClient
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import site.table1.events.insights.InsightsStore
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
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry
import java.time.LocalDate
import java.util.UUID

/* Sideboard guide screens (contract/sideboard-guide-2026-11-04.md § Screens): the guide, a matchup, the In and Out
   pickers, the sideboard and Considering, new matchup, and the print preview. Same as iOS SideboardGuideViews.swift
   and web SideboardGuide.tsx. */

/** The deck's lines with names, oracle ids and art, read again when the list or the catalog changes. */
@Composable
private fun rememberGuideRows(list: CardList?): List<ListLine> {
    val cat by CatalogStore.state.collectAsState()
    val rows by produceState(emptyList<ListLine>(), list?.entries, cat.generation) {
        CatalogStore.load(userInitiated = true)
        val db = CatalogStore.db ?: return@produceState
        val entries = list?.entries ?: return@produceState
        value = withContext(Dispatchers.Default) { resolveLines(entries, db, CardGrouping.Type) }
    }
    return rows
}

private fun edit(list: CardList, change: (SideboardGuide) -> SideboardGuide) = ListsStore.setGuide(list.id, change(list.guide ?: SideboardGuide()))
private fun editMatchup(list: CardList, id: String, change: (Matchup) -> Matchup) =
    edit(list) { g -> g.copy(matchups = g.matchups.map { if (it.id == id) change(it) else it }) }

@Composable
private fun IconAction(icon: T1Icon, label: String, onClick: () -> Unit) {
    Box(Modifier.size(width = 50.dp, height = 40.dp).clickable(onClick = onClick).semantics { contentDescription = label },
        contentAlignment = Alignment.Center) { IconGlyph(icon) }
}

/** The deck screen's row. */
@Composable
fun SideboardGuideRow(list: CardList, onOpen: () -> Unit) {
    val n = list.guide?.matchups?.size ?: 0
    ListRow("Sideboard guide", "$n ${if (n == 1) "matchup" else "matchups"} · sideboard ${list.count("side")}", onClick = onOpen)
}

@Composable
fun SideboardGuideScreen(listId: String, onBack: () -> Unit, go: (String) -> Unit) {
    val s by ListsStore.state.collectAsState()
    val list = s.lists.firstOrNull { it.id == listId }
    val rows = rememberGuideRows(list)
    LaunchedEffect(listId) { Telemetry.capture("sideboard_guide_opened", mapOf("matchups" to (list?.guide?.matchups?.size ?: 0))) }
    T1Screen {
        Bar("Sideboard guide", onBack = onBack) {
            if (list != null) {
                IconAction(T1Icon.Plus, "New matchup") { if ((list.guide?.matchups?.size ?: 0) < SideboardRules.MAX_MATCHUPS) go("new") }
                if (!list.guide?.matchups.isNullOrEmpty()) IconAction(T1Icon.Print, "Print") { go("print") }
            }
        }
        if (list == null) { Notice("That deck isn't here anymore.", error = true); return@T1Screen }
        val lines = SideboardRules.lines(rows)
        val ms = list.guide?.matchups ?: emptyList()
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            SideboardRules.overSideboard(lines, list.format)?.let { item { Notice("The sideboard has $it cards: Constructed allows 15.", error = true) } }
            item { ListRow("Sideboard", "Sideboard ${list.count("side")} · considering ${list.count("maybe")}", onClick = { go("pool") }) }
            if (ms.isNotEmpty()) item { Section("Matchups · ${ms.size}") }
            items(ms, key = { it.id }) { m ->
                val c = SideboardRules.check(m, lines, list.format)
                ListRow(m.name, c.label, onClick = { go("m/${m.id}") }) {
                    if (rows.isNotEmpty() && c.issues.isNotEmpty()) Label("Check", color = T1.danger)
                }
            }
            if (ms.isEmpty()) item { ListRow("New matchup", onClick = { go("new") }) { IconGlyph(T1Icon.Plus) } }
        }
    }
}

@Composable
fun NewMatchupScreen(listId: String, onBack: () -> Unit, onCreated: (String) -> Unit) {
    val s by ListsStore.state.collectAsState()
    val list = s.lists.firstOrNull { it.id == listId }
    var name by remember { mutableStateOf("") }
    LaunchedEffect(list?.format) { list?.format?.let { runCatching { InsightsStore.ensure("constructed", it) } } }
    T1Screen {
        Bar("New matchup", onBack = onBack)
        if (list == null) return@T1Screen
        Column(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp)) {
            T1TextField(name, { name = it.take(SideboardRules.MAX_NAME) }, label = "Name")
        }
        val add = { n: String, archetype: Int? ->
            val id = UUID.randomUUID().toString()
            edit(list) { g -> g.copy(matchups = g.matchups + Matchup(id, n, archetype)) }
            Telemetry.capture("sideboard_matchup_added", mapOf("from" to if (archetype == null) "typed" else "archetype"))
            onCreated(id)
        }
        BigAction("Add", enabled = SideboardRules.name(name).isNotEmpty()) { add(SideboardRules.name(name), null) }
        val taken = list.guide?.matchups?.map { it.name.lowercase() }?.toSet() ?: emptySet()
        val pack = InsightsStore.constructed[list.format]
        val options = pack?.tiers?.get(pack.default_tier)?.windows?.get("30")?.share.orEmpty()
            .filter { it.a != 0 }.sortedByDescending { it.share }.take(30)
            .map { Triple(it.a, pack!!.name(it.a), "%.1f%%".format(it.share * 100)) }
            .filter { it.second.lowercase() !in taken }
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (options.isNotEmpty()) item { Section("${CatalogPack.formatName(list.format)} meta") }
            items(options, key = { it.first }) { (a, n, share) -> ListRow(n, share, onClick = { add(n, a) }) }
        }
    }
}

@Composable
fun SideboardMatchupScreen(listId: String, matchupId: String, onBack: () -> Unit, onPick: (GuideSide) -> Unit) {
    val s by ListsStore.state.collectAsState()
    val list = s.lists.firstOrNull { it.id == listId }
    val rows = rememberGuideRows(list)
    val ms = list?.guide?.matchups ?: emptyList()
    val i = ms.indexOfFirst { it.id == matchupId }
    val m = ms.getOrNull(i)
    var menu by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf<String?>(null) }
    var notes by remember(m?.id) { mutableStateOf(m?.notes ?: "") }
    T1Screen {
        Bar(m?.name ?: "Matchup", onBack = onBack) { if (m != null) BarAction("Edit") { menu = true } }
        if (list == null || m == null) { Notice("That matchup isn't in the guide anymore.", error = true); return@T1Screen }
        val lines = SideboardRules.lines(rows)
        val pool = SideboardRules.pool(lines)
        val c = SideboardRules.check(m, lines, list.format)
        Row(Modifier.fillMaxWidth().height(50.dp), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            for ((side, text) in listOf(GuideSide.In to "In ${c.ins}", GuideSide.Out to "Out ${c.outs}")) {
                Box(Modifier.weight(1f).fillMaxHeight().background(T1.surface).clickable { onPick(side) }, contentAlignment = Alignment.Center) {
                    Label(text, color = T1.text)
                }
            }
        }
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (rows.isNotEmpty()) items(c.issues.size) { k -> Notice(SideboardRules.text(c.issues[k], pool), error = true) }
            for (side in listOf(GuideSide.In, GuideSide.Out)) {
                val cards = if (side == GuideSide.In) m.ins else m.outs
                item { Section("${if (side == GuideSide.In) "In" else "Out"} · ${if (side == GuideSide.In) c.ins else c.outs}") }
                if (cards.isEmpty()) item { ListRow("—") }
                items(cards, key = { "$side${it.oracle}" }) { card ->
                    val line = rows.firstOrNull { it.oracleId == card.oracle && (if (side == GuideSide.Out) it.board == "main" else it.board != "main") }
                        ?: rows.firstOrNull { it.oracleId == card.oracle }
                    val fromMaybe = side == GuideSide.In && (pool[card.oracle]?.side ?: 0) < card.qty
                    CardRow(line?.printing, pool[card.oracle]?.name ?: line?.name ?: "Card", if (fromMaybe) "Considering" else null, onClick = { onPick(side) }) {
                        Text("${if (side == GuideSide.In) "+" else "−"}${card.qty}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                    }
                }
            }
            item { Section("Notes · ${notes.length}/${SideboardRules.MAX_NOTES}") }
            item {
                // The whole box is the text field's decoration: a tap anywhere in it focuses the notes.
                BasicTextField(notes, { v ->
                    notes = v.take(SideboardRules.MAX_NOTES)
                    editMatchup(list, m.id) { it.copy(notes = notes.trim()) }
                }, Modifier.fillMaxWidth(), textStyle = TextStyle(color = T1.text, fontFamily = T1.mono, fontSize = 14.sp, lineHeight = 22.sp),
                    cursorBrush = SolidColor(T1.accent),
                    decorationBox = { inner ->
                        Box(Modifier.fillMaxWidth().heightIn(min = 140.dp).background(T1.surface).padding(horizontal = 16.dp, vertical = 14.dp)) {
                            if (notes.isEmpty()) Text("Add notes", color = T1.muted, fontFamily = T1.mono, fontSize = 14.sp)
                            inner()
                        }
                    })
            }
        }
        if (menu) T1Menu(m.name, listOfNotNull(
            T1MenuItem("Rename") { renaming = m.name },
            T1MenuItem("Move up", enabled = i > 0) { edit(list) { g -> g.copy(matchups = g.matchups.toMutableList().apply { add(i - 1, removeAt(i)) }) } },
            T1MenuItem("Move down", enabled = i < ms.size - 1) { edit(list) { g -> g.copy(matchups = g.matchups.toMutableList().apply { add(i + 1, removeAt(i)) }) } },
            T1MenuItem("Delete matchup", danger = true) { edit(list) { g -> g.copy(matchups = g.matchups.filter { it.id != m.id }) }; onBack() },
        )) { menu = false }
        renaming?.let { r ->
            T1AlertDialog(
                title = "Rename matchup", onDismiss = { renaming = null },
                confirm = {
                    TextButton(enabled = SideboardRules.name(r).isNotEmpty(), onClick = {
                        editMatchup(list, m.id) { it.copy(name = SideboardRules.name(r)) }
                        renaming = null
                    }) { Label("Save", color = T1.text) }
                },
                dismiss = { TextButton(onClick = { renaming = null }) { Label("Cancel", color = T1.text) } },
                body = { T1TextField(r, { renaming = it.take(SideboardRules.MAX_NAME) }, label = "Name") },
            )
        }
    }
}

/** "SIDEBOARD 2 · CONSIDERING 1", "CONSIDERING 1" or "MAIN 4". */
fun guideCopies(c: SideboardRules.Copies, side: GuideSide): String =
    if (side == GuideSide.Out) "Main ${c.main}"
    else listOfNotNull(if (c.side > 0) "Sideboard ${c.side}" else null, if (c.maybe > 0) "Considering ${c.maybe}" else null).joinToString(" · ")

@Composable
fun SideboardPickScreen(listId: String, matchupId: String, side: GuideSide, onBack: () -> Unit) {
    val s by ListsStore.state.collectAsState()
    val list = s.lists.firstOrNull { it.id == listId }
    val rows = rememberGuideRows(list)
    val m = list?.guide?.matchup(matchupId)
    var query by remember { mutableStateOf("") }
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val pool = SideboardRules.pool(SideboardRules.lines(rows))
    val cards = rows.sortedBy { it.name }.mapNotNull { l -> l.oracleId?.let { o -> pool[o]?.let { Triple(o, l, it) } } }.distinctBy { it.first }
    val total = m?.let { (if (side == GuideSide.In) it.ins else it.outs).sumOf { c -> c.qty } } ?: 0
    T1Screen {
        Bar("${if (side == GuideSide.In) "In" else "Out"} · $total", onBack = onBack)
        if (list == null || m == null) { Notice("That matchup isn't in the guide anymore.", error = true); return@T1Screen }
        if (side == GuideSide.In) {
            Column(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp)) {
                T1TextField(query, { query = it }, placeholder = "Add a card to consider")
            }
        }
        val step = { o: String, n: Int -> editMatchup(list, m.id) { it.set(o, n, side) } }
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (side == GuideSide.In && query.isNotBlank()) {
                val hits = CatalogStore.db?.search(query, 12).orEmpty()
                items(hits, key = { it.oracleId }) { o ->
                    ListRow(o.name, o.typeLine, onClick = {
                        val p = CatalogStore.db?.printings(o.idx)?.firstOrNull() ?: return@ListRow
                        val have = m.qty(o.oracleId, GuideSide.In)
                        val c = pool[o.oracleId]
                        // A card already in the sideboard or Considering only needs bringing in.
                        if ((c?.side ?: 0) + (c?.maybe ?: 0) <= have) {
                            val finish = p.finishList.firstOrNull()?.wire ?: "nonfoil"
                            scope.launch { runCatching { ListsStore.add(list.id, p.cardId, "maybe", 1, finish) } }
                        }
                        step(o.oracleId, have + 1)
                        Telemetry.capture("sideboard_card_considered")
                        query = ""
                    }) { IconGlyph(T1Icon.Plus) }
                }
            } else {
                val groups = if (side == GuideSide.In) listOf(
                    Triple("Sideboard", cards.filter { it.third.side > 0 }) { c: SideboardRules.Copies -> c.side + c.maybe } to { c: SideboardRules.Copies -> c.side },
                    Triple("Considering", cards.filter { it.third.side == 0 && it.third.maybe > 0 }) { c: SideboardRules.Copies -> c.maybe } to { c: SideboardRules.Copies -> c.maybe },
                ) else listOf(Triple("Main deck", cards.filter { it.third.main > 0 }) { c: SideboardRules.Copies -> c.main } to { c: SideboardRules.Copies -> c.main })
                for ((g, counted) in groups) {
                    val (title, rs, max) = g
                    if (rs.isEmpty()) continue
                    item { Section("$title · ${rs.sumOf { counted(it.third) }}") }
                    items(rs, key = { "$title${it.first}" }) { (o, line, c) ->
                        val n = m.qty(o, side)
                        Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                            Box(Modifier.weight(1f)) {
                                CardRow(line.printing, c.name, guideCopies(c, side)) {
                                    Text(if (n == 0) "0" else "${if (side == GuideSide.In) "+" else "−"}$n", color = if (n == 0) T1.muted else T1.text,
                                        fontFamily = T1.mono, fontSize = 17.sp)
                                }
                            }
                            GuideStep("−", n > 0) { step(o, n - 1) }
                            GuideStep("+", n < max(c)) { step(o, n + 1) }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun GuideStep(glyph: String, enabled: Boolean, onClick: () -> Unit) {
    Box(Modifier.width(52.dp).fillMaxHeight().background(T1.surfaceHover).clickable(enabled = enabled, onClick = onClick), contentAlignment = Alignment.Center) {
        Text(glyph, color = if (enabled) T1.text else T1.disabled, fontFamily = T1.mono, fontSize = 22.sp)
    }
}

@Composable
fun SideboardPoolScreen(listId: String, onBack: () -> Unit) {
    val s by ListsStore.state.collectAsState()
    val list = s.lists.firstOrNull { it.id == listId }
    val rows = rememberGuideRows(list)
    var menu by remember { mutableStateOf<ListLine?>(null) }
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    T1Screen {
        Bar("Sideboard", onBack = onBack)
        if (list == null) return@T1Screen
        val uses = list.guide?.let(SideboardRules::uses) ?: emptyMap()
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            for (board in listOf("side", "maybe")) {
                val ls = rows.filter { it.board == board }
                item { Section("${list.boardTitle(board)} · ${ls.sumOf { it.qty }}") }
                if (ls.isEmpty()) item { ListRow("—") }
                items(ls, key = { it.key }) { l ->
                    val n = l.oracleId?.let { uses[it] } ?: 0
                    CardRow(l.printing, l.name, if (n == 0) "In no matchups" else "In $n ${if (n == 1) "matchup" else "matchups"}", onClick = { menu = l }) {
                        Text("${l.qty}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                    }
                }
            }
        }
        menu?.let { l ->
            val to = if (l.board == "side") "maybe" else "side"
            T1Menu(l.name, listOf(
                T1MenuItem("Move one to ${list.boardTitle(to)}") {
                    scope.launch { runCatching { ListsStore.add(list.id, l.cardId, l.board, -1, l.finish, l.lang, l.cond); ListsStore.add(list.id, l.cardId, to, 1, l.finish, l.lang, l.cond) } }
                },
                T1MenuItem("Move all to ${list.boardTitle(to)}") {
                    scope.launch { runCatching { ListsStore.move(list.id, l.cardId, l.board, to, l.finish, l.lang, l.cond) } }
                },
            )) { menu = null }
        }
    }
}

@Composable
fun SideboardPrintScreen(listId: String, onBack: () -> Unit) {
    val s by ListsStore.state.collectAsState()
    val list = s.lists.firstOrNull { it.id == listId }
    val rows = rememberGuideRows(list)
    val context = LocalContext.current
    T1Screen {
        Bar("Print", onBack = onBack)
        val guide = list?.guide
        if (list == null || guide == null) { Notice("No matchups yet."); return@T1Screen }
        val r = SideboardRules.printModel(list.name, CatalogPack.formatName(list.format), LocalDate.now().toString(), SideboardRules.lines(rows), guide, list.format)
        val html = SideboardRules.html(r.model)
        r.warnings.forEach { Notice(SideboardRules.warningText(it), error = true) }
        Box(Modifier.weight(1f).fillMaxWidth().background(Color.White).padding(16.dp)) {
            AndroidView(factory = { WebView(it).apply { setBackgroundColor(android.graphics.Color.WHITE) } }, update = { it.loadDataWithBaseURL(null, html, "text/html", "utf-8", null) },
                modifier = Modifier.fillMaxSize())
        }
        BigAction("Print") {
            Telemetry.capture("sideboard_guide_printed", mapOf("matchups" to guide.matchups.size,
                "left_considering" to (r.warnings.firstOrNull { it.code == "considering" }?.qty ?: 0), "sheets" to r.sheets))
            GuidePrinter.print(context, html, "${list.name} sideboard guide")
        }
    }
}

/** Prints from a WebView kept until its page has loaded (its print adapter needs the page). */
object GuidePrinter {
    private var web: WebView? = null

    fun print(context: Context, html: String, name: String) {
        val w = WebView(context)
        web = w
        w.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String?) {
                val pm = context.getSystemService(Context.PRINT_SERVICE) as PrintManager
                pm.print(name, view.createPrintDocumentAdapter(name), PrintAttributes.Builder().build())
                web = null
            }
        }
        w.loadDataWithBaseURL(null, html, "text/html", "utf-8", null)
    }
}
