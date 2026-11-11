package site.table1.events.ui

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test
import kotlinx.serialization.json.jsonPrimitive as prim
import site.table1.events.ui.screens.DeckPhoto
import site.table1.events.ui.screens.DeckPhotoPrompt
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.contentOrNull
import site.table1.events.ui.screens.MyDeckPhotoRules
import site.table1.events.ui.screens.MyDeckPhotos
import site.table1.events.ui.screens.deckPhotoFileName
import site.table1.events.ui.screens.deckPhotoSize
import site.table1.events.ui.screens.deckPhotoTurn
import site.table1.events.ui.screens.turnedSize
import java.io.File
import java.time.ZoneId

/** Deck photos go up at most 2048 px on the long side, turned as the player set them, the same as iOS and web
 *  (DeckPhotoTests, deckPhotos.test.ts) against testdata/deck-photos/cases.json. */
class DeckPhotosTest {
    private val c = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/deck-photos") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

    /** Long press → Share names the file after the player (iOS DeckPhotoTurns.fileName says the same). */
    @Test fun shareFileNameIsThePlayers() {
        assertEquals("Deck photo - Ann Ito.jpg", deckPhotoFileName("Ann Ito"))
        assertEquals("Deck photo - Zoë OBrien  2.jpg", deckPhotoFileName("Zoë O'Brien / 2"))
        assertEquals("Deck photo.jpg", deckPhotoFileName(" ?! "))
    }

    @Test fun bringsTheLongestSideDownTo2048() {
        assertEquals(2048 to 1536, deckPhotoSize(4032, 3024))
        assertEquals(1536 to 2048, deckPhotoSize(3024, 4032))
    }

    @Test fun neverUpscales() {
        assertEquals(1200 to 900, deckPhotoSize(1200, 900))
    }

    @Test fun turnsStayWithinZeroToThree() {
        for (t in c["turn"]!!.jsonArray.map { it.jsonObject }) {
            val (turns, by, out) = listOf("turns", "by", "out").map { t[it]!!.jsonPrimitive.int }
            assertEquals("$turns by $by", out, deckPhotoTurn(turns, by))
        }
    }

    @Test fun aQuarterTurnSwapsTheSides() {
        for (s in c["size"]!!.jsonArray.map { it.jsonObject }) {
            val (w, h, turns) = listOf("width", "height", "turns").map { s[it]!!.jsonPrimitive.int }
            val out = s["out"]!!.jsonArray.map { it.jsonPrimitive.int }
            assertEquals("${w}x$h turned $turns", out[0] to out[1], turnedSize(deckPhotoSize(w, h), turns))
        }
    }

    // Account → Deck photos (§ 7 On your account): the row's summary and the screen's headings, same cases.
    @Test fun summarySaysPhotosAndEvents() {
        for (x in c["summary"]!!.jsonArray.map { it.jsonObject }) {
            assertEquals(x["out"]!!.prim.content, MyDeckPhotoRules.summary(x["total"]!!.prim.int, x["events"]!!.prim.int))
        }
    }

    @Test fun consecutivePhotosOfOneEventShareAHeading() {
        for (g in c["groups"]!!.jsonArray.map { it.jsonObject }) {
            val photos = g["photos"]!!.jsonArray.map { it.jsonObject }.map {
                DeckPhoto(id = it["id"]!!.prim.content, participantId = "p", path = it["id"]!!.prim.content,
                    eventId = it["event_id"]!!.prim.content, eventName = it["event_name"]!!.prim.content)
            }
            val want = g["out"]!!.jsonArray.map { it.jsonObject }.map {
                Triple(it["event_id"]!!.prim.content, it["title"]!!.prim.content, it["ids"]!!.jsonArray.map { i -> i.prim.content })
            }
            assertEquals(want, MyDeckPhotoRules.groups(photos).map { Triple(it.eventId, it.title, it.photos.map { p -> p.id }) })
        }
    }

    @Test fun readsTheServersRowsAndLeavesOutAFormatTheNameSays() {
        val json = Json { ignoreUnknownKeys = true }
        val mine = json.decodeFromString(MyDeckPhotos.serializer(), """{"total": 1, "events": 1, "photos": [{"id": "d1", "participant_id": "p1", "player": "Bea", "path": "e/d1.jpg", "note": "", "created_at": "2026-11-06T10:00:00.123456+00:00", "turns": 1, "mine": true, "editable": true, "event_id": "e1", "event_name": "Old", "event_status": "completed", "format_label": "Draft", "event_at": "2026-10-29T18:00:00+00:00"}]}""")
        val p = mine.photos.single()
        assertEquals("e1/completed/1", "${p.eventId}/${p.eventStatus}/${p.turns}")
        assertEquals("29 Oct 2026 · Draft", MyDeckPhotoRules.detail(p, ZoneId.of("UTC")))
        assertEquals("29 Oct 2026", MyDeckPhotoRules.detail(p.copy(eventName = "Thursday Draft"), ZoneId.of("UTC")))
    }

    /** Add a deck photo once your last match is in (§ 7), against testdata/deck-photos/prompt.json (make_prompt.py). */
    @Test fun promptFollowsTheSharedCases() {
        val dir = generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/deck-photos") }.first { it.isDirectory }
        val cases = Json.parseToJsonElement(File(dir, "prompt.json").readText()).jsonObject["cases"]!!.jsonArray
        assert(cases.size > 10)
        for (el in cases) {
            val o = el.jsonObject
            val name = o["name"]!!.prim.content
            val event = o["event"]!!.jsonObject
            val me = o["me"]?.takeIf { it != JsonNull }?.jsonObject
            val played = o["rounds"]!!.jsonArray.map { r ->
                val ro = r.jsonObject
                val m = ro["mine"]?.takeIf { it != JsonNull }?.jsonObject
                DeckPhotoPrompt.Played(ro["number"]!!.prim.int, ro["stage"]?.prim?.contentOrNull,
                    m?.let { DeckPhotoPrompt.Mine(it["bye"]!!.prim.booleanOrNull == true, it["status"]!!.prim.content, it["my"]!!.prim.int, it["their"]!!.prim.int) })
            }
            val why = DeckPhotoPrompt.done(event["status"]!!.prim.content, event["rounds"]!!.prim.int, event["top_cut"]?.prim?.intOrNull ?: 0,
                me != null, me?.get("status")?.prim?.content, me?.get("dropped_in_round")?.prim?.intOrNull, played)
            assertEquals(name, o["why"]?.prim?.contentOrNull, why)
            assertEquals(name, o["show"]?.prim?.contentOrNull, DeckPhotoPrompt.show(why, if (o["photo"]!!.prim.booleanOrNull == true) 1 else 0))
        }
        assertEquals("Last match in", DeckPhotoPrompt.label("last"))
    }
}
