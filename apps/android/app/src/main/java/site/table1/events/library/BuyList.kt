package site.table1.events.library

import java.text.NumberFormat
import java.util.Locale
import kotlin.math.roundToInt

/* The Buy screen's rules (contract/buy-2026-11-06.md): which copies of a deck, cube, Wants or Missing go into a
   TCGplayer cart, what they cost, and the tcgplayer_cart calls that build it. Cases in testdata/buy/cases.json
   (BuyListTest), shared with iOS and web. */
object BuyList {
    /** One line offered for buying. [unit] is one copy's price in cents; [any] marks a want for any printing (sent by
     *  [oracleId], priced and drawn by [cardId]). */
    data class Line(
        val cardId: String, val oracleId: String? = null, val any: Boolean = false, val board: String,
        val finish: String = "nonfoil", val qty: Int, val unit: Int? = null, val basic: Boolean = false,
    )

    data class Options(
        val skipOwned: Boolean = true, val anyPrinting: Boolean = true, val exact: Boolean = false,
        val boards: Set<String> = setOf("commander", "main", "side"),
    )

    data class Row(val line: Line, val owned: Int) { val buy get() = line.qty - owned }

    data class Totals(
        val cards: Int = 0, val owned: Int = 0, val buy: Int = 0, val price: Int = 0, val ownedValue: Int = 0,
        val total: Int = 0, val unpriced: Int = 0,
    )

    data class Call(val products: Boolean, val items: List<TCGplayerCart.Item>)

    val BOARD_ORDER = listOf("commander", "main", "side", "maybe", "tokens")

    /** One row per line in a picked board with copies, in line order. Skip owned leaves basic lands out, then a line's
     *  own printing and finish cover it first and, with Any printing, the card's other copies, lines in order, each copy
     *  once. Without Skip owned nothing is owned. */
    fun rows(lines: List<Line>, h: Holdings, o: Options): List<Row> {
        val inc = lines.filter { it.board in o.boards && it.qty > 0 && !(o.skipOwned && it.basic) }
        if (!o.skipOwned) return inc.map { Row(it, 0) }
        val exact = HashMap(h.byPrinting)
        val spare = HashMap(h.byCard)
        val cov = IntArray(inc.size)
        inc.forEachIndexed { i, l ->
            val k = "${l.cardId}|${l.finish}"
            val c = minOf(l.qty, exact[k] ?: 0)
            exact[k] = (exact[k] ?: 0) - c
            val card = h.card(l.cardId)
            spare[card] = (spare[card] ?: 0) - c
            cov[i] = c
        }
        if (o.anyPrinting) inc.forEachIndexed { i, l ->
            val card = h.card(l.cardId)
            val c = minOf(l.qty - cov[i], maxOf(0, spare[card] ?: 0))
            spare[card] = (spare[card] ?: 0) - c
            cov[i] += c
        }
        return inc.mapIndexed { i, l -> Row(l, cov[i]) }
    }

    /** Money in cents: price over every row's copies, the owned copies at their line's price, the total bought. */
    fun totals(rows: List<Row>): Totals {
        var t = Totals()
        for (r in rows) {
            val u = r.line.unit
            t = t.copy(cards = t.cards + r.line.qty, owned = t.owned + r.owned, buy = t.buy + r.buy)
            t = if (u == null) t.copy(unpriced = t.unpriced + r.buy)
            else t.copy(price = t.price + r.line.qty * u, ownedValue = t.ownedValue + r.owned * u, total = t.total + r.buy * u)
        }
        return t
    }

    /** The tcgplayer_cart calls: tokens always to their product pages, everything else by Exact printings; copies
     *  summed per key in row order; one call when both agree, none when nothing's bought. */
    fun calls(rows: List<Row>, exact: Boolean): List<Call> {
        val groups = HashMap<Boolean, LinkedHashMap<String, TCGplayerCart.Item>>()
        for (r in rows) {
            if (r.buy <= 0) continue
            val products = if (r.line.board == "tokens") true else exact
            val any = r.line.any && r.line.oracleId != null
            val key = if (any) "o:${r.line.oracleId}" else "c:${r.line.cardId}"
            val g = groups.getOrPut(products) { LinkedHashMap() }
            val had = g[key]
            g[key] = if (had != null) had.copy(qty = had.qty + r.buy)
                else if (any) TCGplayerCart.Item(oracleId = r.line.oracleId, qty = r.buy) else TCGplayerCart.Item(cardId = r.line.cardId, qty = r.buy)
        }
        return listOf(exact, !exact).mapNotNull { p -> groups[p]?.let { Call(p, it.values.toList()) } }
    }

    /** Two calls' answers as one: Mass Entry parts in order, then every product page by name, set and number. */
    fun merge(answers: List<TCGplayerCartAnswer>): TCGplayerCartAnswer = TCGplayerCartAnswer(
        enabled = answers.all { it.enabled }, lines = answers.sumOf { it.lines }, unknown = answers.sumOf { it.unknown },
        urls = answers.flatMap { it.urls },
        products = answers.flatMap { it.products }.sortedWith(compareBy({ it.name }, { it.set }, { it.number })),
    )

    fun cents(usd: Double?): Int? = usd?.let { (it * 100).roundToInt() }

    /** "$1,441.95". */
    fun money(cents: Int): String = NumberFormat.getCurrencyInstance(Locale.US).format(cents / 100.0)

    // Options remembered per device and family (deck, cube, wants, missing).
    private val prefs get() = site.table1.events.T1App.instance.getSharedPreferences("library", android.content.Context.MODE_PRIVATE)

    fun stored(family: String): Options {
        val p = prefs
        fun b(o: String, d: Boolean) = if (p.contains("buy.$family.$o")) p.getBoolean("buy.$family.$o", d) else d
        return Options(
            skipOwned = b("skip", true), anyPrinting = b("any", true), exact = b("exact", family == "wants"),
            boards = p.getString("buy.$family.boards", null)?.let { s -> s.split(",").filter { it.isNotEmpty() }.toSet() } ?: setOf("commander", "main", "side"),
        )
    }

    fun storedTokens(family: String) = prefs.getBoolean("buy.$family.tokens", false)
    fun save(family: String, o: String, v: Boolean) = prefs.edit().putBoolean("buy.$family.$o", v).apply()
    fun saveBoards(family: String, boards: Set<String>) = prefs.edit().putString("buy.$family.boards", boards.sorted().joinToString(",")).apply()
}
