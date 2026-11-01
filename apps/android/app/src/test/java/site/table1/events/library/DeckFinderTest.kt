package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.JsonNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.Instant

/** Deck finder jobs (contract/deck-finder-2026-10-15.md § Jobs) against testdata/deck-finder/cases.json (iOS DeckFinderTests, web deckFinder.test.ts). */
class DeckFinderTest {
    private val doc = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/deck-finder") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

    @Test fun resumeAndHeadline() {
        for (c in doc["resume"]!!.jsonArray.map { it.jsonObject }) {
            val ago = c["finished_seconds_ago"]!!.let { if (it is JsonNull) null else it.jsonPrimitive.double }
            assertEquals("${c["status"]} $ago", c["show"]!!.jsonPrimitive.boolean, DeckFinderJobs.resume(c["status"]!!.jsonPrimitive.content, ago))
        }
        for (c in doc["headline"]!!.jsonArray.map { it.jsonObject }) {
            assertEquals(c["text"]!!.jsonPrimitive.content,
                DeckFinderJobs.headline(c["placement"]!!.jsonPrimitive.content, c["event"]!!.jsonPrimitive.content, c["date"]!!.jsonPrimitive.content))
        }
    }

    @Test fun decodesAJob() {
        val json = Json { ignoreUnknownKeys = true }
        val j = json.decodeFromString(FinderJob.serializer(), """{"job_id": "j1", "status": "done", "query": "boros energy", "format": "modern", "answers": [{"question": "Which?", "answer": "Boros"}], "result": {"status": "deck", "deck": {"name": "Boros Energy", "archetype": "Boros Energy", "format": "modern", "event": "Modern Challenge 32", "date": "2026-10-30", "placement": "1st", "player": "", "source_url": "https://www.mtgo.com/decklist/x", "notes": "", "from": "table1", "main": [{"qty": 4, "name": "Guide of Souls"}], "side": []}}, "steps": ["Checking Table 1's results: Modern, last 30 days"], "created_at": "2026-11-01T16:11:02.042+00:00", "finished_at": "2026-11-01T16:12:10+00:00"}""")
        assertTrue(j.finished)
        assertEquals(listOf(FinderAnswer("Which?", "Boros")), j.answers)
        assertEquals("Boros Energy", j.result?.deck?.name)
        assertEquals("table1", j.result?.deck?.from)
        assertEquals(listOf("Checking Table 1's results: Modern, last 30 days"), j.steps)
        assertTrue(DeckFinderJobs.resume(j, Instant.parse("2026-11-01T16:30:00Z")))
        assertFalse(DeckFinderJobs.resume(j, Instant.parse("2026-11-01T18:30:00Z")))
        val running = json.decodeFromString(FinderJob.serializer(), """{"job_id": "j2", "status": "running", "query": "x", "format": null, "answers": [], "result": null, "created_at": "2026-11-01T16:11:02Z", "finished_at": null}""")
        assertFalse(running.finished)
        assertNull(running.result)
        assertTrue(running.steps.isEmpty())
        assertTrue(DeckFinderJobs.resume(running))
        assertEquals(DeckFinderJobs.COULD_NOT_FINISH, DeckFinderJobs.resultOf(running).message)
        assertEquals("error", DeckFinderJobs.resultOf(running).status)
    }

    @Test fun refusedStartWords() {
        assertEquals("That's today's 20 searches. Try again tomorrow.",
            DeckFinderJobs.words(RuntimeException("""{"code":"P0001","details":null,"hint":null,"message":"That's today's 20 searches. Try again tomorrow."}""")))
        assertEquals("plain", DeckFinderJobs.words(RuntimeException("plain")))
    }
}
