package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import site.table1.events.ui.components.parseInstant
import java.io.File

/** Following (contract/follows-2026-10-25.md) against testdata/follows/cases.json (iOS FollowsTests, web follows.test.ts). */
class FollowsTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val doc = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/follows") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject
    private val now = parseInstant(doc["now"]!!.jsonPrimitive.content)!!

    private fun str(o: JsonObject, k: String) = (o[k] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.contentOrNull

    @Test fun agoAndChange() {
        for (a in doc["ago"]!!.jsonArray.map { it.jsonObject }) assertEquals(str(a, "text"), Follows.ago(a["seconds"]!!.jsonPrimitive.double))
        for (c in doc["change"]!!.jsonArray.map { it.jsonObject }) {
            assertEquals(str(c, "text"), Follows.change(c["added"]!!.jsonPrimitive.int, c["removed"]!!.jsonPrimitive.int))
        }
    }

    @Test fun detailAndHome() {
        for (d in doc["detail"]!!.jsonArray.map { it.jsonObject }) {
            assertEquals(str(d, "text"), Follows.detail(json.decodeFromJsonElement<Follow>(d["follow"]!!), now))
        }
        for (h in doc["home"]!!.jsonArray.map { it.jsonObject }) {
            assertEquals(str(h, "text"), Follows.home(h["items"]!!.jsonArray.map { json.decodeFromJsonElement<Follow>(it) }))
        }
    }

    @Test fun sections() {
        for (s in doc["sections"]!!.jsonArray.map { it.jsonObject }) {
            val cards = FollowUpdateWire("", 0, 0, s["cards"]!!.jsonArray.map { it as JsonArray }).cards()
            val (added, removed) = Follows.sections(cards)
            fun rows(k: String) = s[k]!!.jsonArray.map { it.jsonObject }.map { FollowCard(str(it, "card_id")!!, str(it, "board"), it["qty"]!!.jsonPrimitive.int) }
            assertEquals(rows("added"), added)
            assertEquals(rows("removed"), removed)
        }
    }

    @Test fun serverTimestampsAndRoutes() {
        val f = json.decodeFromJsonElement<Follow>(doc["detail"]!!.jsonArray[2].jsonObject["follow"]!!)
        val micro = f.copy(lastUpdate = f.lastUpdate!!.copy(at = "2026-10-25T15:59:59.500000+00:00"))
        assertEquals(str(doc["detail"]!!.jsonArray[2].jsonObject, "text"), Follows.detail(micro, now))
        assertEquals("profile/u1/deck/${f.id}", f.copy(userId = "u1").route)
        assertEquals("collection/shared/tok", f.copy(userId = "u1", token = "tok").route)
        assertNull(f.copy(available = false, userId = "u1").route)
    }
}
