package site.table1.events.data

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File

/** Drafts with several pods (contract/draft-pods-2026-11-09.md) against testdata/draft-pods/cases.json. */
class DraftPodsTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val cases: JsonObject by lazy {
        val dir = generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/draft-pods") }.first { it.isDirectory }
        json.parseToJsonElement(File(dir, "cases.json").readText()).jsonObject
    }
    private fun list(key: String) = cases[key]!!.jsonArray.map { it.jsonObject }
    private fun JsonObject.intOrNull(k: String) = this[k]!!.let { if (it is JsonNull) null else it.jsonPrimitive.int }
    private fun JsonObject.str(k: String) = this[k]!!.let { if (it is JsonNull) null else it.jsonPrimitive.content }
    private fun JsonObject.ints(k: String) = this[k]!!.jsonArray.map { it.jsonPrimitive.int }
    private fun seats(sizes: List<Int>) = sizes.map { n -> (1..n).toList() }
    private fun seatOf(id: String): DraftPods.Seat {
        val (p, s) = id.drop(1).split("S")
        return DraftPods.Seat(p.toInt() - 1, s.toInt())
    }

    @Test fun plansRoundsAndLabels() {
        for (c in list("plan")) {
            assertEquals(c.toString(), c.ints("want"), DraftPods.plan(c.intOrNull("players")!!, c.intOrNull("pods")))
        }
        for (c in list("rounds")) assertEquals(c.toString(), c.intOrNull("want"), DraftPods.rounds(c.ints("sizes"), c.str("pod_pairing")!!))
        for (c in list("label")) assertEquals(c.str("want"), DraftPods.label(c.intOrNull("players")!!, c.intOrNull("pods")))
        for (c in list("auto_label")) {
            assertEquals(c.toString(), c.str("want"), DraftPods.autoLabel(c.intOrNull("players")!!, c.intOrNull("pods"), c.str("pod_pairing")!!))
        }
    }

    @Test fun roundOneAcrossEveryPod() {
        for (c in list("round1")) {
            val plan = DraftPods.roundOne(seats(c.ints("sizes")))
            val want = c["want"]!!.jsonObject
            val wantPods = want["pods"]!!.jsonArray.map { it.jsonObject }
            assertEquals(wantPods.size, plan.pods.size)
            plan.pods.zip(wantPods).forEach { (got, w) ->
                assertEquals(w["pairs"]!!.jsonArray.map { p -> p.jsonArray.map { seatOf(it.jsonPrimitive.content).seat }.let { it[0] to it[1] } }, got.pairs)
                assertEquals(w.str("left")?.let { seatOf(it).seat }, got.left)
            }
            assertEquals(want["across"]!!.jsonArray.map { p -> p.jsonArray.map { seatOf(it.jsonPrimitive.content) }.let { it[0] to it[1] } }, plan.across)
            assertEquals(want.str("bye")?.let { seatOf(it) }, plan.bye)
        }
        for (c in list("note")) {
            val pod = c.intOrNull("pod")!!
            assertEquals(c.toString(), c.str("want"), DraftPods.note(seats(c.ints("sizes")), pod) { "Pod ${it + 1}" })
        }
    }

    @Test fun podCodes() {
        assertEquals("P3", DraftPods.code("Pod 3", 0))
        assertEquals("P2", DraftPods.code("Main", 1))
        assertEquals("P1", DraftPods.code(null, 0))
    }

    @Test fun eventDecodesPods() {
        val e = json.decodeFromString<EventRow>("""{"id":"e","short_code":"ABCD","name":"Draft","pods":2,"pod_pairing":"pod"}""")
        assertEquals(2, e.pods)
        assertEquals("pod", e.podPairing)
        val old = json.decodeFromString<EventRow>("""{"id":"e","short_code":"ABCD","name":"Draft"}""")
        assertNull(old.pods)
        assertEquals("a server without the column paired across pods", "cross", old.podPairing)
    }

    @Test fun podSections() {
        fun pods(c: JsonObject) = c["pods"]!!.jsonArray.map { it.jsonObject.str("id")!! to it.jsonObject.str("name") }
        fun want(c: JsonObject, items: String) = c["want"]!!.let { w ->
            if (w is JsonNull) null else w.jsonArray.map { it.jsonObject }.map { listOf(it.str("pod") ?: "-", it.str("title")!!) +
                it[items]!!.jsonArray.map { x -> x.jsonPrimitive.content } }
        }
        for (c in list("sections")) {
            val podOf = c["players"]!!.jsonObject.mapValues { (_, v) -> if (v is JsonNull) null else v.jsonPrimitive.content }
            val matches = c["matches"]!!.jsonArray.map { it.jsonObject }
            val got = DraftPods.sections(matches, pods(c), podOf, c.str("stage"),
                players = { m -> m["players"]!!.jsonArray.map { it.jsonPrimitive.content } }, table = { it.intOrNull("table") },
                isBye = { it["bye"]!!.jsonPrimitive.content == "true" })
            assertEquals(c.toString(), want(c, "matches"), got?.map { s -> listOf(s.pod ?: "-", s.title) + s.items.map { it.str("id")!! } })
        }
        for (c in list("player_sections")) {
            val players = c["players"]!!.jsonArray.map { it.jsonObject }
            val got = DraftPods.playerSections(players, pods(c), { it.str("pod") }, { it.intOrNull("seat") })
            assertEquals(c.toString(), want(c, "players"), got?.map { s -> listOf(s.pod ?: "-", s.title) + s.items.map { it.str("id")!! } })
        }
    }
}
