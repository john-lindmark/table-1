package site.table1.events.library

import kotlinx.serialization.Serializable
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.ln

// Cube rankings engine (contract/cube-rankings-2026-10-21.md). Pure: everything comes from a ranking's screen log, so
// undo, redo and watching never need repair. Same rules as the reference testdata/cube-ranking/make_cases.py, iOS
// CubeRanking.swift and web cubeRanking.ts, checked against its cases.json by CubeRankingTest:
// - A screen is 2-4 cards put in order, best first; every pair on it is known. A P1P1 pick ("P") is the picked card,
//   then the rest of its pack: the picked card beats each of them. Knowledge is the transitive closure, applied final
//   screens newest first, then the colors' screens, then picks (applyOrder); a pair that contradicts what's known is
//   skipped. It covers the cube's cards and every card in the log, so a
//   card that left the cube still carries what it settled; jobs and lists only hold the cube's cards.
// - Cards added since the ranking last caught up with its cube ("fresh") wait outside the lists until they're placed
//   (in a list with nothing placed yet they're simply part of what's left to sort).
// - A job (a color, or the final over every card) places from the top: the next place goes to the card known to beat
//   every other card still in; a card with `target` or more known above it is out.
// - The next screen: the cards nothing still in is known to beat (fewest known below, then a seeded hash), filled to
//   four with cards unordered against the screen, nearest the top first; in the final, new colors first. When only two
//   qualify it's a placement screen: one free card against up to three locked cards in known order.
// - The final places a card only once its order against the rest is checked (RankSupport): against each other color's
//   best card not yet placed, asked on a screen or backed by two chains of screens that share no card (2026-11-13).
//   Until then the next screen is that check, and its answer wins over what the colors or a detour had settled.

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
    /** The screens this knowledge was built from. */
    private val screenLog: MutableList<RankScreen> = ArrayList(),
) {
    val log: List<RankScreen> get() = screenLog
    /** The final's support, kept up to date one screen at a time (built again when a check overturns an order). */
    private var support: RankSupport? = null

    var screens = screens
        private set

    val size get() = ids.size
    fun indexOf(id: String): Int? = idx[id.lowercase()]
    fun beatsSet(x: Int) = b[x]
    fun belowSet(x: Int) = w[x]
    fun known(a: Int, c: Int) = c in b[a]

    fun copy(): RankKnowledge = RankKnowledge(ids, idx, Array(size) { b[it].copy() }, Array(size) { w[it].copy() }, screens, HashMap(perJob), HashMap(contradicted),
                               ArrayList(screenLog)).also { it.support = support?.copy() }

    /** The same cards, nothing known (RankSupport's own orders). */
    fun blank(): RankKnowledge = RankKnowledge(ids, idx, Array(size) { RankBits(size) }, Array(size) { RankBits(size) }, 0, HashMap(), HashMap())

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

    private fun build() {
        for (x in 0 until size) { b[x] = RankBits(size); w[x] = RankBits(size) }
        contradicted.clear()
        perJob.clear()
        support = null
        for (s in screenLog) perJob[s.s] = (perJob[s.s] ?: 0) + 1
        for (k in applyOrder(screenLog)) {
            val skipped = pairs(screenLog[k]).filter { !add(it.first, it.second) }
            if (skipped.isNotEmpty()) contradicted[k] = skipped
        }
        screens = screenLog.size
    }

    /** One more screen. A final screen that contradicts what's known wins (final screens apply newest first), so the
     *  whole log is applied again; anything else gives the same answer added on its own. */
    fun apply(screen: RankScreen) {
        screenLog += screen
        val prs = pairs(screen)
        if (screen.s == RankJob.Final.key && prs.any { known(it.second, it.first) }) { build(); return }
        perJob[screen.s] = (perJob[screen.s] ?: 0) + 1
        val skipped = prs.filter { !add(it.first, it.second) }
        if (skipped.isNotEmpty()) contradicted[screens] = skipped
        screens++
        support?.addScreen(this, screen)
    }

    /** The final's support for these colors (built once, then kept up to date by [apply]). */
    fun supportFor(groups: IntArray): RankSupport {
        support?.let { if (it.groups.contentEquals(groups)) return it }
        return RankSupport(this, groups).also { support = it }
    }

    /** Learns a beats c; false when the opposite was already known (the pair is skipped). */
    fun add(a: Int, c: Int): Boolean {
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
                                  Array(ids.size) { RankBits(ids.size) }, 0, HashMap(), HashMap(), ArrayList(log))
            k.build()
            return k
        }

        /** The order screens are applied in (2026-11-07): final screens newest first, then the colors' screens, then
         *  picks, each in log order. Without a contradiction the order changes nothing (the closure is the same). With
         *  one, a newer final screen wins over an older one and over a color's sort, so the final's checks can correct an
         *  order the colors or a detour through another color settled. Picks stay last, so "Keep my ranking" still skips
         *  a pick's disagreeing pairs. */
        fun applyOrder(log: List<RankScreen>): List<Int> {
            val f = RankJob.Final.key; val p = RankJob.Pick.key
            return log.indices.reversed().filter { log[it].s == f } + log.indices.filter { log[it].s != f && log[it].s != p } +
                log.indices.filter { log[it].s == p }
        }
    }
}

/** One job's state: who is placed, whether it's done, and the next screen. */
class RankSession(val top: List<Int>, val done: Boolean, val target: Int, val size: Int, val question: List<Int>?, val pinned: List<Int>, val open: RankBits,
                  /** New cards that can still make the list and aren't placed yet: [top] leaves them out. */
                  val waiting: List<Int> = emptyList(),
                  /** The final's check: the next card to place against cards its order with hasn't been asked about directly. */
                  val check: Boolean = false,
                  /** Places checked from the top (the final; a color's list counts every place). `done` once it reaches the
                   *  target; [top] shows every place the log settles, checked or not. */
                  val checked: Int = 0)

/** What the final needs before it places a card (2026-11-07): which orders a screen asked about directly. `met[x]` the
 *  cards x was ordered against on any screen (a pick: the picked card and the rest), `metFinal[x]` on a final screen,
 *  `won[x]` the cards x beat on a screen (and still beats); `sorted` the same-color order the color's own screens set.
 *  `backed` remembers pairs with two chains: screens only add wins, and a final screen that overturns an order builds the
 *  knowledge (and this) again, so a backed pair stays backed. */
class RankSupport private constructor(
    val groups: IntArray, private val met: Array<RankBits>, private val metFinal: Array<RankBits>, private val won: Array<RankBits>,
    private val sorted: RankKnowledge, private val backed: HashSet<Int>,
) {
    constructor(K: RankKnowledge, groups: IntArray) : this(groups, Array(K.size) { RankBits(K.size) }, Array(K.size) { RankBits(K.size) },
                                                          Array(K.size) { RankBits(K.size) }, K.blank(), HashSet()) {
        for (sc in K.log) addScreen(K, sc)
    }

    fun copy(): RankSupport = RankSupport(groups, Array(met.size) { met[it].copy() }, Array(met.size) { metFinal[it].copy() }, Array(met.size) { won[it].copy() },
                             sorted.copy(), HashSet(backed))

    /** One more screen of K's log (K already knows it). */
    fun addScreen(K: RankKnowledge, sc: RankScreen) {
        val f = RankJob.Final.key; val p = RankJob.Pick.key
        for ((w, l) in K.pairs(sc)) {
            met[w].add(l); met[l].add(w)
            if (sc.s == f) { metFinal[w].add(l); metFinal[l].add(w) }
            if (K.known(w, l)) {
                won[w].add(l)
                if (groups[w] == groups[l] && sc.s != f && sc.s != p) sorted.add(w, l)
            }
        }
    }

    /** x is known to beat every other card still in the running; [p] is the final's cards not placed yet, in the running
     *  or not (2026-11-13: in Daniel Shea's Lindmark Cube top 50 every white, red and green card had been pushed out of the
     *  running by answers nothing checked, so places 35-46 were twelve black cards checked only against each other). The
     *  cards x still needs a screen with, one per color at most: each other color's best card in p (fewest known above it
     *  in p, then index) unless x met it on a screen or two chains of screens that share no card put x above it (one
     *  chain is one answer away from wrong: Duress over Wheel of Fortune carried those twelve, all through Urza's Saga
     *  over Path to Exile); and x's own color's best card when only the color's own screens put x above it (a color sorted
     *  wrong holds its better cards back, then lets them out in a run). */
    fun unchecked(K: RankKnowledge, x: Int, p: RankBits): RankBits {
        val best = HashMap<Int, Pair<Int, Int>>()
        for (y in p.members) {
            if (y == x) continue
            val g = groups[y]; val k = K.belowSet(y).andCount(p)
            val cur = best[g]
            if (cur == null || k < cur.first || (k == cur.first && y < cur.second)) best[g] = k to y
        }
        val miss = RankBits(K.size)
        for ((g, ky) in best) {
            val y = ky.second
            if (g == groups[x]) { if (sorted.known(x, y) && y !in metFinal[x]) miss.add(y); continue }
            if (y in met[x]) continue
            val key = x * K.size + y
            if (key in backed) continue
            if (chains(won, x, y) >= 2) backed += key else miss.add(y)
        }
        return miss
    }

    companion object {
        /** How many chains of screens that share no card lead from x down to y, at most [limit] (2026-11-13): vertex-disjoint
         *  paths in the graph of screen wins (`won[a]`: the cards a beat on a screen and still beats), found by augmenting
         *  paths over split vertices (in(v) = 2v, out(v) = 2v + 1). Only the count matters, so the search order doesn't. */
        fun chains(won: Array<RankBits>, x: Int, y: Int, limit: Int = 2): Int {
            val n = won.size
            val usedV = BooleanArray(n)                      // vertices carrying a chain (x and y never count)
            val usedIn = HashMap<Int, HashSet<Int>>()        // b -> the a's whose edge a -> b carries a chain
            val usedOut = HashMap<Int, HashSet<Int>>()       // a -> the b's of those edges
            var flow = 0
            while (flow < limit) {
                val start = 2 * x + 1; val goal = 2 * y
                val from = IntArray(2 * n) { -1 }
                from[start] = start
                val queue = IntArray(2 * n); var tail = 0; var head = 0
                queue[tail++] = start
                var found = false
                fun go(t: Int, st: Int) { if (from[t] < 0) { from[t] = st; queue[tail++] = t; if (t == goal) found = true } }
                while (head < tail && !found) {
                    val st = queue[head++]; val v = st shr 1
                    if (st and 1 == 1) {
                        val out = usedOut[v]
                        val ws = won[v].words
                        var k = 0
                        while (k < ws.size && !found) {
                            var m = ws[k]
                            while (m != 0L && !found) {
                                val b = k * 64 + java.lang.Long.numberOfTrailingZeros(m)
                                m = m and (m - 1)
                                if (out == null || b !in out) go(2 * b, st)
                            }
                            k++
                        }
                        if (usedV[v] && v != x) go(2 * v, st)
                    } else {
                        if (v != y && !usedV[v]) go(2 * v + 1, st)
                        usedIn[v]?.let { for (a in it) go(2 * a + 1, st) }
                    }
                }
                if (!found) break
                var t = goal
                while (t != start) {
                    val f = from[t]; val fv = f shr 1; val tv = t shr 1
                    if (f and 1 == 1 && t and 1 == 0) {        // out(fv) -> in(tv): along an edge, or back across a used vertex
                        if (fv == tv) usedV[fv] = false
                        else { usedIn.getOrPut(tv) { HashSet() } += fv; usedOut.getOrPut(fv) { HashSet() } += tv }
                    } else if (f and 1 == 0 && t and 1 == 1) { // in(fv) -> out(tv): across a vertex, or back along a used edge
                        if (fv == tv) usedV[fv] = true
                        else { usedIn[fv]?.remove(tv); usedOut[tv]?.remove(fv) }
                    }
                    t = f
                }
                flow++
            }
            return flow
        }
    }
}

object CubeRanking {
    const val PACK_SIZE = 15
    /** The rules this engine implements, by the date they changed; the same in every engine and in cases.json (`rules`).
     *  [RankEngine] runs the server's engine file instead when its manifest names newer rules. */
    const val RULES = "2026-11-13"

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
        var sure = full.size
        var stuck: Pair<Int, RankBits>? = null
        val unplaced = scope.copy()
        if (groups != null) {
            val (good, why) = checked(K, live.copy(), unplaced, T, K.supportFor(groups))
            sure = good.size; stuck = why
        }
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
        if (sure >= T) return RankSession(top, true, T, n, null, emptyList(), u, waiting, checked = sure)

        val hashes = HashMap<Int, Long>()
        fun h(x: Int) = hashes.getOrPut(x) { fnv1a("$seed:${K.ids[x]}") }
        if (stuck != null && groups != null) return RankSession(top, false, T, n, checkScreen(K, unplaced, stuck.first, stuck.second, groups, ::h), emptyList(), u, waiting, true, sure)
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
        return RankSession(top, false, T, n, picked, pinned, u, waiting, checked = sure)
    }

    /** ranked() for the final: a card known to beat every other card still in ([u]) is placed only once its order against
     *  the cards not placed yet ([p]) is checked (RankSupport.unchecked); u and p lose the placed cards. Returns the places
     *  and, when it stops at one, the card and its unchecked cards. */
    private fun checked(K: RankKnowledge, u: RankBits, p: RankBits, T: Int, support: RankSupport): Pair<List<Int>, Pair<Int, RankBits>?> {
        val top = ArrayList<Int>()
        while (top.size < T) {
            val x = ranked(K, u.copy(), 1).firstOrNull() ?: break
            val miss = support.unchecked(K, x, p)
            if (miss.members.isNotEmpty()) return top to (x to miss)
            top += x
            u.remove(x)
            p.remove(x)
        }
        return top to null
    }

    /** The check: x with up to three of the cards it hasn't been checked against: its own color's next card first, then
     *  other colors' cards nearest the top (fewest known above them among the cards not placed yet, [p]), one per color
     *  first. Nothing is locked: the answer is new and wins. */
    private fun checkScreen(K: RankKnowledge, p: RankBits, x: Int, miss: RankBits, groups: IntArray, h: (Int) -> Long): List<Int> {
        val ys = miss.members.sortedWith(compareBy<Int>({ K.belowSet(it).andCount(p) }, { h(it) }, { it }))
        val picked = mutableListOf(x)
        picked += ys.filter { groups[it] == groups[x] }.take(1)
        for (y in ys) if (picked.size < 4 && y !in picked && picked.none { groups[it] == groups[y] }) picked += y
        for (y in ys) if (picked.size < 4 && y !in picked) picked += y
        return picked
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
        return ceil(6.0 * log2(f[T]) / log2(24.0)).toInt() // 1.78 before the final's checks, 4.9 before 2026-11-13
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
                                       val fresh: Set<String>,
                                       /** The same ranking in the server's engine file when it has newer rules than this build ([RankEngine]); null = ours. */
                                       val js: RankEngineState?) {
    /** [cards] are the cube's cards now (a card in the log but not here has left the cube); [fresh] its new cards. */
    constructor(rankingId: String, cards: Map<String, RankJob>, log: List<RankScreen>, depth: String, top: Int, fresh: Set<String> = emptySet()) : this(
        rankingId.lowercase(), cards.mapKeys { it.key.lowercase() }, RankKnowledge.of(cards.keys, log), depth, top,
        fresh.map { it.lowercase() }.filter { f -> cards.keys.any { it.lowercase() == f } }.toSet(), null, log)

    private constructor(rankingId: String, category: Map<String, RankJob>, knowledge: RankKnowledge, depth: String, top: Int, fresh: Set<String>,
                        js: RankEngineState?, log: List<RankScreen>) :
        this(rankingId, category, knowledge, depth, top, fresh, js ?: RankEngine.open(rankingId, category, log, depth, top, fresh))

    private val cache = HashMap<RankJob, RankSession>()

    fun appending(screen: RankScreen) = RankingState(rankingId, category, knowledge.copy().also { it.apply(screen) }, depth, top, fresh, js?.appending(screen))
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
        js?.session(job, knowledge)?.let { return@getOrPut it }
        val groups = if (job == RankJob.Final) IntArray(knowledge.size) { maxOf(0, RankJob.colors.indexOf(category[knowledge.ids[it]] ?: RankJob.C)) } else null
        val freshBits = if (fresh.isEmpty()) null else RankBits(knowledge.size).also { b -> fresh.forEach { c -> knowledge.indexOf(c)?.let(b::add) } }
        CubeRanking.session(knowledge, scope(job), target(job), "$rankingId:${job.key}:${knowledge.screens}", groups, freshBits)
    }

    fun expected(job: RankJob) = js?.expected(job) ?:
        if (job == RankJob.Final) CubeRanking.expectedMerge(jobs.map { size(it) }, top) else CubeRanking.expectedSort(size(job), target(job))

    /** Every list's places (or some: a color's screen can only move that color and the final). */
    fun places(only: List<RankJob>? = null): Map<RankJob, Map<String, Int>> =
        (only ?: (jobs + RankJob.Final)).associateWith { j -> session(j).top.withIndex().associate { id(it.value) to it.index + 1 } }

    data class Progress(val sorted: Int, val categories: Int, val ranked: Int)
    val progress: Progress get() = jobs.let { js -> Progress(js.count { session(it).done }, js.size, session(RankJob.Final).top.size) }
}
