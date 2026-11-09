package site.table1.events.library

import kotlin.math.abs

/* Scanner matching: OCR lines in, a card and printing out. Tuned against the photo test set in testdata/scan
   (README there; accuracy test in CardMatcherTest.kt). Same rules as iOS (CardMatcher.swift). */

/**
 * A card read, its printing and whether that was read ([exact]), and the languages its text says it's in ([langs]):
 * the language code by the set code ("WAR • JP"), else the languages of the printed name read; empty when neither
 * tells (an English name, which many cards print in every language).
 */
data class ScanMatch(val oracle: CatalogOracle, val printing: CatalogPrinting, val exact: Boolean, val langs: List<String> = emptyList())

/** What the matcher reads from the catalog; CatalogDb on a phone, the test pack in unit tests. */
interface ScanCatalog {
    val version: String
    /** Every card: index, name, normalized name, type line, number of printings. */
    fun scanNames(): List<ScanName>
    /** Printed names in other languages (pack N lines), one per card, language and name. */
    fun foreignNames(): List<ForeignName>
    fun setCodes(): Set<String>
    fun oracles(idxs: Collection<Int>): Map<Int, CatalogOracle>
    fun printings(oracleIdx: Int): List<CatalogPrinting>
    /** Printings by set code and collector number, any card, English first. */
    fun printings(set: String, cn: String): List<CatalogPrinting>
}

data class ScanName(val idx: Int, val name: String, val norm: String, val typeLine: String, val printings: Int)

/** A printed name in another language, normalized. */
data class ForeignName(val idx: Int, val lang: String, val norm: String)

/**
 * Names the scanner can read, built once per catalog pack: each card's name and a split or double-faced card's
 * front face (tokens, art cards, emblems and Vanguard left out), its printed names in other languages (pack N
 * lines; never over an English name, and left out when two cards share one), with trigrams for misread names.
 * Each name knows the languages it's printed in, so a card read by its German name goes in as German.
 */
class ScanNames(catalog: ScanCatalog) {
    val version = catalog.version
    val sets = catalog.setCodes()
    /**
     * A card the name belongs to, and the languages it's printed in (empty for an English name, which doesn't
     * tell: a German card whose name is the English one reads the same).
     */
    data class Hit(val idx: Int, val langs: List<String>)
    /** Normalized names, sorted (cut-off names are looked up by prefix). */
    private val keys: List<String>
    private val idxs: IntArray
    /** Per key, a bit per language in [Languages.all] (0 = an English name). */
    private val langBits: IntArray
    private val byKey: Map<String, Int>
    /** Trigram → the keys containing it: a range of [postings] (key positions, ascending), packed start shl 32 or end. */
    private val grams: HashMap<Int, Long>
    private val postings: IntArray
    /**
     * Each half of a split card (instants and sorceries: Fire // Ice, fuse, Aftermath; and Rooms), normalized → the
     * cards with that half (Fire: Fire // Ice and Start // Fire). Every half of a split card is printed on the one
     * face, so two halves of one card read are that card (README § Split cards).
     */
    private val halves: Map<String, List<Int>>
    /**
     * The halves after the first (Ice, Memory, a Room's second door) that no other card is named: read exactly, the
     * card. Not in the trigram index, so cut-off and misread names never come to them (Liberate, Blood, Chaos and
     * Saw are also cards or tokens of their own, so Bind // Liberate's Liberate isn't here).
     */
    private val laterHalves: Map<String, Int>

    init {
        val all = catalog.scanNames()
        // Every name and face name any card has, tokens too: a later half by one of these isn't the split card's.
        val taken = HashMap<String, MutableSet<Int>>()
        for (o in all) {
            taken.getOrPut(o.norm) { HashSet() }.add(o.idx)
            if (" // " in o.name) for (face in o.name.split(" // ")) taken.getOrPut(CardName.norm(face)) { HashSet() }.add(o.idx)
        }
        val halves = HashMap<String, MutableList<Int>>()
        val later = HashMap<String, Int>()
        for (o in all) {
            if (o.printings == 0 || !split(o.name, o.typeLine)) continue
            for ((k, face) in o.name.split(" // ").withIndex()) {
                val h = CardName.norm(face)
                val cards = halves.getOrPut(h) { mutableListOf() }
                if (o.idx !in cards) cards.add(o.idx)
                if (k > 0 && taken[h] == setOf(o.idx)) later[h] = if (h in later) -1 else o.idx
            }
        }
        this.halves = halves
        laterHalves = later.filterValues { it >= 0 }
        // printings -1 marks a printed name in another language; idx -1 one that two cards share.
        class Best(val idx: Int, val printings: Int, val langs: Int = 0)
        val best = HashMap<String, Best>()
        val scannable = HashSet<Int>()
        for (o in all) {
            if (o.printings == 0 || UNSCANNABLE.any { o.typeLine.startsWith(it) }) continue
            val names = mutableListOf(o.norm)
            val cut = o.name.indexOf(" // ")
            if (cut >= 0) {
                val front = CardName.norm(o.name.substring(0, cut))
                if (front == CardName.norm(o.name.substring(cut + 4))) continue // an art card ("X // X")
                names.add(front)
            }
            scannable.add(o.idx)
            for (k in names) if (best[k].let { it == null || o.printings > it.printings }) best[k] = Best(o.idx, o.printings)
        }
        val bit = Languages.all.withIndex().associate { (i, l) -> l.first to (1 shl i) }
        for ((idx, lang, norm) in catalog.foreignNames()) {
            if (idx !in scannable) continue
            val l = bit[lang] ?: 0
            val b = best[norm]
            if (b == null) best[norm] = Best(idx, -1, l)
            else if (b.printings < 0 && b.idx != idx) best[norm] = Best(-1, -1)
            else if (b.printings < 0 && b.idx == idx) best[norm] = Best(idx, -1, b.langs or l)
        }
        keys = best.keys.filter { best.getValue(it).idx >= 0 }.sorted()
        idxs = IntArray(keys.size) { best.getValue(keys[it]).idx }
        langBits = IntArray(keys.size) { best.getValue(keys[it]).langs }
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

    fun exact(q: String): Hit? = byKey[q]?.let(::hit)

    /** A split card by a later half's name read exactly (Ice, Memory). */
    fun laterHalf(q: String): Hit? = laterHalves[q]?.let { Hit(it, emptyList()) }

    /** The split cards a half's name belongs to, any half. */
    fun half(q: String): List<Int> = halves[q] ?: emptyList()

    private fun hit(i: Int) = Hit(idxs[i], langs(langBits[i]))

    private fun langs(bits: Int) = Languages.all.indices.filter { bits and (1 shl it) != 0 }.map { Languages.all[it].first }

    /**
     * A name cut off at the edge of the frame: only one card has names starting with it (its English and printed
     * names often share a start: "Urza's Saga", "Urzas Sage"), and it's most of one of them.
     */
    fun prefix(q: String): Hit? {
        if (q.length < (if (CardName.hasCjk(q)) 4 else 8)) return null
        var lo = 0
        var hi = keys.size
        while (lo < hi) { val mid = (lo + hi) / 2; if (keys[mid] < q) lo = mid + 1 else hi = mid }
        var hit: Int? = null
        var most = false
        // The languages of the names it starts; none when one of them is English (it doesn't tell).
        var bits: Int? = null
        for (j in lo until minOf(keys.size, lo + 16)) {
            if (!keys[j].startsWith(q)) break
            if (hit != null && hit != idxs[j]) return null
            hit = idxs[j]
            bits = if (bits == 0 || langBits[j] == 0) 0 else (bits ?: 0) or langBits[j]
            if (q.length >= 0.6 * keys[j].length) most = true
        }
        return if (most) hit?.let { Hit(it, langs(bits ?: 0)) } else null
    }

    /**
     * A misread name: the closest name within about one edit in eight letters, if no other card's name is as close.
     * Han, kana and Hangul carry more per character: four of them at least, and one edit in six.
     */
    fun fuzzy(q: String): Hit? {
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
        return if (bestI >= 0 && bestD <= cap && second > bestD) hit(bestI) else null
    }

    companion object {
        @Volatile private var cached: ScanNames? = null

        /** The index for this pack, built on first use (a few hundred milliseconds; call it off the main thread). */
        fun shared(catalog: ScanCatalog): ScanNames = synchronized(this) {
            cached?.takeIf { it.version == catalog.version } ?: ScanNames(catalog).also { cached = it }
        }

        private val UNSCANNABLE = listOf("Token", "Card", "Emblem", "Vanguard")

        private val SPELLS = setOf("Instant", "Sorcery", "Kindred", "Tribal")

        /**
         * A split card: its halves are all instants or sorceries (split, fuse, Aftermath) or all Rooms, every one
         * printed on the same face. Adventures, omens, flip and double-faced cards have a creature, land or other face.
         */
        fun split(name: String, typeLine: String): Boolean {
            val faces = typeLine.split(" // ")
            if (faces.size < 2 || faces.size != name.split(" // ").size) return false
            return faces.all { f ->
                val types = f.split("—").first().split(' ').filter { it.isNotEmpty() }
                types.isNotEmpty() && types.all { it in SPELLS }
            } || faces.all { it.endsWith("Room") }
        }

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
    /** The last printing picked by hand this session. When nothing read tells a card's printings apart, the next
     *  card goes in as that set, nearest that collector number: after one fix, a stack of Beta cards or a run of
     *  MH2's retro fetchlands (436–440, not the regular 248–254) follows. */
    var lastPick: CatalogPrinting? = null
        private set

    /** [border]: the colour of the card's border read from the camera frame ([ScanBorder]), when the scanner could tell. */
    fun match(lines: List<String>, border: ScanBorder = ScanBorder.UNKNOWN): ScanMatch? {
        val frame = Collector(lines, names.sets, border)
        name(lines)?.let { hit ->
            oracle(hit.idx)?.let { o ->
                val bottom = remembered(o.idx, frame)
                val m = pick(o, bottom, hit.langs) ?: run { missed(); return null }
                return m.copy(langs = bottom.lang?.let { listOf(it) } ?: hit.langs)
            }
        }
        // Not an English name (or none legible): the set code and collector number, when they agree on one card.
        val hits = LinkedHashMap<Int, CatalogPrinting>()
        for (s in frame.sets) for (n in frame.collectorNumbers) for (p in printings(s, n)) hits.putIfAbsent(p.oracleIdx, p)
        if (hits.size != 1) { missed(); return null }
        val (idx, p) = hits.entries.first()
        val o = oracle(idx) ?: run { missed(); return null }
        remembered(idx, frame)
        return ScanMatch(o, p, true, frame.lang?.let { listOf(it) } ?: emptyList())
    }

    /** A printing picked by hand (the scanned row's Change printing): the guess for the next card that reads alike. */
    fun picked(p: CatalogPrinting) { lastPick = p; recent = null }

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
    private fun name(lines: List<String>): ScanNames.Hit? {
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
        // A split card's halves, each a line of its own anywhere: printed sideways, the halves' title lines can land
        // anywhere among the lines (below their own type lines too). Two halves of one card can't come from anything
        // else, so where they are doesn't matter.
        splitHalves(lines)?.let { return it }
        fun exact(i: Int): ScanNames.Hit? {
            for (q in candidates(words[i])) if (long(q) && fits(q, i)) (names.exact(q) ?: names.laterHalf(q))?.takeIf { allowed(it.idx) }?.let { return it }
            // A name broken over two lines.
            if (i + 1 < words.size && words[i].size <= 3 && words[i + 1].size <= 3) {
                for (q in candidates(words[i] + words[i + 1])) if (long(q) && fits(q, i)) names.exact(q)?.takeIf { allowed(it.idx) }?.let { return it }
            }
            return null
        }
        for (i in 0 until minOf(3, words.size)) {
            exact(i)?.let { return it }
            if (typeLine(words[i])) break
            for (q in candidates(words[i])) if (fits(q, i)) (names.prefix(q) ?: names.fuzzy(q))?.takeIf { allowed(it.idx) }?.let { return it }
        }
        // Not a Japanese, Chinese or Korean name: short ones turn up in rules text. And never from below the type
        // line: the title is above it, and the flavor text under it names people who are cards too (an Ice Age
        // Counterspell whose title didn't read went in as Gustha Ebbasdotter, from "-Gustha Ebbasdotter,", 2026-11-01).
        val below = words.indexOfFirst { typeLine(it) }.let { if (it < 0) words.size else it }
        for (i in minOf(3, words.size) until below) {
            if (words[i].any(CardName::hasCjk)) continue
            exact(i)?.let { if (oracle(it.idx)?.norm?.contains(' ') == true) return it }
        }
        return null
    }

    /** A split card two of whose halves are read as lines of their own ("Fire" and "Ice"), among the first 24 lines. */
    private fun splitHalves(lines: List<String>): ScanNames.Hit? {
        val seen = HashMap<Int, MutableSet<String>>()
        for (line in lines.take(24)) {
            val words = CardName.norm(line).split(' ').filter { it.isNotEmpty() }
            if (words.size !in 1..6) continue
            val q = candidates(words).firstOrNull { names.half(it).isNotEmpty() } ?: continue
            for (idx in names.half(q)) {
                val s = seen.getOrPut(idx) { HashSet() }
                s.add(q)
                if (s.size >= 2 && allowed(idx)) return ScanNames.Hit(idx, emptyList())
            }
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
     * The printing, scored by what the card's bottom text says (`Collector`, merged over the last frames of the same
     * card): set code read (4), collector number read (2; for a card with no power/toughness also a lone three-digit
     * number that could have been a misread "2/2"), copyright year (1), an "Illus." line for a 1993 or 1997 frame
     * (2: old cards and retro-frame reprints print one; a 2003+ frame prints the artist after a brush), the
     * illustrator's name read (2, when the card's printings don't all share one), or for an old frame with no year
     * (4th Edition on prints "© 1995") a 1993–94 printing (1); ties go to a for-trade copy, the set last picked by
     * hand (nearest its number), the name's language on an old frame (French Sol Ring → Foreign Black Border),
     * the border colour the camera read when nothing printed was (black: Alpha, Beta, Foreign Black Border; white:
     * Unlimited, Revised), English, a regular collector number, the most printed of Revised, Unlimited, Beta, Alpha
     * (nothing printed on them tells them apart, and Alpha was the rarest), then the default printing. Exact when one printing leads
     * with the set code and number (or the set's only printing), or with the number and one more thing (the year,
     * the frame), or with the set code and the artist. A prerelease date stamp picks the set's prerelease promo.
     */
    private fun pick(o: CatalogOracle, bottom: Collector, langs: List<String> = emptyList()): ScanMatch? {
        val ps = printings(o.idx)
        if (ps.isEmpty()) return null
        val old = bottom.years.isEmpty() && bottom.sets.isEmpty() && bottom.numbers.isEmpty() && bottom.illustrated
        // Vehicles have power/toughness; a battle's defense is one number.
        val noPT = !(o.typeLine.contains("Creature") || o.typeLine.contains("Vehicle"))
        val artistTells = ps.map { it.artist }.filter { it.isNotEmpty() }.toSet().size > 1
        fun number(p: CatalogPrinting) = stripZeros(p.cn.lowercase())
        fun year(p: CatalogPrinting) = p.releasedAt.take(4).toIntOrNull()
        fun numbered(p: CatalogPrinting) = number(p) in bottom.numbers || (noPT && number(p) in bottom.loneNumbers)
        fun retro(p: CatalogPrinting) = bottom.illustrated && (p.frame == "1993" || p.frame == "1997")
        // Each artist is looked up in the frames' words once per pick, and each printing scored once: the scores are
        // read several times per printing while sorting, and the fuzzy word match over every line is the costly part.
        val drawnBy = HashMap<String, Collector.ArtistLine?>()
        fun drawn(p: CatalogPrinting): Collector.ArtistLine? {
            if (!artistTells || p.artist.isEmpty()) return null
            if (p.artist !in drawnBy) drawnBy[p.artist] = bottom.names(p.artist)
            return drawnBy[p.artist]
        }
        // The artist read after a brush, not "Illus.": a 2003 or newer frame.
        fun modern(p: CatalogPrinting) = drawn(p) == Collector.ArtistLine.PLAIN && (p.frame == "2003" || p.frame == "2015" || p.frame == "future")
        val scores = HashMap<String, Int>()
        fun score(p: CatalogPrinting) = scores.getOrPut(p.cardId) {
            (if (p.set in bottom.sets) 4 else 0) + (if (numbered(p)) 2 else 0) +
                (if (year(p) in bottom.years || (old && early(p))) 1 else 0) + (if (retro(p)) 2 else 0) +
                (if (drawn(p) != null) 2 else 0) + (if (modern(p)) 1 else 0)
        }
        val last = lastPick
        fun near(p: CatalogPrinting) = if (last == null || p.set != last.set) Int.MIN_VALUE else -abs(digits(p.cn) - digits(last.cn))
        // The border the camera read counts only when nothing printed was read (a set code, number or year read
        // always wins, and old cards print none), and after a hand-picked set: a fix still carries to the next card.
        val border = if (bottom.sets.isEmpty() && bottom.numbers.isEmpty() && bottom.years.isEmpty()) bottom.border else ScanBorder.UNKNOWN
        fun bordered(p: CatalogPrinting) = when (border) {
            ScanBorder.BLACK -> p.set in BLACK_BORDER
            ScanBorder.WHITE -> p.set in WHITE_BORDER
            ScanBorder.UNKNOWN -> false
        }
        var best = ps.sortedWith(
            compareByDescending<CatalogPrinting> { score(it) }.thenByDescending { it.cardId in preferred }.thenByDescending { near(it) }
                .thenByDescending { old && it.lang in langs }.thenByDescending { bordered(it) }.thenByDescending { it.lang == "en" }
                .thenBy { it.cn.endsWith("★") }.thenByDescending { PRINT_RUN[it.set] ?: 0 }.thenByDescending { it.original }.thenBy { it.ord },
        ).first()
        val top = score(best)
        val alone = ps.count { score(it) == top } == 1
        val exact = alone && (top >= 6 || (numbered(best) && top >= 3) || (best.set in bottom.sets && ps.count { it.set == best.set } == 1))
        if (bottom.dated) {
            ps.firstOrNull { it.set == "p" + best.set && it.cn.lowercase().trimEnd('s', '★') == best.cn.lowercase() }?.let { best = it }
        }
        return ScanMatch(o, best, exact)
    }

    // Evidence over frames ---------------------------------------------------------------------------------------

    /**
     * Evidence about the card in view, kept over its last frames: the set code read in one frame and the number in
     * the next pick the printing together (a borderless Tourach read "MH2 • EN" in one frame and "312" four frames
     * later, and went in as the regular 102). Only the last FRAMES frames are kept (2026-10-31: the merged evidence
     * had grown by every frame's words for as long as the card stayed in view, and the artist's fuzzy match scanned
     * all of them, so each frame was slower than the last; 80 frames of one card went 0.1 s → 7.9 s each). Cleared
     * after MISSES frames that named nothing, when another card is named, after a hand-picked printing, and when the
     * card is taken (`took`).
     */
    private class Recent(val idx: Int) {
        val frames = ArrayDeque<Collector>()
        var misses = 0
    }
    private var recent: Recent? = null

    /** How many frames of the card in view are remembered (tests). */
    val rememberedFrames: Int get() = recent?.frames?.size ?: 0

    /** The evidence for this card: this frame's, merged with what the last frames of the same card read. */
    private fun remembered(idx: Int, bottom: Collector): Collector {
        val r = recent?.takeIf { it.idx == idx } ?: Recent(idx)
        r.frames.addLast(bottom)
        while (r.frames.size > FRAMES) r.frames.removeFirst()
        r.misses = 0
        recent = r
        if (r.frames.size == 1) return bottom
        // Newest first, so this frame's language code wins as before.
        val merged = Collector(emptyList(), emptySet())
        for (f in r.frames.asReversed()) merged.merge(f)
        return merged
    }

    private fun missed() {
        val r = recent ?: return
        if (++r.misses >= MISSES) recent = null
    }

    /** The card in view was taken: what its frames read mustn't pick the next copy's printing. */
    fun took() { recent = null }

    private fun oracle(idx: Int): CatalogOracle? = oracles.getOrPut(idx) { catalog.oracles(listOf(idx))[idx] }

    private fun printings(idx: Int) = printingsByOracle.getOrPut(idx) {
        catalog.printings(idx).let { all -> if (owned == null) all else all.filter { it.cardId in owned } }
    }

    private fun printings(set: String, cn: String) = bySetCn.getOrPut("$set|$cn") {
        catalog.printings(set, cn).let { all -> if (owned == null) all else all.filter { it.cardId in owned } }
    }

    private fun allowed(idx: Int) = owned == null || printings(idx).isNotEmpty()

    companion object {
        const val MISSES = 5
        /** Frames of the card in view whose bottom text is remembered: about 2 s at the camera's pace. */
        const val FRAMES = 10

        /**
         * Whether the lines include a type line ("Instant", "Creature — Elf"): text from a card, not a keyboard or a
         * list. With no card found in the frame (always, on Android), a card is taken only when this holds or its set
         * code and number agree with the name: a keyboard's "option" key is Opt (its French name), a decklist on a
         * screen is a card. Same rule as iOS.
         */
        fun hasTypeLine(lines: List<String>) = lines.any { l -> typeLine(CardName.norm(l).split(' ').filter { it.isNotEmpty() }) }

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
        fun furigana(words: List<String>) = words.size == 1 && words[0].length <= 12 && words[0].all { it in 'ぁ'..'ゟ' }

        fun stripZeros(s: String) = s.trimStart('0').ifEmpty { if (s.isEmpty()) "" else "0" }

        /** The 1993–94 core sets, most printed first: one printed card reads the same in all four. */
        val PRINT_RUN = mapOf("3ed" to 4, "2ed" to 3, "leb" to 2, "lea" to 1)
        /** The 1993–95 printings with a black border (Alpha, Beta, Collectors' Edition, Foreign Black Border, 4th Edition's
         *  foreign black border) and a white one (Unlimited, Revised, Summer Magic): what the camera's border read picks
         *  between when nothing printed tells them apart. */
        val BLACK_BORDER = setOf("lea", "leb", "ced", "cei", "fbb", "4bb")
        val WHITE_BORDER = setOf("2ed", "3ed", "sum")

        /** Printed before cards carried a copyright year (4th Edition, April 1995). */
        fun early(p: CatalogPrinting) = (p.releasedAt.take(4).toIntOrNull() ?: 9999) <= 1994

        /** A collector number's digits as a number ("437" → 437, "M20-125" → 20125), for nearness. */
        fun digits(cn: String) = cn.filter { it in '0'..'9' }.take(6).toIntOrNull() ?: 0
    }
}

/**
 * What a card's bottom text says about its printing: "154/196 M", "RIX • RU", "M 0244", "FRA • EN", the year and
 * number on a copyright line ("™ & © 2024 Wizards of the Coast 407"), an "Illus." line, the illustrator's name, a
 * prerelease date stamp. Built per frame; `merge` keeps what earlier frames of the same card read. Same rules as
 * iOS (CardMatcher.swift).
 */
class Collector(lines: List<String>, known: Set<String>, border: ScanBorder = ScanBorder.UNKNOWN) {
    /** The border colour the camera read in this frame ([ScanBorder]), when it could tell. */
    var border = border
        private set
    val sets = HashSet<String>()
    val numbers = HashSet<String>()
    /** The numbers written as collector numbers ("154/196", "0244", "R 1695", "297"), not a lone "212" that may be a misread 2/2. */
    val collectorNumbers = HashSet<String>()
    /** Lone three-digit numbers that could be power/toughness read with the slash as 1 or 7 ("2/2" → "212"): a
     *  collector number only for a card that prints no power/toughness. */
    val loneNumbers = HashSet<String>()
    /** The language printed by a known set code ("WAR • JP" → ja), when only one is. */
    var lang: String? = null
        private set
    /** Copyright years ("© 2019 Wizards", "1993-2003", "& C 2013 W"): the last year of each line. */
    val years = HashSet<Int>()
    /** An artist credit as 1993 and 1997 frames print it ("Illus. Mark Poole"; also read as "Ius." or "lllus,"). */
    var illustrated = false
        private set
    /** A prerelease date stamp ("30-31 January 2021", "27-28 giugno 2020"): a month and a year on a line that isn't the copyright. */
    var dated = false
        private set
    /** Every line's words, normalized, for the illustrator's name, and whether the line is an "Illus." credit. */
    /** This frame's lines for the illustrator's name (then older frames' after [merge]); each frame remembers which
     *  illustrators it names, so it's searched once per artist however many frames it stays in memory. */
    private val frames = ArrayList<ScanLines>()

    /** How the illustrator's name was printed: after "Illus." (a 1993 or 1997 frame) or plainly, after a brush. */
    enum class ArtistLine { ILLUSTRATED, PLAIN }

    init {
        var langLine = false
        val printed = HashSet<String>()
        val digits = BooleanArray(lines.size)
        val words = ArrayList<List<String>>()
        val credits = ArrayList<Boolean>()
        for ((i, line) in lines.withIndex()) {
            // Cheap checks first: most lines of a busy desk have no digit and no two capitals in a row, and none of
            // these patterns can match without them (2026-10-31).
            val hasDigit = line.any { it in '0'..'9' }
            digits[i] = hasDigit
            var codes = if (hasCode(line)) SET_LANG.findAll(line).map { it.groupValues[1] to it.groupValues[2] }.toList() else emptyList()
            if (codes.isEmpty() && hasCode(line)) codes = SET_LANG_LOOSE.findAll(line).map { it.groupValues[1] to it.groupValues[2] }.toList()
            for ((raw, l) in codes) {
                val lang = LANGS[l] ?: continue
                langLine = true
                known(raw, known)?.let { sets.add(it); printed.add(lang) }
            }
            if (hasDigit) {
                for (m in OF_TOTAL.findAll(line)) {
                    if ((m.groupValues[3].toIntOrNull() ?: 0) >= 30) {
                        val n = strip(m.groupValues[1]) + m.groupValues[2].lowercase()
                        numbers.add(n)
                        collectorNumbers.add(n)
                    }
                }
                val range = YEAR_RANGE.find(line)
                if (range != null) years.add(range.groupValues[2].toInt())
                else if (COPYRIGHT.containsMatchIn(line)) YEAR.findAll(line).lastOrNull()?.let { years.add(it.value.toInt()) }
            }
            val credit = mayCredit(line) && ILLUS.containsMatchIn(line.trim())
            if (credit) illustrated = true
            val norm = CardName.norm(line)
            if (hasDigit && YEAR.containsMatchIn(norm) && "wizards" !in norm && norm.split(Regex("[^a-zа-я]+")).any { it in MONTHS }) dated = true
            words.add(norm.split(' ').filter { it.isNotEmpty() })
            credits.add(credit)
        }
        frames.add(ScanLines(words, credits))
        lang = printed.singleOrNull()
        for ((i, line) in lines.withIndex()) {
            if (!digits[i]) continue
            val m = ALONE.matchEntire(line)
            if (m != null) {
                val n = m.groupValues[1].replace(" ", "")
                if (n.length > 4) continue
                // "0244", "R 1695", or three digits that can't be power/toughness read with the slash as 1 or 7 ("2/2" → "212").
                val toughness = n.length == 3 && n[1] in "17"
                if (toughness && !langLine) { loneNumbers.add(strip(n)); continue }
                if (!(langLine || n.length >= 3)) continue
                numbers.add(strip(n))
                if ((n.length == 4 && n[0] == '0') || line.any { it.isLetter() } || (n.length == 3 && !toughness)) collectorNumbers.add(strip(n))
            } else if (COPYRIGHT.containsMatchIn(line) && !OF_TOTAL.containsMatchIn(line)) {
                // The number at the end of a copyright line, never the year itself.
                val t = TRAILING.find(line) ?: continue
                val n = t.groupValues[1]
                if (n.length == 4 && (n.toIntOrNull() ?: 0) >= 1990) continue
                numbers.add(strip(n) + t.groupValues[2].lowercase())
            }
        }
    }

    /**
     * Whether the lines name this illustrator, and how: every word of the name, in order, in one line; a word of
     * four or five letters may be one edit off and a longer one two ("TOOD LOCKVOOD", "Shells Wan", "CANARAT" for
     * Canavan), shorter ones exact.
     */
    fun names(artist: String): ArtistLine? {
        val want = CardName.norm(artist).split(' ').filter { it.isNotEmpty() && it != "and" && it != "&" }
        if (want.isEmpty()) return null
        for (f in frames) f.names(artist, want)?.let { return it }
        return null
    }

    /** What earlier frames of the same card read, added to this frame's. */
    fun merge(o: Collector) {
        sets.addAll(o.sets); numbers.addAll(o.numbers); collectorNumbers.addAll(o.collectorNumbers)
        loneNumbers.addAll(o.loneNumbers); years.addAll(o.years)
        illustrated = illustrated || o.illustrated
        dated = dated || o.dated
        frames.addAll(o.frames)
        if (lang == null) lang = o.lang
        if (border == ScanBorder.UNKNOWN) border = o.border
    }

    companion object {
        /** The codes printed by the set code, as Scryfall's language codes. */
        val LANGS = mapOf(
            "EN" to "en", "DE" to "de", "FR" to "fr", "IT" to "it", "ES" to "es", "PT" to "pt", "JP" to "ja", "JA" to "ja", "RU" to "ru",
            "KR" to "ko", "KO" to "ko", "CS" to "zhs", "CT" to "zht", "PH" to "ph", "ZHS" to "zhs", "ZHT" to "zht",
        )
        /** An uppercase code, a bullet, star, dash or Japanese middle dot, a language code ("one it ate." in rules
         *  text is not a set and a language); the bullet is often read as a letter ("MH2 WEN", "ECL MEN", "MH2VEN")
         *  or lost, so a code of three or more may also be followed by one stray letter or nothing. */
        val SET_LANG = Regex("\\b([A-Z0-9]{2,5})\\s*[•*·★+.\\-–・]\\s*([A-Z]{2,3})\\b")
        val SET_LANG_LOOSE = Regex("\\b([A-Z0-9]{3,5})\\s?[A-Z]?\\s?(EN|DE|FR|IT|ES|PT|JP|JA|RU|KR|KO|CS|CT|PH|ZHS|ZHT)\\b")
        /** "154/196": the number after the slash is the set's size, which tells it from power/toughness ("6/6"). */
        val OF_TOTAL = Regex("(?:^|[^\\d/])(\\d{1,4})([a-zA-Z]?)\\s*/\\s*(\\d{2,4})\\b")
        /** A line that is only a collector number, maybe with its rarity: "667", "R 0244", "0014", "07 29". */
        val ALONE = Regex("\\s*(?:[CURMLSTP]\\s+)?(\\d[\\d ]{0,4}\\d|\\d)(?:\\s+[CURMLSTP])?\\s*")
        /** A copyright line, as the camera reads it: "™ & © 2024 Wizards of the Coast 407", "& C 2013W", "2012 Wi",
         *  "ds of the Coast 248 27.", "1993-2001 Wizards of the Coast, Inc. 214/350". */
        val COPYRIGHT = Regex("©|wizards|wi[sz]a|of the co|\\bcoast|&\\s*\\S{0,2}\\s*(?:19|20)\\d\\d|(?:19|20)\\d\\d\\s*W", RegexOption.IGNORE_CASE)
        /** The number a 1997-style copyright line ends with ("… of the Coast 407", "… Coast 248 27." with the total cut off). */
        val TRAILING = Regex("(?:^|\\D)(\\d{1,4})([a-z]?)(?:\\s+\\d{2,3}\\.?)?\\s*$")
        val YEAR_RANGE = Regex("(19[89]\\d)\\s*[-–]?\\s*(20[0-4]\\d)")
        val YEAR = Regex("(?<!\\d)(?:19[89]\\d|20[0-4]\\d)(?!\\d)")
        val ILLUS = Regex("^[il1|]{0,3}us[.,:/]\\s", RegexOption.IGNORE_CASE)
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

        fun strip(s: String) = s.trimStart('0').ifEmpty { "0" }

        /** Two capital letters in a row, as every set-code-and-language pattern needs ("EN", "JP"). */
        fun hasCode(line: String): Boolean {
            var upper = false
            for (c in line) { val u = c in 'A'..'Z'; if (u && upper) return true; upper = u }
            return false
        }

        /** Could be an "Illus." credit: starts with i, l, 1, | or u, like every spelling ILLUS accepts. */
        fun mayCredit(line: String) = line.trimStart().firstOrNull()?.let { it in "iIlL1|uU" } ?: false

        fun alike(a: String, b: String): Boolean {
            if (a == b) return true
            val n = b.length
            if (n < 4 || abs(a.length - n) > 2) return false
            return edits(a, b, if (n >= 6) 2 else 1)
        }

        /** Whether a and b are within [k] single-character edits (insert, delete, replace) of each other. */
        fun edits(a: String, b: String, k: Int): Boolean {
            if (abs(a.length - b.length) > k) return false
            var prev = IntArray(b.length + 1) { it }
            for (i in 1..a.length) {
                val cur = IntArray(b.length + 1); cur[0] = i
                var rowMin = i
                for (j in 1..b.length) {
                    cur[j] = minOf(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + if (a[i - 1] == b[j - 1]) 0 else 1)
                    rowMin = minOf(rowMin, cur[j])
                }
                if (rowMin > k) return false
                prev = cur
            }
            return prev[b.length] <= k
        }

        /** A read set code as the catalog knows it: as read, else with the letters the camera swaps for digits put
         *  back ("4OK" → 40k, "MHT" → mh1, "A2S" → a25), else without a stray first or last character ("YMH2", "4A25", "MH2V"). */
        private fun known(raw: String, known: Set<String>): String? {
            val code = raw.lowercase()
            if (code in known) return code
            val swapped = code.map { mapOf('o' to '0', 'i' to '1', 'l' to '1', 't' to '1', 's' to '5')[it] ?: it }.joinToString("")
            if (swapped != code && swapped in known) return swapped
            if (code.length >= 4) for (cut in listOf(code.drop(1), code.dropLast(1))) if (cut in known) return cut
            return null
        }
    }
}

/**
 * The colour of a card's border, read from the camera frame: Alpha, Beta and Foreign Black Border cards have black
 * borders, Unlimited and Revised white ones, and nothing printed on a 1993–94 card tells them apart, so this breaks
 * that tie in [CardMatcher] (contract/trades-2026-10-16.md § Scanning "Border colour"; measured over the photo set in
 * testdata/scan/border.json, made by testdata/scan/tools/border.swift, which holds the reference copy of these rules;
 * iOS: `ScanBorder` in CardMatcher.swift. Change all three together.)
 *
 * The scanner samples luma (0–255) at a few points per camera frame: just inside and just outside each side of the
 * card's edge (ML Kit finds no card rectangle, so the edge is found in a short luma profile across each side of the
 * guide box, which the card roughly fills), further outside, and in the card's text box, whose ink and paper are the
 * frame's own black and white, so a dim or low-contrast frame still reads.
 */
enum class ScanBorder {
    BLACK, WHITE, UNKNOWN;

    /** The samples one frame yields: per side (top, right, bottom, left) twelve just inside the edge, twelve just
     *  outside, twelve further out; and 24 in the text box. */
    data class Samples(val inside: List<List<Int>>, val outside: List<List<Int>>, val far: List<List<Int>>, val inner: List<Int>)

    companion object {
        /** Where a side's samples are taken: six points along it, 15–85% of its length. */
        val ALONG = doubleArrayOf(0.15, 0.29, 0.43, 0.57, 0.71, 0.85)
        /** Offsets from the edge, as fractions of the card's width: a 1993–94 border is about 4.5% wide. */
        val DEPTHS = doubleArrayOf(0.015, 0.03)
        /** Further out, past where a border would end: tells a border plateau outside an edge that was the frame
         *  inside the border (a step between the two) from a table that just goes on (no step). */
        val FAR_DEPTHS = doubleArrayOf(0.065, 0.09)
        /** Where the text box is sampled (u right, v down, fractions of the card): light with dark text on every
         *  1993–2003 card. */
        val INNER_U = doubleArrayOf(0.2, 0.32, 0.44, 0.56, 0.68, 0.8)
        val INNER_V = doubleArrayOf(0.66, 0.72, 0.78, 0.84)
        /** The luma profile across a side of the guide box: from 12% outside to 12% inside its width, 25 samples. */
        const val PROFILE_STEPS = 25
        const val PROFILE_SPAN = 0.12

        /** Luma at or under this is black, at or over the other white, whatever the card (a phone's auto exposure keeps
         *  a card about this bright); in between, the card's own text box decides. */
        const val BLACK_AT_MOST = 70
        const val WHITE_AT_LEAST = 165
        /** Relative to the text box (0 = its ink, 1 = its paper): a border this far below the paper is black, this far
         *  above the ink white, within these absolute bounds (so a lit black border or a greyed white one still counts,
         *  but not frame texture), when the text box has this much contrast. */
        const val BLACK_BELOW = 0.25
        const val WHITE_ABOVE = 0.9
        const val BLACK_ABS_MAX = 115
        const val WHITE_ABS_MIN = 140
        const val TEXT_BOX_CONTRAST = 50
        /** A border plateau outside the edge found ends in a step this big (relative to the text box; in luma when it
         *  has no contrast) to the table beyond it; a table just goes on. */
        const val PLATEAU_STEP = 0.3
        const val PLATEAU_STEP_LUMA = 45

        fun upperMedian(a: List<Int>) = a.sorted()[a.size / 2]

        /**
         * The border from a frame's samples: at least three of the four sides one colour just inside the edge and none
         * the other; else, when the inside is mostly neither (the edge found was the frame inside the border), the same
         * just outside, counting only sides where the outside band steps to what lies beyond it (a border ends; a table
         * doesn't).
         */
        fun classify(s: Samples): ScanBorder {
            if (s.inside.size != 4 || s.outside.size != 4 || s.far.size != 4 || s.inner.isEmpty() ||
                s.inside.any { it.isEmpty() } || s.outside.any { it.isEmpty() } || s.far.any { it.isEmpty() }) return UNKNOWN
            val sorted = s.inner.sorted()
            val ink = sorted[0]
            val paper = sorted[minOf(sorted.size - 1, sorted.size * 3 / 4)]
            val ref = paper - ink >= TEXT_BOX_CONTRAST
            fun norm(m: Int) = (m - ink).toDouble() / (paper - ink)
            fun shade(samples: List<Int>): ScanBorder {
                val m = upperMedian(samples)
                if (m <= BLACK_AT_MOST || (ref && norm(m) <= BLACK_BELOW && m <= BLACK_ABS_MAX)) return BLACK
                if (m >= WHITE_AT_LEAST || (ref && norm(m) >= WHITE_ABOVE && m >= WHITE_ABS_MIN)) return WHITE
                return UNKNOWN
            }
            fun agree(shades: List<ScanBorder>): ScanBorder {
                val black = shades.count { it == BLACK }
                val white = shades.count { it == WHITE }
                if (black >= 3 && white == 0) return BLACK
                if (white >= 3 && black == 0) return WHITE
                return UNKNOWN
            }
            val ins = s.inside.map(::shade)
            val a = agree(ins)
            if (a != UNKNOWN) return a
            if (ins.count { it == UNKNOWN } < 3) return UNKNOWN
            val outs = (0 until 4).map { k ->
                val o = upperMedian(s.outside[k])
                val f = upperMedian(s.far[k])
                val step = if (ref) abs(norm(o) - norm(f)) >= PLATEAU_STEP else abs(o - f) >= PLATEAU_STEP_LUMA
                if (step) shade(s.outside[k]) else UNKNOWN
            }
            return agree(outs)
        }

        /** Luma at the text-box points inside a quad (corners TL, TR, BR, BL as x, y pairs; bilinear in them). */
        fun innerSamples(q: List<Pair<Double, Double>>, luma: (Double, Double) -> Int): List<Int> =
            INNER_V.flatMap { v -> INNER_U.map { u ->
                val tx = q[0].first + (q[1].first - q[0].first) * u
                val ty = q[0].second + (q[1].second - q[0].second) * u
                val bx = q[3].first + (q[2].first - q[3].first) * u
                val by = q[3].second + (q[2].second - q[3].second) * u
                luma(tx + (bx - tx) * v, ty + (by - ty) * v)
            } }

        /**
         * The samples around the guide box ([Box] in pixels, origin top-left): along each side six luma profiles from 12%
         * outside to 12% inside find the card's edge (the strongest step), and the bands around it are the inside, outside
         * and far samples. 624 reads; [luma] reads one pixel (clamping to the image is its job).
         */
        fun samples(guide: Box, luma: (Double, Double) -> Int): Samples {
            val g = guide
            val x0 = g.x.toDouble(); val y0 = g.y.toDouble(); val x1 = (g.x + g.w).toDouble(); val y1 = (g.y + g.h).toDouble()
            val sides = listOf( // start, end, inward unit
                Triple(x0 to y0, x1 to y0, 0.0 to 1.0),
                Triple(x1 to y0, x1 to y1, -1.0 to 0.0),
                Triple(x1 to y1, x0 to y1, 0.0 to -1.0),
                Triple(x0 to y1, x0 to y0, 1.0 to 0.0),
            )
            val inside = ArrayList<List<Int>>(); val outside = ArrayList<List<Int>>(); val far = ArrayList<List<Int>>()
            for ((a, b, n) in sides) {
                val ins = ArrayList<Int>(); val outs = ArrayList<Int>(); val fars = ArrayList<Int>()
                for (t in ALONG) {
                    val px = a.first + (b.first - a.first) * t
                    val py = a.second + (b.second - a.second) * t
                    val s = (0 until PROFILE_STEPS).map { k ->
                        val d = (-PROFILE_SPAN + k * (2 * PROFILE_SPAN) / (PROFILE_STEPS - 1)) * g.w
                        luma(px + n.first * d, py + n.second * d)
                    }
                    val (i, o, f) = edge(s)
                    ins += i; outs += o; fars += f
                }
                inside.add(ins); outside.add(outs); far.add(fars)
            }
            val q = listOf(x0 to y0, x1 to y0, x1 to y1, x0 to y1)
            return Samples(inside, outside, far, innerSamples(q, luma))
        }

        /** From one profile (outside first), the samples around the card's edge: the strongest step is the edge; the two
         *  samples inward of it are inside (about 1–2% in), the two outward outside, two more beyond them far. */
        fun edge(s: List<Int>): Triple<List<Int>, List<Int>, List<Int>> {
            val n = s.size
            var e = n / 2
            var best = 0
            for (k in 2 until n - 2) if (abs(s[k] - s[k - 1]) > best) { best = abs(s[k] - s[k - 1]); e = k }
            return Triple(listOf(s[minOf(n - 1, e + 1)], s[minOf(n - 1, e + 2)]), listOf(s[maxOf(0, e - 2)], s[maxOf(0, e - 3)]),
                listOf(s[maxOf(0, e - 7)], s[maxOf(0, e - 9)]))
        }

        /**
         * An upright pixel (origin top-left; [uw] × [uh] the upright image) in the camera's raw image of [rw] × [rh],
         * which needs [rotation] degrees clockwise to show upright (CameraX's rotationDegrees).
         */
        fun rawPixel(ux: Int, uy: Int, rotation: Int, rw: Int, rh: Int): Pair<Int, Int> = when (rotation) {
            90 -> uy to rh - 1 - ux
            180 -> rw - 1 - ux to rh - 1 - uy
            270 -> rw - 1 - uy to ux
            else -> ux to uy
        }
    }
}

/**
 * One frame's lines, normalized, for the illustrator's name: each line's words and whether it's an "Illus." credit.
 * A class with a cache, so the answer per artist is kept while the frame stays in the matcher's memory (2026-10-31:
 * every remembered frame was searched again for every artist on every frame).
 */
class ScanLines(private val words: List<List<String>>, private val credits: List<Boolean>) {
    private val found = HashMap<String, Collector.ArtistLine?>()

    /** Whether these lines name the artist ([want]: the name's words), and how: every word of the name, in order, in
     *  one line, each [Collector.alike] its word. The first line that does decides. */
    fun names(artist: String, want: List<String>): Collector.ArtistLine? {
        if (artist in found) return found[artist]
        var how: Collector.ArtistLine? = null
        search@ for ((i, line) in words.withIndex()) {
            if (line.size < want.size) continue
            for (start in 0..(line.size - want.size)) {
                if (want.indices.all { k -> Collector.alike(line[start + k], want[k]) }) {
                    how = if (credits[i]) Collector.ArtistLine.ILLUSTRATED else Collector.ArtistLine.PLAIN
                    break@search
                }
            }
        }
        found[artist] = how
        return how
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
        /** Frames that named it. */
        var named = 0
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
        c.named++
        if (m.exact) c.votes[m.printing.cardId] = m.printing to ((c.votes[m.printing.cardId]?.second ?: 0) + 1)
        val top = c.votes.values.maxByOrNull { it.second }
        val voted = top?.first
        val held = now - c.since
        if (!((voted != null && held >= QUICK_MS) || ((top?.second ?: 0) >= AGREE && held >= QUICKER_MS) || (held >= SLOW_MS && c.named >= READS))) return null
        candidate = null
        lastIdx = m.oracle.idx
        lastSeen = now
        return if (voted != null) voted to true else c.latest to false
    }

    companion object {
        /** Taken this long after it's first seen once its printing is read; without the printing, a little longer and
         *  named in at least READS frames (1993–2003 frames print no set code, and their names misread in a third of
         *  frames or more: Crusade, named 6 times in 2.4 s with gaps of 0.6 s, was never taken while any gap over
         *  0.5 s started it over). */
        const val QUICK_MS = 400L
        /** Sooner still when two frames read the same printing exactly (set code and number agree): a second frame
         *  that says the same is as sure as a third that says nothing (2026-10-28). */
        const val QUICKER_MS = 200L
        const val AGREE = 2
        const val SLOW_MS = 800L
        const val READS = 3
        /** A blurred or unreadable frame doesn't drop the card in view unless the gap lasts this long. */
        const val GAP_MS = 1000L
        /** After a take, the same card has to be out of view this long before it counts again. */
        const val AWAY_MS = 1000L
    }
}

/**
 * The order the scanner hands lines to the matcher when the card's text isn't upright (README § Split cards). A
 * split card's halves are printed sideways, so held upright in the guide its text runs up or down the frame, and
 * sorted by the top of each line's box its names land among the rules text, under the type lines; an upside-down
 * card reads bottom first. OCR gives each line's corners in the text's own direction (top-left, top-right,
 * bottom-right, bottom-left), so when most of the text (by letters and digits) reads in one other direction, those
 * lines are put in reading order for that direction, top line first, and the rest follow as they came. Text that
 * is mostly upright keeps the order it came in. Same rule on iOS (CardMatcher.swift), cases in testdata/scan/split.json.
 */
object ScanOrder {
    /** A line read, with its corners in pixels, origin top-left: x, y of top-left, top-right, bottom-right, bottom-left. */
    class Line(val text: String, val quad: FloatArray)

    /** Which way a line reads: upright, a quarter clockwise (reads down the frame), upside down, a quarter counterclockwise. */
    enum class Turn(val wire: String) { UPRIGHT("upright"), CLOCKWISE("clockwise"), UPSIDE_DOWN("upside_down"), COUNTERCLOCKWISE("counterclockwise") }

    class Ordered(val lines: List<String>, val turn: Turn)

    fun turn(q: FloatArray): Turn {
        val dx = q[2] - q[0]
        val dy = q[3] - q[1]
        if (abs(dx) >= abs(dy)) return if (dx >= 0) Turn.UPRIGHT else Turn.UPSIDE_DOWN
        return if (dy > 0) Turn.CLOCKWISE else Turn.COUNTERCLOCKWISE
    }

    /** Lines in the order they came (top of the box first), reordered by the text's direction when most of it isn't upright. */
    fun order(lines: List<Line>): Ordered {
        val turns = lines.map { turn(it.quad) }
        val weight = IntArray(4)
        for ((l, t) in lines.zip(turns)) weight[t.ordinal] += l.text.count { it.isLetterOrDigit() }
        val most = (1..3).maxByOrNull { weight[it] }!!
        if (weight[most] <= weight[0]) return Ordered(lines.map { it.text }, Turn.UPRIGHT)
        val turn = Turn.entries[most]
        // The text's up and along, in the frame.
        val (up, along) = when (turn) {
            Turn.UPRIGHT -> floatArrayOf(0f, -1f) to floatArrayOf(1f, 0f)
            Turn.CLOCKWISE -> floatArrayOf(1f, 0f) to floatArrayOf(0f, 1f)
            Turn.UPSIDE_DOWN -> floatArrayOf(0f, 1f) to floatArrayOf(-1f, 0f)
            Turn.COUNTERCLOCKWISE -> floatArrayOf(-1f, 0f) to floatArrayOf(0f, -1f)
        }
        fun dots(q: FloatArray, v: FloatArray) = (0 until 4).map { q[2 * it] * v[0] + q[2 * it + 1] * v[1] }
        class Keyed(val text: String, val top: Float, val start: Float)
        val read = mutableListOf<Keyed>()
        val rest = mutableListOf<String>()
        for ((l, t) in lines.zip(turns)) {
            if (t == turn) read.add(Keyed(l.text, dots(l.quad, up).max(), dots(l.quad, along).min())) else rest.add(l.text)
        }
        // Descending top, then ascending start: the same comparisons as iOS's sort.
        val sorted = read.sortedWith { a, b -> if (a.top != b.top) b.top.compareTo(a.top) else a.start.compareTo(b.start) }
        return Ordered(sorted.map { it.text } + rest, turn)
    }
}
