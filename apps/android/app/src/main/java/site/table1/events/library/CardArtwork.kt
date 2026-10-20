package site.table1.events.library

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridScope
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.geometry.Offset
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.Canvas
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import site.table1.events.T1App
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.theme.T1
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

// Card images from Scryfall's CDN (cards.scryfall.io: no rate limit, no API call), built for long lists:
//  - the smallest rendition that covers the drawn pixels: "small" (146 px wide, ~10 KB) for thumbnails,
//    "normal" (488 px) for the grid and card detail;
//  - decoded off the main thread with power-of-two sampling, so a 36 dp thumbnail holds a small bitmap;
//  - decoded bitmaps in a memory LRU sized to 1/8 of the heap, files in a 300 MB disk cache;
//  - at most 6 downloads at once, one per image however many rows ask.

/** Corner radius as a fraction of card width, measured from Scryfall's transparent PNG scans (2026-10-15):
 *  every printing 4.32% (≈2.7 mm), Alpha 6.99% (≈4.4 mm, a rounder cutting die), CE/IE square. */
object CardCorners {
    fun ratio(set: String): Float = when (set) {
        "lea" -> 0.0699f
        "ced", "cei" -> 0f
        else -> 0.0432f
    }
}

const val CARD_ASPECT = 488f / 680f

object CardImageLoader {
    private const val DISK_LIMIT = 300L shl 20

    private val memory = object : LruCache<String, ImageBitmap>((Runtime.getRuntime().maxMemory() / 8).toInt()) {
        override fun sizeOf(key: String, value: ImageBitmap) = value.width * value.height * 4
    }
    private val network = Semaphore(6)
    private val lock = Mutex()
    private val flights = HashMap<String, CompletableDeferred<ImageBitmap?>>()
    private val dir by lazy { File(T1App.instance.cacheDir, "card-images").apply { mkdirs() } }
    @Volatile private var trimmed = false

    fun size(px: Int) = if (px <= 146) "small" else if (px <= 488) "normal" else "large"
    private fun key(url: String, maxPx: Int) = "$maxPx|$url"

    fun cached(url: String, maxPx: Int): ImageBitmap? = memory.get(key(url, maxPx))

    suspend fun load(url: String, maxPx: Int): ImageBitmap? {
        val k = key(url, maxPx)
        memory.get(k)?.let { return it }
        var mine = false
        val flight = lock.withLock {
            flights[k] ?: CompletableDeferred<ImageBitmap?>().also { flights[k] = it; mine = true }
        }
        if (mine) {
            val result = runCatching { fetch(url, maxPx) }.getOrNull()
            result?.let { memory.put(k, it) }
            lock.withLock { flights.remove(k) }
            flight.complete(result)
        }
        return flight.await()
    }

    private suspend fun fetch(url: String, maxPx: Int): ImageBitmap? = withContext(Dispatchers.IO) {
        val name = MessageDigest.getInstance("SHA-1").digest(url.toByteArray()).joinToString("") { "%02x".format(it) }
        val file = File(dir, "$name.jpg")
        if (!file.exists()) {
            network.withPermit {
                val conn = URL(url).openConnection() as HttpURLConnection
                conn.setRequestProperty("User-Agent", "Table1Events/1.0 (table-1.site)")
                try {
                    if (conn.responseCode != 200) return@withContext null
                    val tmp = File(dir, "$name.part")
                    conn.inputStream.use { input -> tmp.outputStream().use { input.copyTo(it) } }
                    tmp.renameTo(file)
                } finally {
                    conn.disconnect()
                }
            }
            if (!trimmed) { trimmed = true; trimDisk() }
        } else {
            file.setLastModified(System.currentTimeMillis()) // keeps recently seen images on trim
        }
        decode(file, maxPx)?.asImageBitmap()
    }

    /** Decodes with the largest power-of-two sample that still covers `maxPx` on the long side. */
    private fun decode(file: File, maxPx: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        val longSide = maxOf(bounds.outWidth, bounds.outHeight)
        if (longSide <= 0) return null
        var sample = 1
        while (longSide / (sample * 2) >= maxPx) sample *= 2
        val opts = BitmapFactory.Options().apply {
            inSampleSize = sample
            // JPEGs have no alpha; thumbnails don't need 32-bit color.
            inPreferredConfig = if (maxPx <= 220) Bitmap.Config.RGB_565 else Bitmap.Config.ARGB_8888
        }
        return BitmapFactory.decodeFile(file.path, opts)
    }

    /** Keeps the disk cache under its limit, dropping the least recently used files first. */
    private fun trimDisk() {
        val files = dir.listFiles()?.filter { it.extension == "jpg" } ?: return
        var total = files.sumOf { it.length() }
        if (total <= DISK_LIMIT) return
        for (f in files.sortedBy { it.lastModified() }) {
            if (total <= DISK_LIMIT * 9 / 10) break
            total -= f.length()
            f.delete()
        }
    }
}

/** A card image at a fixed width with the printing's real corner radius; flat placeholder until loaded. `finish`
 *  nonfoil | foil | etched: foil copies get a light sheen, etched a dimmer one. */
@Composable
fun CardArt(printing: CatalogPrinting?, width: Dp, modifier: Modifier = Modifier, finish: String = "nonfoil") {
    val density = LocalDensity.current
    val height = width / CARD_ASPECT
    val maxPx = with(density) { height.roundToPx() }
    val url = printing?.imageUrl(CardImageLoader.size(with(density) { width.roundToPx() }))
    val shape = RoundedCornerShape(width * CardCorners.ratio(printing?.set ?: ""))
    var image by remember(url) { mutableStateOf(url?.let { CardImageLoader.cached(it, maxPx) }) }
    LaunchedEffect(url) { if (url != null && image == null) image = CardImageLoader.load(url, maxPx) }
    Box(modifier.size(width, height).clip(shape).background(T1.bg).let { if (finish != "nonfoil") it.foilSheen(finish == "etched") else it }) {
        image?.let { Image(it, contentDescription = null, Modifier.size(width, height), contentScale = ContentScale.Crop) }
    }
}

private val SPECTRUM = listOf(Color(1f, 0.45f, 0.75f), Color(1f, 0.85f, 0.4f), Color(0.45f, 1f, 0.7f), Color(0.35f, 0.75f, 1f),
    Color(0.75f, 0.5f, 1f), Color(1f, 0.45f, 0.75f))

/** A foil's rainbow sheen over the card image (contract/library-polish-2026-10-19.md § Foil): a diagonal spectrum blended
 *  into the art plus one soft highlight band. Etched foils are matte, so theirs is dimmer. */
private fun Modifier.foilSheen(etched: Boolean) = graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
    .drawWithContent {
        drawContent()
        val end = Offset(size.width, size.height)
        drawRect(Brush.linearGradient(SPECTRUM, Offset.Zero, end), alpha = if (etched) 0.3f else 0.55f, blendMode = BlendMode.Overlay)
        drawRect(Brush.linearGradient(0.3f to Color.Transparent, 0.45f to Color.White.copy(alpha = 0.35f), 0.6f to Color.Transparent,
            start = Offset.Zero, end = end), alpha = if (etched) 0.5f else 1f, blendMode = BlendMode.Softlight)
    }

/** The mark a hero card's row carries on its left edge (white, not the accent: teal means "the result"). */
private fun Modifier.heroEdge() = drawBehind { drawRect(T1.text, size = Size(2.dp.toPx(), size.height)) }
    .semantics { stateDescription = "Hero card" }

/** A hero card's outline in the grid and in stacks. */
private fun Modifier.heroFrame(width: Dp) = border(2.dp, T1.text, RoundedCornerShape(width * 0.0432f))

/** The chevron column at the right of a card with several printings: opens or closes its printings. */
@Composable
fun PrintingsChevron(open: Boolean, hero: Boolean = false, onClick: () -> Unit) {
    Box(Modifier.width(44.dp).fillMaxHeight().background(if (hero) T1.surfaceHover else T1.surface).clickable(onClick = onClick)
        .semantics { contentDescription = if (open) "Hide printings" else "Show printings" }, contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(12.dp, 8.dp)) {
            val (top, bottom) = if (open) size.height to 0f else 0f to size.height
            drawPath(Path().apply { moveTo(0f, top); lineTo(size.width / 2, bottom); lineTo(size.width, top) }, T1.muted,
                style = Stroke(width = 1.5.dp.toPx(), cap = StrokeCap.Round))
        }
    }
}

/** A card row with a printings chevron when it has several printings or finishes. */
@Composable
fun WithChevron(parts: Int, open: Boolean, hero: Boolean = false, onToggle: () -> Unit, row: @Composable () -> Unit) {
    if (parts < 2) return row()
    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
        Box(Modifier.weight(1f)) { row() }
        PrintingsChevron(open, hero, onToggle)
    }
}

/** A list row led by a card thumbnail; same type and spacing as ListRow. A hero card's row is a shade lighter with a
 *  white left edge; `indent` is a printing row under its card. */
@Composable
fun CardRow(printing: CatalogPrinting?, title: String, detail: String? = null, onClick: (() -> Unit)? = null,
            finish: String = "nonfoil", hero: Boolean = false, indent: Boolean = false,
            trailing: @Composable () -> Unit = {}) {
    Row(
        Modifier.fillMaxWidth().background(if (hero) T1.surfaceHover else T1.surface)
            .let { if (hero) it.heroEdge() else it }
            .let { if (onClick != null) it.clickable(onClick = onClick) else it }
            .padding(start = if (indent) 40.dp else 16.dp, end = 16.dp, top = 8.dp, bottom = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        CardArt(printing, 36.dp, finish = finish)
        Column(Modifier.weight(1f)) {
            Text(title, color = T1.text, fontFamily = T1.mono, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            detail?.let { Label(it) }
        }
        trailing()
    }
}

/** One grid cell: the image with a count tag inset from the rounded corner. */
@Composable
fun CardTile(printing: CatalogPrinting?, qty: Int, width: Dp, warn: Boolean = false, onClick: (() -> Unit)? = null,
             finish: String = "nonfoil", hero: Boolean = false) {
    Box(Modifier.width(width).let { if (onClick != null) it.clickable(onClick = onClick) else it }) {
        CardArt(printing, width, if (hero) Modifier.heroFrame(width) else Modifier, finish = finish)
        Text("$qty", Modifier.align(Alignment.BottomEnd).padding(width * 0.05f)
            .background(if (warn) T1.error else T1.bg).padding(horizontal = 6.dp, vertical = 2.dp),
            color = if (warn) T1.bg else T1.text, fontFamily = T1.mono, fontSize = 13.sp)
    }
}

/** A lazily built card grid that fills the width: three columns on a phone, more on wider screens. */
@Composable
fun CardGrid(modifier: Modifier = Modifier, content: LazyGridScope.(tileWidth: Dp) -> Unit) {
    BoxWithConstraints(modifier.fillMaxWidth()) {
        val cols = maxOf(3, (maxWidth / 180.dp).toInt())
        val tile = (maxWidth - 1.dp * (cols - 1)) / cols
        LazyVerticalGrid(GridCells.Fixed(cols), horizontalArrangement = Arrangement.spacedBy(1.dp),
            verticalArrangement = Arrangement.spacedBy(1.dp)) { content(tile) }
    }
}

/** A full-width header cell inside a CardGrid. */
fun LazyGridScope.gridHeader(key: String, content: @Composable () -> Unit) {
    item(key = key, span = { GridItemSpan(maxLineSpan) }) { content() }
}

/** How a card list is drawn: rows, a grid of whole cards, or stacks that show each card's title bar with the
 *  last card in full (like cards fanned down a playmat). Same three as iOS `CardLayout`. */
enum class CardLayout(val wire: String, val title: String) {
    List("list", "List"), Grid("grid", "Grid"), Stacks("stacks", "Stacks");

    companion object {
        /** The saved layout, falling back to the old List/Grid flag and then to list. */
        fun parse(saved: String?, legacyGrid: Boolean): CardLayout = entries.firstOrNull { it.wire == saved } ?: if (legacyGrid) Grid else List
    }
}

/** The layout saved for a screen family under `library` prefs `key`; `legacyGridKey` is the old boolean flag. */
@Composable
fun rememberCardLayout(key: String, legacyGridKey: String): MutableState<CardLayout> {
    val prefs = remember { T1App.instance.getSharedPreferences("library", android.content.Context.MODE_PRIVATE) }
    val state = remember { mutableStateOf(CardLayout.parse(prefs.getString(key, null), prefs.getBoolean(legacyGridKey, false))) }
    return remember(state) {
        object : MutableState<CardLayout> by state {
            override var value: CardLayout
                get() = state.value
                set(v) { state.value = v; prefs.edit().putString(key, v.wire).apply() }
        }
    }
}

/** The bar's "View" menu: the three layouts, the current one selected, then expanding or collapsing every card's
 *  printings when the screen has them, then Group by (`list`: a deck or cube, no None). `screen` is all_cards / deck /
 *  cube / binder / profile_<section>. */
@Composable
fun CardLayoutMenu(layout: MutableState<CardLayout>, screen: String, printings: MutableState<PrintingsDisclosure>? = null,
                   grouping: MutableState<CardGrouping>? = null, list: Boolean = false, onDismiss: () -> Unit) {
    val all = printings?.value?.all == true
    T1Menu("View", CardLayout.entries.map { l ->
        T1MenuItem(l.title, selected = l == layout.value) {
            if (l != layout.value) {
                layout.value = l
                site.table1.events.util.Telemetry.capture("card_layout_changed", mapOf("layout" to l.wire, "screen" to screen))
            }
        }
    } + listOfNotNull(printings?.let { p ->
        T1MenuItem(if (all) "Collapse all printings" else "Expand all printings") {
            p.value = p.value.setAll(!all)
            site.table1.events.util.Telemetry.capture("printings_toggled",
                mapOf("expanded" to !all, "all" to true, "screen" to if (screen == "all_cards" || screen == "binder") screen else "list"))
        }
    }) + (grouping?.let { groupingMenuItems(it, list, screen) } ?: emptyList()), onDismiss)
}

/** One card in a stack. Only its top `STACK_PEEK` shows unless it's the last card. */
data class StackCard(val key: String, val printing: CatalogPrinting?, val name: String, val qty: Int, val warn: Boolean = false,
                     val finish: String = "nonfoil", val hero: Boolean = false, val onClick: () -> Unit)

data class CardStackSpec(val key: String, val title: String?, val cards: List<StackCard>)

/** The share of a card's height left showing: the whole title bar (name and mana cost) on every modern frame. */
const val STACK_PEEK = 0.118f

/** Cards laid over each other, each showing just its title bar; the last shows in full. Later cards draw on
 *  top, so a tap on a strip lands on that card. */
@Composable
fun CardStack(spec: CardStackSpec, width: Dp) {
    val height = width / CARD_ASPECT
    val strip = height * STACK_PEEK
    Column(Modifier.width(width)) {
        spec.title?.let { Label(it, Modifier.padding(horizontal = 4.dp, vertical = 8.dp)) }
        Box(Modifier.size(width, if (spec.cards.isEmpty()) 0.dp else strip * (spec.cards.size - 1) + height)) {
            spec.cards.forEachIndexed { i, c ->
                Box(Modifier.offset(y = strip * i).size(width, height)
                    .semantics(mergeDescendants = true) { contentDescription = "${c.name}, ${c.qty}${if (c.hero) ", hero card" else ""}" }
                    .clickable(onClick = c.onClick)) {
                    CardArt(c.printing, width, if (c.hero) Modifier.heroFrame(width) else Modifier, finish = c.finish)
                    if (c.printing == null) {
                        Box(Modifier.size(width, strip).border(1.dp, T1.surface).padding(horizontal = 8.dp), contentAlignment = Alignment.CenterStart) {
                            Text(c.name, color = T1.text, fontFamily = T1.mono, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                    // The count sits on the frame's left edge, clear of the name, and only when it says something.
                    if (c.qty > 1 || c.warn) {
                        Box(Modifier.height(strip), contentAlignment = Alignment.CenterStart) {
                            Text("${c.qty}", Modifier.background(if (c.warn) T1.error else T1.bg).padding(horizontal = 4.dp, vertical = 1.dp),
                                color = if (c.warn) T1.bg else T1.text, fontFamily = T1.mono, fontSize = 11.sp)
                        }
                    }
                }
            }
        }
    }
}

/** Stack columns for a width: two to a row on a phone, more on wider screens. */
fun stackColumns(maxWidth: Dp): Pair<Int, Dp> {
    val cols = maxOf(2, (maxWidth / 220.dp).toInt())
    return cols to (maxWidth - 1.dp * (cols - 1)) / cols
}

/** Stacks in rows of `cols`, one lazy item per row. */
fun LazyListScope.stackRows(key: String, stacks: List<CardStackSpec>, cols: Int, width: Dp) {
    items(stacks.chunked(cols), key = { row -> "$key|${row.first().key}" }) { row ->
        Row(Modifier.padding(bottom = 16.dp), horizontalArrangement = Arrangement.spacedBy(1.dp), verticalAlignment = Alignment.Top) {
            row.forEach { CardStack(it, width) }
        }
    }
}

/** All cards in stacks follows the sort: one stack per run of a set (titled by set code) when sorted by set,
 *  otherwise runs of ten in sort order. `setOf` returns "" when the set is unknown. A set can come back as a
 *  second run (Secret Lair drops have their own release dates), so keys carry the run's position. */
fun <T> runStacks(items: List<T>, bySet: Boolean, setOf: (T) -> String, keyPrefix: String = ""): List<Triple<String, String?, List<T>>> {
    if (!bySet) return items.chunked(10).mapIndexed { i, run -> Triple("$keyPrefix${i * 10}", null, run) }
    val out = mutableListOf<Triple<String, String?, MutableList<T>>>()
    var prev: String? = null
    for (it in items) {
        val set = setOf(it)
        if (set == prev) out.last().third.add(it)
        else out.add(Triple("set|$set|${out.size}", if (set.isEmpty()) "Unknown set" else set.uppercase(), mutableListOf(it)))
        prev = set
    }
    return out
}
