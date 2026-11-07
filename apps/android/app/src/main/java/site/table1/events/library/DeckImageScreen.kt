package site.table1.events.library

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import site.table1.events.T1App
import site.table1.events.data.Repo
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.Ghost
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1Switch
import site.table1.events.ui.components.T1FullScreenDialog
import site.table1.events.util.Telemetry
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.ceil
import kotlin.math.max

/* Deck image on Android (contract/deck-image-2026-10-20.md): the deck as one picture in melee.gg's visual decklist
   format, drawn on an android.graphics.Canvas from the card images, then Save to Photos (MediaStore, Pictures/Table 1;
   no permission on Android 10+) or Share (a JPEG through the share sheet). Layout rules are DeckImage.kt's, the same
   as iOS and the web. */

/** `owner`: the deck's player on a shared deck; null on your own (your name, switchable). `from`: own / profile. */
@Composable
fun DeckImageScreen(name: String, format: String, entries: List<ListEntry>, owner: String?, from: String, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val cat by CatalogStore.state.collectAsState()
    val prefs = remember { T1App.instance.getSharedPreferences("library", Context.MODE_PRIVATE) }
    var layout by remember { mutableStateOf(DeckImage.Layout.entries.firstOrNull { it.wire == prefs.getString("deckImage.layout", null) } ?: DeckImage.Layout.Grid) }
    var grouping by remember { mutableStateOf(CardGrouping.entries.firstOrNull { it.wire == prefs.getString("deckImage.grouping", null) && it != CardGrouping.None } ?: CardGrouping.Type) }
    var showSide by remember { mutableStateOf(prefs.getBoolean("deckImage.sideboard", true)) }
    var showName by remember { mutableStateOf(prefs.getBoolean("deckImage.name", true)) }
    var me by remember { mutableStateOf<String?>(null) }
    var lines by remember { mutableStateOf<List<ListLine>?>(null) }
    var art by remember { mutableStateOf<Map<String, Bitmap>?>(null) }
    var progress by remember { mutableStateOf(0 to 0) }
    var image by remember { mutableStateOf<Bitmap?>(null) }
    var note by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) { if (owner == null) me = runCatching { Repo.myDisplayName() }.getOrNull() }
    // Resolve the cards and download their images once; options only redraw.
    LaunchedEffect(cat.generation, entries) {
        CatalogStore.load(userInitiated = true)
        val db = CatalogStore.db ?: return@LaunchedEffect
        val resolved = withContext(Dispatchers.Default) { resolveLines(entries.filter { it.board != "maybe" }, db, CardGrouping.Type) }
        val printings = resolved.mapNotNull { it.printing }.associateBy { it.cardId }
        progress = 0 to printings.size
        var done = 0
        val loaded = coroutineScope {
            printings.values.map { p ->
                async {
                    val bmp = p.imageUrl("normal")?.let { CardImageLoader.load(it, 360) }?.asAndroidBitmap()
                    done += 1
                    progress = done to printings.size
                    p.cardId to bmp
                }
            }.awaitAll()
        }.mapNotNull { (id, b) -> b?.let { id to it } }.toMap()
        if (loaded.size < printings.size) note = "${printings.size - loaded.size} card images couldn't be loaded; their names show instead."
        art = loaded
        lines = resolved
    }
    val player = owner ?: if (showName) me else null
    LaunchedEffect(lines, art, layout, grouping, showSide, player) {
        val ls = lines ?: return@LaunchedEffect
        val a = art ?: return@LaunchedEffect
        image = withContext(Dispatchers.Default) {
            DeckImageDrawing.draw(name, CatalogPack.formatName(format), player, DeckImage.plan(ls, grouping), layout, showSide, a)
        }
    }
    fun sent(how: String) = Telemetry.capture("deck_image_shared", mapOf("layout" to layout.wire, "grouping" to grouping.wire,
        "sideboard" to showSide, "cards" to (lines?.sumOf { it.qty } ?: 0), "from" to from, "how" to how))

    suspend fun save(): String {
        val img = image ?: return ""
        return runCatching { saveToPhotos(context, img, DeckImage.fileName(name)) }.fold(
            { note = "Saved to Photos (Pictures/Table 1)."; error = null; sent("photos"); note ?: "" },
            { e -> "Couldn't save: ${e.message}. Use Share instead.".also { error = it } })
    }
    suspend fun share() {
        val img = image ?: return
        runCatching { shareImage(context, img, DeckImage.fileName(name)) }
            .onSuccess { error = null; sent("share") }
            .onFailure { error = it.message }
    }
    suspend fun copy(): String {
        val img = image ?: return ""
        return runCatching { copyImage(context, img, DeckImage.fileName(name)) }.fold(
            { note = "Copied the image."; error = null; sent("copy"); note ?: "" },
            { e -> "Couldn't copy: ${e.message}".also { error = it } })
    }
    val actions = MadeImageActions(copy = { copy() }, save = { save() }, share = { share() })

    T1FullScreenDialog(onDismissRequest = onClose) {
        Box(Modifier.fillMaxSize().background(site.table1.events.ui.theme.T1.bg)) {
            T1Screen {
                Bar("Deck image", name, onBack = onClose)
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    T1Segmented(listOf("Cards", "Stacks"), if (layout == DeckImage.Layout.Grid) 0 else 1) {
                        layout = if (it == 0) DeckImage.Layout.Grid else DeckImage.Layout.Stacks
                        prefs.edit().putString("deckImage.layout", layout.wire).apply()
                    }
                    val groupings = listOf(CardGrouping.Type, CardGrouping.ManaValue, CardGrouping.Color, CardGrouping.Identity)
                    T1Segmented(listOf("Type", "Mana value", "Color", "Identity"), groupings.indexOf(grouping)) {
                        grouping = groupings[it]
                        prefs.edit().putString("deckImage.grouping", grouping.wire).apply()
                    }
                    if (lines?.any { it.board == "side" } == true) ListRow("Sideboard") {
                        T1Switch(showSide) { showSide = it; prefs.edit().putBoolean("deckImage.sideboard", it).apply() }
                    }
                    if (owner == null) ListRow("Your name", me ?: "Not set") {
                        T1Switch(showName) { showName = it; prefs.edit().putBoolean("deckImage.name", it).apply() }
                    }
                    error?.let { Notice(it, error = true) }
                    note?.let { Notice(it) }
                    val img = image
                    if (img != null) {
                        ZoomablePreview(img, "Deck image", name, "deck_image", actions)
                    } else {
                        Notice(if (art == null) "Getting card images… ${progress.first} of ${progress.second}" else "Laying out the cards…")
                    }
                }
                Row(Modifier.fillMaxWidth().padding(bottom = 1.dp), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    Ghost("Save to Photos", enabled = image != null, accent = true) { scope.launch { save() } }
                    Ghost("Share", enabled = image != null) { scope.launch { share() } }
                }
            }
        }
    }
}

/** Pictures/Table 1 through MediaStore (no permission on Android 10+; the legacy public folder before). */
internal suspend fun saveToPhotos(context: Context, image: Bitmap, fileName: String) = withContext(Dispatchers.IO) {
    val values = ContentValues().apply {
        put(MediaStore.Images.Media.DISPLAY_NAME, fileName)
        put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/Table 1")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
    }
    val resolver = context.contentResolver
    val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: error("no photo library")
    resolver.openOutputStream(uri)?.use { image.compress(Bitmap.CompressFormat.JPEG, 90, it) } ?: error("can't write")
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
    }
}

/** The picture as a JPEG under the export FileProvider path, for the share sheet and the clipboard. */
private suspend fun exported(context: Context, image: Bitmap, fileName: String): android.net.Uri {
    val file = File(context.cacheDir, "export/deck-image/$fileName")
    withContext(Dispatchers.IO) {
        file.parentFile?.mkdirs()
        file.outputStream().use { image.compress(Bitmap.CompressFormat.JPEG, 90, it) }
    }
    return FileProvider.getUriForFile(context, "${context.packageName}.avatars", file)
}

/** The system share sheet, with the picture as its preview (ClipData) so the sheet can show it and offer Copy. */
internal suspend fun shareImage(context: Context, image: Bitmap, fileName: String) {
    val uri = exported(context, image, fileName)
    val send = Intent(Intent.ACTION_SEND)
    send.type = "image/jpeg"
    send.putExtra(Intent.EXTRA_STREAM, uri)
    send.clipData = ClipData.newRawUri(fileName, uri)
    send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    context.startActivity(Intent.createChooser(send, fileName))
}

/** The picture on the system clipboard as a content URI (FileProvider grants the pasting app read access). */
internal suspend fun copyImage(context: Context, image: Bitmap, fileName: String) {
    val uri = exported(context, image, fileName)
    (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager)
        .setPrimaryClip(ClipData(ClipDescription(fileName, arrayOf("image/jpeg")), ClipData.Item(uri)))
}

/** The iOS DeckImageCanvas on an android.graphics.Canvas, at 2×. */
internal object DeckImageDrawing {
    private const val BG = 0xFF171725.toInt()
    private const val SURFACE = 0xFF282839.toInt()
    private const val HOVER = 0xFF33334A.toInt()
    private const val TEXT = 0xFFFFFFFF.toInt()
    private const val MUTED = 0xFFC4C4CA.toInt()
    private const val LINE = 0x80C4C4CA.toInt()
    private const val BADGE_EDGE = 0x99C4C4CA.toInt()
    private const val SCALE = 2f
    private const val SW = 140f
    private val SH = SW * DeckImage.ASPECT
    private val SSTEP = SH * 0.118f

    fun draw(name: String, format: String, player: String?, plan: DeckImage.Plan, layout: DeckImage.Layout, showSide: Boolean,
             art: Map<String, Bitmap>): Bitmap {
        val side = if (showSide) plan.side else emptyList()
        val fit = DeckImage.fit(plan.ordered.size, side.size)
        val height = if (layout == DeckImage.Layout.Grid) fit.height else stacksHeight(plan, side)
        val bmp = Bitmap.createBitmap((DeckImage.WIDTH * SCALE).toInt(), ceil(height * SCALE).toInt(), Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        c.scale(SCALE, SCALE)
        c.drawColor(BG)
        val pad = DeckImage.PAD
        val maxW = DeckImage.WIDTH - 2 * pad - 160
        text(c, name, pad, 36f, 30f, TEXT, bold = true, max = maxW)
        var y = 36f + 36f + 8f
        if (player != null) { text(c, "By $player", pad, y, 17f, TEXT, medium = true, max = maxW); y += 21f + 8f }
        val date = SimpleDateFormat("MMM d, yyyy", Locale.US).format(Date())
        text(c, listOfNotNull(date, "Format: $format", "Deck: ${plan.mainCount} cards", if (side.isNotEmpty()) "Sideboard: ${plan.sideCount} cards" else null)
            .joinToString(" · "), pad, y, 14f, MUTED, max = maxW)
        logo(c, DeckImage.WIDTH - pad, 36f, 30f)
        text(c, "TABLE-1.SITE", DeckImage.WIDTH - pad, 74f, 11f, MUTED, tracking = 2.5f, right = true)
        if (layout == DeckImage.Layout.Grid) {
            val ch = fit.cw * DeckImage.ASPECT
            plan.ordered.forEachIndexed { i, card ->
                tile(c, card, pad + (i % fit.cols) * (fit.cw + DeckImage.GAP), DeckImage.HEADER + (i / fit.cols) * (ch + DeckImage.ROW_GAP), fit.cw, art)
            }
            if (side.isNotEmpty()) {
                val sideX = DeckImage.WIDTH - pad - fit.cw
                val rows = ceil(plan.ordered.size / fit.cols.toFloat())
                val h = max(rows * ch + (rows - 1) * DeckImage.ROW_GAP, ch + (side.size - 1) * fit.step)
                divider(c, sideX - DeckImage.SIDE_GUTTER / 2, DeckImage.HEADER, h)
                side.forEachIndexed { i, card -> tile(c, card, sideX, DeckImage.HEADER + i * fit.step, fit.cw, art) }
            }
        } else {
            stacks(c, plan, side, art)
        }
        return bmp
    }

    private fun sideCols(side: List<DeckImage.Card>) = if (side.isEmpty()) 0 else if (side.size > 10) 2 else 1
    private fun mainPerRow(side: List<DeckImage.Card>): Int {
        val n = sideCols(side)
        val room = DeckImage.WIDTH - 2 * DeckImage.PAD - (if (n > 0) n * (SW + DeckImage.GAP) + DeckImage.SIDE_GUTTER else 0f)
        return max(1, ((room + DeckImage.GAP) / (SW + DeckImage.GAP)).toInt())
    }
    private fun columnH(n: Int) = 15f + 12f + SH + max(0, n - 1) * SSTEP

    private fun stacksHeight(plan: DeckImage.Plan, side: List<DeckImage.Card>): Float {
        val rows = DeckImage.columns(plan.main, 9).chunked(mainPerRow(side))
        val mainH = rows.sumOf { r -> r.maxOf { columnH(it.second.size) }.toDouble() }.toFloat() + 28f * max(0, rows.size - 1)
        val per = ceil(side.size / max(1, sideCols(side)).toFloat()).toInt()
        val sideH = if (side.isEmpty()) 0f else columnH(per)
        return ceil(DeckImage.HEADER + max(mainH, sideH) + DeckImage.PAD)
    }

    private fun stacks(c: Canvas, plan: DeckImage.Plan, side: List<DeckImage.Card>, art: Map<String, Bitmap>) {
        fun column(title: String?, cards: List<DeckImage.Card>, x: Float, y: Float) {
            if (title != null) text(c, title.uppercase(), x, y, 12f, MUTED, tracking = 2f, max = SW)
            cards.forEachIndexed { i, card -> tile(c, card, x, y + 27f + i * SSTEP, SW, art) }
        }
        var y = DeckImage.HEADER
        for (r in DeckImage.columns(plan.main, 9).chunked(mainPerRow(side))) {
            r.forEachIndexed { i, col -> column(col.first, col.second, DeckImage.PAD + i * (SW + DeckImage.GAP), y) }
            y += r.maxOf { columnH(it.second.size) } + 28f
        }
        if (side.isNotEmpty()) {
            val n = sideCols(side)
            val per = ceil(side.size / n.toFloat()).toInt()
            val x0 = DeckImage.WIDTH - DeckImage.PAD - n * SW - (n - 1) * DeckImage.GAP
            c.drawRect(x0 - DeckImage.SIDE_GUTTER / 2, DeckImage.HEADER, x0 - DeckImage.SIDE_GUTTER / 2 + 1,
                DeckImage.HEADER + max(y - 28f - DeckImage.HEADER, columnH(per)), Paint().apply { color = LINE })
            side.chunked(per).forEachIndexed { i, cards -> column(if (i == 0) "Sideboard · ${plan.sideCount}" else null, cards, x0 + i * (SW + DeckImage.GAP), DeckImage.HEADER) }
        }
    }

    private fun paint(size: Float, color: Int, bold: Boolean = false, medium: Boolean = false, tracking: Float = 0f) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Typeface.create(Typeface.MONOSPACE, if (bold || medium) Typeface.BOLD else Typeface.NORMAL)
        textSize = size
        this.color = color
        letterSpacing = if (size > 0) tracking / size else 0f
    }

    /** Text with its top at y (the way the iOS stacks lay it out); `max` squeezes it to fit, `right` right-aligns at x. */
    private fun text(c: Canvas, s: String, x: Float, y: Float, size: Float, color: Int, bold: Boolean = false, medium: Boolean = false,
                     tracking: Float = 0f, max: Float? = null, right: Boolean = false) {
        val p = paint(size, color, bold, medium, tracking)
        val w = p.measureText(s)
        if (max != null && w > max) p.textScaleX = max / w
        val drawn = p.measureText(s)
        c.drawText(s, if (right) x - drawn else x, y - p.fontMetrics.ascent, p)
    }

    private fun divider(c: Canvas, x: Float, top: Float, h: Float) {
        c.drawRect(x, top, x + 1, top + h, Paint().apply { color = LINE })
        val p = paint(11f, MUTED, tracking = 2.5f)
        val w = p.measureText("SIDEBOARD")
        c.save()
        c.translate(x + 0.5f, top + h / 2)
        c.rotate(-90f)
        c.drawRect(-w / 2 - 8, -8f, w / 2 + 8, 8f, Paint().apply { color = BG })
        c.drawText("SIDEBOARD", -w / 2, -(p.fontMetrics.ascent + p.fontMetrics.descent) / 2, p)
        c.restore()
    }

    /** A card with its count on a square badge over the top-right corner. */
    private fun tile(c: Canvas, card: DeckImage.Card, x: Float, y: Float, w: Float, art: Map<String, Bitmap>) {
        val h = w * DeckImage.ASPECT
        val r = w * CardCorners.ratio(card.printing?.set ?: "")
        val rect = RectF(x, y, x + w, y + h)
        val img = card.printing?.let { art[it.cardId] }
        c.save()
        c.clipPath(android.graphics.Path().apply { addRoundRect(rect, r, r, android.graphics.Path.Direction.CW) })
        if (img != null) {
            c.drawBitmap(img, null, rect, Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG))
        } else {
            c.drawRect(rect, Paint().apply { color = HOVER })
            text(c, card.name, x + 8, y + 8, 11f, TEXT, max = w - 16)
        }
        if (card.finish != "nonfoil") {
            val colors = intArrayOf(0xFFFF73BF.toInt(), 0xFFFFD966.toInt(), 0xFF73FFB3.toInt(), 0xFF59BFFF.toInt(), 0xFFBF80FF.toInt(), 0xFFFF73BF.toInt())
            c.drawRect(rect, Paint().apply {
                shader = LinearGradient(x, y, x + w, y + h, colors, null, Shader.TileMode.CLAMP)
                alpha = if (card.finish == "etched") 77 else 140
                xfermode = PorterDuffXfermode(PorterDuff.Mode.OVERLAY)
            })
        }
        c.restore()
        val b = max(18f, w * 0.16f)
        val p = paint(b * 0.55f, TEXT, bold = true)
        val label = "${card.qty}"
        val bw = max(b, p.measureText(label) + if (card.qty > 9) 6f else 0f)
        val bx = x + w + b * 0.35f - bw
        val by = y - b * 0.35f
        c.drawRect(bx, by, bx + bw, by + b, Paint().apply { color = SURFACE })
        c.drawRect(bx + 0.5f, by + 0.5f, bx + bw - 0.5f, by + b - 0.5f, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = BADGE_EDGE; style = Paint.Style.STROKE; strokeWidth = 1f })
        c.drawText(label, bx + (bw - p.measureText(label)) / 2, by + b / 2 - (p.fontMetrics.ascent + p.fontMetrics.descent) / 2, p)
    }

    /** The Table 1 mark: eleven tiles on a 6 × 3 grid (the iOS T1Logo), right-aligned at x, `h` tall. */
    private fun logo(c: Canvas, right: Float, top: Float, h: Float) {
        val w = h * 393f / 192.69f
        val sx = w / 393f
        val sy = h / 192.69f
        val x0 = right - w
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = TEXT }
        for ((cx, cy) in listOf(0 to 0, 1 to 0, 2 to 0, 3 to 0, 4 to 0, 1 to 1, 4 to 1, 1 to 2, 3 to 2, 4 to 2, 5 to 2)) {
            val l = x0 + cx * 65.8036f * sx
            val t = top + cy * 64.8302f * sy
            c.drawRect(l, t, l + 63.982f * sx, t + 63.0294f * sy, p)
        }
    }
}
