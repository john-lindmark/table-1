package site.table1.events.data

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Scheduled events, sign-up, top 8, automatic rounds and decklists (contract/scheduled-events-2026-10-27.md) against
 * testdata/scheduled-events/cases.json, plus the new event_bundle / event_public fields from testdata/event-bundle.
 */
class ScheduledEventsTest {
    private val json = Json { ignoreUnknownKeys = true }
    private fun file(dir: String, name: String) =
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/$dir") }.first { it.isDirectory }, name).readText()
    private val cases: JsonObject by lazy { json.parseToJsonElement(file("scheduled-events", "cases.json")).jsonObject }
    private fun list(key: String) = cases[key]!!.jsonArray.map { it.jsonObject }
    private fun JsonObject.str(k: String) = this[k]!!.let { if (it is JsonNull) null else it.jsonPrimitive.content }
    private fun JsonObject.int(k: String) = this[k]!!.let { if (it is JsonNull) null else it.jsonPrimitive.int }

    @Test fun roundsAndNextStep() {
        assertEquals(40, list("next").size)
        assertEquals(9, list("rounds_line").size)
        for (c in list("rounds")) assertEquals("${c["players"]}", c.int("want"), EventRules.swissRounds(c.int("players")!!))
        for (c in list("next")) {
            val stages = (c["stages"] as JsonArray).map { it.jsonPrimitive.content }
            // `active_teams` comes with team events only: the cut then counts teams.
            assertEquals(c.toString(), c.str("want"), EventRules.nextStep(stages, c["waiting"]!!.jsonPrimitive.boolean,
                c.int("number_of_rounds")!!, c.int("top_cut")!!, c.int("active_players")!!, c["active_teams"]?.jsonPrimitive?.int))
        }
        for (c in list("round_name")) assertEquals(c.str("want"), EventRules.roundName(c.str("stage"), c.int("number")!!, c.int("of")!!))
        for (c in list("auto_label")) assertEquals(c.str("want"), EventRules.autoLabel(c.int("players")!!))
        for (c in list("rounds_line")) {
            assertEquals(c.str("want"), EventRules.roundsLine(c["auto"]!!.jsonPrimitive.boolean, c.int("rounds")!!, c.int("top_cut")!!,
                c["open"]!!.jsonPrimitive.boolean))
        }
    }

    @Test fun signUpPage() {
        for (c in list("sign_up")) assertEquals(c.str("want"), EventRules.signUpLine(c.int("players")!!, c.int("capacity"), c.int("waitlist")!!))
        for (c in list("button")) {
            assertEquals(c.toString(), c.str("want"), EventRules.button(c["signed_in"]!!.jsonPrimitive.boolean, c.str("sign_up"), c.str("me")))
        }
    }

    @Test fun decklists() {
        for (c in list("decklist")) {
            val want = c["want"]!!.jsonObject
            assertEquals(c.str("body"), EventRules.Counts(want.int("main")!!, want.int("side")!!), EventRules.decklistCounts(c.str("body")!!))
        }
        for (c in list("deck_format")) assertEquals(c.str("event"), c.str("want"), EventRules.deckFormat(c.str("event")))
        for (c in list("decklists_line")) assertEquals(c.str("want"), EventRules.decklistsLine(c.int("sent")!!, c.int("players")!!))
    }

    @Test fun bundleAndPageCarryTheNewFields() {
        val b = Repo.bundle(json.decodeFromString<EventBundleWire>(file("event-bundle", "bundle.json")))
        assertEquals(8, b.event.topCut)
        assertEquals(8, b.event.capacity)
        assertEquals("optional", b.event.decklists)
        assertEquals(listOf("Dot Waiting"), b.waitlist.map { it.displayName })
        assertEquals(listOf(60), b.decklists.map { it.mainCount })
        assertEquals(listOf("swiss", "swiss"), b.rounds.map { it.stage })
        assertNotNull(b.decklist(b.participants[0].id))
        assertEquals(2, b.decklistsMissing)
        val p = json.decodeFromString<EventPage>(file("event-bundle", "public.json"))
        assertTrue(p.available)
        assertEquals("3/8 players · 1 on the waitlist", p.signUpLine)
        assertEquals("3 rounds · Top 8", p.roundsLine)
        assertEquals("closed", EventRules.button(false, p.signUp, p.me))
    }

    @Test fun standingsWithABracket() {
        val r = json.decodeFromString<StandingsResponse>("""
            {"standings":[{"rank":1,"participant_id":"a","display_name":"Ana","swiss_rank":2,"playoff":"winner"}],"top_cut":8,
             "bracket":[{"stage":"final","matches":[{"match_id":"m","table_number":1,"status":"confirmed","winner":"a",
              "sides":[{"seed":2,"participant_id":"a","display_name":"Ana","game_wins":2},{"seed":1,"participant_id":"b","display_name":"Bo","game_wins":0}]}]}]}
        """.trimIndent())
        assertEquals("winner", r.standings.first().playoff)
        assertEquals("Final", r.bracket.first().title)
        assertEquals("a", r.bracket.first().matches.first().winner)
    }
}
