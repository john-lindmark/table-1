package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Group by (contract/shared-lists-grouping-2026-10-20.md §4) against the shared cases in
 * testdata/card-grouping/cases.json, the same file iOS CardGroupingTests and web cardGrouping.test.ts read.
 */
class CardGroupingTest {
    private val cases = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/card-grouping") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

    @Test fun sharedCases() {
        val cards = cases["cards"]!!.jsonArray
        assertTrue(cards.size >= 10)
        for (c in cards) {
            val o = c.jsonObject
            fun s(k: String) = o[k]!!.jsonPrimitive.content
            val k = GroupKeys.of(s("typeLine"), s("manaCost"), s("colors"), o["cmc"]!!.jsonPrimitive.double)
            assertEquals(s("name"), s("type"), k[CardGrouping.Type])
            assertEquals(s("name"), s("color"), k[CardGrouping.Color])
            assertEquals(s("name"), s("manaValue"), k[CardGrouping.ManaValue])
        }
    }

    @Test fun order() {
        val order = cases["order"]!!.jsonObject
        for (g in listOf(CardGrouping.Type, CardGrouping.Color, CardGrouping.ManaValue)) {
            val want = order[g.wire]!!.jsonArray.map { it.jsonPrimitive.content }
            assertEquals(g.wire, want, g.order)
            assertEquals(g.wire, want, g.sorted(want.reversed()))
        }
        assertEquals(listOf("Lands", "Abc", "Zed"), CardGrouping.Type.sorted(listOf("Zed", "Lands", "Abc")))
    }

    @Test fun labelsAndOptions() {
        assertEquals("Mana value 3", CardGrouping.ManaValue.label("3"))
        assertEquals("Lands", CardGrouping.ManaValue.label("Lands"))
        assertEquals("Creatures", CardGrouping.Type.label("Creatures"))
        assertEquals(listOf(CardGrouping.Type, CardGrouping.Color, CardGrouping.ManaValue), CardGrouping.options(list = true))
        assertEquals(CardGrouping.entries.toList(), CardGrouping.options(list = false))
    }

    @Test fun sectionsKeepTheScreensOrder() {
        val k = { t: String -> GroupKeys.of(t, "", "", 0.0) }
        assertEquals(
            listOf("Creatures" to listOf("Creature", "Creature — Elf"), "Sorceries" to listOf("Sorcery"), "Lands" to listOf("Basic Land")),
            groupSections(listOf("Sorcery", "Creature", "Basic Land", "Creature — Elf"), CardGrouping.Type, k),
        )
        assertEquals(listOf("" to listOf("a", "b")), groupSections(listOf("a", "b"), CardGrouping.None, k))
    }
}
