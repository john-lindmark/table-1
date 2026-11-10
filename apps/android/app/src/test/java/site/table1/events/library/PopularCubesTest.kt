package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/** Popular cubes (contract/cube-rankings-2026-10-21.md § Popular cubes) against testdata/popular-cubes/cases.json: a cube's
 *  row detail and the word a ranked subject goes by (also iOS PopularCubesTests and web popularCubes.test.ts). */
class PopularCubesTest {
    private val cases = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/popular-cubes") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject
    private val json = Json { ignoreUnknownKeys = true }

    @Test fun detail() {
        for (c in cases["detail"]!!.jsonArray.map { it.jsonObject }) {
            val cube = json.decodeFromJsonElement(PopularCube.serializer(), c["cube"]!!)
            assertEquals(c["want"]!!.jsonPrimitive.content, cube.detail)
            assertEquals("set:${cube.key}", cube.subjectId)
        }
    }

    @Test fun noun() {
        for (c in cases["noun"]!!.jsonArray.map { it.jsonObject }) {
            val kind = c["kind"]!!.let { if (it is JsonNull) null else it.jsonPrimitive.contentOrNull }
            assertEquals(c["want"]!!.jsonPrimitive.content, RankSubject.noun(kind))
        }
    }

    @Test fun aPopularSubjectReadsAsACube() {
        val cube = json.decodeFromString(RankingCube.serializer(),
            """{"id": "set:PLSV", "set": "PLSV", "kind": "popular", "name": "PowerLSV", "curator": "LSV", "mine": false, "can_see": true}""")
        assertEquals(true, cube.isSet)
        assertEquals("cube", cube.noun)
        assertEquals("LSV", cube.curator)
    }
}
