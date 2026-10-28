package site.table1.events.library

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
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

/** Figma 325:10820's icons (Material, weight 300), drawn from their SVG paths in an 18 dp box. */
enum class T1Icon(d: String) {
    Plus("M8.4375 9.5625H4.125V8.4375H8.4375V4.125H9.5625V8.4375H13.875V9.5625H9.5625V13.875H8.4375V9.5625Z"),
    Search("M14.6567 15.4328L9.94613 10.722C9.57113 11.0316 9.13987 11.2739 8.65237 11.4489C8.16487 11.6239 7.66056 11.7114 7.13944 11.7114C5.85869 11.7114 4.77406 11.2673 3.88556 10.3789C2.99719 9.49038 2.553 8.40575 2.553 7.125C2.553 5.84425 2.99719 4.75963 3.88556 3.87113C4.77406 2.98275 5.85869 2.53856 7.13944 2.53856C8.42019 2.53856 9.50481 2.98275 10.3933 3.87113C11.2817 4.75963 11.7259 5.84425 11.7259 7.125C11.7259 7.66063 11.636 8.17219 11.4562 8.65969C11.2764 9.14719 11.0364 9.57119 10.7364 9.93169L15.447 14.6422L14.6567 15.4328ZM7.13944 10.5866C8.10581 10.5866 8.92431 10.2513 9.59494 9.5805C10.2657 8.90987 10.6011 8.09138 10.6011 7.125C10.6011 6.15862 10.2657 5.34012 9.59494 4.6695C8.92431 3.99875 8.10581 3.66337 7.13944 3.66337C6.17306 3.66337 5.35456 3.99875 4.68394 4.6695C4.01319 5.34012 3.67781 6.15862 3.67781 7.125C3.67781 8.09138 4.01319 8.90987 4.68394 9.5805C5.35456 10.2513 6.17306 10.5866 7.13944 10.5866Z"),
    Arrow("M10.3847 13.2403L9.59419 12.4269L12.4586 9.5625H3.375V8.4375H12.4586L9.59419 5.57306L10.3847 4.75969L14.625 9L10.3847 13.2403Z"),
    Decks("M8.22295 9.81524L1.95395 6.56561L9.82163 2.36842L16.0979 5.61824L8.22295 9.81524ZM8.22295 12.7431L2.3852 9.73005L3.56345 9.08373L8.22295 11.4624L14.4883 8.13637L15.6667 8.78268L8.22295 12.7431ZM8.22295 15.6711L2.3852 12.6579L3.56345 12.0117L8.22295 14.3902L14.4883 11.0644L15.6667 11.7105L8.22295 15.6711ZM8.22295 8.53462L13.7527 5.61824L9.82163 3.64923L4.29901 6.56561L8.22295 8.53462Z"),
    Binders("M5.14912 16.125C4.6635 16.125 4.24644 15.962 3.89794 15.636C3.54931 15.3101 3.375 14.9068 3.375 14.4259V4.18706C3.375 3.75531 3.51469 3.37237 3.79406 3.03825C4.07331 2.70412 4.42881 2.49188 4.86056 2.4015L11.8558 0.975V12.4558L4.98037 13.8879C4.84862 13.9178 4.73562 13.982 4.64137 14.0805C4.54712 14.1791 4.5 14.2943 4.5 14.4259C4.5 14.5923 4.56469 14.7296 4.69406 14.8378C4.82331 14.9459 4.975 15 5.14912 15H13.5V3.375H14.625V16.125H5.14912ZM6.51919 12.4343L10.7308 11.5586V2.35819L6.51919 3.21919V12.4343ZM5.39419 12.6621V3.44719L5.09138 3.51056C4.92025 3.54519 4.77887 3.62381 4.66725 3.74644C4.55575 3.86906 4.5 4.01594 4.5 4.18706V12.9218C4.57688 12.8823 4.65575 12.8483 4.73662 12.8199C4.81737 12.7916 4.89863 12.7687 4.98037 12.7515L5.39419 12.6621Z"),
    Cubes("M8.4375 14.6769V9.32306L3.75 6.60863V11.9625L8.4375 14.6769ZM9.5625 14.6769L14.25 11.9625V6.60863L9.5625 9.32306V14.6769ZM9 8.35387L13.6313 5.67694L9 3L4.36875 5.67694L9 8.35387ZM2.625 12.6274V5.37262L9 1.70775L15.375 5.37262V12.6274L9 16.2923L2.625 12.6274Z");

    val path = PathParser().parsePathString(d).toPath()
}

@Composable
fun IconGlyph(icon: T1Icon, modifier: Modifier = Modifier) {
    Canvas(modifier.size(18.dp)) { scale(size.width / 18f, pivot = Offset.Zero) { drawPath(icon.path, T1.text) } }
}

/** A printing's art alone (Scryfall's art crop), filling its box. */
@Composable
fun CardArtCrop(printing: CatalogPrinting?, modifier: Modifier = Modifier) {
    BoxWithConstraints(modifier.background(T1.surface)) {
        val density = LocalDensity.current
        val maxPx = with(density) { maxOf(maxWidth, maxHeight).roundToPx() }
        val url = printing?.imageUrl("art_crop")
        var image by remember(url) { mutableStateOf(url?.let { CardImageLoader.cached(it, maxPx) }) }
        LaunchedEffect(url) { if (url != null && image == null) image = CardImageLoader.load(url, maxPx) }
        image?.let { Image(it, contentDescription = null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
    }
}

object ShelfArt {
    /** A shelf tile's art: the place's heroes (in the printing it holds), topped up with the first cards it holds that
     *  aren't basic lands, up to `count`, one per card. */
    fun printings(heroes: List<String>, held: List<String>, basics: Set<String>, count: Int, db: CatalogDb): List<CatalogPrinting> {
        val out = HeroArt.printings(heroes, held, db).take(count).toMutableList()
        if (out.size >= count) return out
        val seen = out.map { it.oracleIdx }.toMutableSet()
        val candidates = held.filter { it !in basics }.take(60)
        val found = db.printings(candidates.toSet())
        for (id in candidates) {
            if (out.size >= count) break
            val p = found[id] ?: continue
            if (seen.add(p.oracleIdx)) out += p
        }
        return out
    }
}

private fun shelfText(size: Int) = androidx.compose.ui.text.TextStyle(fontFamily = T1.mono, fontSize = size.sp, letterSpacing = 1.5.sp)

/** One deck, binder or cube on a shelf: its art under a scrim, name and a detail line at the bottom. */
@Composable
private fun ShelfTile(art: CatalogPrinting?, title: String, subtitle: String? = null, note: String? = null, onClick: () -> Unit) {
    Box(Modifier.size(258.dp, 135.dp).clickable(onClick = onClick)) {
        CardArtCrop(art, Modifier.fillMaxSize())
        Box(Modifier.fillMaxSize().background(T1.bg.copy(alpha = 0.6f)))
        Row(Modifier.align(Alignment.BottomStart).fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.Bottom) {
            Column(Modifier.weight(1f)) {
                Text(title.uppercase(), color = T1.text, style = shelfText(11), maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (!subtitle.isNullOrEmpty()) Text(subtitle.uppercase(), color = T1.muted, style = shelfText(9), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            note?.let { Text(it.uppercase(), color = T1.accent, style = shelfText(9)) }
        }
    }
}

@Composable
private fun Shelf(icon: T1Icon, title: String, onOpen: () -> Unit, tiles: androidx.compose.foundation.lazy.LazyListScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().padding(top = 32.dp)) {
        Row(Modifier.fillMaxWidth().height(50.dp).clickable(onClick = onOpen).padding(start = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            IconGlyph(icon)
            Text(title.uppercase(), Modifier.weight(1f).padding(start = 8.dp), color = T1.text, fontFamily = T1.mono, fontSize = 12.sp, letterSpacing = 2.sp, maxLines = 1)
            Box(Modifier.size(50.dp), contentAlignment = Alignment.Center) { IconGlyph(T1Icon.Arrow) }
        }
        LazyRow(Modifier.fillMaxWidth().height(135.dp), horizontalArrangement = Arrangement.spacedBy(1.dp), content = tiles)
    }
}

/** The Collection tab (Figma 325:10820): the collection as a shelf of its hero art, then a shelf each of decks,
 *  binders and cubes (yours, then the ones you follow), with Trade · Wants · Import along the bottom. + adds cards or
 *  makes a deck, binder or cube; the magnifier searches every card. `go` opens a route. */
@Composable
fun LibraryHomeScreen(foregrounds: Int, go: (String) -> Unit) {
    val lists by ListsStore.state.collectAsState()
    val col by CollectionStore.state.collectAsState()
    val binders by BindersStore.state.collectAsState()
    val heroes by HeroesStore.state.collectAsState()
    val cat by CatalogStore.state.collectAsState()
    val follows by FollowsStore.state.collectAsState()
    val pricesVersion by PriceBook.version.collectAsState()
    var menu by remember { mutableStateOf(false) }
    var creating by remember { mutableStateOf<String?>(null) } // deck | cube | binder
    // Syncs on open and on every return to the Library or to the app.
    LaunchedEffect(foregrounds) {
        CollectionStore.sync()
        ListsStore.sync()
    }
    LaunchedEffect(Unit) { if (follows.items == null) FollowsStore.load() }
    LaunchedEffect(col.version) { PriceBook.load(col.items.values.map { it.cardId }) }
    /** Shelf art by place: "collection", "list:<id>", "binder:<id>". */
    var art by remember { mutableStateOf<Map<String, List<CatalogPrinting>>>(emptyMap()) }
    LaunchedEffect(heroes, cat.generation, col.version, binders.version, pricesVersion, lists.lists.map { "${it.id}${it.current.number}" }) {
        val db = CatalogStore.db ?: run { art = emptyMap(); return@LaunchedEffect }
        val basics = CatalogStore.basics
        val items = col.items.values.filter { it.qty > 0 }
        val places = mutableListOf<Triple<String, List<String>, List<String>>>()
        places += Triple("collection", heroes.heroes(HeroScope.Collection),
            items.sortedByDescending { PriceBook.usd(it.cardId, it.finish) ?: 0.0 }.map { it.cardId })
        for (l in lists.lists) places += Triple("list:${l.id}", heroes.heroes(HeroScope.InList(l.id)),
            l.entries.filter { it.board != "side" && it.board != "maybe" }.sortedByDescending { it.qty }.map { it.cardId })
        for (b in binders.binders) places += Triple("binder:${b.id}", heroes.heroes(HeroScope.InBinder(b.id)),
            binders.itemsIn(b.id, col.items).sortedByDescending { it.qty }.map { it.cardId })
        art = withContext(Dispatchers.Default) {
            places.associate { (k, h, held) -> k to ShelfArt.printings(h, held, basics, if (k == "collection") 2 else 1, db) }
        }
    }
    fun tap(target: String) = Telemetry.capture("collection_home_tap", mapOf("target" to target))
    val s = col.summary
    val decks = lists.lists.filter { it.kind == ListKind.Deck }
    val cubes = lists.lists.filter { it.kind == ListKind.Cube }
    val followed = { kind: String -> follows.items.orEmpty().filter { it.kind == kind && it.available } }
    T1Screen {
        Row(Modifier.fillMaxWidth().background(T1.bg), verticalAlignment = Alignment.CenterVertically) {
            Text("COLLECTION", Modifier.weight(1f).padding(start = 16.dp), color = T1.text, fontFamily = T1.mono, fontSize = 12.sp, letterSpacing = 2.sp, maxLines = 1)
            Box(Modifier.size(50.dp).clickable { tap("add"); menu = true }.semantics { contentDescription = "Add" }, contentAlignment = Alignment.Center) { IconGlyph(T1Icon.Plus) }
            Box(Modifier.size(50.dp).clickable { tap("search"); go("collection/search") }.semantics { contentDescription = "Search cards" },
                contentAlignment = Alignment.Center) { IconGlyph(T1Icon.Search) }
        }
        col.error?.let { Notice(it, error = true) }
        LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(bottom = 64.dp)) {
            item {
                Box(Modifier.fillMaxWidth().height(179.dp).clickable { go("collection/all") }) {
                    val heroArt = art["collection"].orEmpty()
                    Row(Modifier.fillMaxSize()) {
                        if (heroArt.isEmpty()) Box(Modifier.fillMaxSize().background(T1.surface))
                        heroArt.forEach { CardArtCrop(it, Modifier.weight(1f).fillMaxHeight()) }
                    }
                    Box(Modifier.fillMaxSize().background(T1.bg.copy(alpha = 0.6f)))
                    Row(Modifier.align(Alignment.BottomStart).fillMaxWidth().padding(16.dp)) {
                        Text(s?.let { count(it.totalQty) } ?: if (col.ready) "0" else "…", Modifier.weight(1f), color = T1.muted, style = shelfText(9))
                        s?.let { Text(money(it.valueUsd, "USD"), color = T1.muted, style = shelfText(9)) }
                    }
                }
            }
            item {
                Shelf(T1Icon.Decks, "Decks", { go("collection/decks") }) {
                    items(decks, key = { it.id }) { l ->
                        ShelfTile(art["list:${l.id}"]?.firstOrNull(), l.name, CatalogPack.formatName(l.format)) { go("collection/list/${l.id}") }
                    }
                    items(followed("deck"), key = { "f" + it.id }) { f -> ShelfTile(null, f.title, f.owner?.displayName, if (f.unseen > 0) "${f.unseen} new" else null) { f.route?.let(go) } }
                    if (decks.isEmpty()) item { ShelfTile(null, "New deck", "Build or import") { creating = "deck" } }
                }
            }
            item {
                Shelf(T1Icon.Binders, "Binders", { go("collection/binders") }) {
                    items(binders.binders, key = { it.id }) { b -> ShelfTile(art["binder:${b.id}"]?.firstOrNull(), b.name) { go("collection/binder/${b.id}") } }
                    items(followed("binder"), key = { "f" + it.id }) { f -> ShelfTile(null, f.title, f.owner?.displayName, if (f.unseen > 0) "${f.unseen} new" else null) { f.route?.let(go) } }
                    if (binders.binders.isEmpty()) item { ShelfTile(null, "New binder", "Where your copies are") { creating = "binder" } }
                }
            }
            item {
                Shelf(T1Icon.Cubes, "Cubes", { go("collection/cubes") }) {
                    items(cubes, key = { it.id }) { l -> ShelfTile(art["list:${l.id}"]?.firstOrNull(), l.name) { go("collection/list/${l.id}") } }
                    items(followed("cube"), key = { "f" + it.id }) { f -> ShelfTile(null, f.title, f.owner?.displayName, if (f.unseen > 0) "${f.unseen} new" else null) { f.route?.let(go) } }
                    if (cubes.isEmpty()) item { ShelfTile(null, "New cube", "Build or import") { creating = "cube" } }
                }
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            listOf("Trade" to "collection/trades", "Wants" to "collection/wants", "Import" to "collection/csv").forEach { (title, route) ->
                Box(Modifier.weight(1f).height(50.dp).background(T1.bg).clickable { tap(title.lowercase()); go(route) }, contentAlignment = Alignment.Center) {
                    Text(title.uppercase(), color = T1.text, style = shelfText(11))
                }
            }
        }
    }
    if (menu) T1Menu(null, listOf(
        T1MenuItem("Add cards") { go("collection/add") },
        T1MenuItem("New deck") { creating = "deck" },
        T1MenuItem("New binder") { creating = "binder" },
        T1MenuItem("New cube") { creating = "cube" },
    ), onDismiss = { menu = false })
    when (creating) {
        "deck", "cube" -> {
            val kind = if (creating == "deck") ListKind.Deck else ListKind.Cube
            NewListPanel(kind, onDismiss = { creating = null }, onCreated = { go("collection/list/$it") },
                onFind = { go("collection/find") }, onImport = { go("collection/import/${kind.wire}") })
        }
        "binder" -> BinderEditDialog(null, onClose = { creating = null }) { go("collection/binder/${it.id}") }
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
fun AddCardsScreen(onBack: () -> Unit, onOpen: (String) -> Unit, search: Boolean = false) {
    val cat by CatalogStore.state.collectAsState()
    val col by CollectionStore.state.collectAsState()
    /** Search (the Collection home's magnifier): copies owned per oracle idx. */
    var owned by remember { mutableStateOf<Map<Int, Int>>(emptyMap()) }
    LaunchedEffect(search, col.version, cat.generation) {
        val db = CatalogStore.db ?: return@LaunchedEffect
        if (!search) return@LaunchedEffect
        val items = col.items.values.map { it.cardId to it.qty }
        owned = withContext(Dispatchers.Default) {
            val printings = db.printings(items.map { it.first }.toSet())
            items.mapNotNull { (id, q) -> printings[id]?.let { it.oracleIdx to q } }.groupBy({ it.first }, { it.second }).mapValues { it.value.sum() }
        }
    }
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
        Bar(if (search) "Search" else "Add cards", onBack = onBack)
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
            CardSearchBar(query, { query = it }, placeholder = "Lightning Bolt, or t:dragon c:r", label = "Card", onScan = if (search) null else ({ scanning = true }),
                onSubmit = { hits.firstOrNull()?.let { onOpen(it.oracleId) } })
        }
        CardSearchStatus(query, result)
        Hairlines(Modifier.weight(1f)) {
            if (cat.phase == "ready" && result != null && CardName.norm(query).length >= 2 && hits.isEmpty() && !CardQuery.hasSyntax(query)) item { QuietRow("No card by that name") }
            items(hits, key = { it.idx }) { o ->
                CardRow(covers[o.idx], o.name, if (o.manaCost.isEmpty()) o.typeLine else "${o.typeLine} · ${o.manaCost}", onClick = { onOpen(o.oracleId) }) {
                    if (!search) Text("${o.printings}", color = T1.muted, fontFamily = T1.mono, fontSize = 15.sp)
                    else owned[o.idx]?.takeIf { it > 0 }?.let { Text("$it", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp) }
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
