package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Rankings are titled by who ranked them (contract/cube-rankings-2026-10-21.md § Names) against
 *  testdata/ranking-names/cases.json (also iOS RankingNameTests and web rankings.test.ts). */
class RankingNameTest {
    @Test fun sharedCases() {
        val cases = Json.parseToJsonElement(
            File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/ranking-names") }.first { it.isDirectory }, "cases.json").readText(),
        ).jsonObject["cases"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.isNotEmpty())
        for (k in cases) {
            val name = k["name"]!!.jsonPrimitive.content
            assertEquals(name, k["label"]!!.jsonPrimitive.contentOrNull, RankingName.label(name))
            assertEquals(name, k["title"]!!.jsonPrimitive.content,
                RankingName.title(name, k["by"]!!.jsonPrimitive.contentOrNull, k["mine"]!!.jsonPrimitive.boolean))
        }
    }
}
