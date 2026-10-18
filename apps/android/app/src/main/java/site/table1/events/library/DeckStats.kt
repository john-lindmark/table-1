package site.table1.events.library

import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.roundToLong

/*
 * Deck and cube stats (contract/lists-2026-10-15.md, "Stats"). Pure functions over a list's cards, no UI and no catalog
 * access, so the same inputs give the same numbers here, on iOS (DeckStats.swift) and on the web (deckStats.ts).
 * testdata/deck-stats/cases.json holds the shared cases; make_cases.py there is the reference.
 */

/** One list line as the stats read it. `type`, `cost`, `cmc` and `colors` come from the catalog pack's O line. */
data class StatCard(
    val name: String,
    val qty: Int,
    val board: String,
    val type: String,
    val cost: String,
    val cmc: Double,
    val colors: String,
    val legal: String = "",
    val rarity: String = "",
    /** One copy's USD market price; null when there's none. */
    val usd: Double? = null,
) {
    /** The front face's card types as bits in [DeckStats.TYPES] order, read once (stats ask many times). */
    val typeBits: Int = DeckStats.cardTypes(type).fold(0) { b, t -> b or (1 shl DeckStats.TYPES.indexOf(t)) }
}

object DeckStats {
    val COLORS = listOf('W', 'U', 'B', 'R', 'G')
    val TYPES = listOf("Creature", "Planeswalker", "Instant", "Sorcery", "Artifact", "Enchantment", "Battle", "Land")
    val COLOR_GROUPS = listOf("White", "Blue", "Black", "Red", "Green", "Multicolor", "Colorless", "Lands")
    /** Mana value columns: 0 … 6, then 7 and more. */
    val BUCKETS = listOf("0", "1", "2", "3", "4", "5", "6", "7+")
    private val BASIC_TYPES = listOf("Plains" to 'W', "Island" to 'U', "Swamp" to 'B', "Mountain" to 'R', "Forest" to 'G')
    private val FOUR_OF = setOf("standard", "pioneer", "modern", "legacy", "vintage", "pauper", "premodern")
    private val SINGLETON = setOf("commander", "canlander")
    /** Cards whose text lets a deck hold any number of copies, and the few with their own cap. */
    private val ANY_NUMBER = setOf(
        "Relentless Rats", "Rat Colony", "Shadowborn Apostle", "Persistent Petitioners", "Dragon's Approach",
        "Slime Against Humanity", "Hare Apparent", "Templar Knight", "Cid, Timeless Artificer",
    )
    private val UP_TO = mapOf("Seven Dwarves" to 7, "Nazgûl" to 9)
    private val WORD = Regex("[A-Za-z]+")
    private val SYMBOL = Regex("\\{([^}]*)\\}")

    // ── one card

    fun front(type: String) = type.split(" // ").first()
    private fun words(s: String) = WORD.findAll(s).map { it.value }.toList()

    /** The card types on the front face ("Artifact Creature" → Artifact, Creature). */
    fun cardTypes(type: String): List<String> {
        val w = words(front(type).split(" — ").first()).toSet()
        return TYPES.filter { it in w }
    }

    fun isLand(c: StatCard) = c.typeBits and (1 shl 7) != 0
    fun isCreature(c: StatCard) = c.typeBits and 1 != 0
    fun bucket(cmc: Double) = floor(cmc).toInt().coerceIn(0, 7)

    /**
     * Colored mana symbols in a cost, every face counted, as [W, U, B, R, G]. A hybrid symbol counts once for each of
     * its colors; Phyrexian and {2/W} count for their color.
     */
    fun pips(cost: String): List<Int> {
        val out = IntArray(5)
        for (m in SYMBOL.findAll(cost)) {
            val parts = m.groupValues[1].split("/")
            COLORS.forEachIndexed { i, col -> if (parts.contains(col.toString())) out[i]++ }
        }
        return out.toList()
    }

    /**
     * Colors a land makes, read from its basic land types (any face). The pack carries no produced-mana field yet, so a
     * land without a basic type (a fetch land, a utility land) reads as none.
     */
    fun produces(c: StatCard): String {
        if (!isLand(c)) return ""
        val sub = mutableSetOf<String>()
        for (face in c.type.split(" // ")) {
            val i = face.indexOf(" — ")
            if (i >= 0) sub += words(face.substring(i + 3))
        }
        return BASIC_TYPES.filter { it.first in sub }.map { it.second }.joinToString("")
    }

    /** The cube's color group: the card's colors (not its mana cost), lands on their own. */
    fun colorGroup(c: StatCard): String = when {
        isLand(c) -> "Lands"
        c.colors.isEmpty() -> "Colorless"
        c.colors.length > 1 -> "Multicolor"
        else -> COLOR_GROUPS[COLORS.indexOf(c.colors[0]).takeIf { it >= 0 } ?: 6]
    }

    // ── decks

    /** The deck the stats describe: main deck and commander (sideboard and Considering left out). */
    fun deck(cards: List<StatCard>) = cards.filter { it.board == "main" || it.board == "commander" }

    /** Spells by mana value, split into creatures and everything else; lands left out. */
    fun curve(cards: List<StatCard>): Pair<List<Int>, List<Int>> {
        val creatures = IntArray(8)
        val other = IntArray(8)
        for (c in deck(cards)) {
            if (isLand(c)) continue
            if (isCreature(c)) creatures[bucket(c.cmc)] += c.qty else other[bucket(c.cmc)] += c.qty
        }
        return creatures.toList() to other.toList()
    }

    /** Copies of each card type, in [TYPES] order. A card counts once for every type it has. */
    fun typeCounts(cards: List<StatCard>): List<Int> {
        val out = IntArray(TYPES.size)
        for (c in cards) for (i in TYPES.indices) if (c.typeBits and (1 shl i) != 0) out[i] += c.qty
        return out.toList()
    }

    fun averageMV(cards: List<StatCard>, withLands: Boolean): Double {
        var n = 0
        var sum = 0.0
        for (c in deck(cards)) {
            if (!withLands && isLand(c)) continue
            n += c.qty
            sum += c.cmc * c.qty
        }
        return if (n == 0) 0.0 else sum / n
    }

    fun pipTotals(cards: List<StatCard>): List<Int> {
        val out = IntArray(5)
        for (c in deck(cards)) pips(c.cost).forEachIndexed { i, p -> out[i] += p * c.qty }
        return out.toList()
    }

    /** Lands that make each color, and how many lands the pack can't read (no basic land type, not a basic). */
    fun sources(cards: List<StatCard>): Pair<List<Int>, Int> {
        val out = IntArray(5)
        var unread = 0
        for (c in deck(cards)) {
            if (!isLand(c)) continue
            val p = produces(c)
            COLORS.forEachIndexed { i, col -> if (col in p) out[i] += c.qty }
            if (p.isEmpty() && "Basic" !in words(c.type)) unread += c.qty
        }
        return out.toList() to unread
    }

    /** Main deck, sideboard and commander at market price; copies without a price are counted. */
    fun price(cards: List<StatCard>): Pair<Double, Int> {
        var total = 0.0
        var unpriced = 0
        for (c in cards) {
            if (c.board == "maybe") continue
            val usd = c.usd
            if (usd == null) unpriced += c.qty else total += usd * c.qty
        }
        return (total * 100).roundToLong() / 100.0 to unpriced
    }

    /** Cards in the main deck (the library a game starts from). */
    fun librarySize(cards: List<StatCard>) = cards.filter { it.board == "main" }.sumOf { it.qty }

    /** Most copies a deck may hold over main deck and sideboard, null for no limit. */
    fun copyLimit(name: String, format: String, basic: Boolean): Int? = when {
        basic || name in ANY_NUMBER -> null
        name in UP_TO -> UP_TO[name]
        format in SINGLETON -> 1
        format in FOUR_OF -> 4
        else -> null
    }

    /**
     * Why each card can't be played in a format, by name: Banned, Not legal, Restricted to 1, Singleton, or More than N
     * copies. Main deck, sideboard and commander count; Considering doesn't. Sorted by name (code points).
     */
    fun legality(cards: List<StatCard>, format: String): List<Pair<String, String>> {
        val copies = linkedMapOf<String, Int>()
        val first = mutableMapOf<String, StatCard>()
        for (c in cards) {
            if (c.board == "maybe") continue
            copies[c.name] = (copies[c.name] ?: 0) + c.qty
            first.putIfAbsent(c.name, c)
        }
        val out = mutableListOf<Pair<String, String>>()
        for (name in copies.keys.sorted()) {
            val c = first.getValue(name)
            val n = copies.getValue(name)
            val basic = "Basic" in words(c.type)
            val reason = when (val code = CatalogPack.legality(c.legal, format)) {
                "banned" -> "Banned"
                "not_legal" -> "Not legal"
                else -> if (code == "restricted" && n > 1) "Restricted to 1" else if (code == "restricted") null else
                    copyLimit(name, format, basic)?.takeIf { n > it }?.let { if (it == 1) "Singleton" else "More than $it copies" }
            }
            if (reason != null) out += name to reason
        }
        return out
    }

    // ── odds

    private fun lnChoose(n: Int, k0: Int): Double {
        if (k0 <= 0 || k0 >= n) return 0.0
        val k = minOf(k0, n - k0)
        var s = 0.0
        for (i in 1..k) s += ln((n - k + i).toDouble()) - ln(i.toDouble())
        return s
    }

    /** P(at least `k` of the `K` cards in a group are among `n` cards drawn from `N`). */
    fun hypergeometric(N: Int, K: Int, n0: Int, k: Int): Double {
        val n = minOf(n0, N)
        if (k <= 0) return 1.0
        if (k > minOf(K, n)) return 0.0
        val total = lnChoose(N, n)
        var p = 0.0
        for (i in k..minOf(K, n)) {
            if (n - i > N - K) continue
            p += exp(lnChoose(K, i) + lnChoose(N - K, n - i) - total)
        }
        return minOf(1.0, p)
    }

    /** Cards seen by your turn `turn`: the opening seven plus a draw each turn, except the first turn on the play. */
    fun drawsByTurn(turn: Int, onPlay: Boolean) = 7 + turn - if (onPlay) 1 else 0

    // ── cubes

    fun colorBalance(cards: List<StatCard>): List<Int> {
        val out = IntArray(COLOR_GROUPS.size)
        for (c in cards) out[COLOR_GROUPS.indexOf(colorGroup(c))] += c.qty
        return out.toList()
    }

    /** Mana value columns for each color group but Lands. */
    fun curveByColor(cards: List<StatCard>): List<List<Int>> {
        val out = Array(COLOR_GROUPS.size - 1) { IntArray(8) }
        for (c in cards) {
            val g = COLOR_GROUPS.indexOf(colorGroup(c))
            if (g < out.size) out[g][bucket(c.cmc)] += c.qty
        }
        return out.map { it.toList() }
    }

    enum class AsfanBy(val key: String) { Color("color"), Type("type"), Mv("mv") }

    /** Labels for [asfan]'s values. */
    fun asfanLabels(by: AsfanBy) = when (by) {
        AsfanBy.Color -> COLOR_GROUPS
        AsfanBy.Type -> TYPES
        AsfanBy.Mv -> BUCKETS + "Lands"
    }

    /** Expected copies of each characteristic in a pack of `pack` cards drawn from the cube. */
    fun asfan(cards: List<StatCard>, pack: Int, by: AsfanBy): List<Double> {
        val total = cards.sumOf { it.qty }
        val counts = when (by) {
            AsfanBy.Color -> colorBalance(cards)
            AsfanBy.Type -> typeCounts(cards)
            AsfanBy.Mv -> IntArray(9).also { a -> for (c in cards) a[if (isLand(c)) 8 else bucket(c.cmc)] += c.qty }.toList()
        }
        return counts.map { if (total == 0) 0.0 else pack.toDouble() * it / total }
    }

    /** One copy per element: the order sample hands and packs shuffle. */
    fun expand(cards: List<StatCard>): List<Int> = cards.flatMapIndexed { i, c -> List(maxOf(0, c.qty)) { i } }
}

/** mulberry32: a small 32-bit generator, seeded, so tests can replay a hand. Same sequence on every platform. */
class StatsRng(seed: Long) {
    private var a: Int = seed.toInt()

    /** The next value as an unsigned 32-bit number. */
    fun next(): Long {
        a += 0x6D2B79F5
        var t = a
        t = (t xor (t ushr 15)) * (t or 1)
        t = t xor (t + (t xor (t ushr 7)) * (t or 61))
        return (t xor (t ushr 14)).toLong() and 0xFFFFFFFFL
    }

    /** 0 ..< bound (multiply-shift). */
    fun int(bound: Int): Int = ((next() * bound) ushr 32).toInt()

    /** A Fisher-Yates permutation of 0 ..< n. */
    fun shuffle(n: Int): List<Int> {
        val a = IntArray(n) { it }
        for (i in n - 1 downTo 1) {
            val j = int(i + 1)
            val t = a[i]; a[i] = a[j]; a[j] = t
        }
        return a.toList()
    }

    companion object {
        fun randomSeed(): Long = kotlin.random.Random.nextInt().toLong() and 0xFFFFFFFFL
    }
}

/**
 * A sample opening hand with the London mulligan: every mulligan shuffles and draws seven again, then puts one card on
 * the bottom for each mulligan taken. Values are positions in the expanded library ([DeckStats.expand]). Immutable:
 * each action returns the next hand.
 */
class SampleHand private constructor(
    val size: Int,
    private val rng: StatsRng,
    val hand: List<Int>,
    val library: List<Int>,
    val mulligans: Int,
    /** Cards still to put on the bottom before the hand is kept. */
    val toBottom: Int,
    /** Cards drawn after keeping. */
    val drawn: Int,
) {
    /** Down to one card at most. */
    val canMulligan get() = 7 - mulligans > 1 && size > 0
    val canDraw get() = toBottom == 0 && library.isNotEmpty()

    fun mulligan(): SampleHand = if (canMulligan) dealt(size, rng, mulligans + 1) else this

    fun bottom(index: Int): SampleHand {
        if (toBottom == 0 || index !in hand.indices) return this
        return SampleHand(size, rng, hand.filterIndexed { i, _ -> i != index }, library + hand[index], mulligans, toBottom - 1, drawn)
    }

    fun draw(): SampleHand =
        if (!canDraw) this else SampleHand(size, rng, hand + library[0], library.drop(1), mulligans, toBottom, drawn + 1)

    companion object {
        fun deal(size: Int, seed: Long) = dealt(size, StatsRng(seed), 0)

        private fun dealt(size: Int, rng: StatsRng, mulligans: Int): SampleHand {
            val order = rng.shuffle(size)
            return SampleHand(size, rng, order.take(7), order.drop(7), mulligans, minOf(mulligans, minOf(7, size)), 0)
        }
    }
}
