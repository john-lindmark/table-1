package site.table1.events.data

/**
 * Drafts with several pods (contract/draft-pods-2026-11-09.md): the same rules as the engine's seating.ts and
 * playoffs.ts, checked against testdata/draft-pods/cases.json.
 */
object DraftPods {
    /** Pairing after round 1: inside each pod, or Swiss across every pod. */
    const val INSIDE = "pod"
    const val ACROSS = "cross"

    /** How many pods a pick makes: null = automatic (pods of up to 8), never a pod under 2. */
    fun count(players: Int, pods: Int?): Int = when {
        players <= 0 -> 0
        pods == null -> (players + 7) / 8
        else -> maxOf(1, minOf(pods, players / 2))
    }

    /** Pod sizes, largest first: 14 in 2 → [7, 7]. */
    fun plan(players: Int, pods: Int?): List<Int> {
        val c = count(players, pods)
        if (c == 0) return emptyList()
        return (0 until c).map { players / c + if (it < players % c) 1 else 0 }
    }

    /** "2 pods · 9, 8", "1 pod · 6", "No players yet". */
    fun label(players: Int, pods: Int?): String {
        val sizes = plan(players, pods)
        return when (sizes.size) {
            0 -> "No players yet"
            1 -> "1 pod · ${sizes[0]}"
            else -> "${sizes.size} pods · ${sizes.joinToString(", ")}"
        }
    }

    /** Automatic Swiss rounds: inside pods, enough for the largest pod; across pods, enough for everyone. */
    fun rounds(sizes: List<Int>, pairing: String): Int {
        val s = sizes.filter { it > 0 }
        if (s.isEmpty()) return EventRules.swissRounds(0)
        return EventRules.swissRounds(if (pairing == INSIDE) s.max() else s.sum())
    }

    /** The Automatic rounds switch's detail for a draft. */
    fun autoLabel(players: Int, pods: Int?, pairing: String): String {
        if (players < 2) return "Auto · set when round 1 is paired"
        val sizes = plan(players, pods)
        val n = rounds(sizes, pairing)
        val rs = "$n round${if (n == 1) "" else "s"}"
        return if (pairing == INSIDE && sizes.size > 1) "Auto · $rs for pods of ${sizes.max()}" else "Auto · $rs for $players players"
    }

    data class Seat(val pod: Int, val seat: Int)
    data class PodPlan(val pairs: List<Pair<Int, Int>>, val left: Int?)
    data class RoundOne(val pods: List<PodPlan>, val across: List<Pair<Seat, Seat>>, val bye: Seat?)

    /** Round 1 by seat numbers: each pod across its table, then the seats odd pods leave over against each other in
     *  pod order, the last one a bye when the event is odd. `seats`: each pod's seat numbers (any order). */
    fun roundOne(seats: List<List<Int>>): RoundOne {
        val left = mutableListOf<Seat>()
        val pods = seats.mapIndexed { p, podSeats ->
            val s = podSeats.sorted().toMutableList()
            val extra = if (s.size % 2 == 1) s.removeAt(s.size - 1) else null
            val half = s.size / 2
            extra?.let { left += Seat(p, it) }
            PodPlan((0 until half).map { s[it] to s[it + half] }, extra)
        }
        val across = (0 until left.size - 1 step 2).map { left[it] to left[it + 1] }
        return RoundOne(pods, across, if (left.size % 2 == 1) left.last() else null)
    }

    /** The note under pod `index`: "Round 1 pairs across the table: 1 v 4, 2 v 5, 3 v 6. Seat 7 plays Pod 2's seat 7." */
    fun note(seats: List<List<Int>>, index: Int, podName: (Int) -> String): String {
        val plan = roundOne(seats)
        val pod = plan.pods[index]
        val pairs = pod.pairs.joinToString(", ") { "${it.first} v ${it.second}" }
        var text = if (pairs.isEmpty()) "Round 1 pairs across the table." else "Round 1 pairs across the table: $pairs."
        pod.left?.let { left ->
            val me = Seat(index, left)
            if (plan.bye == me) text += " Seat $left has the bye."
            else plan.across.firstOrNull { it.first == me || it.second == me }?.let { pair ->
                val other = if (pair.first == me) pair.second else pair.first
                text += " Seat $left plays ${podName(other.pod)}'s seat ${other.seat}."
            }
        }
        return text
    }

    /** The seat with round 1's bye, if pod `index` has it. */
    fun byeSeat(seats: List<List<Int>>, index: Int): Int? = roundOne(seats).bye?.takeIf { it.pod == index }?.seat

    /** Short pod code for a standings row: "P1" from "Pod 1", else the pod's place. */
    fun code(name: String?, index: Int): String {
        val n = name?.trim()?.split(Regex("\\s+"))?.lastOrNull()
        return if (n != null && n.isNotEmpty() && n.all { it.isDigit() }) "P$n" else "P${index + 1}"
    }
    /* ── Pods in lists (cases `sections`, `player_sections`) ── */

    /** One pod's share of a list: its matches or players, under "Pod 1", "Across pods" or "Not seated". */
    data class Section<T>(val pod: String?, val title: String, val items: List<T>) { val key: String get() = pod ?: title }

    /** A pod's title: its name, else "Pod N" by its place among all the event's pods. */
    fun title(name: String?, index: Int): String = if (!name.isNullOrBlank()) name else "Pod ${index + 1}"

    /** "1 match", "4 matches". */
    fun matchCount(n: Int): String = "$n match${if (n == 1) "" else "es"}"

    /**
     * A round's matches under their pods (Live round, Earlier, Matchups), or null when the round isn't grouped:
     * playoffs, or fewer than two pods hold a player. A match sits in the pod all its players share (a bye in its
     * player's pod), else under Across pods, which comes last. Tables in order inside each, the bye last.
     */
    fun <M> sections(
        matches: List<M>, pods: List<Pair<String, String?>>, podOf: Map<String, String?>, stage: String?,
        players: (M) -> List<String?>, table: (M) -> Int?, isBye: (M) -> Boolean,
    ): List<Section<M>>? {
        val inPlay = podOf.values.filterNotNull().toSet()
        val shown = pods.withIndex().filter { it.value.first in inPlay }
        if ((stage != null && stage != "swiss") || shown.size < 2) return null
        fun podOfMatch(m: M): String? {
            val ps = players(m).filterNotNull()
            val set = ps.map { podOf[it] ?: "" }.toSet()
            return set.singleOrNull()?.takeIf { ps.isNotEmpty() && it.isNotEmpty() }
        }
        fun ordered(ms: List<M>) = ms.withIndex()
            .sortedWith(compareBy({ isBye(it.value) }, { table(it.value) ?: 0 }, { it.index })).map { it.value }
        val out = mutableListOf<Section<M>>()
        for ((i, p) in shown) {
            val ms = matches.filter { podOfMatch(it) == p.first }
            if (ms.isNotEmpty()) out += Section(p.first, title(p.second, i), ordered(ms))
        }
        val across = matches.filter { podOfMatch(it) == null }
        if (across.isNotEmpty()) out += Section(null, "Across pods", ordered(across))
        return out
    }

    /** A list of players under their pods (seat order; no seat keeps list order), then Not seated, or null with fewer
     *  than two pods in play. */
    fun <P> playerSections(players: List<P>, pods: List<Pair<String, String?>>, pod: (P) -> String?, seat: (P) -> Int?): List<Section<P>>? {
        val inPlay = players.mapNotNull(pod).toSet()
        val shown = pods.withIndex().filter { it.value.first in inPlay }
        if (shown.size < 2) return null
        val out = shown.map { (i, p) ->
            Section(p.first, title(p.second, i), players.withIndex().filter { pod(it.value) == p.first }
                .sortedWith(compareBy({ seat(it.value) == null }, { seat(it.value) ?: 0 }, { it.index })).map { it.value })
        }.toMutableList()
        val rest = players.filter { pod(it) == null }
        if (rest.isNotEmpty()) out += Section(null, "Not seated", rest)
        return out
    }
}
