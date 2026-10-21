package site.table1.events.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * Changing a card's language (contract/card-language-2026-10-19.md): copies move to the new language in the places they're
 * in, Unsorted first unless a place is chosen. And the scanner's guide box (contract/library-polish-2026-10-19.md § Scanner
 * reads the guide box). Same cases as iOS LanguageTests.swift and ScanRegionTests.swift.
 */
class LanguageTest {
    private val item = CollectionItem("c1", "foil", "LP", "en", 5, 1)
    private val places = listOf("b-trade" to 2, "b-box" to 1, UNSORTED to 2)

    private fun summary(ops: List<CollectionOp>?) = (ops ?: emptyList()).map { "${it.lang} ${it.delta} ${it.binderId ?: "unsorted"} ${it.finish} ${it.condition}" }

    @Test
    fun unsortedFirstThenBindersInOrder() {
        assertEquals(listOf("en -2 unsorted foil LP", "ja 2 unsorted foil LP", "en -1 b-trade foil LP", "ja 1 b-trade foil LP"),
            summary(LanguageChange.ops(item, places, "ja", 3)))
    }

    @Test
    fun allCopiesKeepTheirPlaces() {
        val ops = LanguageChange.ops(item, places, "de", 5) ?: emptyList()
        assertEquals(0, ops.sumOf { it.delta ?: 0 })
        assertEquals(setOf("b-trade 2", "b-box 1", "unsorted 2"), ops.filter { it.lang == "de" }.map { "${it.binderId ?: "unsorted"} ${it.delta}" }.toSet())
    }

    @Test
    fun fromOnePlace() {
        assertEquals(listOf("en -1 b-box foil LP", "fr 1 b-box foil LP"), summary(LanguageChange.ops(item, places, "fr", 1, from = "b-box")))
        assertNull("the place holds only 1", LanguageChange.ops(item, places, "fr", 2, from = "b-box"))
    }

    @Test
    fun nothingToChange() {
        assertNull(LanguageChange.ops(item, places, "en", 1))
        assertNull(LanguageChange.ops(item, places, "ja", 0))
        assertNull(LanguageChange.ops(item, places, "ja", 6))
    }

    @Test
    fun newCopiesFollowTheirPrinting() {
        assertEquals("ja", Languages.forNew("ja", "de"))
        assertEquals("de", Languages.forNew("en", "de"))
    }

    /** A scanned copy goes in as the language of the printed name the scanner read. */
    @Test
    fun scannedCopiesFollowTheNameRead() {
        assertEquals("de", Languages.forScan("en", listOf("de"), "en"))
        assertEquals("an English name doesn't tell", "fr", Languages.forScan("en", emptyList(), "fr"))
        assertEquals("the printing's own language first", "ja", Languages.forScan("ja", listOf("zhs"), "en"))
        assertEquals("printed alike: the picked one", "pt", Languages.forScan("en", listOf("es", "pt"), "pt"))
        assertEquals("es", Languages.forScan("en", listOf("es", "pt"), "en"))
    }

    @Test
    fun everyCodeFitsTheServer() {
        // collection_items.lang: ^[a-z]{2,3}$
        for ((code, _) in Languages.all) assertTrue(code, Regex("^[a-z]{2,3}$").matches(code))
        assertEquals("Chinese Simplified", Languages.name("zhs"))
    }

    // ── the scanner's guide box

    private val imageW = 1080f
    private val imageH = 1920f
    private fun near(a: Float, b: Float, msg: String = "") = assertTrue("$msg $a ≈ $b", abs(a - b) < 0.001f)

    @Test
    fun guideBoxLandsInTheImage() {
        // A 402 × 560 camera view: the image (1080 × 1920) fills it by width and is cropped top and bottom.
        val box = ScanRegion.viewBox(402f, 560f)
        assertTrue(abs(box.midX - 201f) < 0.5f && abs(box.midY - 280f) < 0.5f)
        val n = ScanRegion.normalized(box, 402f, 560f, imageW, imageH)
        near(n.midX, 0.5f, "centred across")
        near(n.midY, 0.5f, "centred down")
        val scale = 402f / 1080f
        near(n.w, 0.72f)
        near(n.h, box.h / scale / 1920f)
    }

    @Test
    fun topOfTheViewIsTheTopOfTheImage() {
        val top = ScanRegion.normalized(Box(0f, 0f, 400f, 71.11f), 400f, 711.1f, imageW, imageH)
        near(top.y, 0f)
        near(top.y + top.h, 0.1f)
    }

    // Image coordinates here grow downward (ML Kit's), so iOS's y is 1 - y.
    private fun quad(cx: Float, cy: Float, w: Float = 0.3f, h: Float = 0.25f) =
        listOf(cx - w / 2 to cy - h / 2, cx + w / 2 to cy - h / 2, cx + w / 2 to cy + h / 2, cx - w / 2 to cy + h / 2)

    private val guide = Box(0.2f, 0.3f, 0.6f, 0.4f)

    @Test
    fun picksTheCardInTheGuideNotTheBiggestAround() {
        val quads = listOf(
            quad(0.15f, 0.1f, 0.6f, 0.5f), // a bigger card above, outside the guide
            quad(0.55f, 0.48f),            // the one in the guide, a little off centre
            quad(0.45f, 0.9f),             // one below
        )
        assertEquals(1, ScanRegion.pick(quads, guide, imageW, imageH))
    }

    @Test
    fun nearestTheCentreWhenTwoOverlapTheGuide() {
        assertEquals(1, ScanRegion.pick(listOf(quad(0.75f, 0.4f), quad(0.48f, 0.51f)), guide, imageW, imageH))
    }

    @Test
    fun noCardInTheGuide() {
        assertNull(ScanRegion.pick(listOf(quad(0.05f, 0.05f), quad(0.95f, 0.95f)), guide, imageW, imageH))
    }

    @Test
    fun onlyTextInsideTheGuideIsRead() {
        assertTrue(ScanRegion.readsText(guide, 0.5f, 0.5f))
        assertTrue("grown 10%", ScanRegion.readsText(guide, 0.215f, 0.5f))
        assertTrue(!ScanRegion.readsText(guide, 0.1f, 0.5f))
        assertTrue("no guide yet: everything", ScanRegion.readsText(null, 0.0f, 0.0f))
    }
}
