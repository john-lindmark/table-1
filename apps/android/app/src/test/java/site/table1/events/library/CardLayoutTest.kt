package site.table1.events.library

import org.junit.Assert.assertEquals
import org.junit.Test

class CardLayoutTest {
    @Test fun savedLayoutWins() {
        assertEquals(CardLayout.Stacks, CardLayout.parse("stacks", legacyGrid = true))
        assertEquals(CardLayout.List, CardLayout.parse("list", legacyGrid = true))
    }

    @Test fun oldGridFlagCarriesOver() {
        assertEquals(CardLayout.Grid, CardLayout.parse(null, legacyGrid = true))
        assertEquals(CardLayout.List, CardLayout.parse(null, legacyGrid = false))
        assertEquals(CardLayout.List, CardLayout.parse("bogus", legacyGrid = false))
    }

    @Test fun runsOfTenWhenNotBySet() {
        val s = runStacks((0 until 23).toList(), bySet = false, setOf = { "" }, keyPrefix = "0|")
        assertEquals(listOf(10, 10, 3), s.map { it.third.size })
        assertEquals(10, s[1].third.first())
        assertEquals(listOf<String?>(null, null, null), s.map { it.second })
        assertEquals(3, s.map { it.first }.toSet().size)
    }

    @Test fun oneStackPerSetRunWithUniqueKeys() {
        val s = runStacks(listOf("mh3", "mh3", "", "sld", "mh3"), bySet = true, setOf = { it })
        assertEquals(listOf("MH3" to 2, "Unknown set" to 1, "SLD" to 1, "MH3" to 1), s.map { it.second to it.third.size })
        assertEquals(4, s.map { it.first }.toSet().size)
    }

    @Test fun empty() {
        assertEquals(0, runStacks(emptyList<String>(), bySet = true, setOf = { it }).size)
    }
}
