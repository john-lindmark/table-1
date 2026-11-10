package site.table1.events.widgets

import android.app.Application
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.view.View
import android.widget.FrameLayout
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.glance.appwidget.ExperimentalGlanceRemoteViewsApi
import androidx.glance.appwidget.GlanceRemoteViews
import androidx.glance.appwidget.action.actionStartActivity
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import site.table1.events.data.LiveSnapshot
import site.table1.events.data.LiveState
import site.table1.events.data.NextEventData
import site.table1.events.data.NextEventItem
import site.table1.events.data.ValuePoint
import site.table1.events.data.ValueRecord
import java.io.File
import java.time.Instant
import java.time.LocalDate

/**
 * Design QA for the home screen widgets without a phone, like iOS's `-T1WidgetsDemo`: draws every widget on sample data
 * at the sizes a launcher gives them (one row, 2×2, 4×2, tall, full width) and writes one sheet per widget to
 * app/build/widget-gallery/. Runs only with -PT1_WIDGET_GALLERY (see app/build.gradle.kts).
 */
@OptIn(ExperimentalGlanceRemoteViewsApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class, qualifiers = "w411dp-h891dp-xhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class WidgetGalleryTest {
    private val context get() = RuntimeEnvironment.getApplication()
    private val tap get() = actionStartActivity(Intent(Intent.ACTION_VIEW))
    private val out = File(System.getProperty("t1.widgetGallery") ?: "build/widget-gallery").apply { mkdirs() }

    /** Rows of sizes, as a phone launcher draws them (two cells about 170 dp, four about 370). */
    private val sheet = listOf(
        listOf("1×1" to DpSize(72.dp, 72.dp), "2×1" to DpSize(170.dp, 72.dp), "4×1" to DpSize(370.dp, 72.dp)),
        listOf("2×2" to DpSize(170.dp, 170.dp), "4×2" to DpSize(370.dp, 170.dp)),
        listOf("2×3" to DpSize(170.dp, 270.dp), "4×3" to DpSize(370.dp, 270.dp)),
        listOf("4×4" to DpSize(370.dp, 370.dp)),
    )

    private val now = Instant.now()

    private fun event(id: String, name: String, inSeconds: Long?, venue: String? = null, players: Int = 8, label: String = "Modern",
                      organizing: Boolean = false, live: Boolean = false) =
        NextEventItem(id, name, "open", if (live) "live" else "upcoming", organizing, true, venue,
            inSeconds?.let { now.plusSeconds(it).toString() }, 4, if (live) 2 else 0, players, label, label.lowercase())

    private val events = NextEventData(listOf(
        event("a", "Friday Modern", 2 * 3600 + 600, "Mox Boarding House", 12, organizing = true),
        event("b", "Sunday Vintage Cube", 2 * 86400, players = 8, label = "Cube draft"),
        event("c", "Tuesday Pauper League", 5 * 86400, "Card Kingdom", 16, label = "Pauper"),
        event("d", "RCQ: Pioneer", 9 * 86400, "Gamescape North", 64, label = "Pioneer"),
        event("e", "Team Sealed", null, players = 9, label = "Team sealed"),
    ), invites = 2)

    private val value = run {
        val today = LocalDate.now()
        val usd = listOf(3871.10, 3880.25, 3902.60, 3899.90, 3915.00, 3940.75, 3936.10, 3951.30, 3990.00, 4012.40, 4008.80,
            4025.60, 4031.00, 4060.20, 4072.75, 4069.10, 4101.30, 4120.00, 4133.90, 4150.40, 4148.00, 4166.70, 4187.58,
            4180.10, 4201.90, 4230.40, 4226.80, 4249.90, 4262.30, 4275.00)
        ValueRecord("x", usd.mapIndexed { i, v -> ValuePoint(today.minusDays((usd.size - 1 - i).toLong()).toString(), v) }, 1284, 2016)
    }

    private fun match(status: String, phase: String = "playing") = LiveSnapshot("e1", "Friday Modern", "p1", LiveState(
        phase = phase, round = 2, rounds = 4, endsAt = now.epochSecond + 31 * 60 + 12.0, table = 5, myRank = 3, myRecord = "1-0",
        players = 12, oppName = "Mara", oppRank = 7, oppRecord = "1-0", matchId = "m1", mySide = 0, status = status,
        myWins = if (status == "reported_them") 1 else null, theirWins = if (status == "reported_them") 2 else null))

    @Test fun nextEvent() {
        draw("next-event", "Next event", events) { size, d -> NextEventContent(d, true, size, { tap }, now) }
        draw("next-event-empty", "Next event · none", NextEventData()) { size, d -> NextEventContent(d, true, size, { tap }, now) }
    }

    @Test fun collectionValue() {
        draw("collection-value", "Collection value", value) { size, r -> ValueContent(r, true, size, tap) }
        draw("collection-value-today", "Collection value · first day", value.copy(points = value.points.takeLast(1))) { size, r ->
            ValueContent(r, true, size, tap)
        }
    }

    @Test fun currentMatch() {
        draw("match-report", "Current match · report", match("pending")) { size, s -> MatchContent(s, size, tap) { _, _, _ -> tap } }
        draw("match-confirm", "Current match · confirm", match("reported_them")) { size, s -> MatchContent(s, size, tap) { _, _, _ -> tap } }
        draw("match-waiting", "Current match · between rounds", match("confirmed", "waiting")) { size, s -> MatchContent(s, size, tap) { _, _, _ -> tap } }
        draw("match-none", "Current match · none", null as LiveSnapshot?) { size, s -> MatchContent(s, size, tap) { _, _, _ -> tap } }
    }

    /** The live Modern pack of 2026-11-02 (testdata/meta-widgets/modern.json). */
    private val meta: MetaPack = MetaPacks.decode(File(generateSequence(File("").absoluteFile) { it.parentFile }
        .map { File(it, "testdata/meta-widgets") }.first { it.isDirectory }, "modern.json").readText())!!

    @Test fun insights() {
        draw("meta", "Meta · Big events, 30 days", meta) { size, p -> MetaContent(p, MetaPicks(), size, tap) }
        draw("meta-7d", "Meta · All events, 7 days", meta) { size, p -> MetaContent(p, MetaPicks(tier = "all", days = 7), size, tap) }
        draw("meta-none", "Meta · no pack yet", null as MetaPack?) { size, p -> MetaContent(p, MetaPicks(), size, tap) }
        draw("matchup-grid", "Matchup grid · Big events, 30 days", meta) { size, p -> MatchupGridContent(p, MetaPicks(), size, tap) }
        draw("matchup-grid-tapped", "Matchup grid · a square tapped", meta) { size, p -> MatchupGridContent(p, MetaPicks(), size, tap, selected = 1 to 18) }
        draw("meta-focus", "Meta · a row tapped (Izzet Prowess)", meta) { size, p -> MetaContent(p, MetaPicks(), size, tap, focus = 18) }
        draw("archetype", "Archetype matchups · most played", meta) { size, p -> ArchetypeContent(p, MetaPicks(tier = "all"), size, tap) }
        draw("archetype-boros", "Archetype matchups · Boros Energy", meta) { size, p -> ArchetypeContent(p, MetaPicks(tier = "all", archetype = 17), size, tap) }
    }

    private val limited: LimitedWidgetPack? = LimitedPacks.decode(File(generateSequence(File("").absoluteFile) { it.parentFile }
        .first { File(it, "testdata").isDirectory }, "testdata/insights/limited-FRA.json").readText())

    @Test fun limitedCards() {
        draw("limited", "Limited cards · FRA, GIH WR", limited) { size, p -> LimitedContent(p, LimitedPicks("FRA"), size, tap) }
        draw("limited-wu", "Limited cards · IWD, commons and uncommons, W + U", limited) { size, p ->
            LimitedContent(p, LimitedPicks("FRA", "iwd", listOf("common", "uncommon"), listOf("W", "U")), size, tap)
        }
        draw("limited-none", "Limited cards · no set yet", null as LimitedWidgetPack?) { size, p -> LimitedContent(p, LimitedPicks(), size, tap) }
    }

    /** Stand-in art (no card images in the repo): a red-to-blue wash with streaks, about an art crop's shape. */
    private val art: Bitmap = Bitmap.createBitmap(626, 457, Bitmap.Config.ARGB_8888).also { b ->
        val c = Canvas(b)
        c.drawPaint(Paint().apply {
            shader = android.graphics.LinearGradient(0f, 0f, 626f, 457f, 0xFFB0303A.toInt(), 0xFF2A4E9A.toInt(), android.graphics.Shader.TileMode.CLAMP)
        })
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFFF2E6C8.toInt(); strokeWidth = 6f }
        for (i in 0 until 6) c.drawLine(80f + i * 90, 0f, 20f + i * 110, 457f, p)
    }

    @Test fun cardIcon() {
        draw("card-icon", "Card icon · a card", art) { size, a -> IconContent(a, size, tap) }
        draw("card-icon-none", "Card icon · none", null as Bitmap?) { size, a -> IconContent(a, size, tap) }
    }

    private fun <D> draw(file: String, title: String, data: D, content: @Composable (DpSize, D) -> Unit) = runBlocking {
        val d = context.resources.displayMetrics.density
        val gap = (16 * d).toInt()
        val tiles = sheet.map { row -> row.map { (_, size) -> render(size, d) { content(size, data) } } }
        val width = tiles.maxOf { row -> row.sumOf { it.width } + gap * (row.size + 1) }
        val height = tiles.sumOf { row -> row.maxOf { it.height } + gap } + gap + (24 * d).toInt()
        val sheetBmp = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(sheetBmp).apply { drawColor(0xFF525252.toInt()) }
        canvas.drawText(title.uppercase(), gap.toFloat(), 18 * d, Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFFFFFFFF.toInt(); textSize = 12 * d; letterSpacing = 0.12f; typeface = android.graphics.Typeface.MONOSPACE
        })
        var y = (24 * d).toInt() + gap
        tiles.forEach { row ->
            var x = gap
            row.forEach { canvas.drawBitmap(it, x.toFloat(), y.toFloat(), null); x += it.width + gap }
            y += row.maxOf { it.height } + gap
        }
        File(out, "$file.png").outputStream().use { sheetBmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    private suspend fun render(size: DpSize, d: Float, content: @Composable () -> Unit): Bitmap {
        val rv = GlanceRemoteViews().compose(context, size) { content() }.remoteViews
        val parent = FrameLayout(context)
        val view = rv.apply(context, parent)
        parent.addView(view)
        val w = (size.width.value * d).toInt()
        val h = (size.height.value * d).toInt()
        parent.measure(View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(h, View.MeasureSpec.EXACTLY))
        parent.layout(0, 0, w, h)
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        parent.draw(Canvas(bmp))
        // Software drawing ignores the launcher's clip to its corners: cut them as a Pixel launcher would (~24 dp).
        val clipped = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        Canvas(clipped).apply {
            val r = 24 * d
            drawRoundRect(0f, 0f, w.toFloat(), h.toFloat(), r, r, Paint(Paint.ANTI_ALIAS_FLAG))
            drawBitmap(bmp, 0f, 0f, Paint().apply { xfermode = android.graphics.PorterDuffXfermode(android.graphics.PorterDuff.Mode.SRC_IN) })
        }
        return clipped
    }
}
