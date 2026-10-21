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

internal val root: File = generateSequence(File("").absoluteFile) { it.parentFile }
    .map { File(it, "testdata/scan") }.first { it.isDirectory }

/** The test pack, built once per test run and shared: two copies of it don't fit the test JVM's heap. */
internal val testPack: PackCatalog by lazy { PackCatalog(String(CatalogPack.gunzip(File(root, "catalog.tsv.gz").readBytes()))) }

/** The test pack held in memory, answering what CatalogDb answers on a phone (scanner and CSV import). */
internal class PackCatalog(text: String) : ScanCatalog, ImportCatalog, ListCatalog {
    private val oracleList = ArrayList<PackOracle>()
    private val printingList = ArrayList<CatalogPrinting>()
    private val nameList = LinkedHashSet<ForeignName>()
    override val version: String = CatalogPack.parse(text, { oracleList.add(it) }, { p ->
        printingList.add(CatalogPrinting(p.cardId, p.oracleIdx, printingList.size, p.set, p.cn, p.lang, p.rarity, p.finishes,
            p.releasedAt, p.imageTs, p.imageFaces, p.printedName, p.original))
    }, { n -> CardName.norm(n.name).takeIf { it.isNotEmpty() }?.let { nameList.add(ForeignName(n.oracleIdx, n.lang, it)) } }).version
    private val byOracle = printingList.groupBy { it.oracleIdx }
        .mapValues { (_, ps) -> ps.sortedWith(compareByDescending<CatalogPrinting> { it.original }.thenBy { it.ord }) }
    private val bySetCn = printingList.groupBy { "${it.set}|${it.cn}" }
    private val oracleByIdx = oracleList.associateBy { it.idx }

    override fun scanNames() = oracleList.map { ScanName(it.idx, it.name, it.nameNorm, it.typeLine, byOracle[it.idx]?.size ?: 0) }
    override fun foreignNames() = nameList.toList()
    override fun setCodes() = printingList.mapTo(HashSet()) { it.set }
    override fun oracles(idxs: Collection<Int>) = idxs.mapNotNull { i ->
        oracleByIdx[i]?.let { i to CatalogOracle(it.idx, it.oracleId, it.name, it.nameNorm, it.typeLine, it.manaCost, byOracle[i]?.size ?: 0,
            it.legal, it.points, it.cmc, it.colors) }
    }.toMap()
    override fun printings(oracleIdx: Int) = byOracle[oracleIdx] ?: emptyList()
    override fun printings(set: String, cn: String) = (bySetCn["$set|$cn"] ?: emptyList()).sortedByDescending { it.lang == "en" }

    private val bySet by lazy { printingList.groupBy { it.set } }
    private val byCardId by lazy { printingList.associateBy { it.cardId } }
    override fun importNames() = oracleList.map { ImportName(it.idx, it.nameNorm, it.faceNames, it.typeLine.startsWith("Token"), byOracle[it.idx]?.size ?: 0) }
    override fun printings(set: String) = bySet[set] ?: emptyList()
    override fun printings(ids: Collection<String>) = ids.mapNotNull { byCardId[it] }.associateBy { it.cardId }
    /** Same order as CatalogDb.covers: original, then English with an image, then newest. */
    override fun covers(oracleIdxs: Collection<Int>) = oracleIdxs.mapNotNull { i ->
        byOracle[i]?.minWithOrNull(compareBy<CatalogPrinting>({ if (it.original) 0 else 1 }, { if (it.lang == "en" && it.imageFaces > 0) 0 else 1 }, { it.ord }))
            ?.let { i to it }
    }.toMap()

    private val byNorm by lazy { oracleList.groupBy { it.nameNorm }.mapValues { it.value.first().idx } }
    /** Same lookups as CatalogDb.printingsByName: the exact name, else a front face (most printings first). */
    override fun printingsByName(names: Collection<String>): Map<String, CatalogPrinting> {
        val idx = names.toSet().mapNotNull { n ->
            (byNorm[CardName.norm(n)] ?: oracleList.filter { it.name.startsWith("$n // ") }.maxByOrNull { byOracle[it.idx]?.size ?: 0 }?.idx)?.let { n to it }
        }.toMap()
        val covers = covers(idx.values.toSet())
        return idx.mapNotNull { (n, i) -> covers[i]?.let { n to it } }.toMap()
    }
    override fun printingsBySetCn(pairs: Collection<Pair<String, String>>) =
        pairs.mapNotNull { (s, c) -> printings(s.lowercase(), c).firstOrNull()?.let { "$s|$c" to it } }.toMap()

    /** Normalized name (and a split or double-faced card's front face) → oracle index, for the expected cards. */
    val expected: Map<String, Int> = HashMap<String, Pair<Int, Int>>().also { best ->
        for (o in oracleList) {
            val count = byOracle[o.idx]?.size ?: 0
            val keys = listOf(o.nameNorm) + listOfNotNull(o.name.indexOf(" // ").takeIf { it >= 0 }?.let { CardName.norm(o.name.substring(0, it)) })
            for (k in keys) if (best[k].let { it == null || count > it.second }) best[k] = o.idx to count
        }
    }.mapValues { it.value.first }
}

/** One photo or reported case: the card it is, and [lang] the language printed on it. */
private class Case(val id: String, val name: String, val set: String, val cn: String, val tags: Set<String>, val lang: String = "en")

/** Lowest accuracy the tests accept: what the set reached when last tuned (README has the numbers). */
private object Floor {
    const val ENGLISH_NAME = 0.95
    const val ENGLISH_PRINTING = 0.85
    const val FOREIGN_NAME = 0.93
    const val CJK_NAME = 0.6
    /** Of the cards in other languages named right, how many go in as their own language (2026-10-20). */
    const val LANGUAGE = 0.93
}

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
            catalog = testPack
            val started = System.nanoTime()
            names = ScanNames(catalog)
            println("Catalog: scanner name index ${(System.nanoTime() - started) / 1_000_000} ms")
        }
    }

    private fun photos() = File(root, "photos.tsv").readLines().drop(1).filter { it.isNotBlank() }.map { row ->
        val c = row.split('\t')
        Case(c[0], c[1], c[2], c[3], c[5].split(',').toSet(), c[4])
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
        val englishResults = HashMap<String, Tally>()
        // English cards a scan would put in another language (a misread English name close to a printed one).
        val notEnglish = HashMap<String, Int>()
        for (mode in listOf("accurate", "fast", "small", "multi", "title")) {
            val all = Tally(); val english = Tally(); val foreign = Tally()
            val byTag = sortedMapOf<String, Tally>()
            for (c in cases) {
                val lines = ocr[c.id]?.jsonObject?.get(mode)?.jsonArray?.map { it.jsonPrimitive.content } ?: continue
                val m = matcher().match(lines)
                if (m != null && m.oracle.idx != catalog.expected[CardName.norm(c.name)]) report += "    WRONG $mode ${c.id}: ${m.oracle.name}"
                if (c.lang == "en" && m != null && Languages.forScan(m.printing.lang, m.langs, "en") != "en") {
                    notEnglish.merge(mode, 1, Int::plus)
                    report += "    LANGUAGE $mode ${c.id}: ${m.langs}"
                }
                grade(c, m?.oracle, m?.printing, m?.exact ?: false, all)
                grade(c, m?.oracle, m?.printing, m?.exact ?: false, if ("lang" in c.tags) foreign else english)
                if (mode == "accurate") for (tag in c.tags) grade(c, m?.oracle, m?.printing, m?.exact ?: false, byTag.getOrPut(tag) { Tally() })
            }
            results[mode] = all
            englishResults[mode] = english
            report += listOf("  $mode: ${all.line()}", "    English: ${english.line()}", "    other languages: ${foreign.line()}")
            if (mode == "accurate") report += byTag.map { (tag, t) -> "      $tag: ${t.line()}" }
        }
        println(report.joinToString("\n"))
        // Other languages have their own test (foreignCards).
        val accurate = results.getValue("accurate")
        val english = englishResults.getValue("accurate")
        assertEquals("a wrong card from a steady photo", 0, accurate.wrong)
        assertTrue(english.name.toDouble() / english.n >= Floor.ENGLISH_NAME)
        assertTrue(english.printingOk.toDouble() / english.printingChecked >= Floor.ENGLISH_PRINTING)
        assertTrue(accurate.exactWrong <= 2)
        assertTrue(results.getValue("fast").wrong + results.getValue("small").wrong <= 1)
        assertEquals("a wrong card from a steady photo read as the scanner reads", 0, results.getValue("multi").wrong)
        assertEquals("an English card put in another language", 0, (notEnglish["accurate"] ?: 0) + (notEnglish["multi"] ?: 0))
    }

    /** The language code printed by the set code, only by a set the catalog has. */
    @Test
    fun collectorLanguage() {
        assertEquals("ja", Collector(listOf("154/264 M", "WAR • JP Artist"), setOf("war")).lang)
        assertEquals("ru", Collector(listOf("RIX • RU"), setOf("rix")).lang)
        assertEquals("en", Collector(listOf("M21 • EN"), setOf("m21")).lang)
        assertEquals("not a set code", null, Collector(listOf("one IT • ES ate"), setOf("war")).lang)
        assertEquals("two codes", null, Collector(listOf("WAR • JP", "WAR • EN"), setOf("war")).lang)
    }

    /**
     * Cards printed in other languages, read two ways: `accurate` is OCR in the phone's language (Cyrillic comes
     * through, Chinese, Japanese and Korean don't), `multi` is OCR that detects the language, as the scanner reads
     * since 2026-10-16. Names in other languages come from the catalog pack's N lines.
     */
    @Test
    fun foreignCards() {
        val ocr = Json.parseToJsonElement(File(root, "ocr.json").readText()).jsonObject
        val cases = photos().filter { it.lang != "en" }
        val cjk = setOf("ja", "ko", "zhs", "zht")
        val report = mutableListOf("Cards in other languages (${cases.size}):")
        val groups = HashMap<String, Map<String, Tally>>()
        // Cards named right, and of those, put in their own language (as added with English picked for adds).
        val named = HashMap<String, Int>()
        val right = HashMap<String, Int>()
        for (mode in listOf("accurate", "multi", "title")) {
            val byLang = sortedMapOf<String, Tally>()
            val byGroup = sortedMapOf<String, Tally>()
            for (c in cases) {
                val lines = ocr[c.id]?.jsonObject?.get(mode)?.jsonArray?.map { it.jsonPrimitive.content } ?: continue
                val m = matcher().match(lines)
                if (m != null && m.oracle.idx != catalog.expected[CardName.norm(c.name)]) report += "    WRONG $mode ${c.id}: ${m.oracle.name}"
                if (m != null && m.oracle.idx == catalog.expected[CardName.norm(c.name)]) {
                    val lang = Languages.forScan(m.printing.lang, m.langs, "en")
                    named.merge(mode, 1, Int::plus)
                    if (lang == c.lang) right.merge(mode, 1, Int::plus)
                    else if (mode != "title") report += "    LANGUAGE $mode ${c.id}: $lang, is ${c.lang}"
                }
                val group = if (c.lang in cjk) "Chinese, Japanese, Korean" else "Latin and Cyrillic"
                grade(c, m?.oracle, m?.printing, m?.exact ?: false, byLang.getOrPut(c.lang) { Tally() })
                grade(c, m?.oracle, m?.printing, m?.exact ?: false, byGroup.getOrPut(group) { Tally() })
            }
            groups[mode] = byGroup
            report += "  $mode:"
            report += byGroup.map { (g, t) -> "    $g: ${t.line()}" }
            report += byLang.map { (l, t) -> "      $l: ${t.line()}" }
            report += "    language right ${right[mode] ?: 0}/${named[mode] ?: 0}"
        }
        println(report.joinToString("\n"))
        // `title` (a second pass on the deskewed title bar) is measured, not yet read by the scanner: README.
        for ((mode, byGroup) in groups) if (mode != "title") for ((group, t) in byGroup) assertEquals("a wrong card, $group, $mode", 0, t.wrong)
        val latin = groups.getValue("accurate").getValue("Latin and Cyrillic")
        assertTrue(latin.name.toDouble() / latin.n >= Floor.FOREIGN_NAME)
        val cjkNames = groups.getValue("multi").getValue("Chinese, Japanese, Korean")
        assertTrue(cjkNames.name.toDouble() / cjkNames.n >= Floor.CJK_NAME)
        for (mode in listOf("accurate", "multi")) {
            assertTrue("cards put in their own language, $mode", (right[mode] ?: 0).toDouble() / named.getValue(mode) >= Floor.LANGUAGE)
        }
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

    /**
     * Each still photo as a steady 2.4 s clip (12 frames, 200 ms apart) through ScanLanguage and ScanSteadiness, as
     * the scanner runs: frames read like `accurate` (Latin) until text names no card for 0.6 s, then like `multi` (here
     * standing in for every CJK recognizer), and back after misses. Nobody picks a language; this measures what
     * finding it costs: cards taken, wrong cards, and time to take.
     */
    @Test
    fun languageDetection() {
        val ocr = Json.parseToJsonElement(File(root, "ocr.json").readText()).jsonObject
        val cjk = setOf("ja", "ko", "zhs", "zht")
        val groups = sortedMapOf<String, Tally>()
        val times = HashMap<String, MutableList<Long>>()
        val report = mutableListOf("Language detection (each photo held 2.4 s, starting in Latin):")
        for (c in photos()) {
            val reads = ocr[c.id]?.jsonObject ?: continue
            fun read(mode: String) = reads[mode]?.jsonArray?.map { it.jsonPrimitive.content }
            val latin = read("accurate") ?: continue
            val any = read("multi") ?: continue
            val group = if (c.lang == "en") "English" else if (c.lang in cjk) "Chinese, Japanese, Korean" else "Latin and Cyrillic"
            val matcher = matcher()
            val steady = ScanSteadiness()
            val language = ScanLanguage(readers = 3)
            var got: Pair<ScanMatch, Long>? = null
            for (k in 0 until 12) {
                val at = k * 200L
                val lines = if (language.mode == ScanLanguage.LATIN) latin else any
                val m = matcher.match(lines)
                val taken = steady.feed(m, at)
                if (taken != null && m != null) { got = m.copy(printing = taken.first, exact = taken.second) to at; break }
                language.feed(matched = m != null, text = lines.isNotEmpty(), now = at)
            }
            if (got != null && got.first.oracle.idx != catalog.expected[CardName.norm(c.name)]) report += "    WRONG ${c.id}: ${got.first.oracle.name}"
            grade(c, got?.first?.oracle, got?.first?.printing, got?.first?.exact ?: false, groups.getOrPut(group) { Tally() })
            got?.let { times.getOrPut(group) { mutableListOf() }.add(it.second) }
        }
        report += groups.map { (g, t) ->
            val ts = times[g].orEmpty().sorted()
            "  $g: taken ${t.line()}, median ${if (ts.isEmpty()) 0.0 else ts[ts.size / 2] / 1000.0} s"
        }
        println(report.joinToString("\n"))
        for ((g, t) in groups) assertEquals("a wrong card taken, $g", 0, t.wrong)
        val english = groups.getValue("English")
        val cjkCards = groups.getValue("Chinese, Japanese, Korean")
        assertTrue(english.name.toDouble() / english.n >= Floor.ENGLISH_NAME)
        assertTrue(cjkCards.name.toDouble() / cjkCards.n >= Floor.CJK_NAME)
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
