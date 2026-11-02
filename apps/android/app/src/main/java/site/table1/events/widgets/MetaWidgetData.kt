package site.table1.events.widgets

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import site.table1.events.insights.InsightCharts
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/* The Insights home screen widgets (contract/widgets-2026-10-22.md § Meta widgets): Meta breakdown, Matchup grid and
   one archetype's matchups. What they show comes from the format's public Insights pack (the file the Insights tab
   reads), cut to the picked events and window by MetaWidgets: the same answers as the Python reference
   testdata/meta-widgets/make_cases.py and iOS's Shared/MetaWidget.swift (MetaWidgetDataTest checks this file). */

/** The parts of a constructed Insights pack the widgets read (contract/insights-2026-10-24.md § Constructed pack). */
@Serializable
data class MetaPack(val format: String, val name: String, val through: String, val archetypes: List<Archetype>,
                    val tiers: Map<String, View>, val matchups: Grid) {
    @Serializable data class Archetype(val id: Int, val name: String)
    @Serializable data class Share(val a: Int, val share: Double, val prev: Double? = null, val wr: Double? = null, val rec: List<Int>? = null)
    @Serializable data class Grid(val archetypes: List<Int>, val cells: List<List<Int>>, val rows: List<Int>? = null)
    @Serializable data class Window(val decks: Int, val share: List<Share>, val matchups: Grid? = null)
    @Serializable data class Line(val a: Int, val v: List<Double?>)
    @Serializable data class Series(val from: String, val days: Int, val lines: List<Line>)
    @Serializable data class View(val windows: Map<String, Window>, val series: Series? = null)

    fun window(tier: String, days: Int): Window? = tiers[tier]?.windows?.get(days.toString())
    fun name(id: Int): String = archetypes.firstOrNull { it.id == id }?.name ?: "Other"
}

/** The formats Insights covers, in its order. */
object MetaFormats {
    val all = listOf("standard" to "Standard", "pioneer" to "Pioneer", "modern" to "Modern", "legacy" to "Legacy",
        "vintage" to "Vintage", "pauper" to "Pauper", "canlander" to "Canadian Highlander")
    fun name(key: String) = all.firstOrNull { it.first == key }?.second ?: key.replaceFirstChar { it.uppercase() }
    /** Short, for a widget's label. */
    fun short(key: String) = if (key == "canlander") "Canlander" else name(key)
}

/** What a widget shows: a format's pack cut to events and window; [archetype] is the archetype widget's (null = most played). */
@Serializable
data class MetaPicks(val format: String = "modern", val tier: String = "big", val days: Int = 30, val archetype: Int? = null) {
    fun tier(pack: MetaPack) = MetaWidgets.tierFor(pack, tier, days)
    /** Opens Insights on the same picks; [what]: null = the format page, `matchups`, `archetype/<id>`. */
    fun link(what: String?, src: String) = "table1://insights/$format${what?.let { "/$it" } ?: ""}?tier=$tier&days=$days&src=$src"
    fun label(tier: String) = "${MetaFormats.short(format)} · ${if (tier == "big") "Big" else "All"} · ${days}D"
}

object MetaWidgets {
    /** The categorical palette's colors; archetypes past the eighth are grey. */
    const val SLOTS = 8

    /** The picked tier when its window has decks, else All events. */
    fun tierFor(pack: MetaPack, want: String, days: Int): String = if ((pack.window(want, days)?.decks ?: 0) > 0) want else "all"

    /** Color slot per archetype: the eight largest named archetypes of the window, largest first; Other has none. */
    fun slots(pack: MetaPack, tier: String, days: Int): Map<Int, Int> =
        (pack.window(tier, days)?.share ?: emptyList()).filter { it.a != 0 }.take(SLOTS).mapIndexed { i, r -> r.a to i }.toMap()

    data class Row(val a: Int, val name: String, val share: Double, val delta: Double?, val wr: Double?, val slot: Int?)
    data class Breakdown(val decks: Int, val rows: List<Row>, val rest: Double)

    /** The n largest named archetypes with share, change on the window before and win rate; `rest` is the remainder. */
    fun breakdown(pack: MetaPack, tier: String, days: Int, n: Int): Breakdown? {
        val w = pack.window(tier, days) ?: return null
        val s = slots(pack, tier, days)
        val rows = w.share.filter { it.a != 0 }.take(n).map { r ->
            Row(r.a, pack.name(r.a), r.share, r.prev?.let { r.share - it }, r.wr, s[r.a])
        }
        return Breakdown(w.decks, rows, maxOf(0.0, 1 - rows.sumOf { it.share }))
    }

    data class ChartLine(val a: Int, val slot: Int?, val v: List<Double?>)
    data class Chart(val days: Int, val lines: List<ChartLine>, val top: Double, val labels: List<Pair<Int, String>> = emptyList())

    /** The share lines of [ids] over the window; archetypes with no line, or no value in it, are left out. */
    fun chart(pack: MetaPack, tier: String, days: Int, ids: List<Int>): Chart {
        val s = pack.tiers[tier]?.series ?: return Chart(0, emptyList(), 0.0)
        val offset = maxOf(0, s.days - days)
        val sl = slots(pack, tier, days)
        val lines = ids.mapNotNull { a ->
            val line = s.lines.firstOrNull { it.a == a } ?: return@mapNotNull null
            val v = line.v.drop(offset)
            if (v.any { it != null }) ChartLine(a, sl[a], v) else null
        }
        val top = lines.flatMap { it.v.filterNotNull() }.maxOrNull() ?: 0.0
        return Chart(s.days - offset, lines, top, InsightCharts.window(s.from, s.days, days).labels)
    }

    private fun words(name: String) = Regex("[A-Za-z0-9]+").findAll(name.replace("'s", "")).map { it.value }.toList()

    /** Short column names: initials (one word: its first three letters); a clash takes the first word's first two
     *  letters and the other initials, then a number. */
    fun codes(names: List<String>): List<String> {
        val out = mutableListOf<String>()
        for (n in names) {
            val w = words(n)
            var c = when {
                w.isEmpty() -> "?"
                w.size == 1 -> w[0].take(3).uppercase()
                else -> w.take(3).joinToString("") { it.take(1) }.uppercase()
            }
            if (c in out) {
                c = when {
                    w.size > 1 -> (w[0].take(2) + w.drop(1).take(2).joinToString("") { it.take(1) }).uppercase()
                    w.isEmpty() -> "?"
                    else -> w[0].take(4).uppercase()
                }
                val base = c
                var k = 2
                while (c in out) { c = "$base$k"; k++ }
            }
            out += c
        }
        return out
    }

    /** The window's grid, else the pack's 90-day All events grid (the Insights tab's rule), with its title. */
    fun gridOf(pack: MetaPack, tier: String, days: Int): Pair<MetaPack.Grid, String> =
        pack.window(tier, days)?.matchups?.let { it to "${if (tier == "big") "Big events" else "All events"}, last $days days" }
            ?: (pack.matchups to "All events, last 90 days")

    fun rowIds(m: MetaPack.Grid) = m.rows?.takeIf { it.isNotEmpty() } ?: m.archetypes

    /** [a] against [b]: wins, losses, draws from a's side. */
    fun cell(m: MetaPack.Grid, a: Int, b: Int): Triple<Int, Int, Int>? {
        for (c in m.cells) {
            if (c.size < 5) continue
            if (c[0] == a && c[1] == b) return Triple(c[2], c[3], c[4])
            if (c[0] == b && c[1] == a) return Triple(c[3], c[2], c[4])
        }
        return null
    }

    data class Col(val a: Int, val name: String, val code: String, val slot: Int?)
    data class GridRow(val a: Int, val name: String, val slot: Int?)
    data class GridView(val title: String, val cols: List<Col>, val rows: List<GridRow>, val cells: List<List<InsightCharts.Heat?>>)

    /** The top-left of the matchup grid that fits: the most played columns and the first rows. A row's own column is
     *  null; a pair with no matches has tone "none". */
    fun grid(pack: MetaPack, tier: String, days: Int, rows: Int, cols: Int): GridView {
        val (m, title) = gridOf(pack, tier, days)
        val sl = slots(pack, tier, days)
        val c = m.archetypes.take(maxOf(0, cols))
        val r = rowIds(m).take(maxOf(0, rows))
        val names = c.map(pack::name)
        val codes = codes(names)
        val cells = r.map { ra ->
            c.map { ca -> if (ra == ca) null else (cell(m, ra, ca) ?: Triple(0, 0, 0)).let { InsightCharts.heat(it.first, it.second) } }
        }
        return GridView(title, c.indices.map { Col(c[it], names[it], codes[it], sl[c[it]]) }, r.map { GridRow(it, pack.name(it), sl[it]) }, cells)
    }

    data class MatchupRow(val vs: Int, val name: String, val slot: Int?, val wins: Int, val losses: Int, val draws: Int,
                          val wr: Double, val heat: InsightCharts.Heat)
    data class Matchups(val a: Int, val name: String, val slot: Int?, val title: String, val share: Double?, val wr: Double?,
                        val record: List<Int>?, val rows: List<MatchupRow>, val good: List<Int>, val bad: List<Int>)

    /** One archetype against every other row of the grid, most played first; pairs with no decided match are left out.
     *  Good / bad against: 20+ decided matches above / below 50%, three each, best (worst) first, then most matches,
     *  never Other.
     *  Share, win rate and record from the window's Meta now row. */
    fun matchups(pack: MetaPack, tier: String, days: Int, a: Int): Matchups {
        val (m, title) = gridOf(pack, tier, days)
        val sl = slots(pack, tier, days)
        val me = pack.window(tier, days)?.share?.firstOrNull { it.a == a }
        val ids = rowIds(m)
        val rows = if (a !in ids) emptyList() else ids.mapNotNull { b ->
            val x = cell(m, a, b)
            if (b == a || x == null || x.first + x.second == 0) null
            else MatchupRow(b, pack.name(b), sl[b], x.first, x.second, x.third, x.first.toDouble() / (x.first + x.second),
                InsightCharts.heat(x.first, x.second))
        }
        val decided = rows.filter { it.wins + it.losses >= 20 && it.vs != 0 }
        val good = decided.filter { it.wr > 0.5 }.sortedWith(compareBy({ -it.wr }, { -(it.wins + it.losses) })).take(3)
        val bad = decided.filter { it.wr < 0.5 }.sortedWith(compareBy({ it.wr }, { -(it.wins + it.losses) })).take(3)
        return Matchups(a, pack.name(a), sl[a], title, me?.share, me?.wr, me?.rec, rows, good.map { it.vs }, bad.map { it.vs })
    }

    /** The archetypes a widget can follow: the 90-day grid's rows (they have matchups), then the other named ones by
     *  name. Never Other. */
    fun choices(pack: MetaPack): List<Int> {
        val rows = rowIds(pack.matchups).filter { it != 0 }
        return rows + pack.archetypes.filter { it.id != 0 && it.id !in rows }.sortedBy { it.name }.map { it.id }
    }

    /** The archetype the widget shows: the picked one when the format has it, else the most played. */
    fun archetypeFor(pack: MetaPack, picks: MetaPicks): Int? {
        val choices = choices(pack)
        picks.archetype?.takeIf { it in choices }?.let { return it }
        return pack.window(picks.tier(pack), picks.days)?.share?.firstOrNull { it.a != 0 }?.a ?: choices.firstOrNull()
    }
}

/**
 * Packs and each widget's picks on the device. Packs are public: a widget fetches its format's at most every 3 hours
 * (they're rebuilt every 6), with If-None-Match and an 8 s limit, into files/widgets/meta-<format>.json. Picks live
 * per widget id in their own preferences, so signing out (which clears `t1.widgets`) keeps a widget's setup.
 */
object MetaPacks {
    private const val PREFS = "t1.widgets.meta"
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private const val BASE = "https://aaozhfcbvqrgkkrihkrd.supabase.co/storage/v1/object/public/catalog/insights/constructed/"
    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun file(context: Context, format: String) = File(context.filesDir, "widgets/meta-$format.json")

    fun decode(raw: String): MetaPack? = runCatching { json.decodeFromString<MetaPack>(raw) }.getOrNull()

    fun load(context: Context, format: String): MetaPack? = file(context, format).takeIf { it.exists() }?.let { decode(it.readText()) }

    /** The held pack, refreshed first when older than [maxAgeMs]; the held one when the network fails. Off the main thread. */
    fun fresh(context: Context, format: String, maxAgeMs: Long = 3 * 3600_000L): MetaPack? {
        val p = prefs(context)
        val held = load(context, format)
        if (held != null && System.currentTimeMillis() - p.getLong("at.$format", 0) < maxAgeMs) return held
        return runCatching {
            val c = (URL(BASE + "$format.json").openConnection() as HttpURLConnection).apply {
                connectTimeout = 8_000; readTimeout = 8_000
                if (held != null) p.getString("etag.$format", null)?.let { setRequestProperty("If-None-Match", it) }
            }
            try {
                when (c.responseCode) {
                    304 -> { p.edit().putLong("at.$format", System.currentTimeMillis()).apply(); held }
                    200 -> {
                        val raw = c.inputStream.bufferedReader().use { it.readText() }
                        val pack = decode(raw) ?: return@runCatching held
                        file(context, format).apply { parentFile?.mkdirs() }.writeText(raw)
                        p.edit().putLong("at.$format", System.currentTimeMillis()).putString("etag.$format", c.getHeaderField("ETag")).apply()
                        pack
                    }
                    else -> held
                }
            } finally { c.disconnect() }
        }.getOrNull() ?: held
    }

    fun picks(context: Context, widgetId: Int): MetaPicks =
        prefs(context).getString("picks.$widgetId", null)?.let { runCatching { json.decodeFromString<MetaPicks>(it) }.getOrNull() } ?: MetaPicks()

    fun savePicks(context: Context, widgetId: Int, picks: MetaPicks) {
        prefs(context).edit().putString("picks.$widgetId", json.encodeToString(MetaPicks.serializer(), picks)).apply()
    }

    fun forget(context: Context, widgetIds: IntArray) {
        prefs(context).edit().apply { widgetIds.forEach { remove("picks.$it") } }.apply()
    }
}
