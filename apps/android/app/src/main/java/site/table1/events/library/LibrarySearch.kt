package site.table1.events.library

/* Searching inside a screen (a cube, a binder, all binders, wants) and among one card's printings, plus the small
   rules behind want printings, binder Move in and cube Replace (contract/library-search-2026-10-18.md). Same rules
   as iOS and web; search cases in testdata/library-search/cases.json. */
object CardSearch {
    /**
     * Every word of the query is in the card's name or its type line (normalized like card names, so "jace" finds
     * "Jace, the Mind Sculptor" and "legendary creature" finds legends). An empty query matches everything.
     */
    fun matches(query: String, name: String, type: String): Boolean {
        val words = CardName.norm(query).split(" ").filter { it.isNotEmpty() }
        if (words.isEmpty()) return true
        val hay = CardName.norm(name) + " | " + CardName.norm(type)
        return words.all { hay.contains(it) }
    }

    /** One printing by set code, collector number or year: every word starts one of them ("mh2", "mh2 130", "2021"). */
    fun matchesPrinting(query: String, set: String, cn: String, releasedAt: String): Boolean {
        val words = query.lowercase().split(' ', '#').filter { it.isNotEmpty() }
        val hay = listOf(set.lowercase(), cn.lowercase(), releasedAt.take(4))
        return words.all { w -> hay.any { it.startsWith(w) } }
    }

    /** The list's own lines whose card matches a search, by name: what Remove or replace offers. Empty query: none. */
    fun <T> matchingLines(lines: List<T>, query: String, name: (T) -> String, type: (T) -> String, board: (T) -> String, finish: (T) -> String): List<T> {
        if (CardName.norm(query).isEmpty()) return emptyList()
        val order = listOf("commander", "main", "side", "maybe")
        return lines.filter { matches(query, name(it), type(it)) }
            .sortedWith(compareBy<T> { name(it) }.thenBy { order.indexOf(board(it)) }.thenBy { finish(it) })
    }
}

/**
 * Ops that point a want at another printing (`cardId` null = any printing; `finish` only with a printing): the old
 * want comes off and its copies are added to the new one (merging into a want already there), keeping its max price.
 * Null when it already points there.
 */
fun repointWant(w: Want, cardId: String?, finish: String?): List<WantOp>? {
    val f = if (cardId == null) null else finish
    if (w.cardId == cardId && w.finish == f) return null
    return listOf(WantOp(w.oracleId, w.cardId, w.finish, qty = 0),
                  WantOp(w.oracleId, cardId, f, delta = w.qty, setMax = true, maxUsd = w.maxUsd))
}

data class Place(val item: CollectionItem, val from: Binder?, val qty: Int)

/**
 * Where Move in (adding a card you own to a binder, `target` null = Unsorted) takes one copy from: Unsorted first,
 * then binders not for trade, then for-trade binders, each by name; in one place, the item with the most copies
 * there. Never the target itself. Null when every copy is already there.
 */
fun moveInSource(places: List<Place>, target: String?): Pair<CollectionItem, String?>? =
    places.filter { it.qty > 0 && it.from?.id != target }
        .minWithOrNull(compareBy<Place>({ if (it.from == null) 0 else if (it.from.forTrade) 2 else 1 }, { it.from?.name?.lowercase() ?: "" },
                                        { -it.qty }, { it.item.key }))
        ?.let { it.item to it.from?.id }

/** Every place an item's copies are, Unsorted as a null binder. */
fun BindersState.places(items: List<CollectionItem>): List<Place> = items.flatMap { it ->
    val (held, u) = placement(it)
    held.map { h -> Place(it, h.first, h.second) } + (if (u > 0) listOf(Place(it, null, u)) else emptyList())
}
