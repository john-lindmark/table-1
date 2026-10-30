package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import site.table1.events.data.InsightsPush
import site.table1.events.data.PushRoutes
import site.table1.events.data.WebLink
import java.io.File
import java.time.LocalDate

/** Ranking a Limited set (contract/cube-rankings-2026-10-21.md § Sets) and New in Insights pushes against
 *  testdata/limited-rankings/cases.json (also iOS LimitedRankingsTests and web limitedRank.test.ts). */
class LimitedRankingsTest {
    private val cases = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/limited-rankings") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject
    private val json = Json { ignoreUnknownKeys = true }
    private fun list(k: String) = cases[k]!!.jsonArray.map { it.jsonObject }
    private fun str(o: JsonObject, k: String) = o[k]?.let { if (it is JsonNull) null else it.jsonPrimitive.contentOrNull }

    @Test fun subjectIds() {
        for (c in list("subjects")) assertEquals(str(c, "id"), RankSubject.setId(str(c, "set_key")!!))
        for (c in list("keys")) assertEquals(str(c, "id"), str(c, "key"), RankSubject.setKey(str(c, "id")))
    }

    @Test fun rowsFromCubesAndSets() {
        for (c in list("rows")) {
            val row = json.decodeFromString<RankingRow>(c["json"].toString())
            assertEquals(str(c, "subject"), row.listId)
            assertEquals(c["is_set"]!!.jsonPrimitive.boolean, row.isSet)
            if (row.isSet) assertEquals(row.listId, row.cube?.id)
        }
    }

    @Test fun sharingLabels() {
        for (c in list("sharing")) assertEquals(str(c, "label"), RankSubject.sharingLabel(str(c, "sharing")!!, c["set"]!!.jsonPrimitive.boolean))
    }

    @Test fun pushRoutes() {
        for (c in list("pushes")) {
            val info = c["info"]!!.jsonObject.mapValues { it.value.jsonPrimitive.content }
            val want = c["route"]?.takeIf { it !is JsonNull }?.jsonObject
            val got = PushRoutes.insights(info)
            if (want == null) assertNull(info.toString(), got)
            else {
                assertEquals(info.toString(), InsightsPush(str(want, "section")!!, str(want, "key")!!, str(want, "what")!!), got)
                val link = PushRoutes.link(info) as WebLink.Screens
                assertEquals("insights", link.tab)
                assertEquals(if (got!!.what == "rank") listOf("collection/list/set%3A${got.key}/rankings") else emptyList<String>(), link.stack)
            }
        }
        assertEquals(PushRoutes.Channel.Insights, PushRoutes.channel("insights.new"))
    }

    @Test fun rankableSetDetail() {
        val today = LocalDate.parse("2026-10-30")
        assertEquals("Arena cube · 540 cards · 3 rankings (1 yours)",
            RankableSet("PWR-2510", "Arena Powered Cube · Oct 2025", "2025-10-30", "cube", 540, true, 1, 3).detail(today))
        assertEquals("Out Nov 14 · 264 cards", RankableSet("NHZ", "New Horizons", "2026-11-14", "set", 264, false).detail(today))
        assertEquals("281 cards · 1 ranking", RankableSet("FRA", "Foundations Remastered", "2026-09-23", "set", 281, true, 0, 1).detail(today))
        assertEquals("set:PWR-2510", RankableSet("PWR-2510", "x").subjectId)
    }
}
