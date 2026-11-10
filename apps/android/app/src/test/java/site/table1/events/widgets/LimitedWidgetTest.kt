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
 *  numbers, the buttons, and the tap that opens the set in Insights. iOS LimitedWidgetTests checks the same. */
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
    }

    @Test fun tapOpensTheSet() {
        val (link, src) = WebLink.parseApp(LimitedWidgets.link("FRA", "widget_limited"))!!
        assertEquals(WebLink.Insights("limited", null, null, emptyList(), "FRA"), link)
        assertEquals("widget_limited", src)
    }

    /** The Set, Rarity and Color buttons: one pick per tap, round to Any; several picks from the settings go to Any. */
    @Test fun buttonsStepOnePickAtATime() {
        val r = LimitedWidgets.RARITIES
        assertEquals(listOf("common"), LimitedWidgets.next(emptyList(), r))
        assertEquals(listOf("uncommon"), LimitedWidgets.next(listOf("common"), r))
        assertEquals(emptyList<String>(), LimitedWidgets.next(listOf("mythic"), r))
        assertEquals(emptyList<String>(), LimitedWidgets.next(listOf("common", "rare"), r))
        assertEquals(listOf("M"), LimitedWidgets.next(listOf("G"), LimitedWidgets.COLORS))
        assertEquals(emptyList<String>(), LimitedWidgets.next(listOf("C"), LimitedWidgets.COLORS))
        assertEquals("HOB", LimitedWidgets.nextSet("FRA", listOf("TRK", "FRA", "HOB")))
        assertEquals("TRK", LimitedWidgets.nextSet("HOB", listOf("TRK", "FRA", "HOB")))
        assertEquals("TRK", LimitedWidgets.nextSet("OLD", listOf("TRK", "FRA")))
        assertEquals("FRA", LimitedWidgets.nextSet("FRA", emptyList()))
        assertEquals("All", LimitedWidgets.rarityButton(emptyList(), wide = false))
        assertEquals("Any rarity", LimitedWidgets.rarityButton(emptyList(), wide = true))
        assertEquals("Rare", LimitedWidgets.rarityButton(listOf("rare"), wide = true))
        assertEquals("C·U", LimitedWidgets.rarityButton(listOf("uncommon", "common"), wide = false))
    }

    /** The body tap opens Limited on the widget's set, sort, rarity and color; Any travels as a blank. */
    @Test fun tapCarriesThePicks() {
        val picks = LimitedPicks("FRA", "iwd", listOf("uncommon"), listOf("W", "U"))
        val raw = LimitedWidgets.link("FRA", "widget_limited", picks)
        assertEquals("table1://insights/limited/FRA?sort=iwd&rarity=uncommon&color=W,U&src=widget_limited", raw)
        assertEquals(picks, (WebLink.parseApp(raw)!!.first as WebLink.Insights).limited)
        val any = LimitedWidgets.link("FRA", "widget_limited", LimitedPicks("FRA"))
        assertEquals(LimitedPicks("FRA"), (WebLink.parseApp(any)!!.first as WebLink.Insights).limited)
        assertEquals(null, (WebLink.parseApp("table1://insights/limited/FRA?sort=nope")!!.first as WebLink.Insights).limited)
    }
}
