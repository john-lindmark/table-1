package site.table1.events.widgets

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Typeface
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalContext
import androidx.glance.action.Action
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ColumnScope
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxHeight
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.Text
import androidx.glance.text.TextAlign
import site.table1.events.insights.InsightCharts
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.min

/* What the Insights widgets draw (contract/widgets-2026-10-22.md § Meta widgets), on a pack passed in so the gallery
   test (WidgetGalleryTest) can draw them. iOS's Shared/MetaWidgetViews.swift at 2×2 / 4×2 / 4×4; Android widgets
   resize freely, so each also has a one-row strip and a tall narrow layout. Each archetype keeps its color across the
   three: its place among the window's eight largest (MetaWidgets.slots). */

/** The eight categorical colors (dataviz reference palette, dark steps, validated on #171725), and grey past them. */
internal object MetaPalette {
    val colors = listOf(0xFF3987E5, 0xFFD95926, 0xFF199E70, 0xFFC98500, 0xFFD55181, 0xFF008300, 0xFF9085E9, 0xFFE66767).map { Color(it) }
    val none = Color(0xFF6E6E7E)
    fun color(slot: Int?): Color = slot?.let { colors.getOrNull(it) } ?: none
}

private object MetaLook {
    val hover = Color(0xFF33334A)
    /** Library Error pink, the matchup grid's "down" (as the Insights tab). */
    val down = Color(0xFFF2A3E5)
    fun fill(h: InsightCharts.Heat): Color = when (h.tone) {
        "none" -> W1.surface
        "even" -> hover
        else -> (if (h.tone == "up") W1.accent else down).copy(alpha = h.strength.toFloat())
    }
    fun ink(h: InsightCharts.Heat): Color = if (h.ink) W1.ink else if (h.dim) W1.muted else W1.text
    fun tone(h: InsightCharts.Heat): Color = when (h.tone) { "up" -> W1.accent; "down" -> down; else -> W1.text }
}

@Composable
private fun MT(text: String, size: TextUnit = 12.sp, color: Color = W1.text, bold: Boolean = false, lines: Int = 1,
               modifier: GlanceModifier = GlanceModifier, end: Boolean = false) =
    Text(text, modifier, style = W1.style(size, color, bold).copy(textAlign = if (end) TextAlign.End else TextAlign.Start), maxLines = lines)

@Composable
private fun VGap(h: Dp = 4.dp) = Spacer(GlanceModifier.height(h))

@Composable
private fun WGap(w: Dp) = Spacer(GlanceModifier.width(w))

@Composable
private fun Swatch(slot: Int?, size: Dp = 8.dp) = Box(GlanceModifier.size(size).background(MetaPalette.color(slot))) {}

/** The pack hasn't arrived yet (first run offline). */
@Composable
private fun ColumnScope.MetaEmpty(shape: WShape, picks: MetaPicks) {
    Label("Insights", W1.accent)
    if (!shape.strip) Spacer(GlanceModifier.defaultWeight()) else VGap(2.dp)
    MT("${MetaFormats.name(picks.format)} loads when you're online", if (shape.strip) 12.sp else 13.sp, lines = 3)
}

/** Shares as one bar: each archetype in its color, the rest grey, 2 dp apart. */
@Composable
private fun ShareBar(rows: List<MetaWidgets.Row>, rest: Double, width: Dp, height: Dp = 6.dp) {
    val parts = rows.map { it.share to MetaPalette.color(it.slot) } + (rest to W1.surface)
    val room = width.value - 2f * (parts.size - 1)
    val total = parts.sumOf { it.first }.coerceAtLeast(1e-9)
    Row(GlanceModifier.fillMaxWidth().height(height)) {
        parts.forEachIndexed { i, (share, color) ->
            if (i > 0) WGap(2.dp)
            Box(GlanceModifier.width((room * (share / total)).toFloat().coerceAtLeast(0f).dp).fillMaxHeight().background(color)) {}
        }
    }
}

/** The share lines, drawn as a bitmap at about the size they show (Glance draws no paths). */
@Composable
private fun MetaChart(chart: MetaWidgets.Chart, width: Dp, height: Dp, modifier: GlanceModifier) {
    val density = LocalContext.current.resources.displayMetrics.density
    val w = (width.value.coerceAtLeast(60f) * density).toInt()
    val h = (height.value.coerceAtLeast(40f) * density).toInt()
    Image(ImageProvider(chartBitmap(chart, w, h, density)), "Meta over time", modifier, contentScale = ContentScale.FillBounds)
}

internal fun chartBitmap(chart: MetaWidgets.Chart, w: Int, h: Int, density: Float): Bitmap {
    val b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
    val c = Canvas(b)
    val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = W1.muted.toArgb(); textSize = 8 * density; typeface = Typeface.MONOSPACE }
    val grid = Paint().apply { color = W1.surface.toArgb(); strokeWidth = density }
    val left = 26 * density; val bottom = 12 * density; val top = 4 * density
    val pw = (w - left).coerceAtLeast(1f); val ph = (h - bottom - top).coerceAtLeast(1f)
    val ticks = InsightCharts.ticks(0.0, maxOf(chart.top, 0.05), 2)
    val yMax = ticks.lastOrNull() ?: 1.0
    fun x(i: Int) = left + pw * i / maxOf(1, chart.days - 1)
    fun y(v: Double) = top + ph * (1 - (v / yMax).toFloat())
    for (t in ticks) {
        c.drawLine(left, y(t), w.toFloat(), y(t), grid)
        val l = InsightCharts.pct(t)
        c.drawText(l, left - 4 * density - text.measureText(l), y(t) + 3 * density, text)
    }
    // Dates, newest first, each kept only when it clears the one to its right.
    var lastX = Float.MAX_VALUE
    for ((i, l) in chart.labels.reversed()) {
        if (lastX - x(i) < 52 * density) continue
        val tw = text.measureText(l)
        val cx = x(i).coerceIn(left + tw / 2, w - tw / 2)
        c.drawText(l, cx - tw / 2, h - 2 * density, text)
        lastX = x(i)
    }
    // The largest on top.
    for (line in chart.lines.reversed()) {
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = MetaPalette.color(line.slot).toArgb(); style = Paint.Style.STROKE; strokeWidth = 1.5f * density
            strokeJoin = Paint.Join.ROUND; strokeCap = Paint.Cap.ROUND
        }
        val path = Path()
        for (seg in InsightCharts.segments(line.v)) seg.forEachIndexed { k, (i, v) ->
            if (k == 0) path.moveTo(x(i), y(v)) else path.lineTo(x(i), y(v))
        }
        c.drawPath(path, p)
    }
    return b
}

private fun pctOf(share: Double) = InsightCharts.pct(share)

// ─────────────────────────────────────────────── Meta breakdown

@Composable
internal fun MetaContent(pack: MetaPack?, picks: MetaPicks, size: DpSize, tap: Action) {
    val shape = WShape.of(size)
    WidgetFrame(shape, tap) {
        val tier = pack?.let(picks::tier)
        val rowsWanted = when (shape) {
            WShape.STRIP -> 1; WShape.WIDE_STRIP -> 3; WShape.SMALL, WShape.MEDIUM -> 5
            else -> floor((size.height.value - (if (shape.wide) 200f else 220f)) / 19f).toInt().coerceIn(3, 8)
        }
        val b = if (pack != null && tier != null) MetaWidgets.breakdown(pack, tier, picks.days, rowsWanted) else null
        if (pack == null || tier == null || b == null || b.rows.isEmpty()) { MetaEmpty(shape, picks); return@WidgetFrame }
        val inner = size.width - (if (shape.strip) 28.dp else 32.dp)
        val chart = MetaWidgets.chart(pack, tier, picks.days, b.rows.map { it.a })

        @Composable
        fun Line(r: MetaWidgets.Row, text: TextUnit = 11.sp, extra: Boolean = false) =
            Row(GlanceModifier.fillMaxWidth().height(if (extra) 17.dp else 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Swatch(r.slot)
                WGap(6.dp)
                MT(r.name, text, modifier = GlanceModifier.defaultWeight())
                if (extra) {
                    r.delta?.let { d -> MT((if (d >= 0) "▲" else "▼") + InsightCharts.delta(d).drop(1), 10.sp, if (d >= 0) W1.accent else MetaLook.down, modifier = GlanceModifier.width(44.dp), end = true) }
                    r.wr?.let { MT("W ${(it * 100).let(Math::round)}%", 10.sp, W1.muted, modifier = GlanceModifier.width(48.dp), end = true) }
                }
                MT(pctOf(r.share), text, bold = true, modifier = GlanceModifier.width(44.dp), end = true)
            }

        @Composable
        fun Header() = Row(GlanceModifier.fillMaxWidth()) {
            Label(picks.label(tier), modifier = GlanceModifier.defaultWeight())
            Label("${"%,d".format(b.decks)} decks")
        }

        when (shape) {
            WShape.STRIP -> {
                Label(picks.label(tier))
                VGap(4.dp)
                ShareBar(b.rows, b.rest, inner, 5.dp)
                VGap(4.dp)
                Line(b.rows[0])
            }
            WShape.WIDE_STRIP -> Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(GlanceModifier.width(inner * 0.42f)) {
                    Label(picks.label(tier))
                    VGap(4.dp)
                    ShareBar(b.rows, b.rest, inner * 0.42f, 5.dp)
                }
                WGap(12.dp)
                Column(GlanceModifier.defaultWeight()) { b.rows.take(2).forEach { Line(it, 10.sp) } }
            }
            WShape.SMALL -> {
                Label(picks.label(tier))
                VGap(7.dp)
                ShareBar(b.rows, b.rest, inner)
                VGap(6.dp)
                Column(GlanceModifier.fillMaxWidth()) { b.rows.forEach { Line(it) } }
            }
            WShape.MEDIUM -> {
                Header()
                VGap(8.dp)
                Row(GlanceModifier.fillMaxSize()) {
                    Column(GlanceModifier.width(156.dp)) {
                        ShareBar(b.rows, b.rest, 156.dp, 5.dp)
                        VGap(4.dp)
                        b.rows.forEach { Line(it, 10.sp) }
                    }
                    WGap(12.dp)
                    MetaChart(chart, inner - 168.dp, size.height - 60.dp, GlanceModifier.defaultWeight().fillMaxHeight())
                }
            }
            else -> {
                Header()
                VGap(8.dp)
                MetaChart(chart, inner, 140.dp, GlanceModifier.fillMaxWidth().height(140.dp))
                VGap(8.dp)
                ShareBar(b.rows, b.rest, inner)
                VGap(6.dp)
                Column(GlanceModifier.fillMaxWidth()) { b.rows.forEach { Line(it, extra = shape.wide) } }
            }
        }
    }
}

// ─────────────────────────────────────────────── Matchup grid

@Composable
internal fun MatchupGridContent(pack: MetaPack?, picks: MetaPicks, size: DpSize, tap: Action) {
    val shape = WShape.of(size)
    WidgetFrame(shape, tap) {
        if (pack == null) { MetaEmpty(shape, picks); return@WidgetFrame }
        val tier = picks.tier(pack)
        val inner = size.width - (if (shape.strip) 28.dp else 32.dp)
        val nameWidth = if (shape.wide) 104.dp else 34.dp
        // Squares at least 26 dp wide; at most nine columns (Glance draws ten children in a row).
        val cols = floor((inner.value - nameWidth.value) / 28f).toInt().coerceIn(1, 9)
        val rows = if (shape.strip) 1 else floor((size.height.value - 32f - 18f - 16f) / 20f).toInt().coerceIn(1, 14)
        val g = MetaWidgets.grid(pack, tier, picks.days, rows, cols)
        Label(if (shape.wide) "Matchups · ${picks.label(tier)}" else MetaFormats.short(picks.format))
        VGap(4.dp)
        if (g.rows.isEmpty() || g.cols.isEmpty()) { MT("No matchups in this window", 12.sp, W1.muted); return@WidgetFrame }
        val cellW = ((inner.value - nameWidth.value - 2f * g.cols.size) / g.cols.size).dp
        // Glance draws at most ten children in a row or column: spacing is padding, rows go in groups.
        Row(GlanceModifier.fillMaxWidth()) {
            Spacer(GlanceModifier.width(nameWidth))
            g.cols.forEach { c ->
                Column(GlanceModifier.width(cellW + 2.dp).padding(start = 2.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    MT(c.code, 8.sp, W1.muted)
                    VGap(2.dp)
                    Box(GlanceModifier.width(cellW).height(2.dp).background(MetaPalette.color(c.slot))) {}
                }
            }
        }
        val rowH = ((size.height.value - 32f - 18f - 16f) / rows - 2f).coerceIn(16f, 24f).dp
        Column(GlanceModifier.fillMaxWidth()) {
            g.rows.indices.chunked(8).forEach { chunk ->
                Column(GlanceModifier.fillMaxWidth()) {
                    chunk.forEach { i ->
                        Row(GlanceModifier.fillMaxWidth().height(rowH + 2.dp).padding(top = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                            Row(GlanceModifier.width(nameWidth), verticalAlignment = Alignment.CenterVertically) {
                                Swatch(g.rows[i].slot, 6.dp)
                                WGap(4.dp)
                                MT(if (shape.wide) g.rows[i].name else MetaWidgets.codes(listOf(g.rows[i].name))[0], 9.sp)
                            }
                            g.cells[i].forEach { h ->
                                Box(GlanceModifier.width(cellW + 2.dp).fillMaxHeight().padding(start = 2.dp)) {
                                    Box(GlanceModifier.fillMaxSize().background(h?.let(MetaLook::fill) ?: W1.bg), contentAlignment = Alignment.Center) {
                                        if (h != null) MT(h.label, 9.sp, MetaLook.ink(h), bold = h.ink)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// ─────────────────────────────────────────────── One archetype's matchups

@Composable
internal fun ArchetypeContent(pack: MetaPack?, picks: MetaPicks, size: DpSize, tap: Action) {
    val shape = WShape.of(size)
    WidgetFrame(shape, tap) {
        val a = pack?.let { MetaWidgets.archetypeFor(it, picks) }
        if (pack == null || a == null) { MetaEmpty(shape, picks); return@WidgetFrame }
        val tier = picks.tier(pack)
        val m = MetaWidgets.matchups(pack, tier, picks.days, a)
        val byId = m.rows.associateBy { it.vs }
        val good = m.good.mapNotNull(byId::get)
        val bad = m.bad.mapNotNull(byId::get)
        val win = m.wr?.let { "Win ${InsightCharts.pct1(it)}" } ?: "Win –"
        val sub = m.share?.let { "${pctOf(it)} of the meta" } ?: "Not played this window"

        @Composable
        fun Title(textSize: TextUnit, lines: Int) = Column {
            Label(picks.label(tier))
            VGap(4.dp)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Swatch(m.slot)
                WGap(6.dp)
                MT(m.name, textSize, bold = true, lines = lines)
            }
        }

        @Composable
        fun Matchup(r: MetaWidgets.MatchupRow, lead: String? = null) =
            Row(GlanceModifier.fillMaxWidth().height(16.dp), verticalAlignment = Alignment.CenterVertically) {
                lead?.let { Label(it, modifier = GlanceModifier.width(44.dp)) }
                Swatch(r.slot, 6.dp)
                WGap(5.dp)
                MT(if (lead != null) MetaWidgets.codes(listOf(r.name))[0] else r.name, 10.sp, modifier = GlanceModifier.defaultWeight())
                MT("${r.heat.label}%", 10.sp, MetaLook.tone(r.heat), bold = true)
            }

        when (shape) {
            WShape.STRIP, WShape.WIDE_STRIP -> Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(GlanceModifier.defaultWeight()) {
                    Row(verticalAlignment = Alignment.CenterVertically) { Swatch(m.slot); WGap(6.dp); MT(m.name, 12.sp, bold = true) }
                    VGap(2.dp)
                    Label(sub)
                }
                WGap(10.dp)
                MT(win, if (shape.wide) 18.sp else 14.sp, bold = true)
            }
            WShape.SMALL -> {
                Title(13.sp, 2)
                Spacer(GlanceModifier.defaultWeight())
                MT(win, 20.sp, bold = true)
                Label(sub)
                VGap(6.dp)
                good.firstOrNull()?.let { Matchup(it, "Best") }
                bad.firstOrNull()?.let { Matchup(it, "Worst") }
            }
            WShape.MEDIUM -> Row(GlanceModifier.fillMaxSize()) {
                Column(GlanceModifier.width(140.dp).fillMaxHeight()) {
                    Title(13.sp, 2)
                    Spacer(GlanceModifier.defaultWeight())
                    MT(win, 20.sp, bold = true)
                    Label(sub)
                    m.record?.takeIf { it.size == 3 }?.let { VGap(2.dp); Label("${it[0]}-${it[1]}-${it[2]}") }
                }
                WGap(14.dp)
                Column(GlanceModifier.defaultWeight().fillMaxHeight()) {
                    Label("Good against")
                    VGap(2.dp)
                    if (good.isEmpty()) MT("Nothing clear yet", 10.sp, W1.muted)
                    good.forEach { Matchup(it) }
                    Spacer(GlanceModifier.defaultWeight())
                    Label("Bad against")
                    VGap(2.dp)
                    if (bad.isEmpty()) MT("Nothing clear yet", 10.sp, W1.muted)
                    bad.forEach { Matchup(it) }
                }
            }
            else -> {
                Title(15.sp, 1)
                VGap(4.dp)
                Row(verticalAlignment = Alignment.Bottom) {
                    MT(win, 22.sp, bold = true)
                    WGap(10.dp)
                    Label(sub)
                }
                VGap(6.dp)
                Box(GlanceModifier.fillMaxWidth().height(1.dp).background(W1.surface)) {}
                val fit = floor((size.height.value - 32f - 110f) / 19f).toInt().coerceIn(1, 14)
                if (m.rows.isEmpty()) { VGap(6.dp); MT("Not enough matches against other archetypes yet", 12.sp, W1.muted, lines = 2) }
                val barW = if (shape.wide) 70f else 44f
                // Grouped: Glance draws at most ten children in a column.
                Column(GlanceModifier.fillMaxWidth()) {
                    m.rows.take(fit).chunked(9).forEach { chunk ->
                        Column(GlanceModifier.fillMaxWidth()) {
                            chunk.forEach { r ->
                                Row(GlanceModifier.fillMaxWidth().height(19.dp).padding(top = 3.dp), verticalAlignment = Alignment.CenterVertically) {
                                    Swatch(r.slot, 6.dp)
                                    WGap(6.dp)
                                    MT(r.name, 10.sp, modifier = GlanceModifier.defaultWeight())
                                    // One matchup as a bar from 50%: right in the accent, left in pink (25–75% full).
                                    val half = barW / 2
                                    val d = (min(0.25, abs(r.wr - 0.5)) / 0.25 * half).toFloat().coerceAtLeast(1f)
                                    val color = (if (r.wr >= 0.5) W1.accent else MetaLook.down).copy(alpha = if (r.heat.dim) 0.5f else 1f)
                                    Row(GlanceModifier.width((barW + 4).dp).height(6.dp).padding(start = 4.dp)) {
                                        if (r.wr >= 0.5) { Spacer(GlanceModifier.width(half.dp)); Box(GlanceModifier.width(d.dp).fillMaxHeight().background(color)) {} }
                                        else { Spacer(GlanceModifier.width((half - d).dp)); Box(GlanceModifier.width(d.dp).fillMaxHeight().background(color)) {} }
                                    }
                                    MT("${r.heat.label}%", 10.sp, if (r.heat.dim) W1.muted else W1.text, bold = true, modifier = GlanceModifier.width(34.dp), end = true)
                                    if (shape.wide) MT("${r.wins + r.losses}", 9.sp, W1.muted, modifier = GlanceModifier.width(34.dp), end = true)
                                }
                            }
                        }
                    }
                }
                Spacer(GlanceModifier.defaultWeight())
                Label(m.title)
            }
        }
    }
}
