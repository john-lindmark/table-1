package site.table1.events.library

/* Card detail's rules (contract/card-detail-2026-10-23.md): the screen is opened in a scope (the collection, a deck or
   cube, a binder, or search), shows that scope's versions of the card, and a pick in the attribute row changes the
   copies in view. Same rules as iOS CardDetail.swift and web lib/cardDetail.ts, against testdata/card-detail/cases.json. */

/** One thing the scope counts: owned copies are printing × finish × condition × language; a deck or cube line is
 *  printing × section × finish (its condition and language are unused). */
data class CardVersion(
    val cardId: String, val finish: String, val condition: String = "NM", val lang: String = "en",
    /** List scope: the line's section. */
    val board: String? = null,
    val qty: Int = 0,
) {
    val itemKey get() = itemKey(cardId, finish, condition, lang)
    val id get() = board?.let { "$cardId|$it|$finish|$lang" } ?: itemKey

    companion object {
        fun of(item: CollectionItem, qty: Int = item.qty) = CardVersion(item.cardId, item.finish, item.condition, item.lang, qty = qty)
        fun of(e: ListEntry) = CardVersion(e.cardId, e.finish, condition = e.cond, lang = e.lang, board = e.board, qty = e.qty)
    }
}

enum class CardAttribute(val wire: String) { Set("set"), Language("language"), Condition("condition"), Finish("finish"), Section("section") }

object CardDetailRules {
    private val FINISHES = site.table1.events.library.Finish.entries.map { it.wire }

    /** The value every version shares, null when they differ (shown as MIX). Empty → null. */
    fun <T> shared(versions: List<CardVersion>, value: (CardVersion) -> T): T? {
        val first = versions.firstOrNull()?.let(value) ?: return null
        return if (versions.all { value(it) == first }) first else null
    }

    /** The version the stepper and the bar's price act on when none is selected: the one held most of, the first on a tie. */
    fun main(versions: List<CardVersion>): CardVersion? = versions.fold<CardVersion, CardVersion?>(null) { best, v -> if (best == null || v.qty > best.qty) v else best }

    /** Versions in grid order: printings earliest first, then finish, section, condition, language. */
    fun ordered(versions: List<CardVersion>, printings: List<CatalogPrinting>): List<CardVersion> {
        val rank = printings.sortedWith(CatalogPrinting.oldestFirst).withIndex().associate { it.value.cardId to it.index }
        return versions.filter { it.qty > 0 }.sortedWith(
            compareBy<CardVersion> { rank[it.cardId] ?: Int.MAX_VALUE }
                .thenBy { FINISHES.indexOf(it.finish) }
                .thenBy { it.board?.let { b -> CardList.BOARD_ORDER.indexOf(b) } ?: 0 }
                .thenBy { Conditions.all.indexOf(it.condition) }
                .thenBy { it.lang },
        )
    }

    /** The version a pick turns `v` into. Set: the new printing, in the same finish if it has it (else its first), in its
     *  own language when it isn't English (else the copy keeps its language). The others change just that field. */
    fun repoint(v: CardVersion, attribute: CardAttribute, value: String, printing: CatalogPrinting?): CardVersion = when (attribute) {
        CardAttribute.Set -> printing?.let { p ->
            val finishes = p.finishList.map { it.wire }
            v.copy(cardId = p.cardId, finish = if (v.finish in finishes) v.finish else finishes.firstOrNull() ?: v.finish,
                lang = if (p.lang != "en") p.lang else v.lang)
        } ?: v
        CardAttribute.Language -> v.copy(lang = value)
        CardAttribute.Condition -> v.copy(condition = value)
        CardAttribute.Finish -> v.copy(finish = value)
        CardAttribute.Section -> v.copy(board = value)
    }

    /** The version a new copy starts as: the card's original printing (else the earliest), its first finish, and the
     *  condition and language picked for adds. */
    fun fresh(printings: List<CatalogPrinting>, condition: String, lang: String, board: String? = null): CardVersion? {
        val p = printings.firstOrNull { it.original } ?: printings.sortedWith(CatalogPrinting.oldestFirst).firstOrNull() ?: return null
        return CardVersion(p.cardId, p.finishList.firstOrNull()?.wire ?: "nonfoil", condition, Languages.forNew(p.lang, lang), board)
    }

    /** Moves `qty` of an item's copies to another version, each copy staying where it is: from `from` only when given (a
     *  binder id or [UNSORTED]), else Unsorted first, then the binders in the order given. Null when nothing would change
     *  or there aren't that many copies in those places. */
    fun ops(item: CollectionItem, places: List<Pair<String, Int>>, to: CardVersion, qty: Int, from: String? = null): List<CollectionOp>? {
        if (qty <= 0 || qty > item.qty || to.itemKey == item.key) return null
        val order = if (from != null) places.filter { it.first == from }
            else places.filter { it.first == UNSORTED } + places.filter { it.first != UNSORTED }
        var left = qty
        val out = mutableListOf<CollectionOp>()
        for ((place, have) in order) {
            if (left <= 0) break
            val n = minOf(left, have)
            if (n <= 0) continue
            val binderId = place.takeIf { it != UNSORTED }
            out += CollectionOp(item.cardId, item.finish, item.condition, item.lang, delta = -n, binderId = binderId)
            out += CollectionOp(to.cardId, to.finish, to.condition, to.lang, delta = n, binderId = binderId)
            left -= n
        }
        return if (left == 0) out else null
    }

    /** One copy more or less of a version, into or out of a binder (null: the collection's own rule, Unsorted first). */
    fun step(v: CardVersion, delta: Int, binderId: String?) =
        CollectionOp(v.cardId, v.finish, v.condition, v.lang, delta = delta, binderId = binderId?.takeIf { it != UNSORTED })

    /** A new edition (long press on +): a copy of the version it was made from, one copy, not yet written. It stays
     *  dimmed until a pick makes it a version the scope doesn't hold. */
    fun newEdition(from: CardVersion) = from.copy(qty = 1)

    /** Whether a new edition is different from every version in view, so it can be written. */
    fun isNew(edition: CardVersion, among: List<CardVersion>) = among.none { it.qty > 0 && it.id == edition.id }

    /** What Add to (the bar's +) adds: one copy of the version on screen, or every copy in view (just the selected
     *  version's when one is selected), each version with its count. */
    fun addLines(inView: List<CardVersion>, current: CardVersion, all: Boolean): List<CardVersion> {
        val held = inView.filter { it.qty > 0 }
        return if (all && held.isNotEmpty()) held else listOf(current.copy(qty = 1))
    }

    /** Whether the Finish cell shows: some printing in view comes in more than one finish, or the versions differ. */
    fun showsFinish(versions: List<CardVersion>, printings: Map<String, CatalogPrinting>): Boolean =
        shared(versions) { it.finish } == null || versions.any { (printings[it.cardId]?.finishList?.size ?: 1) > 1 }
}
