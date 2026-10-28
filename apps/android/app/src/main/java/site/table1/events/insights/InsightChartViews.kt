package site.table1.events.insights

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import site.table1.events.ui.components.Label
import site.table1.events.ui.theme.T1
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/* Insights charts in the Table 1 look: hairline axes on the surface, mono labels, no fills or shadows, grey for context
   and teal only for the series the brief is about. Positions come from InsightCharts (shared maths). */

data class LineSeries(val id: String, val label: String, val values: List<Double?>, val highlighted: Boolean = false)
data class ChartMarker(val index: Int, val label: String, val ban: Boolean)

private fun DrawScope.label(tm: TextMeasurer, text: String, x: Float, y: Float, color: Color, size: Int = 9, anchor: String = "start-mid") {
    val r = tm.measure(text, TextStyle(color = color, fontFamily = T1.mono, fontSize = size.sp))
    val dx = when { anchor.startsWith("end") -> -r.size.width.toFloat(); anchor.startsWith("center") -> -r.size.width / 2f; else -> 0f }
    val dy = when { anchor.endsWith("mid") -> -r.size.height / 2f; anchor.endsWith("bottom") -> -r.size.height.toFloat(); else -> 0f }
    drawText(r, topLeft = Offset(x + dx, y + dy))
}

/** Share lines over time with change markers and labels at the line ends. */
@Composable
fun InsightLineChart(series: List<LineSeries>, count: Int, markers: List<ChartMarker> = emptyList(), xLabels: List<Pair<Int, String>> = emptyList(),
                     height: Dp = 190.dp, format: (Double) -> String = InsightCharts::pct, labelWidth: Dp = 96.dp,
                     // endLabels: labels at the line ends; off where a picker under the chart names the lines, so the plot runs to the right edge.
                     endLabels: Boolean = true,
                     // fit: scale the y axis to the values (and the reference) instead of starting at 0, e.g. win rates around 50%.
                     // reference: a dashed line across the chart with its own end label, e.g. the average win rate in scope.
                     fit: Boolean = false, reference: Pair<String, Double>? = null) {
    val tm = rememberTextMeasurer()
    Canvas(Modifier.fillMaxWidth().height(height).background(T1.surface).padding(vertical = 12.dp, horizontal = 8.dp)) {
        val left = 34.dp.toPx(); val right = if (endLabels) labelWidth.toPx() else 2.dp.toPx(); val top = 14.dp.toPx(); val bottom = 18.dp.toPx()
        val w = max(1f, size.width - left - right); val h = max(1f, size.height - top - bottom)
        val all = series.flatMap { s -> s.values.filterNotNull() } + listOfNotNull(reference?.second)
        val yt = if (fit) InsightCharts.ticks(all.minOrNull() ?: 0.0, all.maxOrNull() ?: 1.0, 3)
                 else InsightCharts.ticks(0.0, max(all.maxOrNull() ?: 0.1, 0.05), 3)
        val yMin = yt.firstOrNull() ?: 0.0; val yMax = yt.lastOrNull() ?: 1.0
        fun x(i: Int) = left + w * i / max(1, count - 1)
        fun y(v: Double) = (top + h * (1 - (v - yMin) / max(1e-9, yMax - yMin))).toFloat()
        yt.forEach { t ->
            drawLine(T1.surfaceHover, Offset(left, y(t)), Offset(left + w, y(t)), 1f)
            label(tm, format(t), left - 4, y(t), T1.muted, anchor = "end-mid")
        }
        // kept inside the right edge, which has no end labels to make room when they're off
        xLabels.forEach { (i, l) ->
            val half = tm.measure(l, TextStyle(fontFamily = T1.mono, fontSize = 9.sp)).size.width / 2f
            label(tm, l, min(x(i), size.width - half), size.height, T1.muted, anchor = "center-bottom")
        }
        markers.filter { it.index in 0 until count }.forEach { m ->
            val c = if (m.ban) T1.warning else T1.disabled
            drawLine(c, Offset(x(m.index), top), Offset(x(m.index), top + h), 1f, pathEffect = PathEffect.dashPathEffect(floatArrayOf(6f, 6f)))
            label(tm, m.label, x(m.index) + 3, 0f, if (m.ban) T1.warning else T1.muted, 8, "start-top")
        }
        reference?.let { (_, v) ->
            drawLine(T1.text, Offset(left, y(v)), Offset(left + w, y(v)), 1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(8f, 6f)))
        }
        series.sortedBy { it.highlighted }.forEach { s ->
            val color = if (s.highlighted) T1.accent else T1.muted.copy(alpha = 0.55f)
            InsightCharts.segments(s.values).forEach { seg ->
                if (seg.size == 1) drawCircle(color, 2.dp.toPx(), Offset(x(seg[0].first), y(seg[0].second)))
                else {
                    val p = Path()
                    seg.forEachIndexed { k, (i, v) -> if (k == 0) p.moveTo(x(i), y(v)) else p.lineTo(x(i), y(v)) }
                    drawPath(p, color, style = Stroke(if (s.highlighted) 2.dp.toPx() else 1.dp.toPx()))
                }
            }
        }
        if (!endLabels) return@Canvas
        val ends = series.mapNotNull { s -> s.values.lastOrNull { it != null }?.let { Triple(s.label, it, if (s.highlighted) T1.accent else T1.muted) } } +
            listOfNotNull(reference?.let { Triple(it.first, it.second, T1.text) })
        val ys = InsightCharts.spread(ends.map { y(it.second).toDouble() }, 11.dp.toPx().toDouble(), top.toDouble(), (top + h).toDouble())
        ends.forEachIndexed { k, (l, v, c) -> label(tm, "$l ${format(v)}".take(22), left + w + 6, ys[k].toFloat(), c) }
    }
}

/** One horizontal bar with its value and change. */
@Composable
fun InsightBar(label: String, value: Double, max: Double, min: Double = 0.0, detail: String? = null, change: Double? = null, highlighted: Boolean = false,
               format: (Double) -> String = InsightCharts::pct, reference: Double? = null, onClick: (() -> Unit)? = null) {
    Column(Modifier.fillMaxWidth().background(T1.surface).let { if (onClick != null) it.clickable(onClick = onClick) else it }
        .padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(label, Modifier.weight(1f), color = T1.text, fontFamily = T1.mono, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (change != null && abs(change) >= 0.0005) {
                Text("${if (change > 0) "▲" else "▼"} ${InsightCharts.delta(change).drop(1)}", color = if (change > 0) T1.text else T1.muted, fontFamily = T1.mono, fontSize = 11.sp)
            }
            Text(format(value), color = if (highlighted) T1.accent else T1.text, fontFamily = T1.mono, fontSize = 13.sp)
        }
        Canvas(Modifier.fillMaxWidth().height(4.dp)) {
            val span = max(1e-9, max - min)
            drawRect(T1.surfaceHover)
            drawRect(if (highlighted) T1.accent else T1.muted, size = Size(size.width * ((value - min) / span).coerceIn(0.0, 1.0).toFloat(), size.height))
            if (reference != null) {
                val rx = size.width * ((reference - min) / span).coerceIn(0.0, 1.0).toFloat()
                drawRect(T1.text, topLeft = Offset(rx, 0f), size = Size(1.dp.toPx(), size.height))
            }
        }
        if (detail != null) Label(detail)
    }
}

data class SlopeRow(val id: Int, val label: String, val before: Double, val after: Double, val highlighted: Boolean)

/** Before → after for a ban study. */
@Composable
fun InsightSlopeChart(rows: List<SlopeRow>, leftTitle: String, rightTitle: String, height: Dp = 200.dp) {
    val tm = rememberTextMeasurer()
    Canvas(Modifier.fillMaxWidth().height(height).background(T1.surface).padding(12.dp)) {
        val top = 20.dp.toPx(); val bottom = 8.dp.toPx(); val labelW = min(130.dp.toPx(), size.width * 0.34f)
        val x0 = labelW + 4; val x1 = size.width - labelW - 4; val h = max(1f, size.height - top - bottom)
        val maxV = max(0.05, rows.flatMap { listOf(it.before, it.after) }.maxOrNull() ?: 0.05)
        fun y(v: Double) = (top + h * (1 - v / maxV)).toFloat()
        label(tm, leftTitle.uppercase(), x0, 0f, T1.muted, anchor = "center-top")
        label(tm, rightTitle.uppercase(), x1, 0f, T1.muted, anchor = "center-top")
        listOf(x0, x1).forEach { drawLine(T1.surfaceHover, Offset(it, top), Offset(it, top + h), 1f) }
        val ly = InsightCharts.spread(rows.map { y(it.before).toDouble() }, 12.dp.toPx().toDouble(), top.toDouble(), (top + h).toDouble())
        val ry = InsightCharts.spread(rows.map { y(it.after).toDouble() }, 12.dp.toPx().toDouble(), top.toDouble(), (top + h).toDouble())
        rows.forEachIndexed { k, r ->
            val c = if (r.highlighted) T1.accent else T1.muted.copy(alpha = 0.6f)
            drawLine(c, Offset(x0, y(r.before)), Offset(x1, y(r.after)), if (r.highlighted) 2.dp.toPx() else 1.dp.toPx())
            val name = if (r.label.length > 15) r.label.take(14) + "…" else r.label
            label(tm, "$name ${InsightCharts.pct(r.before)}", x0 - 6, ly[k].toFloat(), if (r.highlighted) T1.accent else T1.muted, anchor = "end-mid")
            label(tm, InsightCharts.pct(r.after), x1 + 6, ry[k].toFloat(), if (r.highlighted) T1.accent else T1.muted)
        }
    }
}

data class ScatterPoint(val id: String, val label: String, val x: Double, val y: Double)

/** Win rate against how late a card is taken, with the fitted line: above it is underdrafted. */
@Composable
fun InsightScatter(points: List<ScatterPoint>, height: Dp = 240.dp, onTap: (ScatterPoint) -> Unit = {}) {
    val tm = rememberTextMeasurer()
    val f = InsightCharts.fit(points.map { it.x }, points.map { it.y })
    fun res(p: ScatterPoint) = f?.let { p.y - (it.first + it.second * p.x) } ?: 0.0
    val ranked = points.sortedByDescending { res(it) }
    val named = (ranked.take(3) + ranked.takeLast(2)).map { it.id }.toSet()
    val xt = InsightCharts.ticks(points.minOf { it.x }, points.maxOf { it.x }, 4)
    val yt = InsightCharts.ticks(points.minOf { it.y }, points.maxOf { it.y }, 4)
    Canvas(Modifier.fillMaxWidth().height(height).background(T1.surface).padding(12.dp).pointerInput(points) {
        detectTapGestures { o ->
            val left = 36.dp.toPx(); val w = size.width - left - 8.dp.toPx(); val h = size.height - 28.dp.toPx()
            val hit = points.minByOrNull { p ->
                val px = left + w * ((p.x - xt.first()) / (xt.last() - xt.first())); val py = 8.dp.toPx() + h * (1 - (p.y - yt.first()) / (yt.last() - yt.first()))
                (px - o.x) * (px - o.x) + (py - o.y) * (py - o.y)
            }
            hit?.let(onTap)
        }
    }) {
        val left = 36.dp.toPx(); val bottom = 20.dp.toPx(); val top = 8.dp.toPx()
        val w = size.width - left - 8.dp.toPx(); val h = size.height - top - bottom
        fun sx(v: Double) = (left + w * ((v - xt.first()) / max(1e-9, xt.last() - xt.first()))).toFloat()
        fun sy(v: Double) = (top + h * (1 - (v - yt.first()) / max(1e-9, yt.last() - yt.first()))).toFloat()
        yt.forEach { t -> drawLine(T1.surfaceHover, Offset(left, sy(t)), Offset(left + w, sy(t)), 1f); label(tm, InsightCharts.pct(t), left - 4, sy(t), T1.muted, anchor = "end-mid") }
        xt.forEach { t -> label(tm, if (t == Math.rint(t)) t.toInt().toString() else "%.1f".format(t), sx(t), top + h + 4, T1.muted, anchor = "center-top") }
        f?.let { (a, b) -> drawLine(T1.text, Offset(sx(xt.first()), sy(a + b * xt.first())), Offset(sx(xt.last()), sy(a + b * xt.last())), 1f,
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(8f, 6f))) }
        points.forEach { p ->
            val r = res(p)
            val c = if (r >= 0.02) T1.accent else if (r <= -0.02) T1.error else T1.muted.copy(alpha = 0.6f)
            drawRect(c, topLeft = Offset(sx(p.x) - 2.5.dp.toPx(), sy(p.y) - 2.5.dp.toPx()), size = Size(5.dp.toPx(), 5.dp.toPx()))
            if (p.id in named) label(tm, p.label, sx(p.x) + 5.dp.toPx(), sy(p.y), c)
        }
    }
}

/** Matchup grid: the row archetype's match win rate against each column; under [minMatches] a cell still shows, dimmed. */
@Composable
fun InsightHeatmap(labels: List<String>, cell: (Int, Int) -> Pair<Int, Int>?, minMatches: Int = 30, onTap: (Int, Int) -> Unit = { _, _ -> }) {
    Box(Modifier.horizontalScroll(rememberScrollState())) {
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            labels.forEachIndexed { r, row ->
                Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    Text(row, Modifier.width(100.dp).height(34.dp).background(T1.surface).padding(horizontal = 6.dp, vertical = 4.dp),
                        color = T1.text, fontFamily = T1.mono, fontSize = 10.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    labels.indices.forEach { c ->
                        val v = if (r == c) null else cell(r, c)
                        val h = InsightCharts.heat(v?.first ?: 0, v?.second ?: 0, minMatches)
                        val bg = when (h.tone) {
                            "none" -> T1.surface
                            "even" -> T1.surfaceHover
                            else -> (if (h.tone == "up") T1.accent else T1.error).copy(alpha = h.strength.toFloat())
                        }
                        Box(Modifier.width(40.dp).height(34.dp).background(bg).clickable(enabled = r != c) { onTap(r, c) }, contentAlignment = Alignment.Center) {
                            if (h.label.isNotEmpty()) Text(h.label, color = if (h.ink) T1.ink else if (h.dim) T1.muted else T1.text, fontFamily = T1.mono, fontSize = 10.sp)
                        }
                    }
                }
            }
        }
    }
}
