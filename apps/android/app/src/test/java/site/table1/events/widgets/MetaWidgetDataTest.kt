package site.table1.events.widgets

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import site.table1.events.data.WebLink
import site.table1.events.insights.InsightCharts
import java.io.File

/*
 * The Insights widgets' logic (contract/widgets-2026-10-22.md § Meta widgets) against testdata/meta-widgets/cases.json,
 * written by the Python reference there from the live Modern pack it keeps (modern.json); iOS MetaWidgetTests reads the
 * same files.
 */
class MetaWidgetDataTest {
    @Serializable data class HeatCase(val label: String, val tone: String, val strength: Double, val dim: Boolean, val ink: Boolean)
    @Serializable data class RowCase(val a: Int, val name: String, val share: Double, val delta: Double? = null, val wr: Double? = null, val slot: Int? = null)
    @Serializable data class TierFor(val pack: String, val want: String, val days: Int, val out: String)
    @Serializable data class BreakdownOut(val decks: Int, val rows: List<RowCase>, val rest: Double)
    @Serializable data class Breakdown(val tier: String, val days: Int, val n: Int, val out: BreakdownOut? = null)
    @Serializable data class LineCase(val a: Int, val slot: Int? = null, val v: List<Double?>)
    @Serializable data class ChartOut(val days: Int, val lines: List<LineCase>, val top: Double)
    @Serializable data class Chart(val tier: String, val days: Int, val ids: List<Int>, val out: ChartOut)
    @Serializable data class Codes(val names: List<String>, val out: List<String>)
    @Serializable data class ColCase(val a: Int, val name: String, val code: String, val slot: Int? = null)
    @Serializable data class GRowCase(val a: Int, val name: String, val slot: Int? = null)
    @Serializable data class GridOut(val title: String, val cols: List<ColCase>, val rows: List<GRowCase>, val cells: List<List<HeatCase?>>)
    @Serializable data class Grid(val tier: String, val days: Int, val rows: Int, val cols: Int, val out: GridOut)
    @Serializable data class MRow(val vs: Int, val name: String, val slot: Int? = null, val wins: Int, val losses: Int, val draws: Int, val wr: Double, val heat: HeatCase)
    @Serializable data class MOut(val a: Int, val name: String, val slot: Int? = null, val title: String, val share: Double? = null, val wr: Double? = null,
                                  val record: List<Int>? = null, val rows: List<MRow>, val good: List<Int>, val bad: List<Int>)
    @Serializable data class Matchups(val tier: String, val days: Int, val a: Int, val out: MOut)
    @Serializable data class DetailOut(val title: String, val line: String, val record: String)
    @Serializable data class CellDetailCase(val tier: String, val days: Int, val a: Int, val b: Int, val out: DetailOut? = null)
    @Serializable data class Cases(val slots: Int, val tier_for: List<TierFor>, val breakdown: List<Breakdown>, val chart: List<Chart>,
                                   val codes: List<Codes>, val grid: List<Grid>, val grid_thin: Grid, val matchups: List<Matchups>, val choices: List<Int>,
                                   val cell_detail: List<CellDetailCase>)

    private val dir = generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/meta-widgets") }.first { it.isDirectory }
    private val json = Json { ignoreUnknownKeys = true }
    private val cases = json.decodeFromString<Cases>(File(dir, "cases.json").readText())
    private val raw = File(dir, "modern.json").readText()
    private val pack = MetaPacks.decode(raw)!!

    /** make_cases.py's "thin" pack: Big events' 7 days without decks, no 14 days, All events' windows without grids. */
    private val thin: MetaPack = run {
        val p = pack
        val big = p.tiers.getValue("big")
        val bigW = big.windows.toMutableMap().apply { this["7"] = getValue("7").copy(decks = 0); remove("14") }
        val all = p.tiers.getValue("all")
        val allW = all.windows.mapValues { it.value.copy(matchups = null) }
        p.copy(tiers = mapOf("big" to big.copy(windows = bigW), "all" to all.copy(windows = allW)))
    }

    private fun near(want: Double?, got: Double?, what: String) {
        assertEquals(what, want == null, got == null)
        if (want != null && got != null) assertEquals(what, want, got, 1e-4)
    }

    private fun heat(want: HeatCase?, got: InsightCharts.Heat?, what: String) {
        assertEquals(what, want == null, got == null)
        if (want == null || got == null) return
        assertEquals(what, listOf(want.label, want.tone, want.dim, want.ink), listOf(got.label, got.tone, got.dim, got.ink))
        assertEquals(what, want.strength, got.strength, 1e-4)
    }

    @Test fun slotsAndTier() {
        assertEquals(cases.slots, MetaWidgets.SLOTS)
        assertEquals(cases.slots, MetaPalette.colors.size)
        cases.tier_for.forEach { c -> assertEquals("$c", c.out, MetaWidgets.tierFor(if (c.pack == "thin") thin else pack, c.want, c.days)) }
    }

    @Test fun breakdown() = cases.breakdown.forEach { c ->
        val got = MetaWidgets.breakdown(pack, c.tier, c.days, c.n)
        val o = c.out ?: return@forEach assertNull(got)
        assertNotNull(got); got!!
        assertEquals(o.decks, got.decks)
        near(o.rest, got.rest, "rest")
        assertEquals(o.rows.map { it.a }, got.rows.map { it.a })
        o.rows.zip(got.rows).forEach { (e, g) ->
            assertEquals(e.name, g.name); assertEquals(e.slot, g.slot)
            near(e.share, g.share, "share"); near(e.delta, g.delta, "delta ${e.a}"); near(e.wr, g.wr, "wr ${e.a}")
        }
    }

    @Test fun chart() = cases.chart.forEach { c ->
        val got = MetaWidgets.chart(pack, c.tier, c.days, c.ids)
        assertEquals(c.out.days, got.days)
        near(c.out.top, got.top, "top")
        assertEquals(c.out.lines.map { it.a }, got.lines.map { it.a })
        c.out.lines.zip(got.lines).forEach { (e, g) ->
            assertEquals(e.slot, g.slot); assertEquals(e.v.size, g.v.size)
            e.v.zip(g.v).forEach { (x, y) -> near(x, y, "line ${e.a}") }
        }
        assert(got.labels.isNotEmpty() && got.labels.all { it.first < got.days })
    }

    @Test fun codes() = cases.codes.forEach { assertEquals(it.out, MetaWidgets.codes(it.names)) }

    @Test fun grid() = (cases.grid.map { it to pack } + (cases.grid_thin to thin)).forEach { (c, p) ->
        val got = MetaWidgets.grid(p, c.tier, c.days, c.rows, c.cols)
        assertEquals(c.out.title, got.title)
        assertEquals(c.out.cols.map { MetaWidgets.Col(it.a, it.name, it.code, it.slot) }, got.cols)
        assertEquals(c.out.rows.map { MetaWidgets.GridRow(it.a, it.name, it.slot) }, got.rows)
        assertEquals(c.out.cells.size, got.cells.size)
        c.out.cells.forEachIndexed { i, line -> line.forEachIndexed { j, e -> heat(e, got.cells[i][j], "${c.tier} ${c.days} $i,$j") } }
    }

    @Test fun matchups() = cases.matchups.forEach { c ->
        val got = MetaWidgets.matchups(pack, c.tier, c.days, c.a)
        val o = c.out
        assertEquals(listOf(o.name, o.slot, o.title), listOf(got.name, got.slot, got.title))
        near(o.share, got.share, "share"); near(o.wr, got.wr, "wr"); assertEquals(o.record, got.record)
        assertEquals(o.rows.map { it.vs }, got.rows.map { it.vs })
        o.rows.zip(got.rows).forEach { (e, g) ->
            assertEquals(listOf(e.wins, e.losses, e.draws, e.slot), listOf(g.wins, g.losses, g.draws, g.slot))
            near(e.wr, g.wr, "wr ${e.vs}"); heat(e.heat, g.heat, "heat ${e.vs}")
        }
        assertEquals("good ${c.a}", o.good, got.good); assertEquals("bad ${c.a}", o.bad, got.bad)
    }

    /** A tapped square reads as the Insights tab's grid does. */
    @Test fun cellDetail() = cases.cell_detail.forEach { c ->
        val got = MetaWidgets.cellDetail(pack, c.tier, c.days, c.a, c.b)
        assertEquals("${c.a} vs ${c.b}", c.out?.let { listOf(it.title, it.line, it.record) }, got?.let { listOf(it.title, it.line, it.record) })
    }

    /** A tap picks a square or row; the same tap again lets it go; another picks that one. */
    @Test fun selectionToggle() {
        assertEquals("1:18", MetaWidgets.toggled(null, "1:18"))
        assertNull(MetaWidgets.toggled("1:18", "1:18"))
        assertEquals("18:1", MetaWidgets.toggled("1:18", "18:1"))
        assertEquals(1 to 18, MetaWidgets.cellOf("1:18"))
        assertNull(MetaWidgets.cellOf("12"))
        assertNull(MetaWidgets.cellOf(null))
    }

    @Test fun choices() = assertEquals(cases.choices, MetaWidgets.choices(pack))

    /** The archetype widget falls back to the most played when its pick isn't in the format. */
    @Test fun archetypeFallback() {
        val top = pack.window("all", 30)!!.share.first { it.a != 0 }.a
        assertEquals(17, MetaWidgets.archetypeFor(pack, MetaPicks(tier = "all", days = 30, archetype = 17)))
        assertEquals(top, MetaWidgets.archetypeFor(pack, MetaPicks(tier = "all", days = 30, archetype = 999)))
        assertEquals(top, MetaWidgets.archetypeFor(pack, MetaPicks(tier = "all", days = 30)))
    }

    /** A widget's tap opens Insights on its picks; the app reads the same address back. */
    @Test fun links() {
        val url = MetaPicks("pauper", "all", 7).link("archetype/12", "widget_archetype")
        assertEquals("table1://insights/pauper/archetype/12?tier=all&days=7&src=widget_archetype", url)
        assertEquals(WebLink.Insights("pauper", "all", 7, listOf("insights/arch/pauper/12")) to "widget_archetype", WebLink.parseApp(url))
        assertEquals(WebLink.Insights("modern", "big", 30, listOf("insights/matchups/modern")),
            WebLink.parseApp("table1://insights/modern/matchups?tier=big&days=30")?.first)
        assertEquals(WebLink.Insights("modern", null, null, emptyList()), WebLink.parseApp("table1://insights/modern?tier=nope&days=5")?.first)
        assertNull(WebLink.parseApp("table1://insights"))
    }

    /** Picks are stored as JSON per widget; one from an older build without a field still reads. */
    @Test fun picksRoundTrip() {
        val p = MetaPicks("legacy", "all", 14, 5)
        assertEquals(p, json.decodeFromString<MetaPicks>(Json.encodeToString(MetaPicks.serializer(), p)))
        assertEquals(MetaPicks(format = "vintage"), json.decodeFromString<MetaPicks>("""{"format":"vintage"}"""))
    }
}
