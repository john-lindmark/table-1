package site.table1.events.library

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Searching inside screens, want printings, Move in and cube Replace. Same cases as iOS LibrarySearchTests and web librarySearch.test.ts. */
class LibrarySearchTest {
    private val cases = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/library-search") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

    private fun s(o: kotlinx.serialization.json.JsonElement, k: String) = o.jsonObject[k]!!.jsonPrimitive.content

    @Test fun sharedCardCases() {
        for (c in cases["cards"]!!.jsonArray) {
            assertEquals("${s(c, "query")} / ${s(c, "name")}", c.jsonObject["match"]!!.jsonPrimitive.boolean, CardSearch.matches(s(c, "query"), s(c, "name"), s(c, "type")))
        }
    }

    @Test fun sharedPrintingCases() {
        for (c in cases["printings"]!!.jsonArray) {
            assertEquals("${s(c, "query")} / ${s(c, "set")}", c.jsonObject["match"]!!.jsonPrimitive.boolean,
                CardSearch.matchesPrinting(s(c, "query"), s(c, "set"), s(c, "cn"), s(c, "releasedAt")))
        }
    }

    @Test fun sharedListCases() {
        for (c in cases["lists"]!!.jsonArray) {
            assertEquals("${s(c, "query")} / ${s(c, "name")}", c.jsonObject["match"]!!.jsonPrimitive.boolean, CardSearch.matchesList(s(c, "query"), s(c, "name"), s(c, "format")))
        }
        for (c in cases["listOrder"]!!.jsonArray) {
            val names = c.jsonObject["names"]!!.jsonArray.map { it.jsonPrimitive.content }
            assertEquals(s(c, "query"), c.jsonObject["want"]!!.jsonArray.map { it.jsonPrimitive.content }, CardSearch.order(s(c, "query"), names) { it })
        }
    }

    @Test fun repointMovesCountAndMax() {
        val w = Want("o", null, null, qty = 3, maxUsd = 5.0)
        val ops = repointWant(w, "p", "foil")!!
        assertEquals(WantOp("o", null, null, qty = 0), ops[0])
        assertEquals(WantOp("o", "p", "foil", delta = 3, setMax = true, maxUsd = 5.0), ops[1])
        assertNull(repointWant(w, null, "foil"))
        val back = repointWant(Want("o", "p", "foil", qty = 1), null, "foil")!!
        assertEquals(WantOp("o", null, null, delta = 1, setMax = true, maxUsd = null), back[1])
    }

    @Test fun moveInTakesUnsortedThenNonTradeThenTrade() {
        val trade = Binder("t", "A trade", forTrade = true, seq = 1)
        val box = Binder("b", "Box", forTrade = false, seq = 2)
        val a = CollectionItem("c1", "nonfoil", "NM", "en", 4, 1)
        val b = CollectionItem("c2", "foil", "NM", "en", 1, 2)
        assertEquals("c2", moveInSource(listOf(Place(a, trade, 2), Place(a, box, 1), Place(b, null, 1)), "x")?.first?.cardId)
        assertEquals("b", moveInSource(listOf(Place(a, trade, 2), Place(a, box, 1)), "x")?.second)
        assertEquals("t", moveInSource(listOf(Place(a, trade, 2), Place(a, box, 1)), "b")?.second)
        assertNull(moveInSource(listOf(Place(a, box, 1)), "b"))
    }

    @Test fun removeSearchOnlyOffersTheListsOwnCards() {
        data class L(val name: String, val type: String, val board: String)
        val lines = listOf(L("Lightning Bolt", "Instant", "main"), L("Lightning Helix", "Instant", "maybe"), L("Counterspell", "Instant", "main"))
        fun m(q: String) = CardSearch.matchingLines(lines, q, { it.name }, { it.type }, { it.board }, { "nonfoil" }).map { it.name }
        assertEquals(listOf("Lightning Bolt", "Lightning Helix"), m("light"))
        assertEquals(emptyList<String>(), m(""))
        assertEquals(emptyList<String>(), m("lightning strike"))
    }
}
