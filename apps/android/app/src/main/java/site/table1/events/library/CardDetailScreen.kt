package site.table1.events.library

import android.graphics.Bitmap
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsBottomHeight
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import site.table1.events.ui.components.BackArrowButton
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1AlertDialog
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Overlay
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1TextAction
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry
import java.net.HttpURLConnection
import java.net.URL

/* Card detail (contract/card-detail-2026-10-23.md, Figma 318:10810): the card, one row of attributes and one bottom
   bar, in the scope it was opened from (CardContext: null = the collection, a deck or cube, a binder, or search). The
   attribute row changes the copies in view, the stepper counts them, and Add to puts the version on screen anywhere
   else. The list icon flips to the info view. Same screen as iOS CardDetailViews.swift and web CardDetail.tsx. */

/** An Undo for the strip: a collection batch, or the reverse list edits. */
private class CardUndo(val label: String, val run: suspend () -> Unit)

/** `selected` when the new edition (long press on +) is the picked tile. */
private const val EDITION = "new-edition"

private fun finishCode(f: String) = when (f) { "foil" -> "F"; "etched" -> "E"; else -> "NF" }
private fun sectionCode(b: String) = when (b) { "side" -> "Side"; "maybe" -> "Maybe"; "commander" -> "Cmdr"; else -> "Main" }

@Composable
fun CardDetailScreen(oracleId: String, onBack: () -> Unit, context: CardContext? = null, onList: (String) -> Unit = {}) {
    val col by CollectionStore.state.collectAsState()
    val lists by ListsStore.state.collectAsState()
    val binders by BindersStore.state.collectAsState()
    val cat by CatalogStore.state.collectAsState()
    val pricesVersion by PriceBook.version.collectAsState()
    val scope = rememberCoroutineScope()
    var oracle by remember { mutableStateOf<CatalogOracle?>(null) }
    var printings by remember { mutableStateOf<List<CatalogPrinting>>(emptyList()) }
    var looked by remember { mutableStateOf(false) }
    var selected by remember { mutableStateOf<String?>(null) }
    var draft by remember { mutableStateOf<CardVersion?>(null) }
    /** A new edition from a long press on +: shown dimmed and selected, written once a pick makes it different. */
    var edition by remember { mutableStateOf<CardVersion?>(null) }
    var info by remember { mutableStateOf(false) }
    var back by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    var last by remember { mutableStateOf<CardUndo?>(null) }
    var picker by remember { mutableStateOf<CardAttribute?>(null) }
    var menu by remember { mutableStateOf<Pair<String, List<T1MenuItem>>?>(null) }
    var confirm by remember { mutableStateOf<Pair<String, () -> Unit>?>(null) }
    var addTo by remember { mutableStateOf<List<CardVersion>?>(null) }
    var zoom by remember { mutableStateOf<Pair<Bitmap, String>?>(null) }
    var matching by remember { mutableStateOf(false) }
    val prefs = remember { site.table1.events.T1App.instance.getSharedPreferences("library", android.content.Context.MODE_PRIVATE) }
    val addCondition = prefs.getString("addCondition", "NM") ?: "NM"
    val addLang = Languages.addLang

    val listId = (context as? CardContext.InList)?.listId
    val binderId = (context as? CardContext.InBinder)?.binderId
    val isSearch = context == CardContext.Search
    val scopeName = when { listId != null -> "list"; binderId != null -> "binder"; isSearch -> "search"; else -> "collection" }
    val list = listId?.let { id -> lists.lists.firstOrNull { it.id == id } }

    LaunchedEffect(Unit) { CatalogStore.load(userInitiated = true) }
    LaunchedEffect(cat.generation) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        val found = withContext(Dispatchers.Default) { db.oracle(oracleId)?.let { it to db.printings(it.idx) } }
        oracle = found?.first
        printings = found?.second?.sortedWith(CatalogPrinting.oldestFirst) ?: emptyList()
        looked = true
        PriceBook.load(printings.map { it.cardId })
    }
    val byId = remember(printings) { printings.associateBy { it.cardId } }

    /** The scope's versions of this card, in grid order. */
    val versions = remember(printings, col.version, binders.version, list, context) {
        val raw = when {
            listId != null -> list?.entries?.filter { it.cardId in byId }?.map { CardVersion.of(it) } ?: emptyList()
            binderId != null -> col.items.values.filter { it.cardId in byId }.mapNotNull { it ->
                val q = PrintingChange.places(it, binders).firstOrNull { p -> p.place == binderId }?.qty ?: 0
                if (q > 0) CardVersion.of(it, q) else null
            }
            isSearch -> emptyList()
            else -> col.items.values.filter { it.cardId in byId }.map { CardVersion.of(it) }
        }
        CardDetailRules.ordered(raw, printings)
    }
    LaunchedEffect(versions) { if (selected != null && selected != EDITION && versions.none { it.id == selected }) selected = null }

    val o = oracle
    // A deck or cube line starts near mint: its condition comes only from copies added from your collection.
    val fresh = CardDetailRules.fresh(printings, if (listId != null) "NM" else addCondition, addLang, if (listId != null) "main" else null)
    val chosen = if (selected == EDITION) edition else versions.firstOrNull { it.id == selected }
    val inView = chosen?.let { listOf(it) } ?: versions
    val current = chosen ?: CardDetailRules.main(versions) ?: draft ?: fresh
    val shown = inView.ifEmpty { listOfNotNull(current) }
    fun setLabel(cardId: String) = byId[cardId]?.setLabel ?: o?.name ?: "card"

    fun report(label: String, undo: CardUndo?) {
        error = null
        if (undo != null) { last = undo; notice = null } else { last = null; notice = label }
    }
    // Match collection (contract/owned-by-card-2026-10-31.md § 2): the list's lines of this card and the versions you own.
    val match = list?.let { l ->
        val lines = OwnedByCard.needs(l).filter { it.cardId in byId }
        val owned = OwnedByCard.ownedVersions(printings.map { it.cardId }, col.items.values)
        val boards = OwnedByCard.matchSections(lines, owned)
        if (boards.isEmpty()) null else MatchInfo(lines, owned, boards, OwnedByCard.matchDetail(lines, owned))
    }
    fun openMatch() {
        val m = match ?: return
        Telemetry.capture("match_collection_opened", mapOf("kind" to (list?.kind?.wire ?: "deck"), "versions" to m.owned.size,
            "copies" to m.lines.filter { it.board in m.boards }.sumOf { it.qty }))
        matching = true
    }
    fun write(ops: List<CollectionOp>, label: String, then: () -> Unit = {}) {
        busy = true
        error = null
        scope.launch {
            runCatching { CollectionStore.apply(ops) }
                .onSuccess { res -> then(); report(label, CardUndo(label) { CollectionStore.undo(res.batchId) }) }
                .onFailure { error = it.message }
            busy = false
        }
    }
    fun listEdit(ops: List<JsonObject>, reverse: List<JsonObject>, label: String, then: () -> Unit = {}) {
        val id = listId ?: return
        error = null
        scope.launch {
            runCatching { ListsStore.editMany(id, ops) }
                .onSuccess { then(); report(label, CardUndo(label) { ListsStore.editMany(id, reverse) }) }
                .onFailure { error = it.message }
        }
    }
    fun valueName(a: CardAttribute, value: String) = when (a) {
        CardAttribute.Set -> setLabel(value)
        CardAttribute.Language -> Languages.name(value)
        CardAttribute.Finish -> Finish.of(value)?.label ?: value
        CardAttribute.Section -> list?.boardTitle(value) ?: value
        CardAttribute.Condition -> value
    }

    fun apply(a: CardAttribute, value: String, printing: CatalogPrinting?, targets: List<CardVersion>, one: Boolean, what: String) {
        val copies = if (one) 1 else targets.sumOf { it.qty }
        val props = mapOf("attribute" to a.wire, "scope" to scopeName, "copies" to copies, "mix" to (targets.size > 1), "selected" to (chosen != null))
        val label = "Changed $copies to $what"
        fun follow(to: CardVersion, v: CardVersion) { if (chosen != null && (!one || v.qty == 1)) selected = to.id }
        if (listId != null) {
            val ops = mutableListOf<JsonObject>()
            val reverse = mutableListOf<JsonObject>()
            fun delta(cardId: String, board: String, finish: String, lang: String, cond: String, d: Int) = buildJsonObject {
                put("card_id", cardId); put("board", board); put("finish", finish); put("lang", lang); put("cond", cond); put("delta", d)
            }
            fun swap(from: CardVersion, board: String, to: CardVersion, n: Int) = buildJsonObject {
                put("card_id", from.cardId); put("board", board); put("finish", from.finish); put("lang", from.lang); put("cond", from.condition)
                put("to_card_id", to.cardId); put("to_finish", to.finish); put("to_lang", to.lang); put("to_cond", to.condition); put("qty", n)
            }
            for (v in targets) {
                val to = CardDetailRules.repoint(v, a, value, printing)
                val board = v.board ?: "main"
                val n = if (one) 1 else v.qty
                if (a == CardAttribute.Section) {
                    val toBoard = to.board ?: "main"
                    ops += delta(v.cardId, board, v.finish, v.lang, v.condition, -n); ops += delta(v.cardId, toBoard, v.finish, v.lang, v.condition, n)
                    reverse += delta(v.cardId, toBoard, v.finish, v.lang, v.condition, -n); reverse += delta(v.cardId, board, v.finish, v.lang, v.condition, n)
                } else {
                    ops += swap(v, board, to, n)
                    reverse += swap(to, board, v, n)
                }
                follow(to, v)
            }
            listEdit(ops, reverse, label) { Telemetry.capture("card_attribute_changed", props) }
            return
        }
        val ops = mutableListOf<CollectionOp>()
        for (v in targets) {
            val item = col.items[v.itemKey] ?: continue
            val to = CardDetailRules.repoint(v, a, value, printing)
            val places = PrintingChange.places(item, binders).map { it.place to it.qty }
            CardDetailRules.ops(item, places, to, if (one) 1 else v.qty, binderId)?.let { ops += it; follow(to, v) }
        }
        if (ops.isNotEmpty()) write(ops, label) { Telemetry.capture("card_attribute_changed", props) }
    }

    /** "MB2 #218 · Foil · LP": what sets a version apart, for the Undo strip. */
    fun versionName(v: CardVersion) = listOfNotNull(setLabel(v.cardId), if (v.finish != "nonfoil") Finish.of(v.finish)?.label ?: v.finish else null,
        if (list != null) v.board?.takeIf { it != "main" }?.let { list.boardTitle(it) } else v.condition.takeIf { it != "NM" },
        if (v.lang != "en" && byId[v.cardId]?.lang == "en") Languages.name(v.lang) else null).joinToString(" · ")

    /** The edition now differs from every version in view: add its copies (into the binder or the line's section in
     *  those scopes) and select the version it became. */
    fun addEdition(v: CardVersion, a: CardAttribute) {
        edition = null
        selected = v.id
        notice = null
        val label = "Added ${v.qty} ${versionName(v)}"
        val props = mapOf("scope" to scopeName, "attribute" to a.wire, "copies" to v.qty)
        if (listId != null) {
            val board = v.board ?: "main"
            fun op(d: Int) = buildJsonObject {
                put("card_id", v.cardId); put("board", board); put("finish", v.finish); put("lang", v.lang); put("cond", v.condition); put("delta", d)
            }
            listEdit(listOf(op(v.qty)), listOf(op(-v.qty)), label) { Telemetry.capture("card_edition_added", props) }
            return
        }
        write(listOf(CardDetailRules.step(v, v.qty, binderId)), label) { Telemetry.capture("card_edition_added", props) }
    }

    /** Long press on +: a copy of the version in view to change into another, selected and dimmed until it differs. */
    fun startEdition() {
        if (versions.isEmpty() || edition != null || busy) return
        edition = CardDetailRules.newEdition(chosen ?: CardDetailRules.main(versions) ?: return)
        selected = EDITION
        last = null
        notice = if (listId != null) "Change its set, finish or section to add it." else "Change its set, language, condition or finish to add it."
        Telemetry.capture("card_edition_started", mapOf("scope" to scopeName, "versions" to versions.size))
    }

    /** The bar's +: asks one copy or all of them first when more than one is in view (the selected version's copies when
     *  one is selected). */
    fun openAddTo(cur: CardVersion) {
        val total = inView.sumOf { it.qty }
        if (total <= 1) { addTo = CardDetailRules.addLines(inView, cur, false); return }
        menu = (if (chosen != null) "Add to · this version only" else "Add to") to listOf(
            T1MenuItem("One copy") { addTo = CardDetailRules.addLines(inView, cur, false) },
            T1MenuItem("All $total copies") { addTo = CardDetailRules.addLines(inView, cur, true) },
        )
    }

    /** A pick: changes the copies in view (asking first when more than one would change), or with nothing in view, the
     *  version on screen. */
    fun pick(a: CardAttribute, value: String) {
        picker = null
        val printing = if (a == CardAttribute.Set) byId[value] else null
        // The new edition: written as soon as it is a version the scope doesn't hold, until then just redrawn.
        val e = edition
        if (selected == EDITION && e != null) {
            val to = CardDetailRules.repoint(e, a, value, printing)
            if (CardDetailRules.isNew(to, versions)) addEdition(to, a) else edition = to
            return
        }
        val base = current ?: return
        if (versions.isEmpty()) { draft = CardDetailRules.repoint(base, a, value, printing); return }
        val targets = (chosen?.let { listOf(it) } ?: versions).filter { CardDetailRules.repoint(it, a, value, printing) != it }
        if (targets.isEmpty()) return
        val total = targets.sumOf { it.qty }
        val what = valueName(a, value)
        when {
            targets.size > 1 -> confirm = "Change all $total to $what?" to { apply(a, value, printing, targets, false, what) }
            total > 1 -> menu = "Change to $what" to listOf(
                T1MenuItem("One copy") { apply(a, value, printing, targets, true, what) },
                T1MenuItem("All $total copies") { apply(a, value, printing, targets, false, what) },
            )
            else -> apply(a, value, printing, targets, false, what)
        }
    }

    /** − / + on the selected version (the new edition's count before it's written), else the one held most of. */
    fun step(delta: Int) {
        val e = edition
        if (selected == EDITION && e != null) {
            if (e.qty + delta > 0) { edition = e.copy(qty = e.qty + delta); return }
            edition = null
            selected = null
            notice = null
            return
        }
        val v = chosen ?: (if (versions.isEmpty()) current else CardDetailRules.main(versions)) ?: return
        val label = "${if (delta > 0) "Added" else "Removed"} 1 ${setLabel(v.cardId)}"
        val props = mapOf("scope" to scopeName, "delta" to delta)
        // At 0 the screen keeps this version, so + puts it back.
        if (delta < 0 && v.qty <= 1) draft = v.copy(qty = 0)
        if (listId != null) {
            val board = v.board ?: "main"
            fun op(d: Int) = buildJsonObject {
                put("card_id", v.cardId); put("board", board); put("finish", v.finish); put("lang", v.lang); put("cond", v.condition); put("delta", d)
            }
            listEdit(listOf(op(delta)), listOf(op(-delta)), label) { Telemetry.capture("card_stepped", props) }
            return
        }
        write(listOf(CardDetailRules.step(v, delta, binderId)), label) { Telemetry.capture("card_stepped", props) }
    }

    fun zoomTo(p: CatalogPrinting) {
        val url = CatalogPack.imageUrl(p.cardId, p.imageTs, "large", back && p.imageFaces > 1) ?: return
        Telemetry.capture("image_zoomed", mapOf("screen" to "card_detail"))
        scope.launch { CardImageLoader.load(url, 1400)?.let { zoom = it.asAndroidBitmap() to p.setLabel } }
    }

    T1Screen {
        val price = pricesVersion.let { current?.let { PriceBook.marked(PriceBook.text(PriceBook.usd(it.cardId, it.finish, it.condition)), PriceBook.converted(it.cardId, it.finish)) } }
        CardBar(o?.name ?: "Card", price, onBack, info,
            onAdd = if (!isSearch && o != null && current != null) ({ openAddTo(current) }) else null,
            onInfo = if (o != null) ({ info = !info; if (info) Telemetry.capture("card_info_opened", mapOf("scope" to scopeName)) }) else null)
        (error ?: col.error)?.let { Notice(it, error = true) }
        CatalogStatus(cat)
        if (looked && o == null && cat.phase == "ready") Notice("That card isn't in the card data.", error = true)
        if (o == null || current == null) {
            Box(Modifier.weight(1f))
            return@T1Screen
        }
        @Composable fun Status() {
            last?.let { u ->
                Row(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Label(u.label, Modifier.weight(1f))
                    Label(if (busy) "Undoing…" else "Undo", Modifier.clickable {
                        if (busy) return@clickable
                        busy = true
                        scope.launch { runCatching { u.run() }.onSuccess { last = null }.onFailure { error = it.message }; busy = false }
                    }.padding(4.dp), color = T1.text)
                }
            } ?: notice?.let { Notice(it) }
        }
        if (info) {
            Status()
            CardInfo(o, byId[current.cardId], current, printings, list, context, lists.lists, Modifier.weight(1f), onList,
                match?.let { m -> m.detail to { openMatch() } }) { l, u -> report(l, u) }
            return@T1Screen
        }
        // The card: one image as large as fits, or a two-column grid of versions.
        BoxWithConstraints(Modifier.weight(1f).fillMaxWidth().background(T1.bg)) {
            val tiles = versions.map { Triple(it, it.id, false) } + listOfNotNull(edition?.let { Triple(it, EDITION, true) })
            if (tiles.size > 1) {
                val tile = ((minOf(maxWidth - 64.dp, maxWidth * (376f / 440f)) - 1.dp) / 2)
                Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).heightIn(min = maxHeight).padding(vertical = 16.dp),
                    verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                    tiles.chunked(2).forEach { rowVs ->
                        Row(horizontalArrangement = Arrangement.spacedBy(1.dp), modifier = Modifier.padding(bottom = 1.dp)) {
                            rowVs.forEach { (v, id, dim) ->
                                val on = id == selected
                                Box(Modifier.width(tile)
                                    .let { if (on) it.border(1.dp, T1.accent) else it }
                                    .clickable {
                                        selected = if (on) null else id
                                        if (!on) Telemetry.capture("card_version_selected", mapOf("versions" to versions.size))
                                    }
                                    .semantics {
                                        this.selected = on
                                        contentDescription = listOfNotNull(setLabel(v.cardId), Finish.of(v.finish)?.label,
                                            v.board?.let { list?.boardTitle(it) }, if (list == null) v.condition else null, "${v.qty}",
                                            if (dim) "new, not added yet" else null).joinToString(", ")
                                    }, contentAlignment = Alignment.BottomEnd) {
                                    CardArt(byId[v.cardId], tile, finish = v.finish)
                                    // The new edition is dimmed: it isn't written until it differs.
                                    if (dim) Box(Modifier.matchParentSize().background(T1.bg.copy(alpha = 0.6f)))
                                    if (v.qty > 1) Text("${v.qty}", Modifier.padding(tile * 0.05f).background(T1.bg).padding(horizontal = 6.dp, vertical = 2.dp),
                                        color = T1.text, fontFamily = T1.mono, fontSize = 13.sp)
                                }
                            }
                        }
                    }
                }
            } else {
                val p = byId[current.cardId]
                val flips = (p?.imageFaces ?: 1) > 1
                val w = minOf(maxWidth - 64.dp, (maxHeight - 32.dp - if (flips) 44.dp else 0.dp) * CARD_ASPECT).coerceAtLeast(60.dp)
                Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                    Box(Modifier.clickable { p?.let { zoomTo(it) } }.semantics { contentDescription = "${o.name}, ${setLabel(current.cardId)}. Zoom" }) {
                        CardArt(p, w, finish = current.finish, back = back)
                    }
                    if (flips) Box(Modifier.size(120.dp, 44.dp).clickable { back = !back; Telemetry.capture("card_flipped") }, contentAlignment = Alignment.Center) {
                        Label(if (back) "Front" else "Flip", color = T1.text)
                    }
                }
            }
        }
        Status()
        if (last == null) match?.let { m ->
            Row(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Label(m.detail, Modifier.weight(1f))
                Label("Match collection", Modifier.clickable { openMatch() }.padding(4.dp), color = T1.text)
            }
        }
        // The attribute row: the value the copies in view share, or MIX.
        val setValue = CardDetailRules.shared(shown) { it.cardId }
        val printingShown = setValue?.let { byId[it] }
        val cells = buildList {
            add(Triple(CardAttribute.Set, printingShown?.set?.uppercase() ?: "Mix", true))
            // A non-English printing's language is its own. Deck and cube lines record a language and condition, but the
            // card page opened from a deck or cube shows neither (John, 2026-11-01): they come from the copies added to it.
            if (list == null) {
                add(Triple(CardAttribute.Language, CardDetailRules.shared(shown) { it.lang }?.uppercase() ?: "Mix", printingShown?.let { it.lang == "en" } ?: true))
                add(Triple(CardAttribute.Condition, CardDetailRules.shared(shown) { it.condition } ?: "Mix", true))
            }
            if (CardDetailRules.showsFinish(shown, byId)) {
                add(Triple(CardAttribute.Finish, CardDetailRules.shared(shown) { it.finish }?.let(::finishCode) ?: "Mix", printingShown?.let { it.finishList.size > 1 } ?: true))
            }
            if (list != null) add(Triple(CardAttribute.Section, CardDetailRules.shared(shown) { it.board ?: "main" }?.let(::sectionCode) ?: "Mix", true))
        }
        Row(Modifier.fillMaxWidth().height(50.dp).background(T1.bg), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            cells.forEach { (a, value, opens) ->
                Box(Modifier.weight(1f).height(50.dp).clickable(enabled = opens && !busy) { picker = a }
                    .semantics { contentDescription = "${a.wire}: $value" }, contentAlignment = Alignment.Center) {
                    Text(value.uppercase(), color = T1.muted, fontFamily = T1.mono, fontSize = 12.sp, letterSpacing = 1.5.sp, maxLines = 1)
                }
            }
        }
        if (isSearch) {
            BottomCell(Modifier.fillMaxWidth(), onClick = { addTo = listOf(current) }, label = "Add to") {
                Text("ADD TO", color = T1.text, fontFamily = T1.mono, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 4.sp)
            }
        } else {
            val count = inView.sumOf { it.qty }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                BottomCell(Modifier.weight(1f), enabled = !busy && count > 0, onClick = { step(-1) }, label = "Remove one") {
                    Glyph(Icon.Minus, if (count > 0) T1.text else T1.disabled)
                }
                BottomCell(Modifier.weight(1f), label = "$count copies") {
                    Text("$count", color = T1.text, fontFamily = T1.mono, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 4.sp)
                }
                BottomCell(Modifier.weight(1f), enabled = !busy, onClick = { step(1) }, label = "Add one",
                    onLongClick = if (versions.isNotEmpty() && edition == null) ({ startEdition() }) else null, longClickLabel = "Add a different version") {
                    Glyph(Icon.Plus, T1.text)
                }
            }
        }
    }

    // Pickers and panels over the screen.
    picker?.let { a ->
        val p = current
        if (a == CardAttribute.Set) {
            Sheet({ picker = null }) {
                BoxWithConstraints(Modifier.fillMaxWidth().heightIn(max = 490.dp)) {
                    val w = (maxWidth - 5.dp) / 4
                    Column(Modifier.verticalScroll(rememberScrollState()).padding(1.dp), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                        printings.chunked(4).forEach { row ->
                            Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                                row.forEach { x ->
                                    val on = x.cardId == CardDetailRules.shared(shown) { it.cardId }
                                    Box(Modifier.width(w).let { if (on) it.border(1.dp, T1.accent) else it }.clickable { pick(CardAttribute.Set, x.cardId) }
                                        .semantics { this.selected = on; contentDescription = x.setLabel + if (x.lang == "en") "" else ", ${Languages.name(x.lang)}" }) {
                                        CardArt(x, w)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else if (p != null) {
            val options: List<Triple<String, String, String?>> = when (a) {
                CardAttribute.Language -> Languages.all.map { Triple(it.first, it.second, null) }
                CardAttribute.Condition -> Conditions.all.map { Triple(it, it, null) }
                CardAttribute.Finish -> Finish.entries.filter { f -> shown.any { v -> byId[v.cardId]?.finishList?.contains(f) == true } }
                    .map { Triple(it.wire, it.label, null) }
                CardAttribute.Section -> ((if (list?.boards?.contains("commander") == true || (list?.kind == ListKind.Deck && list.format in CommandZone.FORMATS)) listOf("commander") else emptyList()) + (list?.sections ?: listOf("main")))
                    .map { Triple(it, list?.boardTitle(it) ?: it, null) }
                CardAttribute.Set -> emptyList()
            }
            val cur = when (a) {
                CardAttribute.Language -> CardDetailRules.shared(shown) { it.lang }
                CardAttribute.Condition -> CardDetailRules.shared(shown) { it.condition }
                CardAttribute.Finish -> CardDetailRules.shared(shown) { it.finish }
                CardAttribute.Section -> CardDetailRules.shared(shown) { it.board ?: "main" }
                CardAttribute.Set -> null
            }
            Sheet({ picker = null }) { SelectorRows(options, cur) { pick(a, it) } }
        }
    }
    menu?.let { (title, items) -> T1Menu(title, items) { menu = null } }
    confirm?.let { (title, run) ->
        T1AlertDialog(title, onDismiss = { confirm = null },
            confirm = { T1TextAction("Change all") { confirm = null; run() } },
            dismiss = { T1TextAction("Cancel") { confirm = null } },
            body = { Text("Every copy in view changes. Undo puts them back.", fontFamily = T1.mono, fontSize = 13.sp) })
    }
    addTo?.let { lines ->
        if (o != null) AddToSheet(o, lines, byId, lists.lists, scopeName, onClose = { addTo = null }) { l, u -> addTo = null; report(l, u) }
    }
    if (matching && list != null) match?.let { m ->
        MatchSheet(list, m, byId, onClose = { matching = false }) { l, u -> matching = false; report(l, u) }
    }
    zoom?.let { (bmp, sub) -> ZoomImageScreen(bmp, o?.name ?: "Card", sub) { zoom = null } }
}

private data class MatchInfo(val lines: List<OwnedByCard.Need>, val owned: List<OwnedByCard.Version>, val boards: List<String>, val detail: String)

/** Match collection: a section's copies of the card take the printings you own (contract/owned-by-card-2026-10-31.md § 2).
 *  Opens filled in by Auto; a tap on a tile picks one more of it, or back to none. */
@Composable
private fun MatchSheet(list: CardList, m: MatchInfo, printings: Map<String, CatalogPrinting>, onClose: () -> Unit, onDone: (String, CardUndo?) -> Unit) {
    val co = rememberCoroutineScope()
    var board by remember { mutableStateOf(m.boards.first()) }
    val section = m.lines.filter { it.board == board }
    var picks by remember { mutableStateOf(OwnedByCard.autoMatch(section, m.owned)) }
    var auto by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    val total = section.sumOf { it.qty }
    val used = picks.sumOf { it.qty }
    val ops = OwnedByCard.matchOps(section, picks)
    fun json(ms: List<OwnedByCard.Move>) = ms.map { mv ->
        buildJsonObject {
            put("card_id", mv.cardId); put("board", board); put("finish", mv.finish); put("lang", mv.lang); put("cond", mv.cond)
            put("to_card_id", mv.toCardId); put("to_finish", mv.toFinish); put("to_lang", mv.lang); put("qty", mv.qty)
        }
    }
    fun save() {
        if (ops.isEmpty()) return
        val back = ops.reversed().map { OwnedByCard.Move(it.toCardId, it.toFinish, it.lang, it.cardId, it.finish, it.qty, it.cond) }
        val moved = ops.sumOf { it.qty }
        co.launch {
            runCatching { ListsStore.editMany(list.id, json(ops)) }
                .onSuccess {
                    Telemetry.capture("match_collection_saved", mapOf("kind" to list.kind.wire, "moved" to moved,
                        "versions" to ops.map { "${it.toCardId}|${it.toFinish}" }.toSet().size, "auto" to auto))
                    val label = "$moved ${if (moved == 1) "copy" else "copies"} now your printings"
                    onDone(label, CardUndo(label) { ListsStore.editMany(list.id, json(back)) })
                }
                .onFailure { error = it.message }
        }
    }
    Sheet(onClose) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Label("Match collection")
            if (m.boards.size > 1) T1Segmented(m.boards.map { list.boardTitle(it) }, m.boards.indexOf(board)) { i ->
                board = m.boards[i]
                picks = OwnedByCard.autoMatch(m.lines.filter { it.board == board }, m.owned)
                auto = true
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Label("$used of $total picked · tap to pick", Modifier.weight(1f))
                Label("Clear", Modifier.clickable { picks = emptyList(); auto = false }.padding(8.dp), color = T1.text)
                Label("Auto", Modifier.clickable { picks = OwnedByCard.autoMatch(section, m.owned); auto = true }.padding(8.dp), color = T1.text)
            }
            BoxWithConstraints {
                val w = (maxWidth - 1.dp) / 2
                Column(Modifier.heightIn(max = 440.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    m.owned.chunked(2).forEach { pair ->
                        Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                            pair.forEach { v ->
                                val n = picks.firstOrNull { it.cardId == v.cardId && it.finish == v.finish }?.qty ?: 0
                                val p = printings[v.cardId]
                                Column(Modifier.width(w).clickable {
                                    picks = OwnedByCard.tap(picks, m.owned, total, v.cardId, v.finish)
                                    auto = false
                                }.semantics { contentDescription = "${p?.setLabel ?: "Printing"}, own ${v.owned}, $n picked" },
                                    horizontalAlignment = Alignment.CenterHorizontally) {
                                    Box(Modifier.let { if (n > 0) it.border(1.dp, T1.accent) else it }, contentAlignment = Alignment.BottomEnd) {
                                        CardArt(p, w, finish = v.finish)
                                        if (n > 0) Text("$n", Modifier.padding(w * 0.05f).background(T1.accent).padding(horizontal = 8.dp, vertical = 3.dp),
                                            color = T1.ink, fontFamily = T1.mono, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                                    }
                                    Label(listOfNotNull(p?.setLabel, Finish.of(v.finish)?.takeIf { v.finish != "nonfoil" }?.label, "Own ${v.owned}").joinToString(" · "),
                                        Modifier.padding(vertical = 4.dp))
                                }
                            }
                        }
                    }
                }
            }
            if (total > used) Label("${total - used} not picked stay as listed")
            error?.let { Notice(it, error = true) }
            Box(Modifier.fillMaxWidth().height(54.dp).background(T1.surface).clickable(enabled = ops.isNotEmpty()) { save() }, contentAlignment = Alignment.Center) {
                Text((if (ops.isEmpty()) "Already matches" else "Use these printings").uppercase(), color = if (ops.isEmpty()) T1.muted else T1.text,
                    fontFamily = T1.mono, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 4.sp)
            }
        }
    }
}

/* ── pieces ───────────────────────────────────────────────────────────── */

/** Figma Bar: back arrow, name, price, then + (owned scopes) and the list / tune icon. */
@Composable
private fun CardBar(name: String, price: String?, onBack: () -> Unit, info: Boolean, onAdd: (() -> Unit)?, onInfo: (() -> Unit)?) {
    Row(Modifier.fillMaxWidth().height(50.dp).background(T1.bg), verticalAlignment = Alignment.CenterVertically) {
        BackArrowButton(onBack)
        Row(Modifier.weight(1f).padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(name, Modifier.weight(1f), color = T1.text, fontFamily = T1.mono, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            price?.let { Text(it, color = T1.muted, fontFamily = T1.mono, fontSize = 12.sp, letterSpacing = 1.5.sp, maxLines = 1) }
        }
        onAdd?.let { IconButton(Icon.Plus, "Add to", it) }
        onInfo?.let { IconButton(if (info) Icon.Tune else Icon.List, if (info) "Card" else "Details", it) }
    }
}

@Composable
private fun IconButton(icon: Icon, label: String, onClick: () -> Unit) {
    Box(Modifier.size(50.dp).clickable(onClickLabel = label, onClick = onClick).semantics { contentDescription = label }, contentAlignment = Alignment.Center) {
        Glyph(icon, T1.text)
    }
}

/** One cell of the bottom bar: 54 dp above the navigation bar, the glyph 24 dp from the top, the surface running under
 *  the navigation bar. Disabled is the flat disabled color, never dimmed. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun BottomCell(modifier: Modifier, enabled: Boolean = true, onClick: (() -> Unit)? = null, label: String,
                       onLongClick: (() -> Unit)? = null, longClickLabel: String? = null, content: @Composable () -> Unit) {
    Column(modifier.background(T1.surface).let { m ->
        when {
            onClick != null && onLongClick != null -> m.combinedClickable(enabled = enabled, onLongClickLabel = longClickLabel, onLongClick = onLongClick, onClick = onClick)
            onClick != null -> m.clickable(enabled = enabled, onClick = onClick)
            else -> m
        }
    }
        .semantics { contentDescription = label }) {
        Box(Modifier.fillMaxWidth().height(54.dp).padding(top = 24.dp), contentAlignment = Alignment.TopCenter) { content() }
    }
}

/** A bottom panel over a scrim (Figma Selector panels). */
@Composable
private fun Sheet(onDismiss: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    T1Overlay(onDismiss) {
        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().background(T1.bg)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}
            .navigationBarsPadding(), content = content)
    }
}

/** Selector rows: centred uppercase labels; pressed rows fill with surface; the current value is outlined in accent.
 *  Options are (value, label, detail). */
@Composable
private fun SelectorRows(options: List<Triple<String, String, String?>>, current: String?, title: String? = null, onBack: (() -> Unit)? = null,
                         onPick: (String) -> Unit) {
    Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (title != null || onBack != null) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            onBack?.let { Box(Modifier.size(24.dp).clickable(onClickLabel = "Back", onClick = it), contentAlignment = Alignment.Center) { BackArrowGlyph() } }
            Text((title ?: "").uppercase(), color = T1.muted, fontFamily = T1.mono, fontSize = 12.sp, letterSpacing = 1.5.sp)
        }
        Column(Modifier.fillMaxWidth().heightIn(max = 400.dp).verticalScroll(rememberScrollState())) {
            options.forEach { (value, label, detail) ->
                val on = value == current
                val source = remember { MutableInteractionSource() }
                val pressed by source.collectIsPressedAsState()
                Column(Modifier.fillMaxWidth().height(if (detail == null) 50.dp else 62.dp)
                    .background(if (pressed) T1.surface else Color.Transparent)
                    .let { if (on) it.border(1.dp, T1.accent) else it }
                    .clickable(interactionSource = source, indication = null) { onPick(value) }
                    .semantics { this.selected = on },
                    verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(label.uppercase(), color = if (on) T1.text else T1.muted, fontFamily = T1.mono, fontSize = 12.sp, letterSpacing = 1.5.sp,
                        maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
                    detail?.let { Text(it.uppercase(), color = T1.disabled, fontFamily = T1.mono, fontSize = 8.sp, letterSpacing = 1.5.sp, maxLines = 1) }
                }
            }
        }
    }
}

/* Material icons, weight 300 (Figma bar and stepper), drawn from their rectangles in an 18 dp box. */
private enum class Icon { Plus, Minus, List, Tune }

@Composable
private fun Glyph(icon: Icon, color: Color) {
    Canvas(Modifier.size(18.dp)) {
        val k = size.minDimension / 18f
        fun r(x: Float, y: Float, w: Float, h: Float) = drawRect(color, Offset(x * k, y * k), Size(w * k, h * k))
        when (icon) {
            Icon.Plus -> { r(4.125f, 8.4375f, 9.75f, 1.125f); r(8.4375f, 4.125f, 1.125f, 9.75f) }
            Icon.Minus -> r(4.125f, 8.4375f, 9.75f, 1.125f)
            Icon.List -> for (y in listOf(5.668f, 8.4375f, 11.207f)) {
                r(5.495f, y, 9.88f, 1.125f)
                drawCircle(color, 0.606f * k, Offset(3.231f * k, (y + 0.563f) * k))
            }
            Icon.Tune -> {
                val o = 2.4375f
                r(o, o + 1.5f, 7.125f, 1.125f); r(o + 9f, o, 1.125f, 4.125f); r(o + 10.125f, o + 1.5f, 3f, 1.125f)
                r(o, o + 6f, 3f, 1.125f); r(o + 3f, o + 4.5f, 1.125f, 4.125f); r(o + 6f, o + 6f, 7.125f, 1.125f)
                r(o, o + 10.5f, 4.125f, 1.125f); r(o + 6f, o + 9f, 1.125f, 4.125f); r(o + 7.125f, o + 10.5f, 6f, 1.125f)
            }
        }
    }
}

@Composable
private fun BackArrowGlyph() {
    Canvas(Modifier.size(18.dp)) {
        val k = size.minDimension / 18f
        drawRect(T1.text, Offset(3.6f * k, 8.4375f * k), Size(11.18f * k, 1.125f * k))
        drawLine(T1.text, Offset(3.6f * k, 9f * k), Offset(7.8f * k, 4.9f * k), 1.125f * k)
        drawLine(T1.text, Offset(3.6f * k, 9f * k), Offset(7.8f * k, 13.1f * k), 1.125f * k)
    }
}

/* ── Add to ───────────────────────────────────────────────────────────── */

private sealed interface AddStep {
    data object Root : AddStep
    data object Decks : AddStep
    data class Section(val id: String) : AddStep
    data object Cubes : AddStep
    data object Binders : AddStep
    data object Want : AddStep
    data object Trades : AddStep
    data class Side(val id: String?) : AddStep
}

/** Collection / Deck / Cube / Binder / Want / Trade, each drilling down in place (Figma Add To Selection and Add to
 *  Drilldown). Adds `lines` (one copy, or every copy in view, each version with its count); condition and language go
 *  with collection, binder and trade adds. */
@Composable
private fun AddToSheet(o: CatalogOracle, lines: List<CardVersion>, printings: Map<String, CatalogPrinting>, lists: List<CardList>, scope: String,
                       onClose: () -> Unit, onDone: (String, CardUndo?) -> Unit) {
    val co = rememberCoroutineScope()
    val trades by TradesStore.state.collectAsState()
    val binders by BindersStore.state.collectAsState()
    val col by CollectionStore.state.collectAsState()
    var step by remember { mutableStateOf<AddStep>(AddStep.Root) }
    var error by remember { mutableStateOf<String?>(null) }
    var buyLinks by remember { mutableStateOf<List<TCGplayerCart.Entry>?>(null) }
    val context = androidx.compose.ui.platform.LocalContext.current
    LaunchedEffect(Unit) { if (!trades.loaded) TradesStore.load() }
    val version = lines.first()
    val printingIds = lines.map { it.cardId }.distinct()
    // The printing when every line shares one.
    val p = if (printingIds.size == 1) printings[version.cardId] else null
    val name = p?.setLabel ?: o.name
    val count = lines.sumOf { it.qty }
    val owned = lines.all { (col.items[it.itemKey]?.qty ?: 0) > 0 }

    fun finish(destination: String, label: String, undo: CardUndo?) {
        Telemetry.capture("card_added_to", mapOf("destination" to destination, "scope" to scope, "copies" to count))
        onDone(label, undo)
    }
    fun launch(block: suspend () -> Unit) { co.launch { runCatching { block() }.onFailure { error = it.message } } }
    fun toCollection(binderId: String?, place: String) = launch {
        val res = CollectionStore.apply(lines.map { CardDetailRules.step(it, it.qty, binderId) })
        val label = "Added $count $name to $place"
        finish(if (binderId == null) "collection" else "binder", label, CardUndo(label) { CollectionStore.undo(res.batchId) })
    }
    fun toList(id: String, board: String) = launch {
        val l = lists.firstOrNull { it.id == id } ?: return@launch
        val added = lines.mapNotNull { line ->
            val pr = printings[line.cardId] ?: return@mapNotNull null
            // A finish the printing lacks is saved in one it has (contract/lists-2026-10-15.md).
            val f = pr.finishList.map { it.wire }.let { fs -> if (line.finish in fs) line.finish else fs.firstOrNull() ?: "nonfoil" }
            // The copy keeps the language and condition on screen (a Japanese LP copy you own goes in as Japanese LP).
            val lang = Languages.forNew(pr.lang, line.lang)
            ListsStore.add(id, pr.cardId, board, line.qty, f, lang, line.condition)
            listOf(pr.cardId, f, lang, line.condition) to line.qty
        }
        if (added.isEmpty()) return@launch
        val label = "Added $count $name to ${l.name} · ${l.boardTitle(board)}"
        finish(l.kind.wire, label, CardUndo(label) { added.forEach { (k, n) -> ListsStore.add(id, k[0], board, -n, k[1], k[2], k[3]) } })
    }
    fun want(how: String) = launch {
        // One want per printing (and finish), counting the copies of each.
        val ops = lines.groupBy { (if (how == "any") null else it.cardId) to (if (how == "finish") it.finish else null) }
            .map { (k, vs) -> WantOp(o.oracleId, cardId = k.first, finish = k.second, delta = vs.sumOf { it.qty }) }
        BindersStore.applyWants(ops, "want_added",
            mapOf("any_printing" to (how == "any"), "finish" to (how == "finish"), "has_max" to false, "from" to "card"))
        finish("want", "Wanted $count ${if (how == "any") o.name else name}", null)
    }
    fun toTrade(id: String?, give: Boolean) = launch {
        val t = id?.let { TradesStore.trade(it) }
        fun put(side: List<TradeLine>) = lines.fold(side) { out, v ->
            val line = TradeLine(v.cardId, v.finish, v.condition, v.lang, v.qty, if (give) binders.forTrade(v.itemKey).second else null)
            if (out.any { it.key == line.key }) out.map { if (it.key == line.key) it.copy(qty = it.qty + v.qty) else it } else out + line
        }
        val saved = TradesStore.save(t, t?.partner, if (give) put(t?.gives ?: emptyList()) else t?.gives ?: emptyList(),
            if (give) t?.gets ?: emptyList() else put(t?.gets ?: emptyList()))
        finish("trade", "${if (give) "Giving" else "Getting"} $count $name in the trade${saved.partner?.let { " with $it" } ?: ""}", null)
    }

    // Add to → TCGplayer (contract/buy-2026-11-06.md § Card page): each printing in view to its product page.
    fun openUrl(url: String) {
        runCatching { context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url))) }
            .onFailure { error = it.message }
    }
    fun toTCGplayer() = launch {
        val items = lines.filter { it.qty > 0 }.groupBy { it.cardId }.map { (id, vs) -> TCGplayerCart.Item(cardId = id, qty = vs.sumOf { it.qty }) }
        val a = TCGplayerCart.links(items, "card", products = true)
        Telemetry.capture("tcgplayer_cart_opened", mapOf("from" to "card", "lines" to a.lines, "parts" to a.urls.size, "products" to a.products.size))
        val direct = TCGplayerCart.direct(a)
        val m = TCGplayerCart.menu(a)
        when {
            direct != null -> { openUrl(direct); onClose() }
            m.isEmpty() -> error = "Nothing to buy"
            else -> buyLinks = m
        }
    }
    buyLinks?.let { m ->
        T1Menu("Buy on TCGplayer", m.map { e -> T1MenuItem("${e.title} · ${e.detail}") { openUrl(e.url) } }) { onClose() }
        return
    }

    val s = step
    val (title, options) = when (s) {
        AddStep.Root -> null to listOf("collection" to "Collection", "deck" to "Deck", "cube" to "Cube", "binder" to "Binder", "want" to "Want", "trade" to "Trade",
                                       "tcgplayer" to "TCGplayer")
            .map { Triple(it.first, it.second, null as String?) }
        AddStep.Decks -> "Deck" to lists.filter { it.kind == ListKind.Deck }.map { Triple(it.id, it.name, CatalogPack.formatName(it.format) as String?) }
            .ifEmpty { listOf(Triple("", "No decks yet", null)) }
        is AddStep.Section -> (lists.firstOrNull { it.id == s.id }?.name ?: "Deck") to listOf("main", "side", "maybe")
            .map { b -> Triple(b, lists.firstOrNull { it.id == s.id }?.boardTitle(b) ?: b, null as String?) }
        AddStep.Cubes -> "Cube" to lists.filter { it.kind == ListKind.Cube }.map { Triple(it.id, it.name, "${it.count("main")} cards" as String?) }
            .ifEmpty { listOf(Triple("", "No cubes yet", null)) }
        AddStep.Binders -> "Binder" to binders.binders.sortedBy { it.name.lowercase() }.map { Triple(it.id, it.name, if (it.forTrade) "For trade" else null) }
            .ifEmpty { listOf(Triple("", "No binders yet", null)) }
        AddStep.Want -> "Want" to listOfNotNull(Triple("any", "Any printing", null as String?),
            if (p == null && printingIds.size > 1) Triple("printing", "Each printing", "${printingIds.size} printings") else null,
            if (p == null && printingIds.size > 1) Triple("finish", "Each printing and finish", null) else null,
            p?.let { Triple("printing", "This printing", name) },
            p?.takeIf { it.finishList.size > 1 }?.let { Triple("finish", "This printing and finish", "$name · ${Finish.of(version.finish)?.label ?: version.finish}") })
        AddStep.Trades -> "Trade" to listOf(Triple("new", "New trade", null as String?)) + trades.trades.filter { it.status != "confirmed" }.map { t ->
            Triple(t.id, t.partner ?: "Trade", "Give ${t.gives.sumOf { it.qty }} · get ${t.gets.sumOf { it.qty }}" as String?)
        }
        is AddStep.Side -> "Get or give" to listOf(Triple("get", "Get", null), Triple("give", "Give", "From your copies"))
    }
    Sheet(onClose) {
        error?.let { Notice(it, error = true) }
        SelectorRows(options, null, title, if (s == AddStep.Root) null else ({
            step = when (s) { is AddStep.Section -> AddStep.Decks; is AddStep.Side -> AddStep.Trades; else -> AddStep.Root }
        })) { v ->
            if (v.isEmpty()) return@SelectorRows
            error = null
            when (s) {
                AddStep.Root -> when (v) {
                    "collection" -> toCollection(null, "your collection")
                    "deck" -> step = AddStep.Decks
                    "cube" -> step = AddStep.Cubes
                    "binder" -> step = AddStep.Binders
                    "want" -> step = AddStep.Want
                    "tcgplayer" -> toTCGplayer()
                    else -> step = AddStep.Trades
                }
                AddStep.Decks -> step = AddStep.Section(v)
                is AddStep.Section -> toList(s.id, v)
                AddStep.Cubes -> toList(v, "main")
                AddStep.Binders -> toCollection(v, binders.binder(v)?.name ?: "the binder")
                AddStep.Want -> want(v)
                AddStep.Trades -> { val id = v.takeIf { it != "new" }; if (owned) step = AddStep.Side(id) else toTrade(id, false) }
                is AddStep.Side -> toTrade(s.id, v == "give")
            }
        }
    }
}

/* ── info view ────────────────────────────────────────────────────────── */

private data class CardDetails(val text: String, val type: String?, val rarity: String?, val artist: String?)

/** Rules text and details from Scryfall's API for one printing, asked once per printing per launch. */
private object CardDetailsSource {
    private val cache = java.util.concurrent.ConcurrentHashMap<String, CardDetails>()
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun details(cardId: String): CardDetails = cache[cardId] ?: withContext(Dispatchers.IO) {
        val conn = URL("https://api.scryfall.com/cards/$cardId").openConnection() as HttpURLConnection
        conn.setRequestProperty("User-Agent", "Table1/1.0 (table-1.site)")
        conn.setRequestProperty("Accept", "application/json")
        try {
            check(conn.responseCode == 200) { "Scryfall ${conn.responseCode}" }
            val c = json.parseToJsonElement(conn.inputStream.bufferedReader().readText()).jsonObject
            fun JsonObject.s(k: String) = this[k]?.jsonPrimitive?.content?.takeIf { it != "null" }
            val faces = c["card_faces"]?.jsonArray?.map { it.jsonObject } ?: emptyList()
            val text = c.s("oracle_text")?.takeIf { it.isNotEmpty() }
                ?: faces.mapNotNull { f -> f.s("oracle_text")?.let { t -> if (faces.size > 1) "${f.s("name") ?: ""}\n$t" else t } }.joinToString("\n\n")
            CardDetails(text, c.s("type_line") ?: faces.firstOrNull()?.s("type_line"), c.s("rarity"), c.s("artist") ?: faces.firstOrNull()?.s("artist"))
                .also { cache[cardId] = it }
        } finally { conn.disconnect() }
    }
}

/** The list icon's view (Figma 231:9241): a smaller image, the rules text, Price / Card type / Rarity / Artist, then
 *  where the card is used, your copies, wants, hero and history. */
@Composable
private fun CardInfo(o: CatalogOracle, p: CatalogPrinting?, version: CardVersion, printings: List<CatalogPrinting>, list: CardList?,
                     context: CardContext?, lists: List<CardList>, modifier: Modifier, onList: (String) -> Unit,
                     /** Match collection (detail, open), when the list could use the printings you own. */
                     match: Pair<String, () -> Unit>?, report: (String, CardUndo?) -> Unit) {
    val col by CollectionStore.state.collectAsState()
    val binders by BindersStore.state.collectAsState()
    val heroes by HeroesStore.state.collectAsState()
    val co = rememberCoroutineScope()
    var details by remember { mutableStateOf<CardDetails?>(null) }
    var failed by remember { mutableStateOf(false) }
    var history by remember { mutableStateOf<List<HistoryEntry>?>(null) }
    var moving by remember { mutableStateOf<CollectionItem?>(null) }
    var menu by remember { mutableStateOf<Pair<String, List<T1MenuItem>>?>(null) }
    var wanting by remember { mutableStateOf(false) }
    var pickingPrinting by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    val prefs = remember { site.table1.events.T1App.instance.getSharedPreferences("library", android.content.Context.MODE_PRIVATE) }
    LaunchedEffect(version.cardId) {
        failed = false
        runCatching { CardDetailsSource.details(version.cardId) }.onSuccess { details = it }.onFailure { failed = true }
    }
    LaunchedEffect(version.cardId, col.version) { history = runCatching { CollectionStore.history(version.cardId) }.getOrDefault(emptyList()) }

    val byId = printings.associateBy { it.cardId }
    val owned = col.items.values.filter { it.cardId in byId }.sortedBy { it.key }
    val total = owned.sumOf { it.qty }
    val uses = lists.mapNotNull { l ->
        val es = l.entries.filter { it.cardId in byId }
        val qty = es.filter { it.board != "maybe" }.sumOf { it.qty }
        val considering = es.filter { it.board == "maybe" }.sumOf { it.qty }
        if (qty + considering > 0) Triple(l, qty, considering) else null
    }
    val used = uses.sumOf { it.second }

    @Composable fun Detail(k: String, v: String) {
        Row(Modifier.fillMaxWidth().heightIn(min = 34.dp).background(T1.bg).padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(k.uppercase(), color = T1.muted, fontFamily = T1.mono, fontSize = 11.sp, letterSpacing = 1.5.sp)
            Box(Modifier.weight(1f))
            Text(v, color = T1.text, fontFamily = T1.mono, fontSize = 11.sp, letterSpacing = 1.5.sp, textAlign = TextAlign.End, maxLines = 2)
        }
    }

    Column(modifier.fillMaxWidth().background(T1.bg).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
        p?.let { Box(Modifier.fillMaxWidth().padding(vertical = 16.dp), contentAlignment = Alignment.Center) { CardArt(it, (259 * CARD_ASPECT).dp, finish = version.finish) } }
        Box(Modifier.fillMaxWidth().padding(16.dp)) {
            val d = details
            if (d != null) Text(d.text.ifEmpty { "No rules text." }, color = T1.text, fontFamily = T1.mono, fontSize = 16.sp, letterSpacing = 0.5.sp, lineHeight = 23.sp)
            else Text(if (failed) "Rules text needs a connection." else "Loading rules text…", color = T1.muted, fontFamily = T1.mono, fontSize = 12.sp)
        }
        Detail("Price", PriceBook.marked(PriceBook.conditionText(PriceBook.usd(version.cardId, version.finish), version.condition),
                                         PriceBook.converted(version.cardId, version.finish), source = true) ?: "—")
        Detail("Card type", details?.type ?: o.typeLine)
        if (o.manaCost.isNotEmpty()) Detail("Mana cost", o.manaCost)
        Detail("Rarity", details?.rarity ?: p?.let { CatalogPack.RARITY_NAME[it.rarity]?.lowercase() } ?: "—")
        Detail("Artist", details?.artist ?: "—")
        p?.let { Detail("Printing", listOfNotNull(it.setLabel, if (it.lang == "en") null else Languages.name(it.lang)).joinToString(" · ")) }

        // Add to collection from a deck or cube: what this card lacks there, every copy listed, or one of a listed printing.
        if (list != null) {
            val lines = list.entries.filter { it.cardId in byId }.sortedBy { CardList.BOARD_ORDER.indexOf(it.board) }
            if (lines.isNotEmpty()) {
                val only = lines.map { it.cardId }.toSet()
                // Only the listed printing, finish and language counts here (contract/list-to-collection-2026-10-22.md).
                val ownedBy = col.items.values.filter { it.cardId in byId }.groupBy { "${it.cardId}|${it.finish}|${it.lang}|${it.condition}" }.mapValues { (_, v) -> v.sumOf { it.qty } }
                val basics = CatalogStore.basics
                val missing = ListToCollection.ops(list.entries, list.kind, ownedBy, ListToCollection.Mode.Missing, only = only, basics = basics)
                val all = ListToCollection.ops(list.entries, list.kind, ownedBy, ListToCollection.Mode.All, only = only)
                val m = ListToCollection.copies(missing)
                val a = ListToCollection.copies(all)
                fun add(ops: List<ListToCollection.Op>, mode: String) {
                    val n = ListToCollection.copies(ops)
                    busy = true
                    co.launch {
                        runCatching { CollectionStore.apply(ListToCollection.collectionOps(ops, { byId[it]?.lang })) }
                            .onSuccess { res ->
                                val label = "Added $n ${o.name} to your collection"
                                report(label, CardUndo(label) { CollectionStore.undo(res.batchId) })
                                Telemetry.capture("list_added_to_collection", mapOf("kind" to list.kind.wire, "mode" to mode, "sideboard" to true,
                                    "copies" to n, "lines" to ops.size, "from" to "card"))
                            }.onFailure { report(it.message ?: "Couldn't add", null) }
                        busy = false
                    }
                }
                ListRow("Add to collection", ListToCollection.cardDetail(m, only.any { it in basics }), onClick = {
                    if (!busy) menu = "Add ${o.name} to your collection" to (listOfNotNull(
                        if (m > 0) T1MenuItem("Add the $m missing") { add(missing, "missing") } else null,
                        if (a > 0 && a != m) T1MenuItem("Add all $a") { add(all, "all") } else null,
                    ) + lines.take(4).map { e ->
                        T1MenuItem("Add 1 ${byId[e.cardId]?.setLabel}${if (e.finish == "nonfoil") "" else " · ${Finish.of(e.finish)?.label ?: e.finish}"}" +
                                "${if (e.lang == "en") "" else " · ${e.lang.uppercase()}"}${if (e.cond == "NM") "" else " · ${e.cond}"} · ${list.boardTitle(e.board)}") {
                            add(listOf(ListToCollection.Op(e.cardId, e.finish, 1, e.lang, e.cond)), "one")
                        }
                    })
                }) { Label(if (busy) "Adding…" else "Add", color = T1.text) }
            }
        }
        match?.let { (detail, open) -> ListRow("Match collection", detail, onClick = open) }
        if (uses.isNotEmpty()) {
            Section(if (used > total) "In decks and cubes · $used used · own $total" else "In decks and cubes · $used")
            uses.forEach { (l, qty, considering) ->
                val kind = if (l.kind == ListKind.Deck) "${CatalogPack.formatName(l.format)} deck" else "Cube"
                ListRow(l.name, if (considering > 0) "$kind · $considering considering" else kind, onClick = { onList(l.id) }) {
                    Text("$qty", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                }
            }
        }
        if (owned.isNotEmpty()) {
            Section("Your copies · $total")
            owned.forEach { it ->
                ListRow("${byId[it.cardId]?.setLabel ?: "?"} · ${it.finishLabel}",
                    listOfNotNull(it.condition, if (it.lang == "en") null else it.lang.uppercase(), binders.placementText(it)).joinToString(" · "),
                    onClick = { moving = it }) {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Label("Move", color = T1.text)
                        Text("${it.qty}", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp)
                    }
                }
            }
        }
        val n = binders.liveWants.filter { it.oracleId == o.oracleId }.sumOf { it.qty }
        ListRow(if (n > 0) "Wanted · $n" else "Add to wants", if (n > 0) "Want one more" else "Trades marks it when you get one", onClick = { wanting = true })
        HeroScope.of(context)?.let { hs ->
            val on = heroes.isHero(o.oracleId, hs)
            val place = when (hs) {
                HeroScope.Collection -> "your collection"
                is HeroScope.InList -> lists.firstOrNull { it.id == hs.id }?.name ?: "this list"
                is HeroScope.InBinder -> binders.binder(hs.id)?.name ?: "this binder"
            }
            ListRow(if (on) "Hero of $place" else "Make it a hero", if (on) "Tap to stop highlighting it" else "Highlighted in $place and where it's listed",
                onClick = { if (!HeroesStore.toggle(o.oracleId, hs)) report("${place.replaceFirstChar { it.uppercase() }} has ${HeroesStore.LIMIT} hero cards already.", null) }) {
                if (on) Label("Hero", color = T1.text)
            }
        }
        // The card icon widget (contract/icon-widget-2026-11-06.md): this printing's art behind the Table 1 mark.
        val artUrl = p?.imageUrl("art_crop")
        if (p != null && artUrl != null) {
            val ctx = androidx.compose.ui.platform.LocalContext.current
            var iconOn by remember(p.cardId) { mutableStateOf(site.table1.events.widgets.IconCardStore.contains(ctx, p.cardId)) }
            var iconBusy by remember { mutableStateOf(false) }
            val card = site.table1.events.widgets.IconCard(p.cardId, o.name, p.setLabel)
            ListRow(if (iconOn) "On your icon widget" else "Use for the icon widget",
                if (iconOn) "Tap to take it off" else "Table 1 over this art on your home screen",
                onClick = {
                    if (iconBusy) return@ListRow
                    if (iconOn) {
                        menu = "Icon widget" to listOf(T1MenuItem("Remove from icon widgets", danger = true) {
                            site.table1.events.widgets.IconCardStore.remove(ctx, card.id)
                            iconOn = false
                            report("Removed ${o.name} from your icon widgets", null)
                            Telemetry.capture("icon_card_removed", mapOf("count" to site.table1.events.widgets.IconCardStore.load(ctx).size))
                        })
                        return@ListRow
                    }
                    iconBusy = true
                    co.launch {
                        val image = CardImageLoader.loadRetrying(artUrl, site.table1.events.widgets.IconCardStore.MAX_PX)
                        val ok = image != null && withContext(Dispatchers.IO) {
                            site.table1.events.widgets.IconCardStore.add(ctx, card, image.asAndroidBitmap())
                        }
                        iconBusy = false
                        if (!ok) { report("Couldn't load the art. Try again when you're online.", null); return@launch }
                        iconOn = true
                        report("Added to your icon widgets. Long-press your home screen to add one.", null)
                        Telemetry.capture("icon_card_added", mapOf("count" to site.table1.events.widgets.IconCardStore.load(ctx).size))
                    }
                }) {
                if (iconBusy) Label("Saving…") else if (iconOn) Label("Icon", color = T1.text)
            }
        }
        Section("History · ${p?.setLabel ?: o.name}")
        Column(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
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
        Box(Modifier.windowInsetsBottomHeight(WindowInsets.navigationBars))
    }

    moving?.let { it -> BinderMoveFlow(it, byId[it.cardId]?.setLabel ?: "card", onClose = { moving = null }) { label -> moving = null; report(label, null) } }
    menu?.let { (title, items) -> T1Menu(title, items) { menu = null } }
    if (wanting) {
        fun want(pr: CatalogPrinting?) = co.launch {
            runCatching {
                BindersStore.applyWants(listOf(WantOp(o.oracleId, cardId = pr?.cardId, delta = 1)), "want_added",
                    mapOf("any_printing" to (pr == null), "finish" to false, "has_max" to false, "from" to "card"))
            }.onSuccess { report("Wanted 1 ${pr?.setLabel ?: o.name}", null) }.onFailure { report(it.message ?: "Couldn't add the want", null) }
        }
        T1Menu("Want ${o.name}", listOfNotNull(
            T1MenuItem("Any printing") { want(null) },
            p?.let { pr -> T1MenuItem("Only ${pr.setLabel}") { want(pr) } },
            T1MenuItem("Pick a printing…") { pickingPrinting = true },
        )) { wanting = false }
    }
    if (pickingPrinting) WantPrintingOverlay(o.oracleId, from = "card", onClose = { pickingPrinting = false }, onDone = { report(it, null) }) { report(it, null) }
}

