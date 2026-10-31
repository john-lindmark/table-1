package site.table1.events.library

/* Owning a card in any printing (contract/owned-by-card-2026-10-31.md): a deck or cube line is covered by copies of the
   same card in any printing, finish or language, the printing and finish it names first. Also card detail's Match
   collection. Cases in testdata/owned-by-card/cases.json (OwnedByCardTest). */

/** What the collection holds, per printing + finish and per card. [owned] is keyed "card_id|finish" or
 *  "card_id|finish|lang"; [cardOf] maps a printing to its card (a printing missing from it is its own card). */
class Holdings(owned: Map<String, Int>, private val cardOf: Map<String, String>) {
    val byPrinting: Map<String, Int>
    val byCard: Map<String, Int>

    init {
        val p = HashMap<String, Int>()
        val c = HashMap<String, Int>()
        for ((k, n) in owned) {
            val parts = k.split("|")
            val id = parts[0]
            val finish = parts.getOrElse(1) { "nonfoil" }
            p.merge("$id|$finish", n, Int::plus)
            c.merge(card(id), n, Int::plus)
        }
        byPrinting = p
        byCard = c
    }

    fun card(cardId: String) = cardOf[cardId] ?: cardId
    /** Copies of this printing's card in any printing. */
    fun ownedCard(cardId: String) = byCard[card(cardId)] ?: 0
    fun ownedPrinting(cardId: String, finish: String) = byPrinting["$cardId|$finish"] ?: 0

    companion object {
        /** `owned` with every printing it holds or [listing] names mapped to its card from the open catalog. */
        fun of(owned: Map<String, Int>, listing: Collection<String>): Holdings = Holdings(owned, cardKeys(owned, listing))

        fun cardKeys(owned: Map<String, Int>, listing: Collection<String>): Map<String, String> =
            CatalogStore.cardKeys(owned.keys.map { it.substringBefore("|") }.toSet() + listing)
    }
}

object OwnedByCard {
    /** One deck or cube line, in list order. */
    data class Need(val cardId: String, val board: String, val finish: String = "nonfoil", val qty: Int, val lang: String = "en")

    fun needs(l: CardList) = l.entries.map { Need(it.cardId, it.board, it.finish, it.qty, it.lang) }

    /** Copies each line still needs. The printing and finish a line names cover it first, then the card's other copies
     *  cover what's left, lines in order; a copy covers one line. Considering and basics never need any or use copies. */
    fun shorts(lines: List<Need>, h: Holdings, basics: Set<String>): List<Int> {
        val counted = lines.map { it.board != "maybe" && it.cardId !in basics }
        val exact = HashMap(h.byPrinting)
        val spare = HashMap(h.byCard)
        val covered = IntArray(lines.size)
        lines.forEachIndexed { i, l ->
            if (!counted[i]) return@forEachIndexed
            val k = "${l.cardId}|${l.finish}"
            val c = minOf(l.qty, exact[k] ?: 0)
            exact[k] = (exact[k] ?: 0) - c
            spare.merge(h.card(l.cardId), -c, Int::plus)
            covered[i] = c
        }
        lines.forEachIndexed { i, l ->
            if (!counted[i]) return@forEachIndexed
            val o = h.card(l.cardId)
            val c = minOf(l.qty - covered[i], spare[o] ?: 0)
            spare[o] = (spare[o] ?: 0) - c
            covered[i] += c
        }
        return lines.mapIndexed { i, l -> if (counted[i]) l.qty - covered[i] else 0 }
    }

    /** Wants → Missing: one line per card, the largest shortfall across lists (lists don't reserve copies), shown as the
     *  first short line of the list that needs most (the earliest list on a tie). */
    fun lines(lists: List<Pair<String, List<Need>>>, h: Holdings, basics: Set<String>): List<MissingLine> {
        data class Acc(var short: Int = 0, val lists: MutableList<String> = mutableListOf(), var line: Need? = null)
        val need = LinkedHashMap<String, Acc>()
        for ((name, ls) in lists) {
            val per = LinkedHashMap<String, Int>()
            val first = HashMap<String, Need>()
            val s = shorts(ls, h, basics)
            ls.forEachIndexed { i, e ->
                if (e.board == "maybe" || e.cardId in basics) return@forEachIndexed
                val o = h.card(e.cardId)
                per.merge(o, e.qty, Int::plus)
                if (s[i] > 0) first.putIfAbsent(o, e)
            }
            for ((o, n) in per) {
                val short = n - (h.byCard[o] ?: 0)
                if (short <= 0) continue
                val v = need.getOrPut(o) { Acc() }
                if (short > v.short) { v.short = short; v.line = first[o] }
                v.lists += name
            }
        }
        return need.mapNotNull { (o, v) -> v.line?.let { MissingLine(it.cardId, it.finish, v.short, v.lists.sorted(), o) } }
            .sortedWith(compareByDescending<MissingLine> { it.short }.thenBy { "${it.cardId}|${it.finish}" })
    }

    // ── Match collection (card detail) ─────────────────────────────────

    /** A version you own: printing × finish, every condition and language together. */
    data class Version(val cardId: String, val finish: String, val owned: Int)
    data class Pick(val cardId: String, val finish: String, val qty: Int) { val key get() = "$cardId|$finish" }
    /** A `list_edit` move op: [qty] copies of a line to another printing and/or finish, keeping its language. */
    data class Move(val cardId: String, val finish: String, val lang: String = "en", val toCardId: String, val toFinish: String, val qty: Int)

    /** Versions the section already lists first, then the ones you hold most of, then by card id and finish. */
    fun autoMatch(lines: List<Need>, versions: List<Version>): List<Pick> {
        var left = lines.sumOf { it.qty }
        val listed = lines.map { "${it.cardId}|${it.finish}" }.toSet()
        val order = versions.sortedWith(compareBy<Version>({ "${it.cardId}|${it.finish}" !in listed }, { -it.owned }, { it.cardId }, { it.finish }))
        val picks = mutableListOf<Pick>()
        for (v in order) {
            val n = minOf(v.owned, left)
            if (n > 0) { picks += Pick(v.cardId, v.finish, n); left -= n }
        }
        return picks
    }

    /** A tap on a version's tile: one more of it while you own more and copies are left to pick; otherwise back to none. */
    fun tap(picks: List<Pick>, versions: List<Version>, total: Int, cardId: String, finish: String): List<Pick> {
        val have = versions.firstOrNull { it.cardId == cardId && it.finish == finish }?.owned ?: 0
        val used = picks.sumOf { it.qty }
        val i = picks.indexOfFirst { it.cardId == cardId && it.finish == finish }
        if (i < 0) return if (used < total && have > 0) picks + Pick(cardId, finish, 1) else picks
        if (picks[i].qty < have && used < total) return picks.mapIndexed { j, p -> if (j == i) p.copy(qty = p.qty + 1) else p }
        return picks.filterIndexed { j, _ -> j != i }
    }

    /** Move ops that give the section the picked printings; copies not picked stay as they are. Lines that already are a
     *  picked version keep those copies; the rest move in list order to the picks in pick order. */
    fun matchOps(lines: List<Need>, picks: List<Pick>): List<Move> {
        val want = HashMap<String, Int>()
        for (p in picks) want.merge(p.key, p.qty, Int::plus)
        val keep = lines.map { l ->
            val k = "${l.cardId}|${l.finish}"
            minOf(l.qty, want[k] ?: 0).also { want[k] = (want[k] ?: 0) - it }
        }
        val targets = picks.map { it to (want[it.key] ?: 0) }.toMutableList()
        val ops = mutableListOf<Move>()
        lines.forEachIndexed { i, l ->
            var movable = l.qty - keep[i]
            for (t in targets.indices) {
                if (movable <= 0) break
                val n = minOf(movable, targets[t].second)
                if (n <= 0) continue
                ops += Move(l.cardId, l.finish, l.lang, targets[t].first.cardId, targets[t].first.finish, n)
                targets[t] = targets[t].first to targets[t].second - n
                movable -= n
            }
        }
        return ops
    }

    /** The versions you own of these printings (printing × finish, every condition and language), in [printingIds] order. */
    fun ownedVersions(printingIds: List<String>, items: Collection<CollectionItem>): List<Version> {
        val ids = printingIds.toSet()
        val n = items.filter { it.cardId in ids }.groupBy { "${it.cardId}|${it.finish}" }.mapValues { (_, v) -> v.sumOf { it.qty } }
        return printingIds.flatMap { id -> listOf("nonfoil", "foil", "etched").mapNotNull { f -> n["$id|$f"]?.takeIf { it > 0 }?.let { Version(id, f, it) } } }
    }

    /** Sections holding the card (not Considering) whose printings Auto would change; [lines] are the list's lines of it. */
    fun matchSections(lines: List<Need>, versions: List<Version>): List<String> =
        if (versions.isEmpty()) emptyList()
        else listOf("commander", "main", "side").filter { b ->
            val ls = lines.filter { it.board == b }
            ls.isNotEmpty() && matchOps(ls, autoMatch(ls, versions)).isNotEmpty()
        }

    /** "You own 3 in other printings": copies of the card in versions the list doesn't name. */
    fun matchDetail(lines: List<Need>, versions: List<Version>): String {
        val listed = lines.map { "${it.cardId}|${it.finish}" }.toSet()
        val other = versions.filter { "${it.cardId}|${it.finish}" !in listed }.sumOf { it.owned }
        return if (other > 0) "You own $other in other printings" else "Use the printings you own"
    }
}
