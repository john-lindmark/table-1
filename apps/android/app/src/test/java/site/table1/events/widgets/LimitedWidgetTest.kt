package site.table1.events.widgets

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import site.table1.events.data.WebLink
import site.table1.events.insights.LimitedCards
import site.table1.events.insights.LimitedPack
import java.io.File

/** The Limited cards widget (contract/widgets-2026-10-22.md § Limited cards widget): the app's Top cards order and
 *  numbers, the caption, and the tap that opens the set in Insights. iOS LimitedWidgetTests checks the same. */
class LimitedWidgetTest {
    private val raw = File(generateSequence(File("").absoluteFile) { it.parentFile }.first { File(it, "testdata").isDirectory },
        "testdata/insights/limited-FRA.json").readText()

    @Test fun rowsAreTheAppsTopCards() {
        val pack = LimitedPacks.decode(raw)!!
        val app = Json { ignoreUnknownKeys = true }.decodeFromString<LimitedPack>(raw)
        val v = app.events["PremierDraft"]!!.groups["all"]!!
        for (picks in listOf(LimitedPicks("FRA"), LimitedPicks("FRA", "ata", listOf("common", "uncommon"), listOf("W", "U")),
                             LimitedPicks("FRA", "iwd", color = listOf("M")))) {
            val rows = LimitedWidgets.rows(pack, picks, 12)
            val want = LimitedCards.cards(v.cards, picks.sort, picks.rarity, picks.color).take(12)
            assertEquals(picks.toString(), want.map { it.n }, rows.map { it.name })
            assertEquals(picks.toString(), want.map { LimitedCards.value(it, picks.sort, v.wr).first }, rows.map { it.value })
            assertTrue(rows.isNotEmpty())
        }
        assertEquals("GIH WR", LimitedWidgets.caption(LimitedPicks("FRA")))
        assertEquals("ATA · C · U · WU", LimitedWidgets.caption(LimitedPicks("FRA", "ata", listOf("common", "uncommon"), listOf("U", "W"))))
    }

    @Test fun tapOpensTheSet() {
        val (link, src) = WebLink.parseApp(LimitedWidgets.link("FRA", "widget_limited"))!!
        assertEquals(WebLink.Insights("limited", null, null, emptyList(), "FRA"), link)
        assertEquals("widget_limited", src)
    }
}
