package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/** Command zone rules (contract/command-zone-2026-10-27.md) against testdata/command-zone/cases.json (also iOS
 *  CommandZoneTests and web commandZone.test.ts). */
class CommandZoneTest {
    private val c = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/command-zone") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject
    private fun str(e: kotlinx.serialization.json.JsonElement) = if (e is JsonNull) null else e.jsonPrimitive.content

    @Test fun fits() {
        for (f in c["fits"]!!.jsonArray.map { it.jsonObject }) {
            val type = f["type"]!!.jsonPrimitive.content
            assertEquals(type, f["roles"]!!.jsonArray.map { it.jsonPrimitive.content }, CommandZone.Role.entries.filter { it.fits(type) }.map { it.wire })
        }
    }

    @Test fun slots() {
        for (s in c["slots"]!!.jsonArray.map { it.jsonObject }) {
            val lines = s["lines"]!!.jsonArray.map { it.jsonArray }.map { CommandZone.Line(it[0].jsonPrimitive.content, it[1].jsonPrimitive.content) }
            val want = s["slots"]!!.jsonArray.map { it.jsonArray }.map { listOf(it[0].jsonPrimitive.content, str(it[1])) }
            val got = CommandZone.slots(s["format"]!!.jsonPrimitive.content, lines).map { listOf(it.role.wire, it.cardId) }
            assertEquals(s["name"]!!.jsonPrimitive.content, want, got)
        }
    }

    @Test fun filling() {
        for (f in c["filling"]!!.jsonArray.map { it.jsonObject }) {
            val lines = f["lines"]!!.jsonArray.map { CommandZone.Line(it.jsonPrimitive.content, "") }
            val got = CommandZone.filling(lines, str(f["slot"]!!), CommandZone.Line(f["card"]!!.jsonPrimitive.content, "")).map { it.cardId }
            assertEquals(f["name"]!!.jsonPrimitive.content, f["result"]!!.jsonArray.map { it.jsonPrimitive.content }, got)
        }
    }

    @Test fun roleNames() {
        for (r in c["role"]!!.jsonArray.map { it.jsonObject }) {
            assertEquals(r["role"]!!.jsonPrimitive.content, CommandZone.roleName(r["format"]!!.jsonPrimitive.content, r["type"]!!.jsonPrimitive.content))
        }
    }

    @Test fun inDeck() {
        for (d in c["in_deck"]!!.jsonArray.map { it.jsonObject }) {
            val role = CommandZone.Role.entries.first { it.wire == d["role"]!!.jsonPrimitive.content }
            val lines = d["lines"]!!.jsonArray.map { it.jsonArray }.map {
                CommandZone.DeckLine(it[0].jsonPrimitive.content, it[1].jsonPrimitive.content, it[2].jsonPrimitive.content)
            }
            assertEquals(d["name"]!!.jsonPrimitive.content, d["result"]!!.jsonArray.map { it.jsonPrimitive.content },
                CommandZone.inDeck(role, lines).map { it.cardId })
        }
    }

    @Test fun movingIn() {
        for (m in c["move_in"]!!.jsonArray.map { it.jsonObject }) {
            val card = m["card"]!!.jsonArray
            val line = CommandZone.DeckLine(card[0].jsonPrimitive.content, card[1].jsonPrimitive.content, "", qty = card[2].jsonPrimitive.content.toInt())
            val got = CommandZone.movingIn(line, CommandZone.Slot(CommandZone.Role.Commander, str(m["slot"]!!))).map { op ->
                when (op) {
                    is CommandZone.Op.Move -> listOf("move", op.cardId, op.from, op.to)
                    is CommandZone.Op.Delta -> listOf("delta", op.cardId, op.board, op.by.toString())
                }
            }
            val want = m["ops"]!!.jsonArray.map { o -> o.jsonArray.map { it.jsonPrimitive.content } }
            assertEquals(m["name"]!!.jsonPrimitive.content, want, got)
        }
    }
}
