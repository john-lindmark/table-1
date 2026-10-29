package site.table1.events.insights

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
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

    @Test fun exampleFinish() {
        val main60 = listOf(DeckLine("Lightning Bolt", 4), DeckLine("Mountain", 56))
        fun f(tier: String, rank: Int?, on: String, main: List<DeckLine> = main60) = ArchetypePage.Finish("E", on, 64, tier, rank, null, main, emptyList())
        assertEquals(2, Insights.exampleFinish(listOf(f("regular", 1, "2026-10-20"), f("large", 5, "2026-10-01"), f("large", 2, "2026-09-20"))))
        assertEquals(1, Insights.exampleFinish(listOf(f("major", 3, "2026-10-01"), f("major", 3, "2026-10-10"))))
        assertEquals(1, Insights.exampleFinish(listOf(f("major", 1, "2026-10-01", listOf(DeckLine("Lightning Bolt", 4))), f("small", null, "2026-10-02"))))
        assertNull(Insights.exampleFinish(emptyList()))
        assertEquals(listOf("1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "101st"), listOf(1, 2, 3, 4, 11, 12, 13, 21, 22, 101).map(Insights::place))
    }

    @Test fun hiddenPickers() {
        val all = listOf("standard", "pioneer", "modern", "pauper", "canlander")
        assertEquals(listOf("standard", "modern", "pauper"), Insights.visibleKeys(all, listOf("pioneer", "canlander")))
        assertEquals(all, Insights.visibleKeys(all, all))
        assertTrue(Insights.canHide(all, listOf("pioneer"), "modern"))
        assertEquals(false, Insights.canHide(listOf("modern", "pauper"), listOf("pauper"), "modern"))
        assertEquals(false, Insights.canHide(listOf("modern"), emptyList(), "modern"))
    }

    @Test fun pointsChanges() {
        val c = Change(9, "2026-10-26", "points", listOf("Mana Crypt"), note = "Mana Crypt 3 → 4, Gush 0 → 1")
        assertEquals("Points: Mana Crypt 3 → 4, Gush 0 → 1", c.words)
        assertTrue(c.isBan)
        assertEquals("Points changes", Insights.bansTitle(listOf("points", "points")))
        assertEquals("Bans and unbans", Insights.bansTitle(listOf("ban", "unban")))
    }

    @Test fun sourcesCredit() {
        assertEquals("Results from Magic Online", Insights.sourcesCredit(listOf("mtgo")).first)
        assertEquals("Results from Magic Online and TopDeck.gg" to "https://topdeck.gg", Insights.sourcesCredit(listOf("mtgo", "topdeck")))
        assertEquals("Results from TopDeck.gg" to "https://topdeck.gg", Insights.sourcesCredit(listOf("topdeck")))
        assertEquals("Results from Magic Online, TopDeck.gg and Melee" to "https://topdeck.gg", Insights.sourcesCredit(listOf("melee", "topdeck", "mtgo")))
        assertEquals("Results from Magic Online and Melee" to "https://www.mtgo.com/decklists", Insights.sourcesCredit(listOf("mtgo", "melee")))
        assertEquals("Results from Melee" to "https://melee.gg", Insights.sourcesCredit(listOf("melee")))
        assertEquals("Results from Magic Online", Insights.sourcesCredit(emptyList()).first)
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

    /** The format page's rows (testdata/insights/parts.json, also web insights.test.ts and iOS InsightsPackTests). */
    @Test fun formatParts() {
        val cases = Json.parseToJsonElement(File(dir, "parts.json").readText()).jsonObject["cases"]!!.jsonArray.map { it.jsonObject }
        for (k in cases) {
            val f = k["format"]!!.jsonPrimitive.content
            val tier = k["tier"]!!.jsonPrimitive.content
            val days = k["days"]!!.jsonPrimitive.int
            val p = json.decodeFromString<ConstructedPack>(File(dir, "constructed-$f.json").readText())
            val want = k["parts"]!!.jsonArray.map { it.jsonObject }.map {
                Insights.Part(it["key"]!!.jsonPrimitive.content, it["title"]!!.jsonPrimitive.content, it["detail"]!!.jsonPrimitive.content)
            }
            assertEquals("$f $tier $days", want, Insights.formatParts(p, tier, days))
        }
    }
}
