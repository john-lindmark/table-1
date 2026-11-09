package site.table1.events.data

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/** Re-pair a round (contract/repair-round-2026-11-09.md) against testdata/repair-round/cases.json. */
class RepairRoundTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val cases: JsonObject by lazy {
        val dir = generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/repair-round") }.first { it.isDirectory }
        json.parseToJsonElement(File(dir, "cases.json").readText()).jsonObject
    }
    private fun list(key: String) = cases[key]!!.jsonArray.map { it.jsonObject }
    private fun JsonObject.str(k: String) = this[k]?.let { if (it is JsonNull) null else it.jsonPrimitive.content }

    private fun round(r: JsonObject, i: Int) = RoundRow(
        id = "r$i", eventId = "e", number = r["number"]!!.jsonPrimitive.int, status = r.str("status")!!,
        pairingsPublishedAt = r.str("pairings_published_at"),
        matches = r["matches"]!!.jsonArray.mapIndexed { j, el ->
            val m = el.jsonObject
            MatchRow(id = "m$i-$j", eventId = "e", roundId = "r$i", isBye = m["is_bye"]!!.jsonPrimitive.boolean,
                status = m.str("status")!!, resultSource = m.str("result_source"), updatedAt = m.str("updated_at"))
        },
    )

    @Test fun prompt() {
        for (c in list("prompt")) {
            val got = RepairRound.prompt(c["rounds"]!!.jsonArray.mapIndexed { i, r -> round(r.jsonObject, i) })
            val want = c["want"]!!.let { if (it is JsonNull) null else it.jsonObject }
            assertEquals(c.str("name"), want?.get("round")?.jsonPrimitive?.int, got?.round)
            assertEquals(c.str("name"), want?.get("changed")?.jsonArray?.map { it.jsonPrimitive.int }, got?.changed)
            assertEquals(c.str("name"), want?.str("text"), got?.text)
        }
    }

    @Test fun confirm() {
        for (c in list("confirm")) {
            val matches = c["matches"]!!.jsonArray.map { it.jsonObject.let { m -> m["is_bye"]!!.jsonPrimitive.boolean to m.str("status")!! } }
            val got = RepairRound.confirm(c.str("label")!!, matches)
            val want = c["want"]!!.jsonObject
            assertEquals(c.str("name"), want.str("title"), got.title)
            assertEquals(c.str("name"), want.str("message"), got.message)
            assertEquals(c.str("name"), want["results"]!!.jsonPrimitive.int, got.results)
        }
    }

    @Test fun labels() {
        for (c in list("labels")) assertEquals(c.str("want"), RepairRound.label(c.str("stage"), c["number"]!!.jsonPrimitive.int))
    }
}
