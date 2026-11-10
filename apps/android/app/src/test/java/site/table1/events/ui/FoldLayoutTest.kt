package site.table1.events.ui

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.float
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import site.table1.events.ui.components.Fold
import site.table1.events.ui.components.FoldMode
import site.table1.events.ui.components.FoldRule
import java.io.File

/** Fold-aware layouts (contract/foldables-2026-11-10.md) against testdata/foldables/cases.json (also iOS
 *  FoldLayoutTests and web fold.test.ts), the FoldingFeature conversion and the manifest's continuity setting. */
class FoldLayoutTest {
    private val root = generateSequence(File("").absoluteFile) { it.parentFile }.first { File(it, "testdata/foldables").isDirectory }
    private val data = Json.parseToJsonElement(File(root, "testdata/foldables/cases.json").readText()).jsonObject

    private fun f(o: JsonObject, k: String) = o[k]!!.jsonPrimitive.float

    @Test fun constants() {
        val c = data["constants"]!!.jsonObject
        assertEquals(f(c, "clear"), FoldRule.CLEAR)
        assertEquals(f(c, "minPane"), FoldRule.MIN_PANE)
        assertEquals(f(c, "wide"), FoldRule.WIDE)
        assertEquals(f(c, "heightMin"), FoldRule.HEIGHT_MIN)
    }

    @Test fun sharedCases() {
        val cases = data["cases"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.size > 15)
        for (c in cases) {
            val name = c["name"]!!.jsonPrimitive.content
            val folds = c["folds"]!!.jsonArray.map { it.jsonObject }.map {
                Fold(f(it, "x"), f(it, "y"), f(it, "w"), f(it, "h"), it["vertical"]!!.jsonPrimitive.boolean,
                    it["separating"]!!.jsonPrimitive.boolean, f(it, "margin"))
            }
            val got = FoldRule.of(f(c, "w"), f(c, "h"), folds)
            val out = c["out"]!!.jsonObject
            assertEquals(name, out["width"]!!.jsonPrimitive.content, got.width)
            assertEquals(name, out["height"]!!.jsonPrimitive.content, got.height)
            assertEquals(name, out["mode"]!!.jsonPrimitive.content, got.mode.wire)
            assertEquals(name, out["rail"]!!.jsonPrimitive.boolean, got.rail)
            assertEquals(name, out["rotates"]!!.jsonPrimitive.boolean, got.rotates)
            val panes = out["panes"]!!.jsonArray
            assertEquals(name, panes.size, got.panes.size)
            panes.zip(got.panes).forEach { (want, p) ->
                val w = want.jsonArray.map { it.jsonPrimitive.float }
                listOf(p.x, p.y, p.w, p.h).zip(w).forEach { (a, b) -> assertEquals(name, b, a, 0.01f) }
            }
        }
    }

    /** FoldingFeature bounds are window pixels: a Pixel Fold-style hinge line at 2.625 density. */
    @Test fun featureBoundsBecomeDp() {
        val fold = FoldRule.fromBounds(0, 882, 2208, 882, vertical = false, separating = true, density = 2.625f)
        assertEquals(336f, fold.y, 0.01f)
        assertEquals(0f, fold.h, 0.01f)
        assertEquals(841.14f, fold.w, 0.01f)
        assertEquals(FoldMode.Tabletop, FoldRule.of(841f, 673f, listOf(fold)).mode)
        // Lying flat, a foldable's fold isn't separating: one window, two panes only for its width.
        assertEquals(FoldMode.Wide, FoldRule.of(841f, 673f, listOf(fold.copy(separating = false))).mode)
    }

    @Test fun tabletopKeepsTheTabBarAlongTheBottom() {
        val l = FoldRule.of(841f, 673f, FoldRule.debug("tabletop", 841f, 673f))
        assertEquals(FoldMode.Tabletop, l.mode)
        assertTrue(!l.rail)
        assertTrue(FoldRule.of(841f, 673f, emptyList()).rail)
    }

    /** Folding and unfolding must not restart MainActivity (state would be lost): it handles the change itself. */
    @Test fun mainActivityHandlesFoldConfigurationChanges() {
        val manifest = File(root, "apps/android/app/src/main/AndroidManifest.xml").readText()
        val main = Regex("""<activity\s+android:name="\.MainActivity"[^>]*>""").find(manifest)!!.value
        val changes = Regex("""android:configChanges="([^"]+)"""").find(main)!!.groupValues[1].split("|").toSet()
        for (needed in listOf("orientation", "screenSize", "smallestScreenSize", "screenLayout", "density")) {
            assertTrue("MainActivity configChanges lacks $needed", needed in changes)
        }
        assertTrue("MainActivity must not lock orientation", !main.contains("screenOrientation"))
    }
}
