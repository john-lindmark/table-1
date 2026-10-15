package site.table1.events.library

/* Scanner matching: OCR lines in, a card and printing out. Tuned against the photo test set in testdata/scan
   (README there; accuracy test in CardMatcherTest.kt). Same rules as iOS (CardMatcher.swift). */

data class ScanMatch(val oracle: CatalogOracle, val printing: CatalogPrinting, val exact: Boolean)

/** What the matcher reads from the catalog; CatalogDb on a phone, the test pack in unit tests. */
interface ScanCatalog {
    val version: String
    /** Every card: index, name, normalized name, type line, number of printings. */
    fun scanNames(): List<ScanName>
    fun setCodes(): Set<String>
    fun oracles(idxs: Collection<Int>): Map<Int, CatalogOracle>
    fun printings(oracleIdx: Int): List<CatalogPrinting>
    /** Printings by set code and collector number, any card, English first. */
    fun printings(set: String, cn: String): List<CatalogPrinting>
}

data class ScanName(val idx: Int, val name: String, val norm: String, val typeLine: String, val printings: Int)

/**
 * Names the scanner can read, built once per catalog pack: each card's name and a split or double-faced card's
 * front face (tokens, art cards, emblems and Vanguard left out), with trigrams for misread names.
 */
class ScanNames(catalog: ScanCatalog) {
    val version = catalog.version
    val sets = catalog.setCodes()
    /** Normalized names, sorted (cut-off names are looked up by prefix). */
    private val keys: List<String>
    private val idxs: IntArray
    private val byKey: Map<String, Int>
    private val grams: Map<Int, IntArray>

    init {
        val best = HashMap<String, Pair<Int, Int>>()
        for (o in catalog.scanNames()) {
            if (o.printings == 0 || UNSCANNABLE.any { o.typeLine.startsWith(it) }) continue
            val names = mutableListOf(o.norm)
            val cut = o.name.indexOf(" // ")
            if (cut >= 0) {
                val front = CardName.norm(o.name.substring(0, cut))
                if (front == CardName.norm(o.name.substring(cut + 4))) continue // an art card ("X // X")
                names.add(front)
            }
            for (k in names) if (best[k].let { it == null || o.printings > it.second }) best[k] = o.idx to o.printings
        }
        keys = best.keys.sorted()
        idxs = IntArray(keys.size) { best.getValue(keys[it]).first }
        byKey = keys.withIndex().associate { (i, k) -> k to i }
        val g = HashMap<Int, MutableList<Int>>()
        keys.forEachIndexed { i, k -> for (t in trigrams(k)) g.getOrPut(t) { mutableListOf() }.add(i) }
        grams = g.mapValues { it.value.toIntArray() }
    }

    fun exact(q: String): Int? = byKey[q]?.let { idxs[it] }

    /** A name cut off at the edge of the frame: the only name starting with it, of which it's most. */
    fun prefix(q: String): Int? {
        if (q.length < 8) return null
        var lo = 0
        var hi = keys.size
        while (lo < hi) { val mid = (lo + hi) / 2; if (keys[mid] < q) lo = mid + 1 else hi = mid }
        if (lo >= keys.size || !keys[lo].startsWith(q)) return null
        if (lo + 1 < keys.size && keys[lo + 1].startsWith(q)) return null
        return if (q.length >= 0.6 * keys[lo].length) idxs[lo] else null
    }

    /** A misread name: the closest name within about one edit in six letters, if nothing else is as close. */
    fun fuzzy(q: String): Int? {
        if (q.length < 5) return null
        val cap = maxOf(1, q.length / 6)
        val tg = trigrams(q)
        val shared = HashMap<Int, Int>()
        for (t in tg) grams[t]?.forEach { shared[it] = (shared[it] ?: 0) + 1 }
        var bestD = cap + 1
        var bestI = -1
        var second = cap + 1
        for ((i, n) in shared.entries.sortedByDescending { it.value }.take(60)) {
            if (n < tg.size * 0.4) break
            val d = distance(q, keys[i], cap)
            if (d < bestD) { second = bestD; bestD = d; bestI = i } else if (d < second) second = d
        }
        return if (bestI >= 0 && bestD <= cap && second > bestD) idxs[bestI] else null
    }

    companion object {
        @Volatile private var cached: ScanNames? = null

        /** The index for this pack, built on first use (a few hundred milliseconds; call it off the main thread). */
        fun shared(catalog: ScanCatalog): ScanNames = synchronized(this) {
            cached?.takeIf { it.version == catalog.version } ?: ScanNames(catalog).also { cached = it }
        }

        private val UNSCANNABLE = listOf("Token", "Card", "Emblem", "Vanguard")

        private fun trigrams(s: String): Set<Int> {
            val b = " $s "
            if (b.length < 3) return emptySet()
            return (0..b.length - 3).map { b[it].code shl 16 or (b[it + 1].code shl 8) or b[it + 2].code }.toSet()
        }

        /** Levenshtein distance, giving up (cap + 1) once it's sure to exceed cap. */
        private fun distance(a: String, b: String, cap: Int): Int {
            if (kotlin.math.abs(a.length - b.length) > cap) return cap + 1
            if (a.isEmpty() || b.isEmpty()) return maxOf(a.length, b.length)
            var prev = IntArray(b.length + 1) { it }
            var cur = IntArray(b.length + 1)
            for (i in 1..a.length) {
                cur[0] = i
                var low = i
                for (j in 1..b.length) {
                    cur[j] = minOf(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + if (a[i - 1] == b[j - 1]) 0 else 1)
                    low = minOf(low, cur[j])
                }
                if (low > cap) return cap + 1
                val t = prev; prev = cur; cur = t
            }
            return prev[b.length]
        }
    }
}

/** Turns OCR lines into a card. Remembers every lookup, so a steady frame costs no database work. */
class CardMatcher(
    private val catalog: ScanCatalog,
    private val owned: Map<String, Set<String>>?,
    private val names: ScanNames = ScanNames(catalog),
) {
    private val oracles = HashMap<Int, CatalogOracle?>()
    private val printingsByOracle = HashMap<Int, List<CatalogPrinting>>()
    private val bySetCn = HashMap<String, List<CatalogPrinting>>()

    fun match(lines: List<String>): ScanMatch? {
        val bottom = Collector(lines, names.sets)
        name(lines)?.let { idx -> oracle(idx)?.let { return pick(it, lines, bottom) } }
        // Not an English name (or none legible): the set code and collector number, when they agree on one card.
        val hits = LinkedHashMap<Int, CatalogPrinting>()
        for (s in bottom.sets) for (n in bottom.numbers) for (p in printings(s, n)) hits.putIfAbsent(p.oracleIdx, p)
        if (hits.size != 1) return null
        val (idx, p) = hits.entries.first()
        return oracle(idx)?.let { ScanMatch(it, p, true) }
    }

    /** The finish a scanned copy starts as: what you own of it in owned-only mode, else non-foil when printed. */
    fun defaultFinish(p: CatalogPrinting): String {
        owned?.get(p.cardId)?.let { have -> Finish.entries.firstOrNull { it.wire in have }?.let { return it.wire } }
        return (p.finishList.firstOrNull() ?: Finish.Nonfoil).wire
    }

    /**
     * The card's name: the top lines first (exactly, then cut off or misread), stopping at the type line, which the
     * name is always above; further down, only an exact name of two words or more (one word is often a keyword).
     */
    private fun name(lines: List<String>): Int? {
        val words = lines.take(12).map { l -> CardName.norm(l).split(' ').filter { it.isNotEmpty() } }.filter { it.size in 1..12 }
        fun exact(i: Int): Int? {
            for (q in candidates(words[i])) if (q.length >= 3) names.exact(q)?.takeIf(::allowed)?.let { return it }
            // A name broken over two lines.
            if (i + 1 < words.size && words[i].size <= 3 && words[i + 1].size <= 3) {
                for (q in candidates(words[i] + words[i + 1])) if (q.length >= 3) names.exact(q)?.takeIf(::allowed)?.let { return it }
            }
            return null
        }
        for (i in 0 until minOf(3, words.size)) {
            exact(i)?.let { return it }
            if (words[i].any { it in TYPE_WORDS }) break
            for (q in candidates(words[i])) (names.prefix(q) ?: names.fuzzy(q))?.takeIf(::allowed)?.let { return it }
        }
        for (i in minOf(3, words.size) until words.size) {
            exact(i)?.let { if (oracle(it)?.norm?.contains(' ') == true) return it }
        }
        return null
    }

    /** The line itself, then with up to three short trailing tokens (a misread mana cost) dropped. */
    private fun candidates(words: List<String>): List<String> {
        val out = mutableListOf(words.joinToString(" "))
        for (drop in 1..minOf(3, words.size - 1)) {
            if (words.takeLast(drop).all { it.length <= 3 }) out.add(words.dropLast(drop).joinToString(" "))
        }
        return out
    }

    /**
     * The printing: set code read (4), collector number read (2), copyright year (1); ties go to English, a
     * regular collector number, then the default printing. Exact when the set code and number agree, the set has
     * only one printing of the card, or the number and year single one out. A prerelease date stamp picks the
     * set's prerelease promo.
     */
    private fun pick(o: CatalogOracle, lines: List<String>, bottom: Collector): ScanMatch? {
        val ps = printings(o.idx)
        if (ps.isEmpty()) return null
        val years = years(lines)
        fun number(p: CatalogPrinting) = stripZeros(p.cn.lowercase())
        fun year(p: CatalogPrinting) = p.releasedAt.take(4).toIntOrNull()
        fun score(p: CatalogPrinting) = (if (p.set in bottom.sets) 4 else 0) + (if (number(p) in bottom.numbers) 2 else 0) +
            (if (year(p) in years) 1 else 0)
        var best = ps.sortedWith(
            compareByDescending<CatalogPrinting> { score(it) }.thenByDescending { it.lang == "en" }
                .thenBy { it.cn.endsWith("★") }.thenByDescending { it.original }.thenBy { it.ord },
        ).first()
        val exact = (best.set in bottom.sets && (number(best) in bottom.numbers || ps.count { it.set == best.set } == 1)) ||
            (number(best) in bottom.numbers && year(best) in years && ps.count { number(it) == number(best) } == 1)
        if (dated(lines)) {
            ps.firstOrNull { it.set == "p" + best.set && it.cn.lowercase().trimEnd('s', '★') == best.cn.lowercase() }?.let { best = it }
        }
        return ScanMatch(o, best, exact)
    }

    private fun oracle(idx: Int): CatalogOracle? = oracles.getOrPut(idx) { catalog.oracles(listOf(idx))[idx] }

    private fun printings(idx: Int) = printingsByOracle.getOrPut(idx) {
        catalog.printings(idx).let { all -> if (owned == null) all else all.filter { it.cardId in owned } }
    }

    private fun printings(set: String, cn: String) = bySetCn.getOrPut("$set|$cn") {
        catalog.printings(set, cn).let { all -> if (owned == null) all else all.filter { it.cardId in owned } }
    }

    private fun allowed(idx: Int) = owned == null || printings(idx).isNotEmpty()

    private companion object {
        val TYPE_WORDS = setOf("creature", "instant", "sorcery", "artifact", "enchantment", "land", "planeswalker", "battle",
            "summon", "interrupt", "kindred", "tribal", "legendary")
        val MONTHS = setOf("jan", "january", "feb", "february", "mar", "march", "apr", "april", "may", "jun", "june", "jul", "july",
            "aug", "august", "sep", "sept", "september", "oct", "october", "nov", "november", "dec", "december")
        val YEAR_RANGE = Regex("(19[89]\\d)\\s*[-–]?\\s*(20[0-4]\\d)")
        val YEAR = Regex("19[89]\\d|20[0-4]\\d")

        fun stripZeros(s: String) = s.trimStart('0').ifEmpty { if (s.isEmpty()) "" else "0" }

        /** Copyright years ("© 2019 Wizards", "1993-2003"): the last year of each. */
        fun years(lines: List<String>): Set<Int> {
            val out = HashSet<Int>()
            for (line in lines) {
                val range = YEAR_RANGE.find(line)
                if (range != null) out.add(range.groupValues[2].toInt())
                else if (line.contains("wizards", ignoreCase = true) || line.contains('©')) {
                    YEAR.findAll(line).lastOrNull()?.let { out.add(it.value.toInt()) }
                }
            }
            return out
        }

        /** A prerelease date stamp ("30-31 January 2021"): a month and a year on a line that isn't the copyright. */
        fun dated(lines: List<String>) = lines.any { line ->
            val l = line.lowercase()
            YEAR.containsMatchIn(l) && "wizards" !in l && l.split(Regex("[^a-z]+")).any { it in MONTHS }
        }
    }
}

/** What a card's bottom text says about its printing: "154/196 M", "RIX • RU", "M 0244", "FRA • EN". */
class Collector(lines: List<String>, known: Set<String>) {
    val sets = HashSet<String>()
    val numbers = HashSet<String>()

    init {
        var langLine = false
        for (line in lines) {
            for (m in SET_LANG.findAll(line)) {
                if (m.groupValues[2] !in LANGS) continue
                langLine = true
                val code = m.groupValues[1].lowercase()
                if (code in known) sets.add(code)
            }
            for (m in OF_TOTAL.findAll(line)) {
                if ((m.groupValues[3].toIntOrNull() ?: 0) >= 30) numbers.add(strip(m.groupValues[1]) + m.groupValues[2].lowercase())
            }
        }
        for (line in lines) {
            val m = ALONE.matchEntire(line) ?: continue
            val n = m.groupValues[1].replace(" ", "")
            if (n.length <= 4 && (langLine || n.length == 4)) numbers.add(strip(n))
        }
    }

    private companion object {
        val LANGS = setOf("EN", "DE", "FR", "IT", "ES", "PT", "JP", "JA", "RU", "KR", "KO", "CS", "CT", "PH", "ZHS", "ZHT")
        /** An uppercase code, a bullet or star, a language code ("one it ate." in rules text is not a set and a language). */
        val SET_LANG = Regex("\\b([A-Z0-9]{2,5})\\s*[•*·★+.]\\s*([A-Z]{2,3})\\b")
        /** "154/196": the number after the slash is the set's size, which tells it from power/toughness ("6/6"). */
        val OF_TOTAL = Regex("(?:^|[^\\d/])(\\d{1,4})([a-zA-Z]?)\\s*/\\s*(\\d{2,4})\\b")
        /** A line that is only a collector number, maybe with its rarity: "667", "R 0244", "0014", "07 29". */
        val ALONE = Regex("\\s*(?:[CURMLSTP]\\s+)?(\\d[\\d ]{0,4}\\d|\\d)(?:\\s+[CURMLSTP])?\\s*")

        fun strip(s: String) = s.trimStart('0').ifEmpty { "0" }
    }
}

/**
 * Holds a candidate until it's steady, and keeps a card from being taken twice while it stays in frame.
 * Timings from the movement clips in testdata/scan (motion.json): a hand settling a card or holding it with a
 * little shake is taken within about a second; a card swept past the camera isn't taken at all.
 */
class ScanSteadiness {
    private class Candidate(val idx: Int, val since: Long, var seen: Long, var latest: CatalogPrinting) {
        /** Exact reads per printing; the most read one wins. */
        val votes = LinkedHashMap<String, Pair<CatalogPrinting, Int>>()
    }
    private var candidate: Candidate? = null
    private var lastIdx: Int? = null
    private var lastSeen = 0L

    /** Feed every frame's match (or null). Returns the printing once a card should be taken. */
    fun feed(m: ScanMatch?, now: Long = System.currentTimeMillis()): Pair<CatalogPrinting, Boolean>? {
        if (m == null) {
            candidate?.let { if (now - it.seen > GAP_MS) candidate = null }
            return null
        }
        if (lastIdx == m.oracle.idx && now - lastSeen < AWAY_MS) { lastSeen = now; return null }
        val c = candidate?.takeIf { it.idx == m.oracle.idx && now - it.seen <= GAP_MS }
            ?: Candidate(m.oracle.idx, now, now, m.printing).also { candidate = it }
        c.seen = now
        c.latest = m.printing
        if (m.exact) c.votes[m.printing.cardId] = m.printing to ((c.votes[m.printing.cardId]?.second ?: 0) + 1)
        val voted = c.votes.values.maxByOrNull { it.second }?.first
        val held = now - c.since
        if (!((voted != null && held >= QUICK_MS) || held >= SLOW_MS)) return null
        candidate = null
        lastIdx = m.oracle.idx
        lastSeen = now
        return if (voted != null) voted to true else c.latest to false
    }

    companion object {
        /** Taken this long after it's first seen once its printing is read; without the printing, a little longer. */
        const val QUICK_MS = 400L
        const val SLOW_MS = 800L
        /** A blurred or unreadable frame doesn't drop the card in view unless the gap lasts this long. */
        const val GAP_MS = 500L
        /** After a take, the same card has to be out of view this long before it counts again. */
        const val AWAY_MS = 1000L
    }
}
