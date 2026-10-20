package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Advanced search and the Library polish rules (contract/library-polish-2026-10-19.md). Queries and form fields come from
 * testdata/card-query/cases.json, shared with iOS (Table1Tests/CardQueryTests.swift) and the web (cardQuery.test.ts).
 */
class CardQueryTest {
    private val cases: JsonObject = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/card-query") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

    private fun JsonElement.str(k: String) = jsonObject[k]!!.jsonPrimitive.content

    private val catalog: List<Pair<CatalogOracle, List<CatalogPrinting>>> = cases["cards"]!!.jsonArray.mapIndexed { i, c ->
        val printings = c.jsonObject["printings"]!!.jsonArray
        val o = CatalogOracle(i, "o$i", c.str("name"), CardName.norm(c.str("name")), c.str("type"), c.str("cost"), printings.size,
            legal = c.str("legal"), cmc = c.jsonObject["cmc"]!!.jsonPrimitive.double, colors = c.str("colors"), produced = c.str("produced"))
        o to printings.mapIndexed { j, p ->
            CatalogPrinting("p$i-$j", i, j, p.str("set"), p.str("cn"), p.str("lang"), p.str("rarity"), p.str("finishes"), p.str("released"),
                "", 1, "", original = j == 0)
        }
    }

    @Test
    fun queries() {
        for (q in cases["queries"]!!.jsonArray) {
            val text = q.str("q")
            assertEquals("syntax: $text", q.jsonObject["syntax"]!!.jsonPrimitive.boolean, CardQuery.hasSyntax(text))
            val local = q.jsonObject["local"]?.jsonPrimitive?.boolean ?: continue
            val node = CardQuery.parse(text)
            assertEquals("local: $text", local, node?.let(CardQuery::isLocal) ?: false)
            if (!local || node == null) continue
            val want = q.jsonObject["names"]!!.jsonArray.map { it.jsonPrimitive.content }.sorted()
            val got = catalog.filter { (o, ps) ->
                if (CardQuery.usesPrinting(node)) ps.any { CardQuery.matches(node, o, it) } else CardQuery.matches(node, o, null)
            }.map { it.first.name }.sorted()
            assertEquals(text, want, got)
        }
    }

    @Test
    fun advancedFields() {
        for (a in cases["advanced"]!!.jsonArray) {
            val f = a.jsonObject["fields"]!!.jsonObject.mapValues { it.value.jsonPrimitive.content }
            val fields = AdvancedSearchFields(
                name = f["name"] ?: "", text = f["text"] ?: "", type = f["type"] ?: "", colors = (f["colors"] ?: "").toSet(),
                colorMode = AdvancedSearchFields.ColorMode.of(f["colorMode"] ?: ""), mvOp = f["mvOp"] ?: "=", mv = f["mv"] ?: "",
                rarities = (f["rarities"] ?: "").toSet(), set = f["set"] ?: "", format = f["format"] ?: "",
            )
            assertEquals("$f", a.str("query"), fields.query)
            // What the form writes always runs locally unless it searches card text.
            if (fields.text.isEmpty()) assertEquals(fields.query, true, CardQuery.parse(fields.query)?.let(CardQuery::isLocal))
        }
    }

    @Test
    fun oldestPrintingFirst() {
        fun p(id: String, released: String, ord: Int) = CatalogPrinting(id, 0, ord, "x", "1", "en", "c", "n", released, "", 1, "")
        // Pack order is newest first; same-day printings keep the older pack position first.
        val sorted = listOf(p("new", "2024-01-01", 0), p("old", "1993-08-05", 3), p("mid-b", "2010-07-16", 1), p("mid-a", "2010-07-16", 2))
            .sortedWith(CatalogPrinting.oldestFirst).map { it.cardId }
        assertEquals(listOf("old", "mid-a", "mid-b", "new"), sorted)
    }

    @Test
    fun printingsDisclosure() {
        var d = PrintingsDisclosure()
        assertFalse("collapsed by default", d.open("a"))
        d = d.toggle("a")
        assertTrue(d.open("a"))
        d = d.setAll(true)
        assertTrue(d.open("a") && d.open("b"))
        d = d.toggle("b")
        assertFalse("a card can close while every other one is open", d.open("b"))
        d = d.setAll(false)
        assertFalse(d.open("a") || d.open("b"))
    }

    @Test
    fun lineGroupsOneRowPerCardAndSection() {
        fun line(card: String, oracle: String, board: String, qty: Int, finish: String = "nonfoil") =
            ListLine(card, null, oracle, oracle, "g", board, qty, finish = finish)
        val groups = LineGroup.of(listOf(line("b1", "Bolt", "main", 1), line("b2", "Bolt", "main", 3), line("b1", "Bolt", "main", 1, "foil"),
            line("b1", "Bolt", "side", 2), line("o1", "Opt", "main", 4)))
        assertEquals(listOf("main|Bolt", "side|Bolt", "main|Opt"), groups.map { it.id })
        assertEquals(5, groups[0].qty)
        assertEquals("the line with the most copies leads", "b2", groups[0].lead.cardId)
        assertEquals(3, groups[0].lines.size)
    }

    @Test
    fun unpricedFirstInPriceSort() {
        val prices = listOf(2.0, null, 10.0)
        assertEquals(listOf(1, 2, 0), prices.indices.sortedByDescending { priceRank(prices[it]) })
    }

    @Test
    fun heroScopes() {
        assertEquals(HeroScope.Collection, HeroScope.of(null))
        assertEquals(HeroScope.InList("l1"), HeroScope.of(CardContext.InList("l1")))
        assertEquals(HeroScope.InBinder("b1"), HeroScope.of(CardContext.InBinder("b1")))
        assertNull("Unsorted has no heroes", HeroScope.of(CardContext.InBinder(UNSORTED)))
        assertEquals("list:l1", HeroScope.InList("L1").key)
        assertEquals(listOf("a", "b"), HeroesStore.toggled(listOf("a"), "b"))
        assertEquals(listOf("b"), HeroesStore.toggled(listOf("a", "b"), "a"))
        assertNull(HeroesStore.toggled((0 until HeroesStore.LIMIT).map { "h$it" }, "x"))
    }
}
