package site.table1.events.insights

import java.time.LocalDate
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.roundToLong
import kotlin.math.sqrt

/**
 * Insights chart maths (contract/insights-2026-10-24.md). The same answers as the Python reference
 * testdata/insight-charts/make_cases.py, iOS InsightCharts.swift and the web's insightCharts.ts; InsightChartsTest
 * checks this file against its cases.
 */
object InsightCharts {
    /** 1, 2, 2.5 or 5 × a power of ten: the smallest at least [raw]. */
    fun niceStep(raw: Double): Double {
        if (raw <= 0) return 1.0
        val base = 10.0.pow(floor(log10(raw)))
        for (m in listOf(1.0, 2.0, 2.5, 5.0, 10.0)) if (m * base >= raw - 1e-12) return (m * base * 1e12).roundToLong() / 1e12
        return 10 * base
    }

    /** Evenly spaced round values covering lo…hi with about [count] intervals; lo == hi widens to one step. */
    fun ticks(lo0: Double, hi0: Double, count: Int): List<Double> {
        val lo = min(lo0, hi0)
        var hi = max(lo0, hi0)
        if (hi == lo) hi = lo + (if (abs(lo) * 0.1 == 0.0) 1.0 else abs(lo) * 0.1)
        val step = niceStep((hi - lo) / max(1, count))
        val start = floor(lo / step + 1e-9) * step
        val end = ceil(hi / step - 1e-9) * step
        val n = ((end - start) / step).roundToInt()
        return (0..n).map { ((start + it * step) * 1e10).roundToLong() / 1e10 }
    }

    /** Runs of non-null values as (index, value); a null breaks the line. */
    fun segments(values: List<Double?>): List<List<Pair<Int, Double>>> {
        val out = mutableListOf<List<Pair<Int, Double>>>()
        var cur = mutableListOf<Pair<Int, Double>>()
        values.forEachIndexed { i, v ->
            if (v == null) { if (cur.isNotEmpty()) { out += cur; cur = mutableListOf() } } else cur += i to v
        }
        if (cur.isNotEmpty()) out += cur
        return out
    }

    /** 90% Wilson interval for a win rate; 0…1 with no games. */
    /** A matchup grid cell: its number, tone and fill strength. Under [minimum] matches it still shows, dimmed: half
     *  the fill and muted text (testdata/insight-charts make_cases.py `heat`). */
    data class Heat(val label: String, val tone: String, val strength: Double, val dim: Boolean, val ink: Boolean)
    fun heat(wins: Int, losses: Int, minimum: Int = 30): Heat {
        val n = wins + losses
        if (n == 0) return Heat("", "none", 0.0, dim = false, ink = false)
        val wr = wins.toDouble() / n
        val d = wr - 0.5
        val tone = if (kotlin.math.abs(d) < 0.03) "even" else if (d > 0) "up" else "down"
        val dim = n < minimum
        val strength = (if (tone == "even") 0.0 else min(1.0, 0.25 + kotlin.math.abs(d) * 4)) * (if (dim) 0.5 else 1.0)
        return Heat(kotlin.math.floor(wr * 100 + 0.5).toInt().toString(), tone, Math.round(strength * 10000) / 10000.0, dim,
            ink = kotlin.math.abs(d) >= 0.08 && !dim)
    }

    fun wilson(wins: Int, n: Int, z: Double = 1.6449): Pair<Double, Double> {
        if (n <= 0) return 0.0 to 1.0
        val nn = n.toDouble(); val p = wins / nn; val d = 1 + z * z / nn
        val c = (p + z * z / (2 * nn)) / d
        val h = z * sqrt(p * (1 - p) / nn + z * z / (4 * nn * nn)) / d
        return max(0.0, c - h) to min(1.0, c + h)
    }

    /** Least-squares line y = a + b·x; null with fewer than two distinct x. */
    fun fit(xs: List<Double>, ys: List<Double>): Pair<Double, Double>? {
        if (xs.size < 2) return null
        val mx = xs.average(); val my = ys.average()
        val sxx = xs.sumOf { (it - mx) * (it - mx) }
        if (sxx == 0.0) return null
        val b = xs.indices.sumOf { (xs[it] - mx) * (ys[it] - my) } / sxx
        return (my - b * mx) to b
    }

    /** End labels at screen ys (down is larger) moved apart to at least [gap] and kept inside lo…hi, in input order. */
    fun spread(ys: List<Double>, gap: Double, lo: Double, hi: Double): List<Double> {
        if (ys.isEmpty()) return emptyList()
        val order = ys.indices.sortedWith(compareBy<Int>({ ys[it] }, { it }))
        val pos = DoubleArray(ys.size)
        var prev: Double? = null
        for (i in order) {
            val y = prev?.let { max(ys[i], it + gap) } ?: max(ys[i], lo)
            pos[i] = y; prev = y
        }
        val over = pos[order.last()] - hi
        if (over > 0) {
            var next: Double? = null
            for (i in order.reversed()) {
                val y = next?.let { min(pos[i], it - gap) } ?: (pos[i] - over)
                pos[i] = max(lo, y); next = pos[i]
            }
        }
        return pos.toList()
    }

    /** 21% / 3.4% (under 10% keeps one decimal), as the briefs write shares. */
    fun pct(x: Double?): String = when {
        x == null -> "–"
        x >= 0.0995 || x == 0.0 -> "${(x * 100).roundToInt()}%"
        else -> String.format(java.util.Locale.US, "%.1f%%", x * 100)
    }

    /** 57.1%: win rates keep one decimal. */
    fun pct1(x: Double?): String = if (x == null) "–" else String.format(java.util.Locale.US, "%.1f%%", x * 100)

    /** +2.1 / -12: a change in percentage points; under 10 keeps one decimal. */
    fun delta(d: Double?): String {
        if (d == null) return ""
        val v = abs(d * 100)
        return (if (d >= 0) "+" else "-") + (if (v >= 10) v.roundToInt().toString() else String.format(java.util.Locale.US, "%.1f", v))
    }

    private val MONTHS = listOf("JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC")

    /** Index and upper-case month of each month's first day in a daily series from [start] (yyyy-mm-dd). */
    fun months(start: String, days: Int): List<Pair<Int, String>> {
        val d0 = runCatching { LocalDate.parse(start.take(10)) }.getOrNull() ?: return emptyList()
        return (0 until max(0, days)).mapNotNull { i -> d0.plusDays(i.toLong()).let { if (it.dayOfMonth == 1) i to MONTHS[it.monthValue - 1] else null } }
    }

    data class SeriesWindow(val offset: Int, val from: String, val days: Int, val labels: List<Pair<Int, String>>)

    /**
     * The last [keep] days of a daily series of [days] from [start] (the chart follows the picked 7/14/30/90-day window):
     * where to cut, the new first day, its length and axis labels: months past 45 days, else a day label every
     * (n + 2) / 4 days counted back from the last day, so the newest day is always labelled.
     */
    fun window(start: String, days: Int, keep: Int): SeriesWindow {
        val offset = max(0, days - keep)
        val n = days - offset
        val d0 = runCatching { LocalDate.parse(start.take(10)) }.getOrNull()?.plusDays(offset.toLong())
            ?: return SeriesWindow(offset, start, n, emptyList())
        val from = d0.toString()
        if (n > 45) return SeriesWindow(offset, from, n, months(from, n))
        val step = max(1, (n + 2) / 4)
        val labels = (n - 1 downTo 0 step step).map { i -> i to shortDay(d0.plusDays(i.toLong()).toString()) }.reversed()
        return SeriesWindow(offset, from, n, labels)
    }

    /** "MAY 18" for a yyyy-mm-dd. */
    fun shortDay(iso: String): String = runCatching { LocalDate.parse(iso.take(10)) }.getOrNull()
        ?.let { "${MONTHS[it.monthValue - 1]} ${it.dayOfMonth}" } ?: iso

    /** Days from [from] to [to] (yyyy-mm-dd). */
    fun daysBetween(from: String, to: String): Int? = runCatching {
        java.time.temporal.ChronoUnit.DAYS.between(LocalDate.parse(from.take(10)), LocalDate.parse(to.take(10))).toInt()
    }.getOrNull()
}
