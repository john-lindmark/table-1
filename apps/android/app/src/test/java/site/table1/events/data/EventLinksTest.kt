package site.table1.events.data

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/**
 * Event links in the app and following events (contract/event-links-2026-11-09.md, contract/event-follows-2026-11-09.md),
 * on testdata/event-links/cases.json, the file iOS EventLinksTests and web eventFollows.test.ts read.
 */
class EventLinksTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val all = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/event-links") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

    private fun str(e: kotlinx.serialization.json.JsonElement?) = e?.takeIf { it !is JsonNull }?.jsonPrimitive?.contentOrNull

    @Test fun resultsAndTitle() {
        for (c in all["results"]!!.jsonArray) {
            val o = c.jsonObject
            val p = EventPage(eventId = "e", signUp = str(o["sign_up"]), me = str(o["me"]), currentRound = o["current_round"]!!.jsonPrimitive.int)
            assertEquals(o["name"]!!.jsonPrimitive.content, o["want"]!!.jsonPrimitive.boolean, p.showsResults)
        }
        for (c in all["title"]!!.jsonArray) {
            val o = c.jsonObject
            val round = o["round"]?.takeIf { it !is JsonNull }?.let { json.decodeFromJsonElement(EventPage.Head.serializer(), it) }
            val p = EventPage(eventId = "e", status = str(o["status"]), round = round, currentRound = o["current_round"]!!.jsonPrimitive.int,
                numberOfRounds = o["number_of_rounds"]!!.jsonPrimitive.int)
            assertEquals(o["want"]!!.jsonPrimitive.content, p.resultsTitle)
        }
    }

    @Test fun matchups() {
        for (c in all["round_title"]!!.jsonArray) {
            val o = c.jsonObject
            assertEquals(o["want"]!!.jsonPrimitive.content,
                PublicRound(o["number"]!!.jsonPrimitive.int, str(o["stage"]), str(o["status"])).title)
        }
        for (c in all["score"]!!.jsonArray) {
            val o = c.jsonObject
            val sides = o["sides"]!!.jsonArray.map { s -> s.jsonArray.let { PublicMatch.Side(it[0].jsonPrimitive.int, gameWins = it[1].jsonPrimitive.int) } }
            assertEquals(o["want"]!!.jsonPrimitive.content,
                PublicMatch("m", status = str(o["status"]), gameDraws = o["game_draws"]!!.jsonPrimitive.int, sides = sides).score)
        }
        val p = EventPage(eventId = "e", round = EventPage.Head(2, "swiss"), pairings = listOf(PublicMatch("m", tableNumber = 3)))
        assertEquals(listOf("Round 2 · now"), p.matchupRounds.map { it.title })
        assertEquals("Bye", PublicMatch("b", isBye = true).tableLabel)
    }

    @Test fun followedDetail() {
        for (c in all["followed"]!!.jsonArray) {
            val o = c.jsonObject
            val e = FollowedEvent("e", "N", formatLabel = str(o["format_label"]), status = str(o["status"]),
                currentRound = o["current_round"]!!.jsonPrimitive.int, numberOfRounds = o["number_of_rounds"]!!.jsonPrimitive.int,
                startsAt = str(o["starts_at"]), venueName = str(o["venue_name"]), stage = str(o["stage"]))
            assertEquals(o["want"]!!.jsonPrimitive.content, e.detail)
        }
    }

    @Test fun decodes() {
        assertEquals(EventFollow(true, false, true), json.decodeFromString(EventFollow.serializer(), """{"following": true, "notify": false, "can_follow": true}"""))
        val p = json.decodeFromString(EventPage.serializer(), """{"event_id": "e", "sign_up": "closed", "current_round": 2, "round": {"number": 2, "stage": "swiss", "status": "active"}, "rounds": [{"number": 2, "stage": "swiss", "status": "active", "matches": [{"match_id": "m", "table_number": 1, "is_bye": false, "status": "pending", "game_draws": 0, "sides": [{"side": 0, "display_name": "Ana", "game_wins": 0}, {"side": 1, "display_name": "Bo", "game_wins": 0}]}]}]}""")
        assertEquals(true, p.showsResults)
        assertEquals("Bo", p.matchupRounds.first().matches.first().name(1))
    }
}
