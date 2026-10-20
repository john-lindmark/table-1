package site.table1.events.library

import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/* Deck image (contract/deck-image-2026-10-20.md): which cards go on the picture, in what order, and how big they
   draw. The same rules and numbers as iOS DeckImage.swift and web lib/deckImage.ts (card sizes checked against
   testdata/deck-image/cases.json); DeckImageScreen.kt draws it. */

object DeckImage {
    enum class Layout(val wire: String) { Grid("grid"), Stacks("stacks") }

    /** One card on the image: every copy of an Oracle card in a section, shown as its most-held printing. */
    data class Card(val key: String, val name: String, val qty: Int, val printing: CatalogPrinting?, val finish: String = "nonfoil")

    data class Pile(val title: String, val cards: List<Card>) { val count get() = cards.sumOf { it.qty } }

    /** The main deck's groups (a deck's Commander first) and the sideboard's. Considering is left off. */
    data class Plan(val main: List<Pile>, val side: List<Card>) {
        val mainCount get() = main.sumOf { it.count }
        val sideCount get() = side.sumOf { it.qty }
        /** The cards layout's order: the groups in order, each by mana value then name. */
        val ordered get() = main.flatMap { it.cards }
    }

    /** Lines → the plan. Cards sort by mana value then name inside a group; None groups by type. */
    fun plan(lines: List<ListLine>, grouping: CardGrouping): Plan {
        val by = if (grouping == CardGrouping.None) CardGrouping.Type else grouping
        fun mv(l: ListLine) = if (l.keys.manaValue == "Lands") 99 else l.keys.manaValue.take(1).toIntOrNull() ?: 7
        fun cards(ls: List<ListLine>): List<Card> = ls.groupBy { it.oracleId ?: it.cardId }.map { (key, same) ->
            val lead = same.maxWith(compareBy<ListLine> { it.qty }.thenByDescending { it.cardId })
            Card(key, lead.name, same.sumOf { it.qty }, lead.printing, lead.finish) to mv(lead)
        }.sortedWith(compareBy({ it.second }, { it.first.name })).map { it.first }
        val main = mutableListOf<Pile>()
        val commander = lines.filter { it.board == "commander" }
        if (commander.isNotEmpty()) main += Pile("Commander", cards(commander))
        val deck = lines.filter { it.board == "main" }
        for (g in by.sorted(deck.map { it.keys[by] })) main += Pile(by.label(g), cards(deck.filter { it.keys[by] == g }))
        return Plan(main, cards(lines.filter { it.board == "side" }))
    }

    /** Stacks: a group taller than `max` cards continues in the next column (untitled). */
    fun columns(piles: List<Pile>, max: Int): List<Pair<String?, List<Card>>> = piles.flatMap { p ->
        p.cards.chunked(max).mapIndexed { i, c -> (if (i == 0) "${p.title} · ${p.count}" else null) to c }
    }

    // The cards layout's geometry, in points (drawn at 2×).
    const val WIDTH = 1200f
    const val PAD = 40f
    const val HEADER = 132f
    const val GAP = 14f
    const val ROW_GAP = 22f
    const val SIDE_GUTTER = 56f
    const val ASPECT = 1.396f
    const val MIN_WIDTH = 72f

    data class Fit(val cols: Int, val cw: Float, val step: Float, val height: Float)

    /** Cards grow as large as the 16:9 canvas allows (columns 2–16 tried; the sideboard column keeps cards at least 10%
     *  of a card apart); below MIN_WIDTH the canvas grows taller instead. */
    fun fit(main: Int, side: Int): Fit {
        val height = WIDTH * 9 / 16
        val room = height - HEADER - PAD
        val flag = if (side > 0) 1 else 0
        val sideMax = if (side > 1) room / ((1 + 0.1 * (side - 1)) * ASPECT) else Double.POSITIVE_INFINITY
        var bestCols = 1
        var bestCw = 0.0
        for (cols in 2..16) {
            val r = ceil(max(main, 1) / cols.toDouble())
            val byWidth = (WIDTH - 2 * PAD - flag * SIDE_GUTTER - (cols - 1) * GAP).toDouble() / (cols + flag)
            val byHeight = (room - (r - 1) * ROW_GAP) / (r * ASPECT)
            val cw = floor(minOf(byWidth, byHeight, sideMax))
            if (cw > bestCw) { bestCw = cw; bestCols = cols }
        }
        var cw = bestCw
        var cols = bestCols
        var total = height.toDouble()
        if (cw < MIN_WIDTH) {
            cw = MIN_WIDTH.toDouble()
            cols = max(1, floor((WIDTH - 2 * PAD - flag * (SIDE_GUTTER + cw) + GAP) / (cw + GAP)).toInt())
            val r = ceil(max(main, 1) / cols.toDouble())
            total = max(total, HEADER + PAD + r * cw * ASPECT + (r - 1) * ROW_GAP)
        }
        val ch = cw * ASPECT
        val step = if (side > 1) min(ch * 0.19, (total - HEADER - PAD - ch) / (side - 1)) else 0.0
        return Fit(cols, cw.toFloat(), max(step, 0.0).toFloat(), ceil(total).toFloat())
    }

    /** "Izzet Tempo.jpg", from the deck's name. */
    fun fileName(deck: String) = ListExport.fileName(deck, ListKind.Deck, ListExport.Format.Text).removeSuffix(".txt") + ".jpg"
}
