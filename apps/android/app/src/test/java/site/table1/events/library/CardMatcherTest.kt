package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import java.io.File

/*
 * Scanner accuracy over the photo test set (testdata/scan/README.md): the matcher on each photo's OCR lines, the
 * movement clips through ScanSteadiness, and every reported scan correction in testdata/scan/reports. Prints a
 * report and fails when accuracy drops below what the set reached when it was tuned (2026-10-15). Same as iOS
 * CardMatcherTests.swift.
 */

private val root: File = generateSequence(File("").absoluteFile) { it.parentFile }
    .map { File(it, "testdata/scan") }.first { it.isDirectory }

/** The test pack held in memory, answering what CatalogDb answers on a phone. */
private class PackCatalog(text: String) : ScanCatalog {
    private val oracleList = ArrayList<PackOracle>()
    private val printingList = ArrayList<CatalogPrinting>()
    private val nameList = LinkedHashSet<Pair<Int, String>>()
    override val version: String = CatalogPack.parse(text, { oracleList.add(it) }, { p ->
        printingList.add(CatalogPrinting(p.cardId, p.oracleIdx, printingList.size, p.set, p.cn, p.lang, p.rarity, p.finishes,
            p.releasedAt, p.imageTs, p.imageFaces, p.printedName, p.original))
    }, { n -> CardName.norm(n.name).takeIf { it.isNotEmpty() }?.let { nameList.add(n.oracleIdx to it) } }).version
    private val byOracle = printingList.groupBy { it.oracleIdx }
        .mapValues { (_, ps) -> ps.sortedWith(compareByDescending<CatalogPrinting> { it.original }.thenBy { it.ord }) }
    private val bySetCn = printingList.groupBy { "${it.set}|${it.cn}" }
    private val oracleByIdx = oracleList.associateBy { it.idx }

    override fun scanNames() = oracleList.map { ScanName(it.idx, it.name, it.nameNorm, it.typeLine, byOracle[it.idx]?.size ?: 0) }
    override fun foreignNames() = nameList.toList()
    override fun setCodes() = printingList.mapTo(HashSet()) { it.set }
    override fun oracles(idxs: Collection<Int>) = idxs.mapNotNull { i ->
        oracleByIdx[i]?.let { i to CatalogOracle(it.idx, it.oracleId, it.name, it.nameNorm, it.typeLine, it.manaCost, byOracle[i]?.size ?: 0) }
    }.toMap()
    override fun printings(oracleIdx: Int) = byOracle[oracleIdx] ?: emptyList()
    override fun printings(set: String, cn: String) = (bySetCn["$set|$cn"] ?: emptyList()).sortedByDescending { it.lang == "en" }

    /** Normalized name (and a split or double-faced card's front face) → oracle index, for the expected cards. */
    val expected: Map<String, Int> = HashMap<String, Pair<Int, Int>>().also { best ->
        for (o in oracleList) {
            val count = byOracle[o.idx]?.size ?: 0
            val keys = listOf(o.nameNorm) + listOfNotNull(o.name.indexOf(" // ").takeIf { it >= 0 }?.let { CardName.norm(o.name.substring(0, it)) })
            for (k in keys) if (best[k].let { it == null || count > it.second }) best[k] = o.idx to count
        }
    }.mapValues { it.value.first }
}

private class Case(val id: String, val name: String, val set: String, val cn: String, val tags: Set<String>)

private class Tally {
    var n = 0; var name = 0; var wrong = 0; var printingChecked = 0; var printingOk = 0; var exactWrong = 0
    fun line() = "name $name/$n (${pct(name, n)}), wrong $wrong, none ${n - name - wrong}; " +
        "printing $printingOk/$printingChecked (${pct(printingOk, printingChecked)}), sure-but-wrong $exactWrong"
}

private fun pct(a: Int, b: Int) = if (b == 0) "-" else "${Math.round(a * 100.0 / b)}%"

class CardMatcherTest {
    companion object {
        private lateinit var catalog: PackCatalog
        private lateinit var names: ScanNames

        @BeforeClass @JvmStatic
        fun load() {
            catalog = PackCatalog(String(CatalogPack.gunzip(File(root, "catalog.tsv.gz").readBytes())))
            val started = System.nanoTime()
            names = ScanNames(catalog)
            println("Catalog: scanner name index ${(System.nanoTime() - started) / 1_000_000} ms")
        }
    }

    private fun photos() = File(root, "photos.tsv").readLines().drop(1).filter { it.isNotBlank() }.map { row ->
        val c = row.split('\t')
        Case(c[0], c[1], c[2], c[3], c[5].split(',').toSet())
    }

    private fun matcher() = CardMatcher(catalog, null, names)

    private fun strip(s: String) = s.lowercase().replace("★", "").trimStart('0')

    private fun grade(c: Case, oracle: CatalogOracle?, printing: CatalogPrinting?, exact: Boolean, t: Tally) {
        t.n++
        if (oracle == null || printing == null) return
        val want = catalog.expected[CardName.norm(c.name)]
        assertTrue("${c.id}: ${c.name} isn't in the catalog", want != null)
        if (oracle.idx != want) { t.wrong++; return }
        t.name++
        if (c.set == "*") return
        t.printingChecked++
        if (printing.set == c.set && (c.cn == "*" || strip(printing.cn) == strip(c.cn))) t.printingOk++ else if (exact) t.exactWrong++
    }

    @Test
    fun stillPhotos() {
        val ocr = Json.parseToJsonElement(File(root, "ocr.json").readText()).jsonObject
        val cases = photos()
        val report = mutableListOf("Still photos (${cases.size}):")
        val results = HashMap<String, Tally>()
        for (mode in listOf("accurate", "fast", "small")) {
            val all = Tally(); val english = Tally(); val foreign = Tally()
            val byTag = sortedMapOf<String, Tally>()
            for (c in cases) {
                val lines = ocr[c.id]?.jsonObject?.get(mode)?.jsonArray?.map { it.jsonPrimitive.content } ?: continue
                val m = matcher().match(lines)
                if (m != null && m.oracle.idx != catalog.expected[CardName.norm(c.name)]) report += "    WRONG $mode ${c.id}: ${m.oracle.name}"
                grade(c, m?.oracle, m?.printing, m?.exact ?: false, all)
                grade(c, m?.oracle, m?.printing, m?.exact ?: false, if ("lang" in c.tags) foreign else english)
                if (mode == "accurate") for (tag in c.tags) grade(c, m?.oracle, m?.printing, m?.exact ?: false, byTag.getOrPut(tag) { Tally() })
            }
            results[mode] = all
            report += listOf("  $mode: ${all.line()}", "    English: ${english.line()}", "    other languages: ${foreign.line()}")
            if (mode == "accurate") report += byTag.map { (tag, t) -> "      $tag: ${t.line()}" }
        }
        println(report.joinToString("\n"))
        val accurate = results.getValue("accurate")
        assertEquals("a wrong card from a steady photo", 0, accurate.wrong)
        assertTrue(accurate.name.toDouble() / accurate.n >= 0.78)
        assertTrue(accurate.printingOk.toDouble() / accurate.printingChecked >= 0.84)
        assertTrue(accurate.exactWrong <= 2)
        assertTrue(results.getValue("fast").wrong + results.getValue("small").wrong <= 1)
    }

    /** Frames 200 ms apart, as the movement clips were made. Returns the first card taken and when (ms). */
    private fun take(frames: List<List<String>>): Pair<ScanMatch, Long>? {
        val matcher = matcher()
        val steady = ScanSteadiness()
        frames.forEachIndexed { k, lines ->
            val t = k * 200L
            val m = matcher.match(lines)
            val got = steady.feed(m, t)
            if (got != null && m != null) return ScanMatch(m.oracle, got.first, got.second) to t
        }
        return null
    }

    @Test
    fun movement() {
        val clips = Json.parseToJsonElement(File(root, "motion.json").readText()).jsonObject
        val byKind = linkedMapOf("settle" to Tally(), "shake" to Tally(), "sweep" to Tally())
        val times = HashMap<String, MutableList<Long>>()
        photos().forEachIndexed { i, c ->
            if ("lang" in c.tags) return@forEachIndexed
            val frames = clips[c.id]?.jsonArray?.map { f -> f.jsonArray.map { it.jsonPrimitive.content } } ?: return@forEachIndexed
            val kind = listOf("settle", "shake", "sweep")[i % 3] // as testdata/scan/tools/ocr.swift assigns them
            val got = take(frames)
            grade(c, got?.first?.oracle, got?.first?.printing, got?.first?.exact ?: false, byKind.getValue(kind))
            got?.let { times.getOrPut(kind) { mutableListOf() }.add(it.second) }
        }
        println("Movement clips (2.4 s each, English cards):\n" + byKind.map { (kind, t) ->
            val ts = times[kind].orEmpty().sorted()
            "  $kind: taken ${t.line()}, median ${if (ts.isEmpty()) 0.0 else ts[ts.size / 2] / 1000.0} s"
        }.joinToString("\n"))
        for ((kind, t) in byKind) assertEquals("a wrong card taken while moving ($kind)", 0, t.wrong)
        assertTrue(byKind.getValue("settle").let { it.name.toDouble() / it.n } >= 0.9)
        assertTrue(byKind.getValue("shake").let { it.name.toDouble() / it.n } >= 0.8)
    }

    /** Scan corrections people reported (testdata/scan/tools/export_reports.py), tracked as they get fixed. */
    @Test
    fun reportedCorrections() {
        val files = File(root, "reports").listFiles { f -> f.extension == "json" }.orEmpty()
        val t = Tally()
        val failures = mutableListOf<String>()
        for (file in files) {
            val r = Json.parseToJsonElement(file.readText()).jsonObject
            val name = r["name"]?.jsonPrimitive?.content?.takeIf { it != "null" } ?: continue
            val c = Case(r.str("id"), name, r.str("set", "*"), r.str("cn", "*"), emptySet())
            val frames = (r["frames"] as JsonArray).map { f -> f.jsonArray.map { it.jsonPrimitive.content } }
            val before = Pair(t.name, t.printingOk)
            val got = take(frames)
            grade(c, got?.first?.oracle, got?.first?.printing, got?.first?.exact ?: false, t)
            val right = t.name > before.first && (c.set == "*" || t.printingOk > before.second)
            if (!right) failures += "${c.id}: wanted $name ${c.set} ${c.cn}, got ${got?.first?.let { "${it.oracle.name} ${it.printing.setLabel}" } ?: "nothing"}"
        }
        println("Reported corrections (${t.n}): ${t.line()}" + failures.joinToString("") { "\n  still wrong: $it" })
    }

    private fun JsonObject.str(key: String, default: String = "") =
        this[key]?.jsonPrimitive?.content?.takeIf { it != "null" } ?: default
}
