package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Add a deck or cube to the collection against testdata/list-to-collection/cases.json (also iOS ListToCollectionTests
 *  and web listToCollection.test.ts), and the zoom math shared with the web's lib/zoom.ts. */
class ListToCollectionTest {
    private val cases = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/list-to-collection") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject["cases"]!!.jsonArray

    @Test fun sharedCases() {
        assertTrue(cases.isNotEmpty())
        for (c in cases.map { it.jsonObject }) {
            val name = c["name"]!!.jsonPrimitive.content
            val entries = c["entries"]!!.jsonArray.map { it.jsonObject }.map {
                ListEntry(it["card_id"]!!.jsonPrimitive.content, it["board"]!!.jsonPrimitive.content, it["qty"]!!.jsonPrimitive.int, it["finish"]!!.jsonPrimitive.content,
                    it["lang"]?.jsonPrimitive?.content ?: "en")
            }
            val kind = if (c["kind"]!!.jsonPrimitive.content == "deck") ListKind.Deck else ListKind.Cube
            val mode = if (c["mode"]!!.jsonPrimitive.content == "all") ListToCollection.Mode.All else ListToCollection.Mode.Missing
            val owned = c["owned"]!!.jsonObject.mapValues { it.value.jsonPrimitive.int }
            val ops = ListToCollection.ops(entries, kind, owned, mode, c["sideboard"]?.jsonPrimitive?.boolean ?: true,
                c["only"]?.jsonArray?.map { it.jsonPrimitive.content }?.toSet(),
                cardOf = c["oracles"]?.jsonObject?.mapValues { it.value.jsonPrimitive.content } ?: emptyMap())
            val want = c["ops"]!!.jsonArray.map { it.jsonObject }.map {
                ListToCollection.Op(it["card_id"]!!.jsonPrimitive.content, it["finish"]!!.jsonPrimitive.content, it["delta"]!!.jsonPrimitive.int,
                    it["lang"]?.jsonPrimitive?.content ?: "en")
            }
            assertEquals(name, want, ops)
            assertEquals(name, c["copies"]!!.jsonPrimitive.int, ListToCollection.copies(ops))
        }
    }

    @Test fun collectionOpsKeepTheListedLanguage() {
        val ops = ListToCollection.collectionOps(listOf(ListToCollection.Op("a", "foil", 2), ListToCollection.Op("a", "nonfoil", 1, "de"),
            ListToCollection.Op("j", "nonfoil", 1), ListToCollection.Op("u", "nonfoil", 1)), { mapOf("a" to "en", "j" to "ja")[it] }, "LP")
        assertEquals(listOf(CollectionOp("a", "foil", "LP", "en", delta = 2), CollectionOp("a", "nonfoil", "LP", "de", delta = 1),
            CollectionOp("j", "nonfoil", "LP", "ja", delta = 1), CollectionOp("u", "nonfoil", "LP", "en", delta = 1)), ops)
    }

    private val box = Zoom.Size(400f, 800f)
    private val fit = Zoom.fitted(box, Zoom.Size(1600f, 900f))

    @Test fun zoomFitsAndCenters() {
        assertEquals(Zoom.Size(400f, 225f), fit)
        assertEquals(Zoom.View(1f, 0f, 287.5f), Zoom.fitView(box, fit))
    }

    @Test fun zoomKeepsThePointUnderTheFingers() {
        assertEquals(Zoom.View(2f, -100f, 175f), Zoom.zoomTo(Zoom.fitView(box, fit), 2f, 100f, 400f, box, fit))
        assertEquals(Zoom.MAX, Zoom.zoomTo(Zoom.fitView(box, fit), 99f, 200f, 400f, box, fit).s)
        assertEquals(Zoom.fitView(box, fit), Zoom.zoomTo(Zoom.fitView(box, fit), 0.2f, 0f, 0f, box, fit))
    }

    @Test fun zoomCantBeDraggedPastAnEdge() {
        val v = Zoom.zoomTo(Zoom.fitView(box, fit), 4f, 200f, 400f, box, fit)
        assertEquals(0f, Zoom.pan(v, 10_000f, 0f, box, fit).x)
        assertEquals(400f - 1600f, Zoom.pan(v, -10_000f, 0f, box, fit).x)
        assertEquals(0f, Zoom.pan(v, 0f, 10_000f, box, fit).y)
        assertEquals(800f - 900f, Zoom.pan(v, 0f, -10_000f, box, fit).y)
    }

    @Test fun doubleTapGoesTo3xAndBack() {
        val v = Zoom.toggle(Zoom.fitView(box, fit), 200f, 400f, box, fit)
        assertEquals(3f, v.s)
        assertEquals(Zoom.fitView(box, fit), Zoom.toggle(v, 0f, 0f, box, fit))
    }
}
