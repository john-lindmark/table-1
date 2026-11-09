package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
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
            p.releasedAt, p.imageTs, p.imageFaces, p.printedName, p.original, p.artist, p.frame))
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
    /** Reported corrections (phone clips) whose printing comes out right (2026-10-28). */
    const val REPORT_PRINTING = 0.44
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
        // `dim` and `dimFixed` exist only for the 1993 and 1997 frames (README § Low-contrast reads).
        val oldFrame = HashMap<String, Tally>()
        for (mode in listOf("accurate", "fast", "small", "multi", "title", "bottom", "dim", "dimFixed")) {
            val all = Tally(); val english = Tally(); val foreign = Tally()
            val byTag = sortedMapOf<String, Tally>()
            for (c in cases) {
                val lines = ocr[c.id]?.jsonObject?.get(mode)?.jsonArray?.map { it.jsonPrimitive.content } ?: continue
                val m = matcher().match(lines)
                if ("frame93" in c.tags || "frame97" in c.tags) grade(c, m?.oracle, m?.printing, m?.exact ?: false, oldFrame.getOrPut(mode) { Tally() })
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
        report += "  1993 and 1997 frames (${oldFrame["dim"]?.n ?: 0}): " + listOf("accurate", "multi", "dim", "dimFixed").joinToString("; ") { "$it ${oldFrame[it]?.line() ?: "-"}" }
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
        // Dim, low-contrast copies of the old-frame photos (2026-11-01): no wrong card, and names within a few of the
        // plain read's (README § Low-contrast reads has the numbers; `dimFixed`, a contrast stretch before OCR, is
        // only measured: it read fewer names and two wrong cards, so the scanners don't do it).
        assertEquals("a wrong card from a dim photo", 0, results.getValue("dim").wrong)
        assertTrue(oldFrame.getValue("dim").name >= oldFrame.getValue("accurate").name - 8)
        assertEquals("an English card put in another language", 0, (notEnglish["accurate"] ?: 0) + (notEnglish["multi"] ?: 0))
    }

    /**
     * What the bottom text says (2026-10-28, from 232 phone reports): the number at the end of a 1997-style copyright
     * line, years on copyright lines the camera garbles, more spellings of the set code line, an "Illus." line, lone
     * numbers that could be a misread power/toughness kept apart, and the illustrator's name read with a few errors.
     */
    /**
     * A name is never read from below the type line (2026-11-01): the title is above it, and the flavor text under
     * it names people who are cards too. An Ice Age Counterspell whose title the camera missed went in as Gustha
     * Ebbasdotter (Mystery Booster Commander) from "-Gustha Ebbasdotter," on John's iPhone (report 17843b42).
     */
    @Test
    fun noNameFromBelowTheTypeLine() {
        val m = CardMatcher(catalog, null, names)
        val flavor = listOf("Interrupt", "Counter target spell.", "\"The duel was going badly for me,", "and Zur thought I was finished. He",
            "-Lightning Bolt,", "Kjeldoran Royal Mage", "Illus. L.A. Williams")
        assertNull("a card named in the flavor text isn't the card", m.match(flavor))
        assertEquals("Lightning Bolt", m.match(listOf("Lightning Bolt", "Instant", "Lightning Bolt deals 3 damage to any target."))?.oracle?.name)
        // Without a type line read, a multi-word name lower down still counts, as before.
        assertEquals("Lightning Bolt", m.match(listOf("smudge", "glare", "more glare", "Lightning Bolt", "deals 3 damage to any target."))?.oracle?.name)
    }

    /**
     * Split cards (2026-11-08, README § Split cards): Vision's reads of Boom // Bust, Fire // Ice, Wear // Tear, a fuse
     * card, an Aftermath card, Dead // Gone and a Room, each held four ways (testdata/scan/split.json, from
     * tools/split.swift). Put in the text's own order (ScanOrder), every read names its card; in the order they come
     * (top of each line's box first, as the scanners handed them on before), never a wrong card. Same cases as iOS.
     */
    @Test
    fun splitCards() {
        val reads = Json.parseToJsonElement(File(root, "split.json").readText()).jsonArray.map { it.jsonObject }
        assertEquals(36, reads.size)
        val ordered = Tally()
        val unordered = Tally()
        val misses = mutableListOf<String>()
        for (r in reads) {
            fun f(k: String) = r.getValue(k).jsonPrimitive.content
            val c = Case(f("id"), f("name"), f("set"), f("cn"), emptySet())
            val lines = r.getValue("lines").jsonArray.map { l ->
                val o = l.jsonObject
                ScanOrder.Line(o.getValue("t").jsonPrimitive.content, o.getValue("q").jsonArray.map { it.jsonPrimitive.content.toFloat() }.toFloatArray())
            }
            val o = ScanOrder.order(lines)
            val m = matcher().match(o.lines)
            val plain = matcher().match(lines.map { it.text })
            val before = ordered.name
            grade(c, m?.oracle, m?.printing, m?.exact ?: false, ordered)
            grade(c, plain?.oracle, plain?.printing, plain?.exact ?: false, unordered)
            if (ordered.name == before) misses.add("${c.id} (${o.turn.wire}): ${m?.oracle?.name ?: "nothing"} from ${o.lines.take(4)}")
        }
        println("Split cards (${reads.size} reads): ordered ${ordered.line()}; as they came ${unordered.line()}" + misses.joinToString("") { "\n  missed $it" })
        assertEquals("a wrong card from a split card", 0, ordered.wrong + unordered.wrong)
        assertEquals("a split card read in the text's order that named nothing", reads.size, ordered.name)
    }

    /** Either half's name, or both, name a split card; a half that's also another card's name stays that card's. */
    @Test
    fun splitHalves() {
        val m = matcher()
        fun name(vararg lines: String) = m.match(lines.toList())?.oracle?.name
        assertEquals("Fire // Ice", name("Ice", "Instant", "Tap target permanent.", "Draw a card."))
        assertEquals("Wear // Tear", name("Tear", "Instant", "Destroy target enchantment."))
        assertEquals("Boom // Bust", name("Boom", "Bust", "Sorcery", "Sorcery"))
        assertEquals("Commit // Memory", name("Memory", "Sorcery", "Aftermath (Cast this spell only from your graveyard.)"))
        // The halves out of order, under their type lines (report 76cbcce6, an MH2 Fire // Ice held upright).
        assertEquals("Fire // Ice", name("Tap target permanent.", "Draw a card.", "Ice", "Instant", "divided as you choose",
            "Fire deals 2 damage", "among one or two", "Fire", "Instant", "targets."))
        // One half alone, low down, is still nothing (it's often a word in rules text).
        assertNull(name("Instant", "Tap target permanent.", "Draw a card.", "Ice"))
        // Liberate, Chaos and Blood are cards (or tokens) of their own.
        assertEquals("Liberate", name("Liberate", "Instant", "Exile target creature you control."))
        assertNull(name("Blood", "Token Artifact - Blood"))
        assertEquals("Bind // Liberate", name("Bind", "Liberate", "Instant", "Instant"))
        assertTrue(ScanNames.split("Fire // Ice", "Instant // Instant"))
        assertTrue(ScanNames.split("Commit // Memory", "Instant // Sorcery"))
        assertTrue(ScanNames.split("Bottomless Pool // Locker Room", "Enchantment — Room // Enchantment — Room"))
        assertFalse(ScanNames.split("Bonecrusher Giant // Stomp", "Creature — Giant // Instant — Adventure"))
        assertFalse(ScanNames.split("Spikefield Hazard // Spikefield Cave", "Instant // Land"))
    }

    /** ScanOrder keeps mostly upright text as it came, and reads turned text in its own direction. */
    @Test
    fun scanOrder() {
        fun line(t: String, x: Float, y: Float, turn: ScanOrder.Turn, len: Float = 100f): ScanOrder.Line {
            val h = 20f
            val q = when (turn) {
                ScanOrder.Turn.UPRIGHT -> floatArrayOf(x, y, x + len, y, x + len, y + h, x, y + h)
                ScanOrder.Turn.CLOCKWISE -> floatArrayOf(x, y, x, y + len, x - h, y + len, x - h, y)
                ScanOrder.Turn.UPSIDE_DOWN -> floatArrayOf(x, y, x - len, y, x - len, y - h, x, y - h)
                ScanOrder.Turn.COUNTERCLOCKWISE -> floatArrayOf(x, y, x, y - len, x + h, y - len, x + h, y)
            }
            return ScanOrder.Line(t, q)
        }
        // A card turned clockwise: its top faces the frame's right edge, so the title is the rightmost line.
        val cw = listOf(line("Instant", 400f, 100f, ScanOrder.Turn.CLOCKWISE), line("Rules text here", 200f, 100f, ScanOrder.Turn.CLOCKWISE),
            line("Fire", 600f, 100f, ScanOrder.Turn.CLOCKWISE), line("Ice", 600f, 500f, ScanOrder.Turn.CLOCKWISE))
        assertEquals(listOf("Fire", "Ice", "Instant", "Rules text here"), ScanOrder.order(cw).lines)
        assertEquals(ScanOrder.Turn.CLOCKWISE, ScanOrder.order(cw).turn)
        val ccw = listOf(line("Rules", 300f, 900f, ScanOrder.Turn.COUNTERCLOCKWISE), line("Boom", 50f, 900f, ScanOrder.Turn.COUNTERCLOCKWISE),
            line("Bust", 50f, 400f, ScanOrder.Turn.COUNTERCLOCKWISE))
        assertEquals(listOf("Boom", "Bust", "Rules"), ScanOrder.order(ccw).lines)
        val down = listOf(line("Lightning Bolt deals 3", 700f, 100f, ScanOrder.Turn.UPSIDE_DOWN), line("Lightning Bolt", 700f, 900f, ScanOrder.Turn.UPSIDE_DOWN))
        assertEquals(listOf("Lightning Bolt", "Lightning Bolt deals 3"), ScanOrder.order(down).lines)
        // Mostly upright: as it came, a sideways line beside it included.
        val up = listOf(line("Shock", 10f, 10f, ScanOrder.Turn.UPRIGHT), line("Noise", 500f, 5f, ScanOrder.Turn.CLOCKWISE, len = 30f),
            line("Instant", 10f, 400f, ScanOrder.Turn.UPRIGHT))
        assertEquals(listOf("Shock", "Noise", "Instant"), ScanOrder.order(up).lines)
        assertEquals(ScanOrder.Turn.UPRIGHT, ScanOrder.order(up).turn)
        assertEquals(emptyList<String>(), ScanOrder.order(emptyList()).lines)
    }

    @Test
    fun bottomLineParsing() {
        val sets = setOf("mh2", "mh1", "rvr", "40k", "ecl", "neo", "a25", "gtc")
        var c = Collector(listOf("Illus. Rob Alexander", "™ & C 2024 Wizande of the Coart 407"), sets)
        assertEquals(setOf("407"), c.numbers); assertEquals(setOf(2024), c.years); assertTrue(c.illustrated)
        assertTrue("a number on the copyright line isn't enough to name a card by", c.collectorNumbers.isEmpty())
        assertEquals(Collector.ArtistLine.ILLUSTRATED, c.names("Rob Alexander")); assertNull(c.names("Svetlin Velinov"))
        assertEquals("the total cut off", setOf("248"), Collector(listOf("ds of the Coast 248 27."), sets).numbers)
        c = Collector(listOf("& C 2013W", "2012 Wi", "* & 6 2013 W", "1995"), sets)
        assertEquals(setOf(2013, 2012), c.years)
        c = Collector(listOf("1993-2001 Wizards of the Coast, Inc. 214/350"), sets)
        assertEquals(setOf(2001), c.years); assertEquals(setOf("214"), c.numbers)
        for (line in listOf("MH2 - EN A ZEZHOU CHEN", "MH2 WEN N PAUL", "MH2VEN & PM", "YMH2 • EN - GREG STAPLES", "4OK•EN SHI", "MHT-EN A NICHOLAS", "NEO・JP ©えすていお", "A25. EN * TODD")) {
            val got = Collector(listOf(line), sets).sets
            assertEquals(line, 1, got.size); assertTrue(line, got.first() in setOf("mh2", "40k", "mh1", "neo", "a25"))
        }
        assertEquals("ja", Collector(listOf("NEO・JP ©えすていお/ESUTHIO"), sets).lang)
        assertTrue(Collector(listOf("one IT - ES ate", "THE END"), sets).sets.isEmpty())
        c = Collector(listOf("Tourach, Dread Cantor", "312", "2/1"), sets)
        assertEquals("could be a 3/2", setOf("312"), c.loneNumbers); assertTrue(c.numbers.isEmpty())
        c = Collector(listOf("392", "3/3"), sets)
        assertEquals(setOf("392"), c.numbers); assertEquals(setOf("392"), c.collectorNumbers)
        c = Collector(listOf("MH2 • EN A- ZEZHOU CHEN", "TOOD LOCKVOOD", "Shells Wan", "CUNT LANGLEY", "PAUL SCOTT CANARAT"), sets)
        assertEquals(Collector.ArtistLine.PLAIN, c.names("Zezhou Chen")); assertEquals(Collector.ArtistLine.PLAIN, c.names("Todd Lockwood"))
        assertEquals(Collector.ArtistLine.PLAIN, c.names("Shelly Wan")); assertEquals(Collector.ArtistLine.PLAIN, c.names("Paul Scott Canavan"))
        assertNull("two errors in a five-letter word is another word", c.names("Clint Langley"))
        assertNull(c.names("Greg Staples")); assertNull("a short name must read exactly", c.names("Won"))
        val m = Collector(listOf("MH2 • EN"), sets); m.merge(Collector(listOf("312"), sets))
        assertEquals(setOf("mh2"), m.sets); assertEquals(setOf("312"), m.loneNumbers)
    }

    /**
     * The printing from frame and artist evidence (2026-10-28): a retro-frame MH2 fetchland reads "Illus." and goes
     * in as MH2's retro printing, not Zendikar's; the illustrator tells a set's variants apart; evidence read over
     * several frames of one card adds up; an old card still goes in as Revised.
     */
    @Test
    fun printingEvidence() {
        fun pick(frames: List<List<String>>): Triple<String, String, Boolean>? {
            val m = matcher()
            var last: ScanMatch? = null
            for (f in frames) last = m.match(f) ?: last
            return last?.let { Triple(it.printing.set, it.printing.cn, it.exact) }
        }
        val misty = listOf("Misty Rainforest", "Land", "r, Pay 1 life, Sacrifice Misty", "Illus. Shelly Wan")
        assertEquals(Triple("mh2", "438", false), pick(listOf(misty)))
        assertEquals("frame and number single it out", Triple("mh2", "438", true), pick(listOf(misty + "ants of the Coast 438")))
        assertEquals("a 2003 frame prints the artist without Illus.", "zen",
            pick(listOf(listOf("Misty Rainforest", "Land", "r, Pay 1 life, Sacrifice Misty", "Shelly Wan")))?.first)
        assertEquals(Triple("rvr", "407", true),
            pick(listOf(listOf("Overgrown Tomb", "Land - Swamp Forest", "Illus. Rob Alexander", "™ & C 2024 Wizards of the Coast 407"))))
        val tourach = listOf("Tourach, Dread Cantor", "Legendary Creature - Human Cleric")
        assertEquals("the artist tells the borderless printing from the regular one", Triple("mh2", "312", true),
            pick(listOf(tourach + "MH2 • EN A- ZEZHOU CHEN")))
        assertEquals("312 alone could be a creature's 3/2", "102", pick(listOf(tourach + "312" + "2/1"))?.second)
        val triome = listOf("Zagoth Triome", "Land - Swamp Forest Island")
        assertEquals("a land has no power/toughness, so 313 is its number", "313", pick(listOf(triome + "313"))?.second)
        assertEquals("the set code from one frame and the number from another", Triple("iko", "313", true),
            pick(listOf(triome + "IKO • EN", triome, triome + "313")))
        assertEquals("an artist after a brush, not Illus., is a 2003 or newer frame", "mb2",
            pick(listOf(listOf("Temporal Manipulation", "Sorcery", "Take an extra turn after this one.", "- Franz Vohwinkel")))?.first)
        assertEquals("old frames still go in as the most printed", "3ed",
            pick(listOf(listOf("Lightning Bolt", "Instant", "Lightning Bolt does 3", "Illus. © Christopher Rush")))?.first)
        // Another card between clears what was read: the artist alone names 312 but can't be sure of it.
        val m = matcher()
        m.match(tourach + "MH2 • EN"); m.match(listOf("Lightning Bolt", "Instant"))
        val after = m.match(tourach + "A- ZEZHOU CHEN")
        assertEquals("312", after?.printing?.cn); assertEquals(false, after?.exact)
    }

    /**
     * The matcher's work per frame must not grow while a card stays in view (2026-10-31): the evidence merged over
     * frames had kept every frame's words for as long as the card was named, and the artist's fuzzy match scanned all
     * of them several times per printing, so each frame of a card held on a cluttered desk was slower than the last
     * (80 frames: 0.1 s → 7.9 s each), on the main thread. Only the last FRAMES frames are kept and each artist is
     * looked up once per frame.
     */
    @Test
    fun evidenceStaysBounded() {
        val m = matcher()
        val clutter = (0 until 30).map { "desk line number $it with some other words printed on it" }
        val frame = listOf("Lightning Bolt", "Instant", "Lightning Bolt deals 3 damage to any target.", "Illus. Christopher Rush") + clutter
        val times = ArrayList<Long>()
        repeat(80) {
            val t = System.nanoTime()
            assertEquals("Lightning Bolt", m.match(frame)?.oracle?.name)
            times.add(System.nanoTime() - t)
        }
        assertEquals(CardMatcher.FRAMES, m.rememberedFrames)
        val first = times.take(20).sum() / 1e6
        val last = times.takeLast(20).sum() / 1e6
        assertTrue("later frames must not be slower: first 20 $first ms, last 20 $last ms", last < first * 2 + 50)
        // The same card scanned in owned-only mode (trades) and a plain frame: every scan mode stays flat.
        val owned = CardMatcher(catalog, mapOf("" to emptySet()), names)
        val plain = listOf("Lightning Bolt", "Instant", "Lightning Bolt deals 3 damage to any target.", "3ED • EN")
        var ownedNs = 0L; var plainNs = 0L
        repeat(80) {
            var t = System.nanoTime(); owned.match(frame); ownedNs += System.nanoTime() - t
            t = System.nanoTime(); assertEquals(true, m.match(plain)?.exact); plainNs += System.nanoTime() - t
        }
        println("Matcher per frame: cluttered first 20 ${first / 20} ms, last 20 ${last / 20} ms; owned-only ${ownedNs / 80 / 1e6} ms; plain ${plainNs / 80 / 1e6} ms")
        // Evidence still carries across frames: a set code, then nothing, then the number.
        val triome = listOf("Zagoth Triome", "Land - Swamp Forest Island")
        m.match(triome + "IKO • EN")
        repeat(CardMatcher.FRAMES - 2) { m.match(triome) }
        val got = m.match(triome + "313")
        assertEquals(Triple("iko", "313", true), got?.let { Triple(it.printing.set, it.printing.cn, it.exact) })
        // Frames that name nothing forget the card after MISSES; a take forgets it at once.
        repeat(CardMatcher.MISSES) { assertNull(m.match(listOf("nothing here"))) }
        assertEquals(0, m.rememberedFrames)
        m.match(frame); m.took()
        assertEquals(0, m.rememberedFrames)
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
        assertTrue(byKind.getValue("shake").let { it.name.toDouble() / it.n } >= 0.88)
        assertEquals("a card swept past is never taken", 0, byKind.getValue("sweep").name)
    }

    /**
     * 1993–94 cards print no set, number or year, so nothing read tells Alpha, Beta, Unlimited and Revised apart.
     * They went in as Alpha, the rarest (scan reports 2026-10-26). Now: the most printed, the name's language on an
     * old frame, and after a fix by hand the set picked (nearest its number: MH2's retro fetchlands). Same as iOS.
     */
    @Test
    fun oldPrintings() {
        val m = matcher()
        fun got(lines: List<String>) = m.match(lines)?.let { "${it.printing.set} ${it.printing.cn}${if (it.exact) " exact" else ""}" } ?: "nothing"
        assertEquals("3ed 188", got(listOf("Channel", "Sorcery", "Until end of turn, you may add", "Illus. © Richard Thomas")))
        assertEquals("no bottom read", "3ed 54", got(listOf("Counterspell", "Counters target spell", "as it is being cast.")))
        assertEquals("not in Revised", "2ed 233", got(listOf("Black Lotus", "Mono Artifact", "Illus. Christopher Rush")))
        assertEquals("French, old frame", "fbb 274", got(listOf("Anneau solaire", "Artefact", "Illus, Mark Tedin")))
        val fourth = listOf("Channel", "Sorcery", "Illus. Richard Thomas", "© 1995 Wizards of the Coast, Inc.")
        assertEquals("4th Edition prints a year", "4ed 236", got(fourth))

        fun printings(name: String) = catalog.printings(catalog.expected.getValue(CardName.norm(name)))
        m.picked(printings("Tundra").first { it.set == "leb" })
        assertEquals("Beta, as picked", "leb 282", got(listOf("Scrubland", "Counts as both plains and swamp", "Illus. © Jesper Myrfors")))
        assertEquals("what's read still wins", "4ed 236", got(fourth))

        assertEquals("the original, before a fix", "zen 219", got(listOf("Marsh Flats", "Land", "Pay 1 life, Sacrifice Marsh Flats")))
        m.picked(printings("Marsh Flats").first { it.set == "mh2" && it.cn == "437" })
        assertEquals("retro, as picked", "mh2 439", got(listOf("Scalding Tarn", "Land", "Pay 1 life, Sacrifice Scalding Tarn")))
        assertEquals("mh2 436", got(listOf("Arid Mesa", "Land")))
    }

    /**
     * The border colour read from the camera frame (2026-11-01; testdata/scan/border.json from
     * testdata/scan/tools/border.swift): the rule over the luma samples of every photo with a border, as iOS samples
     * around Vision's rectangle (`quad`) and as Android samples along the guide box (`g100`), each also on a dim,
     * low-contrast copy (`dim.`). What counts is the 1993 frame (the only cards it picks between): most read right,
     * almost none wrong; a wrong read is no worse than today's Revised guess. Same as iOS testBorderRule.
     */
    @Test
    fun borderRule() {
        val photos = Json.parseToJsonElement(File(root, "border.json").readText()).jsonObject
        val old = photos().filter { "frame93" in it.tags }.map { it.id }.toSet()
        fun ints(e: JsonObject, key: String) = e.getValue(key).jsonArray.map { it.jsonPrimitive.content.toInt() }
        fun sides(e: JsonObject, key: String) = e.getValue(key).jsonArray.map { s -> s.jsonArray.map { it.jsonPrimitive.content.toInt() } }
        val report = mutableListOf("Border (${photos.size} photos):")
        class T { var right = 0; var wrong = 0; var unknown = 0; var oldRight = 0; var oldWrong = 0; var oldN = 0 }
        val tallies = HashMap<String, T>()
        for (read in listOf("quad", "dim.quad", "g100", "dim.g100")) {
            val t = T()
            for ((file, p) in photos) {
                val r = p.jsonObject.getValue("reads").jsonObject[read]?.jsonObject ?: continue
                val got = ScanBorder.classify(ScanBorder.Samples(sides(r, "inside"), sides(r, "outside"), sides(r, "far"), ints(r, "inner")))
                val isOld = file in old
                if (isOld) t.oldN++
                val expected = p.jsonObject.getValue("expected").jsonPrimitive.content
                if (got.name.lowercase() == expected) { t.right++; if (isOld) t.oldRight++ }
                else if (got == ScanBorder.UNKNOWN) t.unknown++
                else { t.wrong++; if (isOld) { t.oldWrong++; report += "    WRONG $read $file: $got" } }
            }
            tallies[read] = t
            report += "  $read: old frame right ${t.oldRight}/${t.oldN}, wrong ${t.oldWrong}; all right ${t.right}, wrong ${t.wrong}, unknown ${t.unknown}"
        }
        println(report.joinToString("\n"))
        fun oldRate(read: String) = tallies.getValue(read).let { it.oldRight.toDouble() / it.oldN }
        // What the set reached on 2026-11-01: quad 47/58 (1 wrong: a full-art basic), g100 31/58, dim 37/58 and 26/58.
        assertTrue(oldRate("quad") >= 0.78); assertTrue(tallies.getValue("quad").oldWrong <= 1)
        assertTrue(oldRate("g100") >= 0.5); assertTrue(tallies.getValue("g100").oldWrong <= 1)
        assertTrue(oldRate("dim.quad") >= 0.6); assertEquals(0, tallies.getValue("dim.quad").oldWrong)
        assertTrue(oldRate("dim.g100") >= 0.42); assertEquals(0, tallies.getValue("dim.g100").oldWrong)
        assertTrue(tallies.getValue("quad").wrong <= 10)
        assertEquals(ScanBorder.UNKNOWN, ScanBorder.classify(ScanBorder.Samples(emptyList(), emptyList(), emptyList(), emptyList())))
    }

    /**
     * The border breaks the Alpha / Beta / Unlimited / Revised tie (2026-11-01): black picks Beta, white Revised, a
     * French name with a black border Foreign Black Border; anything printed that was read still wins, and so does the
     * set last picked by hand. Remembered over the card's frames. Same as iOS testBorderPicksPrinting.
     */
    @Test
    fun borderPicksPrinting() {
        val m = matcher()
        fun got(lines: List<String>, border: ScanBorder) =
            m.match(lines, border)?.let { "${it.printing.set} ${it.printing.cn}${if (it.exact) " exact" else ""}" } ?: "nothing"
        val counterspell = listOf("Counterspell", "Interrupt", "Counter target spell.", "Illus. Mark Poole")
        assertEquals("no border read: Revised, as before", "3ed 54", got(counterspell, ScanBorder.UNKNOWN))
        assertEquals("black: Beta over Alpha", "leb 55", got(counterspell, ScanBorder.BLACK)); m.took()
        assertEquals("white: Revised over Unlimited", "3ed 54", got(counterspell, ScanBorder.WHITE)); m.took()
        assertEquals("no Illus. line read either", "leb 55", got(listOf("Counterspell", "Counters target spell", "as it is being cast."), ScanBorder.BLACK)); m.took()
        assertEquals("white, not in Revised", "2ed 233", got(listOf("Black Lotus", "Mono Artifact", "Illus. Christopher Rush"), ScanBorder.WHITE)); m.took()
        assertEquals("French, black: Foreign Black Border", "fbb 54", got(listOf("Contresort", "Interruption", "Illus. Mark Poole"), ScanBorder.BLACK)); m.took()
        assertEquals("the name's language beats the border", "fbb 54", got(listOf("Contresort", "Interruption", "Illus. Mark Poole"), ScanBorder.WHITE)); m.took()
        assertEquals("a year read wins over the border", "4ed 65",
            got(listOf("Counterspell", "Interrupt", "Illus. Mark Poole", "© 1995 Wizards of the Coast, Inc."), ScanBorder.BLACK)); m.took()
        assertEquals("a set code read wins", "ice 64 exact", got(listOf("Counterspell", "Instant", "ICE • EN"), ScanBorder.WHITE)); m.took()
        assertEquals("leb 55", got(counterspell, ScanBorder.BLACK))
        assertEquals("the border read two frames ago still counts", "leb 55", got(counterspell, ScanBorder.UNKNOWN)); m.took()
        assertEquals("forgotten with the take", "3ed 54", got(counterspell, ScanBorder.UNKNOWN))
        fun printings(name: String) = catalog.printings(catalog.expected.getValue(CardName.norm(name)))
        m.picked(printings("Tundra").first { it.set == "lea" })
        assertEquals("Alpha, as picked, over the white border", "lea 54", got(counterspell, ScanBorder.WHITE))
    }

    /** Upright pixels in the camera's raw image for each rotation CameraX reports, and what the sampling costs per frame. */
    @Test
    fun borderSamplingCostAndMapping() {
        // A 1920×1080 raw image that needs 90° to show upright (1080×1920): the upright top-left is the raw bottom-left.
        assertEquals(0 to 1079, ScanBorder.rawPixel(0, 0, 90, 1920, 1080))
        assertEquals(0 to 0, ScanBorder.rawPixel(1079, 0, 90, 1920, 1080))
        assertEquals(1919 to 1079, ScanBorder.rawPixel(0, 1919, 90, 1920, 1080))
        assertEquals(1919 to 0, ScanBorder.rawPixel(0, 0, 270, 1920, 1080))
        assertEquals(5 to 7, ScanBorder.rawPixel(5, 7, 0, 1080, 1920))
        assertEquals(1074 to 1912, ScanBorder.rawPixel(5, 7, 180, 1080, 1920))
        // A frame-sized luma plane with a white-bordered card in it; the samples and the rule per frame.
        val plane = ByteArray(1080 * 1920) { 60 }
        for (y in 400 until 1500) for (x in 150 until 930) plane[y * 1080 + x] = (if (y < 450 || y >= 1450 || x < 200 || x >= 880) 230 else 120).toByte()
        for (y in 1150 until 1400) for (x in 240 until 840) plane[y * 1080 + x] = (if ((x / 7 + y / 9) % 5 == 0) 20 else 215).toByte()
        val luma = { x: Double, y: Double -> plane[y.toInt().coerceIn(0, 1919) * 1080 + x.toInt().coerceIn(0, 1079)].toInt() and 0xFF }
        val guide = Box(170f, 430f, 740f, 1040f) // the card a little bigger than the outline
        assertEquals(ScanBorder.WHITE, ScanBorder.classify(ScanBorder.samples(guide, luma)))
        repeat(50) { ScanBorder.classify(ScanBorder.samples(guide, luma)) }
        val t = System.nanoTime()
        repeat(200) { ScanBorder.classify(ScanBorder.samples(guide, luma)) }
        val ms = (System.nanoTime() - t) / 200 / 1e6
        println("Border per frame (JVM): guide %.3f ms (624 reads)".format(ms))
        assertTrue("border sampling per frame $ms ms", ms < 5)
    }

    /** An old card whose name reads in every other frame or so: Crusade, named 6 times in 2.4 s with gaps of 0.6 s. */
    @Test
    fun oldFrameTaken() {
        val clips = Json.parseToJsonElement(File(root, "motion.json").readText()).jsonObject
        val crusade = clips.getValue("016-crusade.jpg").jsonArray.map { f -> f.jsonArray.map { it.jsonPrimitive.content } }
        assertEquals("Crusade", take(crusade)?.first?.oracle?.name)
        val m = matcher()
        val steady = ScanSteadiness()
        val lines = listOf("Crusade", "Enchantment", "All white creatures get +1/+1.")
        assertNull(steady.feed(m.match(lines), 0))
        assertNull(steady.feed(null, 400))
        assertNull("named twice: not enough", steady.feed(m.match(lines), 900))
        assertNotNull("a third read takes it", steady.feed(m.match(lines), 1100))
    }

    /** A card the scanner couldn't read between ones it could is a miss too (only a scan with no take was reported). */
    @Test
    fun missAfterTake() {
        val f = ScanFrames()
        repeat(3) { f.add(listOf("Scrubland", "Land"), named = true) }
        f.took()
        f.add(emptyList())
        repeat(ScanFrames.MISSED) { k -> f.add(listOf("D vamp $k", "Tap to add 4 to")) }
        assertEquals("blank frames don't count", ScanFrames.MISSED, f.unnamed)
        assertEquals(ScanFrames.KEEP, f.unnamedFrames.size)
        assertEquals("D vamp ${ScanFrames.MISSED - 1}", f.unnamedFrames.last().first())
        f.took()
        assertEquals(0, f.unnamed)
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
                language.feed(matched = m != null, text = lines.isNotEmpty(), now = at, latin = m != null && ScanLanguage.latin(m))
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
            if (!right) failures += "${c.id}: wanted $name ${c.set} ${c.cn}, got ${got?.first?.let { "${it.oracle.name} ${it.printing.setLabel}${if (it.exact) " (sure)" else ""}" } ?: "nothing"}"
        }
        println("Reported corrections (${t.n}): ${t.line()}" + failures.joinToString("") { "\n  still wrong: $it" })
        // Reports are the cases that went wrong before. Since the frame and artist evidence of 2026-10-28, the
        // printing is right in most of them; the rest are what no text tells (The List, prerelease stamps the camera
        // can't read, Unlimited vs Revised), so the floor sits under what the set reached then.
        assertEquals("a reported clip named the wrong card", 0, t.wrong)
        assertTrue(t.printingOk.toDouble() / maxOf(t.printingChecked, 1) >= Floor.REPORT_PRINTING)
    }

    private fun JsonObject.str(key: String, default: String = "") =
        this[key]?.jsonPrimitive?.content?.takeIf { it != "null" } ?: default

    /** The card gate (iOS testCardGate): with no card found in the frame, a name counts only with a type line or an
     *  exact set code and number, so a keyboard's "option" key isn't Opt. */
    @Test fun typeLineGate() {
        assertTrue(CardMatcher.hasTypeLine(listOf("Lightning Bolt", "Instant")))
        assertTrue(CardMatcher.hasTypeLine(listOf("Llanowar Elves", "Creature — Elf Druid")))
        assertTrue(CardMatcher.hasTypeLine(listOf("稲妻", "インスタント")))
        assertFalse(CardMatcher.hasTypeLine(listOf("command", "option", "control")))
        assertFalse(CardMatcher.hasTypeLine(listOf("4 Lightning Bolt", "4 Opt")))
    }
}
