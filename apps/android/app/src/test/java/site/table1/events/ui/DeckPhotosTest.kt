package site.table1.events.ui

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test
import site.table1.events.ui.screens.deckPhotoSize
import site.table1.events.ui.screens.deckPhotoTurn
import site.table1.events.ui.screens.turnedSize
import java.io.File

/** Deck photos go up at most 2048 px on the long side, turned as the player set them, the same as iOS and web
 *  (DeckPhotoTests, deckPhotos.test.ts) against testdata/deck-photos/cases.json. */
class DeckPhotosTest {
    private val c = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/deck-photos") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

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
}
