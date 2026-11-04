package site.table1.events.tracker

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import site.table1.events.data.TrackerGame
import site.table1.events.data.TrackerOp
import java.io.File
import java.time.Instant

/**
 * The life tracker's table setup, seats and commander damage (contract/life-tracker-commander-2026-11-03.md)
 * against testdata/tracker-table/cases.json (also iOS TrackerTableTests and web trackerTable.test.ts).
 */
class TrackerTableTest {
    private val c = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/tracker-table") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

    private fun cases(name: String) = c[name]!!.jsonArray.map { it.jsonObject }
    private fun ints(e: JsonObject, key: String) = e[key]!!.jsonArray.map { it.jsonPrimitive.int }
    private val t0 = Instant.parse("2026-11-03T00:00:00Z")

    private fun ops(e: JsonObject): List<TrackerOp> = e["ops"]!!.jsonArray.mapIndexed { i, o ->
        val op = o.jsonObject
        val at = op["at"]?.jsonPrimitive?.intOrNull ?: i
        TrackerOp("op-$i", 1, op["side"]!!.jsonPrimitive.int, op["counter"]!!.jsonPrimitive.content,
            op["delta"]!!.jsonPrimitive.int, t0.plusMillis(at.toLong()).toString())
    }

    private fun table(players: Int, life: Int, ops: List<TrackerOp> = emptyList()) =
        TrackerDoc(key = "local", mySide = 0, names = TrackerTable.names(players), startingLife = life, ops = ops)

    @Test fun setupChoices() {
        val setup = c["setup"]!!.jsonObject
        assertEquals(ints(setup, "players"), TrackerTable.playerChoices)
        assertEquals(ints(setup, "lives"), TrackerTable.lifeChoices)
        assertEquals(setup["commanderFrom"]!!.jsonPrimitive.int, TrackerTable.COMMANDER_FROM)
        assertEquals(setup["commanderLoss"]!!.jsonPrimitive.int, TrackerTable.COMMANDER_LOSS)
    }

    @Test fun namesAndLayouts() {
        cases("names").forEach { n ->
            assertEquals(n["names"]!!.jsonArray.map { it.jsonPrimitive.content }, TrackerTable.names(n["players"]!!.jsonPrimitive.int))
        }
        cases("layouts").forEach { l ->
            val expected: List<TrackerRow> = l["rows"]!!.jsonArray.map { row ->
                if (row is JsonPrimitive) null else (row as JsonArray).map { p ->
                    val o = p.jsonObject
                    TrackerPlace(o["side"]!!.jsonPrimitive.int, TrackerSeat.valueOf(o["seat"]!!.jsonPrimitive.content.replaceFirstChar { it.uppercase() }))
                }
            }
            assertEquals(expected, TrackerTable.layout(l["players"]!!.jsonPrimitive.int))
        }
    }

    @Test fun commanderKeys() {
        assertEquals(3, commanderFrom("cmd:3"))
        assertNull(commanderFrom("life"))
        assertNull(commanderFrom("cmd:"))
        assertNull(commanderFrom("cmd:-1"))
    }

    @Test fun pickerRows() {
        cases("picker").forEach { p ->
            val d = table(p["players"]!!.jsonPrimitive.int, p["life"]!!.jsonPrimitive.int)
            assertEquals(p["rows"]!!.jsonArray.map { it.jsonPrimitive.content }, d.pickerCounters(p["side"]!!.jsonPrimitive.int).map { it.id })
        }
    }

    @Test fun labels() {
        cases("labels").forEach { l ->
            val kind = table(l["players"]!!.jsonPrimitive.int, 40).counterKind(l["counter"]!!.jsonPrimitive.content)!!
            assertEquals(l["label"]!!.jsonPrimitive.content, kind.label)
            assertEquals(l["short"]!!.jsonPrimitive.content, kind.shortLabel)
        }
    }

    @Test fun commanderDamageComesOffLife() {
        cases("totals").forEach { t ->
            val d = table(t["players"]!!.jsonPrimitive.int, t["life"]!!.jsonPrimitive.int, ops(t))
            assertEquals(ints(t, "lifeTotals"), d.sides.map { d.total(1, it, "life") })
            t["counters"]!!.jsonArray.map { it.jsonObject }.forEach { v ->
                assertEquals(v["value"]!!.jsonPrimitive.int, d.total(1, v["side"]!!.jsonPrimitive.int, v["counter"]!!.jsonPrimitive.content))
            }
        }
    }

    @Test fun losingAndTheSettledWinner() {
        cases("losing").forEach { l ->
            val d = table(l["players"]!!.jsonPrimitive.int, l["life"]!!.jsonPrimitive.int, ops(l))
            assertEquals(ints(l, "lost"), d.sides.filter { d.hasLost(it) })
            assertEquals(l["winner"]?.jsonPrimitive?.intOrNull, d.settledWinner())
        }
    }

    @Test fun lifeGroupsCountCommanderDamage() {
        cases("groups").forEach { g ->
            val d = table(g["players"]!!.jsonPrimitive.int, g["life"]!!.jsonPrimitive.int, ops(g))
            val expected = g["groups"]!!.jsonArray.map { it.jsonObject }.map {
                listOf(it["side"]!!.jsonPrimitive.int, it["counter"]!!.jsonPrimitive.content, it["delta"]!!.jsonPrimitive.int, it["after"]!!.jsonPrimitive.int)
            }
            assertEquals(expected, d.groups(1).map { listOf(it.side, it.counter, it.delta, it.after) })
            assertEquals(ints(g, "lifeTotals"), d.sides.map { d.total(1, it, "life") })
        }
    }

    @Test fun scoreText() {
        cases("score").forEach { s ->
            val d = table(s["players"]!!.jsonPrimitive.int, 20).copy(
                games = ints(s, "winners").mapIndexed { i, w -> TrackerGame(i + 1, w, false, null) },
            )
            assertEquals(s["text"]!!.jsonPrimitive.content, d.scoreText)
        }
    }

    @Test fun commanderDamageOnlyForLocalTablesFrom30() {
        assertFalse(table(4, 20).commanderDamage)
        assertTrue(table(4, 30).commanderDamage)
        assertFalse(table(2, 40).copy(synced = true).commanderDamage)
        assertFalse(table(3, 40).decided)
    }

    @Test fun swipesTowardEachSeat() {
        assertEquals(30f, TrackerSeat.Bottom.toward(0f, 30f).first)
        assertEquals(30f, TrackerSeat.Top.toward(0f, -30f).first)
        assertEquals(30f, TrackerSeat.Left.toward(-30f, 0f).first)
        assertEquals(30f, TrackerSeat.Right.toward(30f, 0f).first)
    }

    @Test fun onlyASwipeTowardThePlayerOpensThePicker() {
        assertTrue(TrackerSeat.Bottom.opensPicker(0f, 30f, 24f))
        assertTrue(TrackerSeat.Top.opensPicker(0f, -30f, 24f))
        assertTrue(TrackerSeat.Left.opensPicker(-30f, 0f, 24f))
        assertTrue(TrackerSeat.Right.opensPicker(30f, 0f, 24f))
        // Swiping up (scrolling the picker's rows) is not a close.
        assertFalse(TrackerSeat.Bottom.opensPicker(0f, -60f, 24f))
        assertFalse(TrackerSeat.Top.opensPicker(0f, 60f, 24f))
        assertFalse(TrackerSeat.Bottom.opensPicker(0f, 20f, 24f))
        assertFalse(TrackerSeat.Bottom.opensPicker(30f, 30f, 24f))
    }
}
