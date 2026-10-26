package site.table1.events.insights

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/*
 * Insights packs (contract/insights-2026-10-24.md § Packs) as the server builds them: testdata/insights holds constructed
 * packs built from real MTGO pages and a Limited pack from 17Lands data (tools/insights/).
 */
class InsightsPackTest {
    private val dir = generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/insights") }.first { it.isDirectory }
    private val json = Json { ignoreUnknownKeys = true }

    @Test fun constructedPacksDecode() {
        for (f in listOf("standard", "pioneer", "modern", "pauper")) {
            val p = json.decodeFromString<ConstructedPack>(File(dir, "constructed-$f.json").readText())
            assertEquals(f, p.format)
            assertEquals(0, p.archetypes.first().id)
            for (t in listOf("big", "all")) {
                val v = p.tiers[t]!!
                assertEquals(setOf("7", "14", "30", "90"), v.windows.keys)
                assertTrue(v.series.lines.all { it.v.size == v.series.days })
                v.windows["30"]!!.share.forEach { s -> assertTrue(p.archetypes.any { it.id == s.a }) }
            }
        }
    }

    @Test fun names() {
        val p = json.decodeFromString<ConstructedPack>(File(dir, "constructed-modern.json").readText())
        assertEquals("Other", p.name(0))
        assertEquals("Other", p.name(-9))
    }

    @Test fun matchupCellsReadBothWays() {
        val m = Matchups(listOf(1, 2), listOf(listOf(1, 2, 31, 22, 1)))
        assertEquals(Triple(31, 22, 1), m.cell(1, 2))
        assertEquals(Triple(22, 31, 1), m.cell(2, 1))
        assertNull(m.cell(1, 3))
    }

    @Test fun banStudyUsesTheLongestEndedWindow() {
        val s = listOf(AShare(1, 0.2))
        assertEquals(30, BanStudy(1, "2026-05-18", s, mapOf("14" to s, "30" to s), emptyList(), emptyList(), emptyList()).afterWindow?.first)
        assertNull(BanStudy(1, "2026-05-18", s, emptyMap(), emptyList(), emptyList(), emptyList()).afterWindow)
    }

    @Test fun sourcesCredit() {
        assertEquals("Results from Magic Online", Insights.sourcesCredit(listOf("mtgo")).first)
        assertEquals("Results from Magic Online and TopDeck.gg" to "https://topdeck.gg", Insights.sourcesCredit(listOf("mtgo", "topdeck")))
        assertEquals("Results from TopDeck.gg" to "https://topdeck.gg", Insights.sourcesCredit(listOf("topdeck")))
        assertEquals(listOf("standard", "pioneer", "modern", "pauper", "canlander"), Insights.formats.map { it.first })
    }

    @Test fun changeWords() {
        assertEquals("Unbanned: A, B, C and others", Change(1, "2026-05-18", "unban", listOf("A", "B", "C", "D")).words)
        assertEquals("Released: Reality Fracture", Change(2, "2026-10-02", "set_release", emptyList(), "fra", "Reality Fracture").words)
    }

    @Test fun limitedPackDecodes() {
        val p = json.decodeFromString<LimitedPack>(File(dir, "limited-FRA.json").readText())
        assertEquals("17Lands", p.credit.name)
        val v = p.events["PremierDraft"]!!.groups["all"]!!
        assertTrue(v.games > 100_000)
        assertTrue(v.cards.any { it.gih != null && it.c != null })
        assertTrue(v.cards.any { it.ata != null })
        assertTrue(v.pairs.any { it.p == "3C" })
        assertTrue("deck colours carry their splashes", v.colors.any { it.s.isNotEmpty() })
    }

    @Test fun deckColourNames() {
        assertEquals("Dimir UB", Insights.colorsName("UB", ""))
        assertEquals("Dimir UB + r", Insights.colorsName("UB", "R"))
        assertEquals("Esper WUB", Insights.colorsName("WUB", ""))
        assertEquals("Naya WRG + u", Insights.colorsName("WRG", "U"))
        assertEquals("Four-colour WUBR", Insights.colorsName("WUBR", ""))
    }
}
