package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Spice (contract/spice-2026-10-28.md) against testdata/spice/cases.json (iOS SpiceTests, web spice.test.ts): every
 *  case's server answer decodes and shows exactly the case's `display`. */
class SpiceTest {
    private val doc = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/spice") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject
    private val json = Json { ignoreUnknownKeys = true }

    private fun str(o: kotlinx.serialization.json.JsonObject, k: String) = (o[k] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
    private fun strs(o: kotlinx.serialization.json.JsonObject, k: String) = o[k]!!.jsonArray.map { it.jsonPrimitive.content }

    @Test fun everyCaseShowsItsDisplay() {
        val cases = doc["cases"]!!.jsonArray
        assertTrue(cases.size > 10)
        for (c in cases) {
            val o = c.jsonObject
            val name = o["name"]!!.jsonPrimitive.content
            val r = json.decodeFromJsonElement(SpiceResult.serializer(), o["expect"]!!)
            val d = o["display"]!!.jsonObject
            assertEquals(name, str(d, "summary"), Spice.summary(r))
            assertEquals(name, str(d, "headline"), Spice.headline(r))
            assertEquals(name, str(d, "basis"), Spice.basis(r))
            assertEquals(name, strs(d, "cubes"), Spice.cubes(r))
            assertEquals(name, strs(d, "cards"), r.cards.map { Spice.cardLine(it, r) })
            assertEquals(name, strs(d, "missing"), r.stockMissing.map { Spice.missingLine(it, r) })
            assertEquals(name, str(d, "reason"), Spice.reason(r))
        }
    }

    @Test fun words() {
        for (w in doc["words"]!!.jsonArray) {
            val o = w.jsonObject
            assertEquals(o["label"]!!.jsonPrimitive.content, Spice.WORDS[o["word"]!!.jsonPrimitive.content])
        }
    }
}
