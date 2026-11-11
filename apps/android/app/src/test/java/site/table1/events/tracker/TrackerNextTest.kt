package site.table1.events.tracker

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The life tracker follows its player into the next round (contract/life-tracker-options-2026-10-20.md § Next round)
 * against testdata/tracker-next/cases.json (also iOS TrackerNextTests and web trackerNext.test.ts).
 */
class TrackerNextTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val file = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/tracker-next") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

    @Test
    fun sharedCases() {
        val cases = file["cases"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.isNotEmpty())
        for (c in cases) {
            val name = c["name"]!!.jsonPrimitive.content
            val current = c["current"]!!.let { if (it is JsonNull) null else it.jsonPrimitive.content }
            val answer = c["answer"]!!.let { if (it is JsonNull) null else json.decodeFromJsonElement(TrackerNextAnswer.serializer(), it) }
            val want = c["want"]!!.jsonObject
            val expected = when (val d = want["do"]!!.jsonPrimitive.content) {
                "stay" -> TrackerNext.Stay
                "soon" -> TrackerNext.Soon
                "move" -> TrackerNext.Move(want["match_id"]!!.jsonPrimitive.content)
                "notice" -> TrackerNext.Notice(want["text"]!!.jsonPrimitive.content)
                else -> error("unknown $d")
            }
            assertEquals(name, expected, TrackerNext.decide(current, answer))
        }
    }
}
