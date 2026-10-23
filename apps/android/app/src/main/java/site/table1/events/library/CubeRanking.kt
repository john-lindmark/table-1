package site.table1.events.library

import kotlinx.serialization.Serializable
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.ln

// Cube rankings engine (contract/cube-rankings-2026-10-21.md). Pure: everything comes from a ranking's screen log, so
// undo, redo and watching never need repair. Same rules as the reference testdata/cube-ranking/make_cases.py, iOS
// CubeRanking.swift and web cubeRanking.ts, checked against its cases.json by CubeRankingTest:
// - A screen is 2-4 cards put in order, best first; every pair on it is known. A P1P1 pick ("P") is the picked card,
//   then the rest of its pack: the picked card beats each of them. Knowledge is the transitive closure, applied in log
//   order; a pair that contradicts what's known is skipped. It covers the cube's cards and every card in the log, so a
//   card that left the cube still carries what it settled; jobs and lists only hold the cube's cards.
// - Cards added since the ranking last caught up with its cube ("fresh") wait outside the lists until they're placed
//   (in a list with nothing placed yet they're simply part of what's left to sort).
// - A job (a color, or the final over every card) places from the top: the next place goes to the card known to beat
//   every other card still in; a card with `target` or more known above it is out.
// - The next screen: the cards nothing still in is known to beat (fewest known below, then a seeded hash), filled to
//   four with cards unordered against the screen, nearest the top first; in the final, new colors first. When only two
//   qualify it's a placement screen: one free card against up to three locked cards in known order.

/** A ranking job: a color of the cube (Group by color) or the final. [Pick] isn't a job: its screens are P1P1 picks. */
enum class RankJob(val key: String, val title: String) {
    W("W", "White"), U("U", "Blue"), B("B", "Black"), R("R", "Red"), G("G", "Green"), M("M", "Multicolor"),
    C("C", "Colorless"), L("L", "Lands"), Final("F", "Final"), Pick("P", "P1P1");

    companion object {
        val colors = listOf(W, U, B, R, G, M, C, L)
        fun of(key: String): RankJob? = entries.firstOrNull { it.key == key }
        /** From the cube's Group by color ("White" … "Lands"). */
        fun ofColor(group: String): RankJob? = colors.firstOrNull { it.title == group }
    }
}

/**
 * How much of each color a ranking sorts: the top quarter, third or half, or every card (2026-10-23: quarter and third
 * added). The final top N comes out exact at any depth; it just asks about a card itself when a color has more cards in
 * the top N than it sorted.
 */
object RankDepth {
    val all = listOf("quarter", "third", "half", "full")
    fun divisor(depth: String): Int? = mapOf("half" to 2, "third" to 3, "quarter" to 4)[depth] ?: if (depth == "full") null else 2
    fun target(n: Int, depth: String): Int = divisor(depth)?.let { (n + it - 1) / it } ?: n
    fun phrase(depth: String) = mapOf("half" to "top half", "third" to "top third", "quarter" to "top quarter")[depth] ?: "every card"
    /** The depth a new ranking starts with: a quarter of each color for a top 50, a third for a top 100. */
    fun suggested(top: Int) = if (top <= 50) "quarter" else "third"
}

/** One screen of the log: the cards as locked in (best first), its job, and when (epoch ms). */
@Serializable
data class RankScreen(val s: String, val o: List<String>, val t: Double? = null) {
    val job: RankJob? get() = RankJob.of(s)
}

/** One line of the change log: a card's place in a list went from → to (null = not placed). */
@Serializable
data class RankChange(val s: String, val c: String, val f: Int? = null, val to: Int? = null, val t: Double? = null, val by: String? = null, val n: Int? = null) {
    companion object {
        /** What moved between two states' places: colors then the final, each by the better place, then card id. */
        fun diff(before: Map<RankJob, Map<String, Int>>, after: Map<RankJob, Map<String, Int>>): List<RankChange> {
            val out = ArrayList<RankChange>()
            for (job in RankJob.colors + RankJob.Final) {
                val a = before[job] ?: emptyMap(); val b = after[job] ?: emptyMap()
                out += (a.keys + b.keys).filter { a[it] != b[it] }
                    .sortedWith(compareBy<String>({ k -> listOfNotNull(a[k], b[k]).min() }, { it }))
                    .map { RankChange(job.key, it, a[it], b[it]) }
            }
            return out
        }
    }
}

/** A set of card indexes. */
class RankBits(val words: LongArray) {
    constructor(n: Int) : this(LongArray((n + 63) / 64))

    operator fun contains(i: Int) = words[i ushr 6] and (1L shl (i and 63)) != 0L
    fun add(i: Int) { words[i ushr 6] = words[i ushr 6] or (1L shl (i and 63)) }
    fun remove(i: Int) { words[i ushr 6] = words[i ushr 6] and (1L shl (i and 63)).inv() }
    fun union(o: RankBits) { for (k in words.indices) words[k] = words[k] or o.words[k] }
    fun copy() = RankBits(words.copyOf())
    fun andCount(o: RankBits): Int { var n = 0; for (k in words.indices) n += java.lang.Long.bitCount(words[k] and o.words[k]); return n }
    fun intersects(o: RankBits): Boolean { for (k in words.indices) if (words[k] and o.words[k] != 0L) return true; return false }
    val members: List<Int>
        get() {
            val out = ArrayList<Int>()
            for (k in words.indices) {
                var v = words[k]
                while (v != 0L) { out += k * 64 + java.lang.Long.numberOfTrailingZeros(v); v = v and (v - 1) }
            }
            return out
        }
    override fun equals(other: Any?) = other is RankBits && words.contentEquals(other.words)
    override fun hashCode() = words.contentHashCode()
}

/** The log as a transitive "beats" relation over the cube's cards, indexed by sorted Oracle id. */
class RankKnowledge private constructor(
    val ids: List<String>, private val idx: Map<String, Int>, private val b: Array<RankBits>, private val w: Array<RankBits>,
    screens: Int, val perJob: MutableMap<String, Int>,
    /** Screen index → pairs it said that were skipped because the opposite was already known. */
    val contradicted: MutableMap<Int, List<Pair<Int, Int>>>,
) {
    var screens = screens
        private set

    val size get() = ids.size
    fun indexOf(id: String): Int? = idx[id.lowercase()]
    fun beatsSet(x: Int) = b[x]
    fun belowSet(x: Int) = w[x]
    fun known(a: Int, c: Int) = c in b[a]

    fun copy() = RankKnowledge(ids, idx, Array(size) { b[it].copy() }, Array(size) { w[it].copy() }, screens, HashMap(perJob), HashMap(contradicted))

    fun indexes(cards: List<String>): List<Int> {
        val xs = ArrayList<Int>()
        for (c in cards) { val i = idx[c.lowercase()]; if (i != null && i !in xs) xs += i }
        return xs
    }

    /** What a screen says, as (winner, loser) pairs: every pair in order, or for a pick the picked card over each other
     *  card of its pack. */
    fun pairs(screen: RankScreen): List<Pair<Int, Int>> {
        val xs = indexes(screen.o)
        if (screen.s == RankJob.Pick.key) {
            if (xs.isEmpty()) return emptyList()
            return xs.drop(1).map { xs[0] to it }
        }
        val out = ArrayList<Pair<Int, Int>>()
        for (i in xs.indices) for (j in i + 1 until xs.size) out += xs[i] to xs[j]
        return out
    }

    fun apply(screen: RankScreen) {
        perJob[screen.s] = (perJob[screen.s] ?: 0) + 1
        val skipped = pairs(screen).filter { !add(it.first, it.second) }
        if (skipped.isNotEmpty()) contradicted[screens] = skipped
        screens++
    }

    /** Learns a beats c; false when the opposite was already known (the pair is skipped). */
    private fun add(a: Int, c: Int): Boolean {
        if (a in b[c]) return false
        if (c in b[a]) return true
        val ups = w[a].copy().also { it.add(a) }
        val downs = b[c].copy().also { it.add(c) }
        for (x in ups.members) b[x].union(downs)
        for (y in downs.members) w[y].union(ups)
        return true
    }

    /** Same relation (redo: "Removing it changes nothing"). */
    fun same(o: RankKnowledge) = ids == o.ids && (0 until size).all { b[it] == o.b[it] }

    companion object {
        fun of(cards: Collection<String>, log: List<RankScreen> = emptyList()): RankKnowledge {
            val ids = (cards + log.flatMap { it.o }).map { it.lowercase() }.toSortedSet().toList()
            val k = RankKnowledge(ids, ids.withIndex().associate { it.value to it.index }, Array(ids.size) { RankBits(ids.size) },
                                  Array(ids.size) { RankBits(ids.size) }, 0, HashMap(), HashMap())
            log.forEach { k.apply(it) }
            return k
        }
    }
}

/** One job's state: who is placed, whether it's done, and the next screen. */
class RankSession(val top: List<Int>, val done: Boolean, val target: Int, val size: Int, val question: List<Int>?, val pinned: List<Int>, val open: RankBits,
                  /** New cards that can still make the list and aren't placed yet: [top] leaves them out. */
                  val waiting: List<Int> = emptyList())

object CubeRanking {
    const val PACK_SIZE = 15

    fun fnv1a(s: String): Long {
        var h = 0x811C9DC5L
        for (byte in s.toByteArray(Charsets.UTF_8)) {
            h = h xor (byte.toLong() and 0xFF)
            h = (h * 0x01000193L) and 0xFFFFFFFFL
        }
        return h
    }

    /** Places from the top: the next place goes to the card in [u] known to beat every other card in [u] (u loses them). */
    private fun ranked(K: RankKnowledge, u: RankBits, T: Int): List<Int> {
        val top = ArrayList<Int>()
        while (top.size < T) {
            var found = -1
            for (x in u.members) {
                val bx = K.beatsSet(x)
                var ok = true
                for (k in u.words.indices) {
                    var rest = u.words[k] and bx.words[k].inv()
                    if (k == x ushr 6) rest = rest and (1L shl (x and 63)).inv()
                    if (rest != 0L) { ok = false; break }
                }
                if (ok) { found = x; break }
            }
            if (found < 0) break
            top += found
            u.remove(found)
        }
        return top
    }

    /** One job: [scope] is the cards in it; [groups] maps a card index to its color (final only); [fresh] the cube's new
     *  cards. The list (`top`) leaves out new cards still waiting to be placed (`waiting`); screens and `done` count all. */
    fun session(K: RankKnowledge, scope: RankBits, target: Int, seed: String, groups: IntArray? = null, fresh: RankBits? = null): RankSession {
        val inScope = scope.members
        val n = inScope.size
        val T = minOf(target, n)
        val live = RankBits(K.size)
        for (x in inScope) if (K.belowSet(x).andCount(scope) < T) live.add(x)
        val u = live.copy()
        val full = ranked(K, u, T)
        val placed = full.toSet()
        var waiting = if (fresh == null) emptyList() else live.members.filter { it in fresh && it !in placed }
        var top = full
        if (waiting.isNotEmpty()) {
            val shown = live.copy()
            for (x in waiting) shown.remove(x)
            top = ranked(K, shown, T)
            // A list with nothing placed yet: new cards are simply part of what's left to sort.
            if (top.isEmpty()) { top = full; waiting = emptyList() }
        }
        if (full.size >= T) return RankSession(top, true, T, n, null, emptyList(), u, waiting)

        val hashes = HashMap<Int, Long>()
        fun h(x: Int) = hashes.getOrPut(x) { fnv1a("$seed:${K.ids[x]}") }
        val open = u.members
        val cands = open.filter { !K.belowSet(it).intersects(u) }
        val sortedCands = cands.sortedWith(compareBy<Int>({ K.beatsSet(it).andCount(u) }, { h(it) }, { it }))
        var picked = choose(K, sortedCands, groups, emptyList())
        if (picked.size < 4) {
            val candSet = cands.toSet()
            val others = open.filter { it !in candSet }
                .sortedWith(compareBy<Int>({ K.belowSet(it).andCount(u) }, { K.beatsSet(it).andCount(u) }, { h(it) }, { it }))
            picked = choose(K, others, groups, picked)
        }
        var pinned = emptyList<Int>()
        if (picked.size == 2) placement(K, u, picked[0], picked[1], ::h).let { picked = it.first; pinned = it.second }
        return RankSession(top, false, T, n, picked, pinned, u, waiting)
    }

    private fun choose(K: RankKnowledge, order: List<Int>, groups: IntArray?, start: List<Int>): List<Int> {
        val picked = start.toMutableList()
        fun ok(x: Int) = x !in picked && picked.all { !K.known(x, it) && !K.known(it, x) }
        if (groups != null) for (x in order) {
            if (picked.size == 4) break
            if (ok(x) && picked.none { groups[it] == groups[x] }) picked += x
        }
        for (x in order) {
            if (picked.size == 4) break
            if (ok(x)) picked += x
        }
        return picked
    }

    private fun placement(K: RankKnowledge, u: RankBits, a: Int, b: Int, h: (Int) -> Long): Pair<List<Int>, List<Int>> {
        var best: Pair<List<Int>, Int>? = null
        for ((lead, free) in listOf(a to b, b to a)) {
            val run = u.members.filter { K.known(lead, it) && !K.known(free, it) && !K.known(it, free) }
                .sortedWith(compareBy<Int>({ K.belowSet(it).andCount(u) }, { h(it) }, { it }))
            val chain = mutableListOf(lead)
            for (c in run) if (K.known(chain.last(), c)) chain += c
            if (best == null || chain.size > best.first.size) best = chain to free
        }
        var (chain, free) = best!!
        if (chain.size == 1) return listOf(a, b) to emptyList()
        if (chain.size > 3) { val rest = chain.drop(1); chain = listOf(chain[0], rest[(rest.size - 1) / 2], rest.last()) }
        return (chain + free) to chain
    }

    /** A redone screen's cards come back first while each is still open and their order is unknown. */
    fun reaskOpen(K: RankKnowledge, st: RankSession, cards: List<String>): Boolean {
        val xs = cards.map { K.indexOf(it) ?: return false }
        if (xs.size < 2 || !xs.all { it in st.open }) return false
        for (i in xs.indices) for (j in i + 1 until xs.size) if (K.known(xs[i], xs[j]) || K.known(xs[j], xs[i])) return false
        return true
    }

    private fun log2(x: Double) = ln(x) / ln(2.0)

    /** About how many screens a job takes: ordering the top k of n cards. */
    fun expectedSort(n: Int, k0: Int): Int {
        val k = minOf(k0, n)
        if (n <= 1 || k <= 0) return 0
        var bits = 0.0
        for (i in n - k + 1..n) bits += log2(i.toDouble())
        val f = if (k >= n - 1) 1.55 else 1.66
        return ceil(f * bits / log2(24.0)).toInt()
    }

    /** About how many screens the final takes once every color is sorted: placing the top [top] across colors. */
    fun expectedMerge(sizes: List<Int>, top: Int): Int {
        val T = minOf(top, sizes.sum())
        if (T <= 0 || sizes.count { it > 0 } <= 1) return 0
        val C = ArrayList<DoubleArray>().apply { add(doubleArrayOf(1.0)) }
        for (t in 1..T) { val row = DoubleArray(t + 1) { 1.0 }; for (k in 1 until t) row[k] = C[t - 1][k - 1] + C[t - 1][k]; C += row }
        var f = DoubleArray(T + 1).also { it[0] = 1.0 }
        for (s in sizes) {
            val g = DoubleArray(T + 1)
            for (t in 0..T) for (k in 0..minOf(s, t)) g[t] += f[t - k] * C[t][k]
            f = g
        }
        return ceil(1.78 * log2(f[T]) / log2(24.0)).toInt()
    }

    data class Link(val winner: String, val loser: String, val screen: Int)

    /** The shortest chain of screens that puts [hi] above [lo], or null when nothing has settled it. */
    fun why(K: RankKnowledge, log: List<RankScreen>, hi: String, lo: String): List<Link>? {
        val a = K.indexOf(hi) ?: return null
        val b = K.indexOf(lo) ?: return null
        if (a == b || !K.known(a, b)) return null
        val n = K.size
        val first = HashMap<Int, Int>()
        log.forEachIndexed { k, sc -> for ((w, l) in K.pairs(sc)) if (K.known(w, l)) first.putIfAbsent(w * n + l, k) }
        val adj = HashMap<Int, MutableList<Pair<Int, Int>>>()
        for ((key, k) in first) adj.getOrPut(key / n) { ArrayList() } += k to key % n
        for (l in adj.values) l.sortWith(compareBy({ it.first }, { it.second }))
        val prev = HashMap<Int, Pair<Int, Int>?>().apply { put(a, null) }
        var queue = listOf(a)
        while (queue.isNotEmpty()) {
            val next = ArrayList<Int>()
            for (x in queue) for ((k, y) in adj[x] ?: emptyList()) if (!prev.containsKey(y)) { prev[y] = x to k; next += y }
            if (prev.containsKey(b)) break
            queue = next
        }
        if (!prev.containsKey(b)) return null
        val chain = ArrayList<Link>()
        var y = b
        while (true) { val p = prev[y] ?: break; chain += Link(K.ids[p.first], K.ids[y], p.second + 1); y = p.first }
        return chain.reversed()
    }

    /** The next pack: up to 15 of the cube's cards, by a hash of the ranking, the picks so far and the card. */
    fun pack(rankingId: String, K: RankKnowledge): List<String> {
        val n = K.perJob[RankJob.Pick.key] ?: 0
        val rid = rankingId.lowercase()
        return K.ids.indices.sortedWith(compareBy<Int>({ fnv1a("$rid:P:$n:${K.ids[it]}") }, { it })).take(PACK_SIZE).map { K.ids[it] }
    }

    /** Cards of the pack the ranking already puts above the picked card, in pack order. */
    fun disagreements(K: RankKnowledge, picked: String, pack: List<String>): List<String> {
        val p = K.indexOf(picked) ?: return emptyList()
        return pack.filter { it.lowercase() != picked.lowercase() && K.indexOf(it)?.let { i -> K.known(i, p) } == true }
    }

    /** "Let the pick win": while the ranking puts a pack card above the picked one, take out the newest screen of the
     *  shortest chain that says so (at most 30). Returns the log indexes to remove, ascending. */
    fun pickWins(cards: Collection<String>, log: List<RankScreen>, picked: String, pack: List<String>): List<Int> {
        val alive = log.indices.toMutableList()
        val removed = ArrayList<Int>()
        repeat(30) {
            val cur = alive.map { log[it] }
            val K = RankKnowledge.of(cards, cur)
            val d = disagreements(K, picked, pack).firstOrNull() ?: return removed.sorted()
            val chain = why(K, cur, d, picked) ?: return removed.sorted()
            removed += alive.removeAt(chain.maxOf { it.screen } - 1)
        }
        return removed.sorted()
    }

    data class Gap(val card: String, val a: Int, val aOut: Boolean, val b: Int, val bOut: Boolean, val gap: Int, val atLeast: Boolean)
    data class Comparison(val compared: Int, val avgTenths: Int, val atLeast: Boolean, val biggest: List<Gap>, val oneSide: List<Gap>)

    /** Two rankings' orders of one list, both in K's card indexes. */
    fun compare(K: RankKnowledge, a: RankSession, b: RankSession, scope: RankBits): Comparison {
        fun place(st: RankSession, x: Int): Pair<Int, Boolean>? {
            val i = st.top.indexOf(x)
            if (i >= 0) return (i + 1) to false
            if (st.done && st.top.size < st.size) return (st.top.size + 1) to true
            return null
        }
        data class R(val gap: Gap, val best: Int, val x: Int)
        val rows = ArrayList<R>()
        for (x in scope.members) {
            val pa = place(a, x) ?: continue
            val pb = place(b, x) ?: continue
            if (pa.second && pb.second) continue
            val best = listOf(pa, pb).filter { !it.second }.minOf { it.first }
            rows += R(Gap(K.ids[x], pa.first, pa.second, pb.first, pb.second, abs(pa.first - pb.first), pa.second || pb.second), best, x)
        }
        val n = rows.size
        val total = rows.sumOf { it.gap.gap }
        return Comparison(n, if (n == 0) 0 else (20 * total + n) / (2 * n), rows.any { it.gap.atLeast },
            rows.sortedWith(compareBy<R>({ -it.gap.gap }, { it.best }, { it.x })).take(10).map { it.gap },
            rows.filter { it.gap.aOut != it.gap.bOut }.sortedWith(compareBy<R>({ it.best }, { it.x })).map { it.gap })
    }
}

/** A whole ranking worked out from its log: the cube's cards and colors, depth and final size. */
class RankingState private constructor(val rankingId: String, val category: Map<String, RankJob>, val knowledge: RankKnowledge, val depth: String, val top: Int,
                                       /** The cube's cards added since the ranking last caught up: they wait outside the lists until placed. */
                                       val fresh: Set<String>) {
    /** [cards] are the cube's cards now (a card in the log but not here has left the cube); [fresh] its new cards. */
    constructor(rankingId: String, cards: Map<String, RankJob>, log: List<RankScreen>, depth: String, top: Int, fresh: Set<String> = emptySet()) : this(
        rankingId.lowercase(), cards.mapKeys { it.key.lowercase() }, RankKnowledge.of(cards.keys, log), depth, top,
        fresh.map { it.lowercase() }.filter { f -> cards.keys.any { it.lowercase() == f } }.toSet())

    private val cache = HashMap<RankJob, RankSession>()

    fun appending(screen: RankScreen) = RankingState(rankingId, category, knowledge.copy().also { it.apply(screen) }, depth, top, fresh)
    fun id(x: Int) = knowledge.ids[x]

    /** New cards not placed yet in any list: a re-rank is due. */
    val waiting: List<String> get() = (jobs + RankJob.Final).flatMap { j -> session(j).waiting.map(::id) }.toSortedSet().toList()

    fun scope(job: RankJob): RankBits {
        val m = RankBits(knowledge.size)
        knowledge.ids.forEachIndexed { i, id -> val c = category[id]; if (c != null && (job == RankJob.Final || c == job)) m.add(i) }
        return m
    }

    fun size(job: RankJob) = if (job == RankJob.Final) category.size else category.values.count { it == job }
    fun target(job: RankJob): Int = if (job == RankJob.Final) top else RankDepth.target(size(job), depth)
    val jobs: List<RankJob> get() = RankJob.colors.filter { size(it) > 0 }

    fun session(job: RankJob): RankSession = cache.getOrPut(job) {
        val groups = if (job == RankJob.Final) IntArray(knowledge.size) { maxOf(0, RankJob.colors.indexOf(category[knowledge.ids[it]] ?: RankJob.C)) } else null
        val freshBits = if (fresh.isEmpty()) null else RankBits(knowledge.size).also { b -> fresh.forEach { c -> knowledge.indexOf(c)?.let(b::add) } }
        CubeRanking.session(knowledge, scope(job), target(job), "$rankingId:${job.key}:${knowledge.screens}", groups, freshBits)
    }

    fun expected(job: RankJob) =
        if (job == RankJob.Final) CubeRanking.expectedMerge(jobs.map { size(it) }, top) else CubeRanking.expectedSort(size(job), target(job))

    /** Every list's places (or some: a color's screen can only move that color and the final). */
    fun places(only: List<RankJob>? = null): Map<RankJob, Map<String, Int>> =
        (only ?: (jobs + RankJob.Final)).associateWith { j -> session(j).top.withIndex().associate { id(it.value) to it.index + 1 } }

    data class Progress(val sorted: Int, val categories: Int, val ranked: Int)
    val progress: Progress get() = jobs.let { js -> Progress(js.count { session(it).done }, js.size, session(RankJob.Final).top.size) }
}
