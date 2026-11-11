package site.table1.events.tracker

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.float
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The life tracker's touch rule (contract/life-tracker-options-2026-10-20.md § Taps and the pull band) against
 * testdata/tracker-touch/cases.json (also iOS TrackerTouchTests and web trackerTouch.test.ts): a tap always
 * counts however far it drifts; only a touch that starts in the band along the player's far edge and travels
 * toward them opens the counter picker. Cases are in dp; density 1 here.
 */
class TrackerTouchTest {
    private val c = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/tracker-touch") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

    private fun f(key: String) = c[key]!!.jsonPrimitive.float

    @Test fun sharedConstants() {
        assertEquals(f("band"), TrackerTouch.BAND_DP)
        assertEquals(f("swipe"), TrackerTouch.SWIPE_DP)
        assertEquals(f("holdSlop"), TrackerTouch.HOLD_SLOP_DP)
        assertEquals(f("moved"), TrackerTouch.MOVED_DP)
    }

    @Test fun touches() {
        val touches = c["touches"]!!.jsonArray.map { it.jsonObject }
        assertTrue(touches.isNotEmpty())
        for (t in touches) {
            val note = t["note"]!!.jsonPrimitive.content
            val seat = TrackerSeat.valueOf(t["seat"]!!.jsonPrimitive.content.replaceFirstChar { it.uppercase() })
            val (w, h) = t["box"]!!.jsonArray.map { it.jsonPrimitive.float }
            val (x, y) = t["start"]!!.jsonArray.map { it.jsonPrimitive.float }
            val (dx, dy) = t["move"]!!.jsonArray.map { it.jsonPrimitive.float }
            assertEquals(note, t["far"]!!.jsonPrimitive.float, seat.far(x, y, w, h))
            assertEquals(note, t["band"]!!.jsonPrimitive.boolean, TrackerTouch.inBand(seat, x, y, w, h, TrackerTouch.BAND_DP))
            assertEquals(note, t["pull"]!!.jsonPrimitive.boolean,
                TrackerTouch.pulls(seat, x, y, w, h, dx, dy, TrackerTouch.BAND_DP, TrackerTouch.SWIPE_DP))
            assertEquals(note, t["holds"]!!.jsonPrimitive.boolean, TrackerTouch.holds(dx, dy, TrackerTouch.HOLD_SLOP_DP))
        }
    }

    @Test fun statsResetAfterTake() {
        TrackerTouchStats.take(2, "local")
        TrackerTouchStats.taps = 3
        TrackerTouchStats.moved = 1
        val props = TrackerTouchStats.take(2, "local")!!
        assertEquals(3, props["taps"])
        assertEquals(1, props["moved"])
        assertEquals(null, TrackerTouchStats.take(2, "local"))
    }
}
