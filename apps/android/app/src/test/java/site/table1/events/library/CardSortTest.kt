package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Sort (contract/card-sort-2026-10-25.md) against the shared cases in testdata/card-sort/cases.json, the same file
 * iOS CardSortTests and web cardSort.test.ts read.
 */
class CardSortTest {
    private val cases = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/card-sort") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

    @Test fun sharedOrders() {
        val cards = cases["cards"]!!.jsonArray.map { it.jsonObject }
        fun key(o: kotlinx.serialization.json.JsonObject): SortKey {
            fun s(k: String) = o[k]!!.jsonPrimitive.content
            return SortKey(s("name"), o["cmc"]!!.jsonPrimitive.double, o["land"]!!.jsonPrimitive.boolean, s("released"), s("set"), s("cn"))
        }
        for (sort in listOf(CardSort.Name, CardSort.ManaValue, CardSort.Set)) {
            val want = cases["order"]!!.jsonObject[sort.wire]!!.jsonArray.map { it.jsonPrimitive.content }
            assertEquals(sort.wire, want, sort.apply(cards) { key(it) }.map { it["name"]!!.jsonPrimitive.content })
        }
    }

    @Test fun optionsAndDefaults() {
        val options = cases["options"]!!.jsonObject
        val defaults = cases["defaults"]!!.jsonObject
        val screens = listOf("deck" to CardSort.Screen.List, "cube" to CardSort.Screen.List, "shared" to CardSort.Screen.Shared,
            "binder" to CardSort.Screen.Binder, "allCards" to CardSort.Screen.AllCards)
        for ((name, s) in screens) {
            assertEquals(name, options[name]!!.jsonArray.map { it.jsonPrimitive.content }, CardSort.options(s).map { it.wire })
            assertEquals(name, defaults[name]!!.jsonPrimitive.content, CardSort.of(null, s).wire)
        }
        // A sort another screen offers falls back to this screen's own.
        assertEquals(CardSort.Name, CardSort.of("recent", CardSort.Screen.List))
        assertEquals(CardSort.Set, CardSort.of("set", CardSort.Screen.Binder))
    }

    @Test fun ownOrdersLeaveItemsAlone() {
        assertEquals(listOf("b", "a"), CardSort.Count.apply(listOf("b", "a")) { SortKey(it) })
        assertEquals(listOf("a", "b"), CardSort.Name.apply(listOf("b", "a")) { SortKey(it) })
    }

    @Test fun groupKeysCarryManaValue() {
        assertEquals(15.0, SortKey.of("Emrakul", GroupKeys.of("Legendary Creature — Eldrazi", "{15}", "", 15.0), null).cmc, 0.0)
        assertTrue(SortKey.of("Forest", GroupKeys.of("Basic Land — Forest", "", "", 0.0), null).land)
    }
}
