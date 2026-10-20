package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.ceil

/**
 * Deck image layout (contract/deck-image-2026-10-20.md), the same checks as iOS DeckImageTests and web
 * deckImage.test.ts; card sizes against testdata/deck-image/cases.json.
 */
class DeckImageTest {
    private val cases = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/deck-image") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

    private fun line(name: String, board: String, qty: Int, type: String, mv: Double, card: String = name): ListLine {
        val keys = GroupKeys.of(type, "", "R", mv)
        return ListLine(card, null, name, name, keys.type, board, qty, keys = keys)
    }

    private val lines = listOf(
        line("Mountain", "main", 10, "Basic Land — Mountain", 0.0),
        line("Lightning Bolt", "main", 2, "Instant", 1.0, "bolt-a"),
        line("Lightning Bolt", "main", 2, "Instant", 1.0, "bolt-b"),
        line("Goblin Guide", "main", 4, "Creature — Goblin", 1.0),
        line("Fury", "main", 1, "Creature — Elemental", 5.0),
        line("Atraxa", "commander", 1, "Legendary Creature — Phyrexian", 7.0),
        line("Blood Moon", "side", 3, "Enchantment", 3.0),
        line("Maybe card", "maybe", 1, "Sorcery", 2.0),
    )

    @Test fun planOrdersMergesAndLeavesOutConsidering() {
        val p = DeckImage.plan(lines, CardGrouping.Type)
        assertEquals(listOf("Commander", "Creatures", "Instants", "Lands"), p.main.map { it.title })
        assertEquals(listOf("Goblin Guide", "Fury"), p.main[1].cards.map { it.name })
        assertEquals(listOf(4), p.main[2].cards.map { it.qty })
        assertEquals(20, p.mainCount) // the commander counts toward the deck
        assertEquals(listOf("Blood Moon"), p.side.map { it.name })
        assertFalse(p.ordered.any { it.name == "Maybe card" })
        assertEquals(listOf("Commander", "Mana value 1", "Mana value 5", "Lands"), DeckImage.plan(lines, CardGrouping.ManaValue).main.map { it.title })
        assertEquals(listOf("Commander", "Creatures", "Instants", "Lands"), DeckImage.plan(lines, CardGrouping.None).main.map { it.title })
    }

    @Test fun fitSharedCases() {
        val fits = cases["fit"]!!.jsonArray
        assertTrue(fits.size >= 9)
        for (c in fits) {
            val o = c.jsonObject
            fun i(k: String) = o[k]!!.jsonPrimitive.int
            val f = DeckImage.fit(i("main"), i("side"))
            val name = "${i("main")} + ${i("side")}"
            assertEquals(name, i("cols"), f.cols)
            assertEquals(name, i("cw").toFloat(), f.cw, 0f)
            assertEquals(name, i("height").toFloat(), f.height, 0f)
            assertEquals(name, o["step"]!!.jsonPrimitive.double, f.step.toDouble(), 0.001)
            val rows = ceil(i("main") / f.cols.toDouble()).toFloat()
            assertTrue(name, DeckImage.HEADER + rows * f.cw * DeckImage.ASPECT + (rows - 1) * DeckImage.ROW_GAP <= f.height)
        }
    }

    @Test fun columnsSplitTallGroupsAndFileName() {
        val pile = DeckImage.Pile("Lands", (0 until 12).map { DeckImage.Card("$it", "L$it", 1, null) })
        val cols = DeckImage.columns(listOf(pile), 9)
        assertEquals(listOf(9, 3), cols.map { it.second.size })
        assertEquals(listOf("Lands · 12", null), cols.map { it.first })
        assertEquals("Izzet Tempo.jpg", DeckImage.fileName("Izzet: Tempo!"))
    }
}
