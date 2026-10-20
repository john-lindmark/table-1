package site.table1.events.library

/* Printings, collapsed (contract/library-polish-2026-10-19.md § Printings, collapsed): a card with several printings
   (or finishes) is one row that opens into one row per printing and finish. Same rules as iOS `PrintingsDisclosure`
   and `LineGroup`. */

/** Which cards show each printing on its own row. Collapsed by default; Expand all opens every card, and a card's own
 *  chevron flips just that card. */
data class PrintingsDisclosure(val all: Boolean = false, val flipped: Set<String> = emptySet()) {
    fun open(id: String) = all != (id in flipped)
    fun toggle(id: String) = copy(flipped = if (id in flipped) flipped - id else flipped + id)
    fun setAll(on: Boolean) = PrintingsDisclosure(all = on)
}

/** One card's lines in one section (its printings and finishes), shown as one row until opened. First-seen order is
 *  kept; inside, the line with the most copies leads. */
data class LineGroup(val id: String, val lines: List<ListLine>) {
    val lead get() = lines[0]
    val qty get() = lines.sumOf { it.qty }
    val key get() = lead.oracleId ?: lead.cardId

    companion object {
        fun of(lines: List<ListLine>): List<LineGroup> {
            val by = LinkedHashMap<String, MutableList<ListLine>>()
            for (l in lines) by.getOrPut("${l.board}|${l.oracleId ?: l.cardId}") { mutableListOf() }.add(l)
            return by.map { (k, ls) -> LineGroup(k, ls.sortedWith(compareByDescending<ListLine> { it.qty }.thenBy { it.key })) }
        }
    }
}

/** All cards → Price: the most a single copy is worth; no price yet sorts first, as if most valuable. */
fun priceRank(price: Double?): Double = price ?: Double.POSITIVE_INFINITY
