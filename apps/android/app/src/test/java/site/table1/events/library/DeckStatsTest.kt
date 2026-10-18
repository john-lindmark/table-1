package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/*
 * Deck and cube stats (contract/lists-2026-10-15.md, "Stats"). Every number comes from testdata/deck-stats/cases.json,
 * written by the Python reference there; iOS DeckStatsTests.swift and web deckStats.test.ts read the same file, so all
 * three clients give the same answers.
 */
class DeckStatsTest {
    private val cases: JsonObject = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/deck-stats") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

    private fun JsonElement.obj(k: String) = jsonObject[k]!!
    private fun JsonElement.ints() = jsonArray.map { it.jsonPrimitive.int }
    private fun JsonElement.longs() = jsonArray.map { it.jsonPrimitive.long }
    private fun JsonElement.str(k: String) = jsonObject[k]!!.jsonPrimitive.content

    private fun card(e: JsonElement) = StatCard(
        name = e.str("name"), qty = e.obj("qty").jsonPrimitive.int, board = e.str("board"), type = e.str("type"), cost = e.str("cost"),
        cmc = e.obj("cmc").jsonPrimitive.double, colors = e.str("colors"), legal = e.str("legal"), rarity = e.str("rarity"),
        usd = e.obj("usd").let { if (it is JsonNull) null else it.jsonPrimitive.double },
    )

    private fun issues(e: JsonElement) = e.jsonArray.map { it.str("name") to it.str("reason") }

    @Test fun randomNumbersMatchEveryPlatform() {
        val prng = cases.obj("prng")
        val r = StatsRng(prng.obj("seed").jsonPrimitive.long)
        assertEquals(prng.obj("first").longs(), prng.obj("first").longs().map { r.next() })
        val b = cases.obj("bounded")
        val br = StatsRng(b.obj("seed").jsonPrimitive.long)
        val bound = b.obj("bound").jsonPrimitive.int
        assertEquals(b.obj("first").ints(), b.obj("first").ints().map { br.int(bound) })
        for (s in cases.obj("shuffles").jsonArray) {
            assertEquals(s.obj("order").ints(), StatsRng(s.obj("seed").jsonPrimitive.long).shuffle(s.obj("n").jsonPrimitive.int))
        }
    }

    @Test fun pips() {
        for (p in cases.obj("pips").jsonArray) assertEquals(p.str("cost"), p.obj("pips").ints(), DeckStats.pips(p.str("cost")))
    }

    @Test fun hypergeometric() {
        for (h in cases.obj("hypergeometric").jsonArray) {
            fun i(k: String) = h.obj(k).jsonPrimitive.int
            assertEquals(h.obj("p").jsonPrimitive.double, DeckStats.hypergeometric(i("N"), i("K"), i("n"), i("k")), 1e-9)
        }
        for (t in cases.obj("drawsByTurn").jsonArray) {
            assertEquals(t.obj("draws").jsonPrimitive.int, DeckStats.drawsByTurn(t.obj("turn").jsonPrimitive.int, t.obj("onPlay").jsonPrimitive.boolean))
        }
    }

    private fun checkDeck(d: JsonElement) {
        val cards = d.obj("cards").jsonArray.map(::card)
        val e = d.obj("expected")
        val (creatures, other) = DeckStats.curve(cards)
        assertEquals(e.obj("curve").obj("creatures").ints(), creatures)
        assertEquals(e.obj("curve").obj("other").ints(), other)
        assertEquals(e.obj("types").ints(), DeckStats.typeCounts(DeckStats.deck(cards)))
        assertEquals(e.obj("averageWithLands").jsonPrimitive.double, DeckStats.averageMV(cards, true), 1e-9)
        assertEquals(e.obj("averageWithoutLands").jsonPrimitive.double, DeckStats.averageMV(cards, false), 1e-9)
        assertEquals(e.obj("pips").ints(), DeckStats.pipTotals(cards))
        val (src, unread) = DeckStats.sources(cards)
        assertEquals(e.obj("sources").obj("colors").ints(), src)
        assertEquals(e.obj("sources").obj("unread").jsonPrimitive.int, unread)
        val (total, unpriced) = DeckStats.price(cards)
        assertEquals(e.obj("price").obj("total").jsonPrimitive.double, total, 0.006)
        assertEquals(e.obj("price").obj("unpriced").jsonPrimitive.int, unpriced)
        assertEquals(issues(e.obj("legality")), DeckStats.legality(cards, d.str("format")))
        assertEquals(e.obj("librarySize").jsonPrimitive.int, DeckStats.librarySize(cards))
        (d.jsonObject["legalityIn"] as? JsonObject)?.forEach { (format, want) -> assertEquals(format, issues(want), DeckStats.legality(cards, format)) }
    }

    @Test fun deck() = checkDeck(cases.obj("deck"))
    @Test fun commanderDeck() = checkDeck(cases.obj("commander"))

    @Test fun londonMulligan() {
        val m = cases.obj("mulligan")
        val size = m.obj("size").jsonPrimitive.int
        var hand = SampleHand.deal(size, m.obj("seed").jsonPrimitive.long)
        for (step in m.obj("script").jsonArray) {
            val action = step.str("do")
            hand = when (action) {
                "mulligan" -> hand.mulligan()
                "bottom" -> hand.bottom(step.obj("index").jsonPrimitive.int)
                "draw" -> hand.draw()
                else -> hand
            }
            val want = step.obj("expect")
            assertEquals(action, want.obj("hand").ints(), hand.hand)
            assertEquals(action, want.obj("library").jsonPrimitive.int, hand.library.size)
            assertEquals(action, want.obj("toBottom").jsonPrimitive.int, hand.toBottom)
            assertEquals(action, want.obj("mulligans").jsonPrimitive.int, hand.mulligans)
        }
        // The library and hand always hold every card once.
        assertEquals((0 until size).toList(), (hand.hand + hand.library).sorted())
    }

    @Test fun mulliganRules() {
        var hand = SampleHand.deal(60, 1)
        assertTrue(hand.canMulligan)
        hand = hand.mulligan()
        assertFalse("keep first: bottom a card before drawing", hand.canDraw)
        assertEquals(7, hand.draw().hand.size)
        hand = hand.bottom(0)
        assertTrue(hand.canDraw)
        repeat(10) { hand = hand.mulligan() }
        assertEquals("down to one card at most", 6, hand.mulligans)
        val small = SampleHand.deal(5, 3)
        assertEquals(5, small.hand.size)
        assertFalse(small.canDraw)
    }

    @Test fun cube() {
        val cube = cases.obj("cube")
        val e = cube.obj("expected")
        val cards = cube.obj("cards").jsonArray.map(::card).filter { it.board == "main" }
        assertEquals(e.obj("size").jsonPrimitive.int, cards.sumOf { it.qty })
        assertEquals(e.obj("colorBalance").ints(), DeckStats.colorBalance(cards))
        assertEquals(e.obj("curveByColor").jsonArray.map { it.ints() }, DeckStats.curveByColor(cards))
        assertEquals(e.obj("types").ints(), DeckStats.typeCounts(cards))
        for (by in DeckStats.AsfanBy.entries) {
            val want = (e.obj("asfan").obj(by.key) as JsonArray).map { it.jsonPrimitive.double }
            val got = DeckStats.asfan(cards, 15, by)
            assertEquals(want.size, got.size)
            assertEquals(DeckStats.asfanLabels(by).size, got.size)
            want.zip(got).forEach { (w, g) -> assertEquals(by.key, w, g, 1e-9) }
        }
        val pack = e.obj("pack")
        assertEquals(pack.obj("cards").ints(),
            StatsRng(pack.obj("seed").jsonPrimitive.long).shuffle(DeckStats.expand(cards).size).take(pack.obj("size").jsonPrimitive.int))
    }

    /** Budget: every stat on a 540-card cube, as the Stats screen computes them on open. Same work as iOS and web. */
    @Test fun perfCube540() {
        val base = cases.obj("cube").obj("cards").jsonArray.map(::card).filter { it.board == "main" }
        val cube = List(540) { i -> base[i % base.size].let { it.copy(name = "${it.name} $i") } }
        fun all() {
            DeckStats.colorBalance(cube)
            DeckStats.curveByColor(cube)
            DeckStats.typeCounts(cube)
            for (by in DeckStats.AsfanBy.entries) DeckStats.asfan(cube, 15, by)
            DeckStats.curve(cube)
            DeckStats.pipTotals(cube)
            DeckStats.sources(cube)
            DeckStats.averageMV(cube, false)
            DeckStats.legality(cube, "vintage")
            StatsRng(5).shuffle(540)
        }
        repeat(5) { all() } // warm the JIT
        val runs = 20
        val t0 = System.nanoTime()
        repeat(runs) { all() }
        val ms = (System.nanoTime() - t0) / 1e6 / runs
        println("perf android cube stats 540 cards: ${"%.1f".format(ms)} ms (budget 10 ms)")
        assertTrue("cube stats took $ms ms", ms < 10)
    }
}
