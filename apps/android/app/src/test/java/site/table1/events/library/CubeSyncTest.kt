package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Sync a cube with Cube Cobra against testdata/cube-sync/cases.json (also iOS CubeSyncTests and web cubeSync.test.ts). */
class CubeSyncTest {
    private val root = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/cube-sync") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

    private fun entry(e: JsonElement): ListEntry {
        val a = e.jsonArray
        return ListEntry(a[0].jsonPrimitive.content, a[1].jsonPrimitive.content, a[2].jsonPrimitive.int,
            if (a.size > 3) a[3].jsonPrimitive.content else "nonfoil", if (a.size > 4) a[4].jsonPrimitive.content else "en")
    }
    private fun s(o: Map<String, JsonElement>, k: String) = o[k]!!.jsonPrimitive.content
    private fun line(e: JsonElement) = e.jsonObject.let { CubeSync.Line(s(it, "board"), s(it, "card"), s(it, "finish"), s(it, "lang"), it["qty"]!!.jsonPrimitive.int) }

    @Test fun sharedCases() {
        val printings = root["printings"]!!.jsonObject.mapValues { (_, v) -> CubeSync.Printing(s(v.jsonObject, "oracle"), s(v.jsonObject, "lang")) }
        val cases = root["cases"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.isNotEmpty())
        for (c in cases) {
            val name = s(c, "name")
            val want = c["want"]!!.jsonObject
            val r = CubeSync.diff(c["current"]!!.jsonArray.map(::entry), c["incoming"]!!.jsonArray.map(::entry), printings)
            assertEquals(name, want["in"]!!.jsonArray.map(::line), r.into)
            assertEquals(name, want["out"]!!.jsonArray.map(::line), r.out)
            assertEquals(name, want["changed"]!!.jsonArray.map { it.jsonObject }.map {
                CubeSync.Changed(s(it, "board"), s(it, "from_card"), s(it, "from_finish"), s(it, "from_lang"), s(it, "to_card"), s(it, "to_finish"),
                    s(it, "to_lang"), it["qty"]!!.jsonPrimitive.int)
            }, r.changed)
            assertEquals(name, want["same"]!!.jsonPrimitive.int, r.same)
            assertEquals(name, want["entries"]!!.jsonArray.map(::entry), r.entries)
            assertEquals(name, s(c, "summary"), r.summary)
        }
    }

    @Test fun cubeIdFromLinks() {
        assertEquals("lindmark", CubeSync.cubeId("https://cubecobra.com/cube/list/lindmark"))
        assertEquals("abc-1", CubeSync.cubeId("cubecobra.com/cube/overview/abc-1"))
        assertEquals("xyz", CubeSync.cubeId("https://www.cubecobra.com/c/xyz"))
        assertNull(CubeSync.cubeId("https://moxfield.com/decks/abc"))
        assertNull(CubeSync.cubeId(null))
    }

    @Test fun wireKeepsSeqAndLink() {
        val w = Json { ignoreUnknownKeys = true }.decodeFromString<ListWire>(
            """{"id":"a","kind":"cube","name":"C","format":"vintage","seq":7,"source_url":"https://cubecobra.com/cube/list/a","versions":[{"version":1,"note":"x","at":0,"entries":[]}]}""")
        val l = w.toList()!!
        assertEquals(7L, l.seq)
        assertEquals("https://cubecobra.com/cube/list/a", l.sourceUrl)
        assertEquals(l.sourceUrl, ListWire.of(l).toList()!!.sourceUrl)
    }
}
