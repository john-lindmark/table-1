package site.table1.events.library

/* Scanner matching: OCR lines in, a card and printing out. Tuned against the photo test set in testdata/scan
   (README there; accuracy test in CardMatcherTest.kt). Same rules as iOS (CardMatcher.swift). */

data class ScanMatch(val oracle: CatalogOracle, val printing: CatalogPrinting, val exact: Boolean)

/** What the matcher reads from the catalog; CatalogDb on a phone, the test pack in unit tests. */
interface ScanCatalog {
    val version: String
    /** Every card: index, name, normalized name, type line, number of printings. */
    fun scanNames(): List<ScanName>
    /** Printed names in other languages (pack N lines): oracle index and normalized name, one per card and name. */
    fun foreignNames(): List<Pair<Int, String>>
    fun setCodes(): Set<String>
    fun oracles(idxs: Collection<Int>): Map<Int, CatalogOracle>
    fun printings(oracleIdx: Int): List<CatalogPrinting>
    /** Printings by set code and collector number, any card, English first. */
    fun printings(set: String, cn: String): List<CatalogPrinting>
}

data class ScanName(val idx: Int, val name: String, val norm: String, val typeLine: String, val printings: Int)

/**
 * Names the scanner can read, built once per catalog pack: each card's name and a split or double-faced card's
 * front face (tokens, art cards, emblems and Vanguard left out), its printed names in other languages (pack N
 * lines; never over an English name, and left out when two cards share one), with trigrams for misread names.
 */
class ScanNames(catalog: ScanCatalog) {
    val version = catalog.version
    val sets = catalog.setCodes()
    /** Normalized names, sorted (cut-off names are looked up by prefix). */
    private val keys: List<String>
    private val idxs: IntArray
    private val byKey: Map<String, Int>
    /** Trigram → the keys containing it: a range of [postings] (key positions, ascending), packed start shl 32 or end. */
    private val grams: HashMap<Int, Long>
    private val postings: IntArray

    init {
        // Second of the pair: printings, or -1 for a printed name in another language; first -1 when two cards share it.
        val best = HashMap<String, Pair<Int, Int>>()
        val scannable = HashSet<Int>()
        for (o in catalog.scanNames()) {
            if (o.printings == 0 || UNSCANNABLE.any { o.typeLine.startsWith(it) }) continue
            val names = mutableListOf(o.norm)
            val cut = o.name.indexOf(" // ")
            if (cut >= 0) {
                val front = CardName.norm(o.name.substring(0, cut))
                if (front == CardName.norm(o.name.substring(cut + 4))) continue // an art card ("X // X")
                names.add(front)
            }
            scannable.add(o.idx)
            for (k in names) if (best[k].let { it == null || o.printings > it.second }) best[k] = o.idx to o.printings
        }
        for ((idx, norm) in catalog.foreignNames()) {
            if (idx !in scannable) continue
            val b = best[norm]
            if (b == null) best[norm] = idx to -1 else if (b.second < 0 && b.first != idx) best[norm] = -1 to -1
        }
        keys = best.keys.filter { best.getValue(it).first >= 0 }.sorted()
        idxs = IntArray(keys.size) { best.getValue(keys[it]).first }
        byKey = HashMap<String, Int>(keys.size * 2).also { m -> keys.forEachIndexed { i, k -> m[k] = i } }
        // Every (trigram, key position), sorted, becomes one posting list per trigram.
        var pairs = LongArray(keys.size * 20)
        var n = 0
        keys.forEachIndexed { i, k ->
            val codes = trigramCodes(k)
            codes.sort()
            for (j in codes.indices) {
                if (j > 0 && codes[j] == codes[j - 1]) continue
                if (n == pairs.size) pairs = pairs.copyOf(n * 2)
                pairs[n++] = codes[j].toLong() shl 32 or i.toLong()
            }
        }
        pairs = pairs.copyOf(n)
        pairs.sort()
        postings = IntArray(n) { pairs[it].toInt() }
        grams = HashMap()
        var start = 0
        for (j in 0 until n) {
            if (j + 1 == n || pairs[j + 1] ushr 32 != pairs[j] ushr 32) {
                grams[(pairs[j] ushr 32).toInt()] = start.toLong() shl 32 or (j + 1).toLong()
                start = j + 1
            }
        }
    }

    fun exact(q: String): Int? = byKey[q]?.let { idxs[it] }

    /**
     * A name cut off at the edge of the frame: only one card has names starting with it (its English and printed
     * names often share a start: "Urza's Saga", "Urzas Sage"), and it's most of one of them.
     */
    fun prefix(q: String): Int? {
        if (q.length < (if (CardName.hasCjk(q)) 4 else 8)) return null
        var lo = 0
        var hi = keys.size
        while (lo < hi) { val mid = (lo + hi) / 2; if (keys[mid] < q) lo = mid + 1 else hi = mid }
        var hit: Int? = null
        var most = false
        for (j in lo until minOf(keys.size, lo + 16)) {
            if (!keys[j].startsWith(q)) break
            if (hit != null && hit != idxs[j]) return null
            hit = idxs[j]
            if (q.length >= 0.6 * keys[j].length) most = true
        }
        return if (most) hit else null
    }

    /**
     * A misread name: the closest name within about one edit in eight letters, if no other card's name is as close.
     * Han, kana and Hangul carry more per character: four of them at least, and one edit in six.
     */
    fun fuzzy(q: String): Int? {
        val cjk = CardName.hasCjk(q)
        if (q.length < (if (cjk) 4 else 5) || q.toByteArray(Charsets.UTF_8).size >= 250) return null
        val cap = maxOf(1, q.length / (if (cjk) 6 else 8))
        val tg = trigrams(q)
        val shared = ByteArray(keys.size)
        val touched = ArrayList<Int>()
        for (t in tg) {
            val r = grams[t] ?: continue
            for (j in (r ushr 32).toInt() until r.toInt()) {
                val i = postings[j]
                if (shared[i].toInt() == 0) touched.add(i)
                shared[i]++
            }
        }
        // The 60 names sharing the most trigrams, of those sharing at least 40%.
        val enough = Math.ceil(tg.size * 0.4)
        fun count(i: Int) = shared[i].toInt() and 0xFF
        val top = touched.filter { count(it) >= enough }.sortedWith(compareByDescending<Int> { count(it) }.thenBy { it }).take(60)
        var bestD = cap + 1
        var bestI = -1
        var second = cap + 1
        for (i in top) {
            val d = distance(q, keys[i], cap)
            val other = bestI < 0 || idxs[bestI] != idxs[i]
            if (d < bestD) { if (other) second = bestD; bestD = d; bestI = i } else if (d < second && other) second = d
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

        private fun trigrams(s: String): Set<Int> = trigramCodes(s).toSet()

        /**
         * The name's UTF-8 bytes padded with a space each side, as trigram codes (repeats included); bytes like iOS, so a
         * Han, kana or Hangul character (three bytes) shares trigrams with its neighbours and a short name misread by
         * one character still shares enough of them.
         */
        private fun trigramCodes(s: String): IntArray {
            val b = " $s ".toByteArray(Charsets.UTF_8)
            if (b.size < 3) return IntArray(0)
            return IntArray(b.size - 2) { (b[it].toInt() and 0xFF) shl 16 or ((b[it + 1].toInt() and 0xFF) shl 8) or (b[it + 2].toInt() and 0xFF) }
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
    /** Owned-only: printing id → finishes in for-trade binders. Among printings the text scores alike these win
     *  (contract/binders-wants-2026-10-17.md), and their finish is the default. */
    private val preferred: Map<String, Set<String>> = emptyMap(),
) {
    private val oracles = HashMap<Int, CatalogOracle?>()
    private val printingsByOracle = HashMap<Int, List<CatalogPrinting>>()
    private val bySetCn = HashMap<String, List<CatalogPrinting>>()

    fun match(lines: List<String>): ScanMatch? {
        val bottom = Collector(lines, names.sets)
        name(lines)?.let { idx -> oracle(idx)?.let { return pick(it, lines, bottom) } }
        // Not an English name (or none legible): the set code and collector number, when they agree on one card.
        val hits = LinkedHashMap<Int, CatalogPrinting>()
        for (s in bottom.sets) for (n in bottom.collectorNumbers) for (p in printings(s, n)) hits.putIfAbsent(p.oracleIdx, p)
        if (hits.size != 1) return null
        val (idx, p) = hits.entries.first()
        return oracle(idx)?.let { ScanMatch(it, p, true) }
    }

    /** The finish a scanned copy starts as: what you own of it in owned-only mode, else non-foil when printed. */
    fun defaultFinish(p: CatalogPrinting): String {
        preferred[p.cardId]?.let { trade -> Finish.entries.firstOrNull { it.wire in trade }?.let { return it.wire } }
        owned?.get(p.cardId)?.let { have -> Finish.entries.firstOrNull { it.wire in have }?.let { return it.wire } }
        return (p.finishList.firstOrNull() ?: Finish.Nonfoil).wire
    }

    /**
     * The card's name: the top lines first (exactly, then cut off or misread), stopping at the type line, which the
     * name is always above; further down, only an exact name of two words or more (one word is often a keyword).
     */
    private fun name(lines: List<String>): Int? {
        // Furigana over a Japanese name isn't a line of its own, unless it's a name itself.
        val read = lines.take(12).map { l -> l to CardName.norm(l).split(' ').filter { it.isNotEmpty() } }
            .filter { (_, w) -> w.size in 1..12 && !(furigana(w) && names.exact(w[0]) == null) }
        val words = read.map { it.second }
        /**
         * A one-word name only from the first two lines of card text, not from a line in capitals: one word lower
         * down is usually a keyword ("Fliegen" is also the German name of Fly), and capitals are a grading label
         * ("FOIL"), which also doesn't count as a line above the name. Japanese, Chinese and Korean lines are one
         * word (no spaces in their names) and have no capitals.
         */
        val text = read.map { (line, w) -> line.any { it.isLowerCase() } || w.any(CardName::hasCjk) }
        // A name of one or two Han, kana or Hangul characters only from the first line: on the second it's usually a
        // keyword ("飛行", Flying, is also the Japanese name of Flight).
        fun fits(q: String, i: Int) =
            ' ' in q || (text[i] && (0 until i).count { text[it] } <= (if (q.length <= 2 && CardName.hasCjk(q)) 0 else 1))
        fun long(q: String) = q.length >= (if (CardName.hasCjk(q)) 2 else 3)
        fun exact(i: Int): Int? {
            for (q in candidates(words[i])) if (long(q) && fits(q, i)) names.exact(q)?.takeIf(::allowed)?.let { return it }
            // A name broken over two lines.
            if (i + 1 < words.size && words[i].size <= 3 && words[i + 1].size <= 3) {
                for (q in candidates(words[i] + words[i + 1])) if (long(q) && fits(q, i)) names.exact(q)?.takeIf(::allowed)?.let { return it }
            }
            return null
        }
        for (i in 0 until minOf(3, words.size)) {
            exact(i)?.let { return it }
            if (typeLine(words[i])) break
            for (q in candidates(words[i])) if (fits(q, i)) (names.prefix(q) ?: names.fuzzy(q))?.takeIf(::allowed)?.let { return it }
        }
        // Not a Japanese, Chinese or Korean name: short ones turn up in rules text.
        for (i in minOf(3, words.size) until words.size) {
            if (words[i].any(CardName::hasCjk)) continue
            exact(i)?.let { if (oracle(it)?.norm?.contains(' ') == true) return it }
        }
        return null
    }

    /** The line itself, then with up to three short trailing tokens (a misread mana cost) dropped. */
    private fun candidates(words: List<String>): List<String> {
        val out = mutableListOf(join(words))
        for (drop in 1..minOf(3, words.size - 1)) {
            if (words.takeLast(drop).all { it.length <= 3 }) out.add(join(words.dropLast(drop)))
        }
        return out
    }

    /** Words joined as CardName.norm would: a space, except between two of Han, kana and Hangul (a name over two lines). */
    private fun join(words: List<String>): String {
        val out = StringBuilder()
        for (w in words) {
            if (out.isNotEmpty() && w.isNotEmpty() &&
                !(CardName.isCjk(Character.codePointBefore(out, out.length)) && CardName.isCjk(w.codePointAt(0)))
            ) out.append(' ')
            out.append(w)
        }
        return out.toString()
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
            compareByDescending<CatalogPrinting> { score(it) }.thenByDescending { it.cardId in preferred }.thenByDescending { it.lang == "en" }
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
            "summon", "interrupt", "kindred", "tribal", "legendary",
            // The same on foreign printings (normalized: no accents).
            "kreatur", "spontanzauber", "hexerei", "artefakt", "verzauberung", "beschworung", "beschworen", "invoquer", "unterbrechungszauber", "legendare",
            "legendarer", "legendares", "ephemere", "rituel", "artefact", "enchantement", "terrain", "invocation", "interruption",
            "legendaire", "bataille", "criatura", "instantaneo", "conjuro", "artefacto", "encantamiento", "tierra", "invocar",
            "interrupcion", "legendaria", "legendario", "batalla", "creatura", "stregoneria", "artefatto", "incantesimo", "terra",
            "evoca", "interruzione", "leggendaria", "leggendario", "battaglia", "instantanea", "feitico", "artefato", "encantamento",
            "terreno", "lendaria", "lendario", "batalha", "существо", "мгновенное", "волшебство", "артефакт", "чары", "земля",
            "легендарное", "легендарныи", "легендарная", "сражение")

        /**
         * Type lines in Japanese, Chinese and Korean, normalized (no spaces): a line containing one of these is a type
         * line, since a CJK line normalizes to a single word. "リーチャー": OCR often misreads the ク of クリーチャー.
         */
        val CJK_TYPE_WORDS = listOf(
            "リーチャー", "インスタント", "ソーサリー", "エンチャント", "アーティファクト", "プレインズウォーカー", "土地", "伝説の",
            "召喚", "部族", "同族", "バトル", "割り込み", "インタラプト", "生物", "瞬间", "瞬間", "法术", "法術", "巫术", "巫術", "神器", "结界", "結界", "鹏洛客",
            "鵬洛客", "传奇", "傳奇", "基本地", "魔法力源", "战役", "戰役", "생물", "순간마법", "집중마법", "마법물체", "부여마법", "마법부여", "대지",
            "플레인즈워커", "전설적", "소환", "전투", "동족", "부족",
        ).map(CardName::norm)

        fun typeLine(words: List<String>) = words.any { it in TYPE_WORDS } || words.any { w -> CJK_TYPE_WORDS.any { it in w } }

        /** Furigana: a short line of hiragana only, the reading printed over a Japanese name. */
        fun furigana(words: List<String>) = words.size == 1 && words[0].length <= 12 && words[0].all { it in '\u3041'..'\u309F' }
        /** Month names as a date stamp prints them, normalized: English, then de, fr, it, es, pt, ru. */
        val MONTHS = setOf(
            "jan", "january", "feb", "february", "mar", "march", "apr", "april", "may", "jun", "june", "jul", "july",
            "aug", "august", "sep", "sept", "september", "oct", "october", "nov", "november", "dec", "december", "januar",
            "februar", "marz", "mai", "juni", "juli", "oktober", "dezember", "janvier", "fevrier", "mars", "avril", "juin",
            "juillet", "aout", "septembre", "octobre", "novembre", "decembre", "gennaio", "febbraio", "marzo", "aprile",
            "maggio", "giugno", "luglio", "agosto", "settembre", "ottobre", "dicembre", "enero", "febrero", "abril",
            "mayo", "junio", "julio", "septiembre", "octubre", "noviembre", "diciembre", "janeiro", "fevereiro", "marco",
            "maio", "junho", "julho", "setembro", "outubro", "novembro", "dezembro", "января", "февраля", "марта",
            "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря",
        )
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

        /** A prerelease date stamp ("30-31 January 2021", "27-28 giugno 2020"): a month and a year on a line that isn't the copyright. */
        fun dated(lines: List<String>) = lines.any { line ->
            val l = CardName.norm(line)
            YEAR.containsMatchIn(l) && "wizards" !in l && l.split(Regex("[^a-zа-я]+")).any { it in MONTHS }
        }
    }
}

/** What a card's bottom text says about its printing: "154/196 M", "RIX • RU", "M 0244", "FRA • EN". */
class Collector(lines: List<String>, known: Set<String>) {
    val sets = HashSet<String>()
    val numbers = HashSet<String>()
    /** The numbers written as collector numbers ("154/196", "0244", "R 1695", "297"), not a lone "212" that may be a misread 2/2. */
    val collectorNumbers = HashSet<String>()

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
                if ((m.groupValues[3].toIntOrNull() ?: 0) >= 30) {
                    val n = strip(m.groupValues[1]) + m.groupValues[2].lowercase()
                    numbers.add(n)
                    collectorNumbers.add(n)
                }
            }
        }
        for (line in lines) {
            val m = ALONE.matchEntire(line) ?: continue
            val n = m.groupValues[1].replace(" ", "")
            if (n.length <= 4 && (langLine || n.length == 4)) {
                numbers.add(strip(n))
                // "0244", "R 1695", or three digits that can't be power/toughness read with the slash as 1 or 7 ("2/2" → "212").
                val toughness = n.length == 3 && n[1] in "17"
                if ((n.length == 4 && n[0] == '0') || line.any { it.isLetter() } || (n.length == 3 && !toughness)) collectorNumbers.add(strip(n))
            }
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

/**
 * Which script the camera reads. Nobody picks a language: it reads like the phone (Latin and Cyrillic, English
 * first) until there's text in view that names no card for a while, then switches to Chinese, Japanese and Korean
 * (iOS: Vision's automatic language detection, one reader; Android: ML Kit's Japanese, Chinese and Korean
 * recognizers, one a frame in turn). It stays there while cards keep matching and goes back after a run of misses.
 * The frames spent finding the script are frames ScanSteadiness sees nothing in, so a switch never takes a card early.
 */
class ScanLanguage(private val readers: Int) {
    /** -1 reads Latin; 0 until [readers] is the CJK reader in use. */
    var mode = LATIN
        private set
    private var missSince: Long? = null

    /** Feed every frame: whether its lines named a card, and whether there were any lines at all. */
    fun feed(matched: Boolean, text: Boolean, now: Long = System.currentTimeMillis()) {
        if (matched) { missSince = null; return }
        if (mode == LATIN) {
            if (!text) { missSince = null; return }
            val since = missSince ?: now
            missSince = since
            if (now - since >= DETECT_MS) { mode = 0; missSince = now }
        } else {
            val since = missSince ?: now
            missSince = since
            if (now - since >= BACK_MS) { mode = LATIN; missSince = null } else mode = (mode + 1) % readers
        }
    }

    companion object {
        const val LATIN = -1
        /** Text naming no card for this long switches to CJK reading. */
        const val DETECT_MS = 600L
        /** CJK reading naming no card for this long goes back. */
        const val BACK_MS = 1200L
    }
}
