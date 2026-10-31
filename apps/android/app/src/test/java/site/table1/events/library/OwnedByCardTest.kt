package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/** Owning a card in any printing and Match collection (contract/owned-by-card-2026-10-31.md) against
 *  testdata/owned-by-card/cases.json (also iOS OwnedByCardTests and web ownedByCard.test.ts). */
class OwnedByCardTest {
    private val c = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/owned-by-card") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject
    private val basics = c["basics"]!!.jsonArray.map { it.jsonPrimitive.content }.toSet()

    private fun str(o: JsonObject, k: String) = o[k]!!.jsonPrimitive.content
    private fun ints(o: JsonObject, k: String) = o[k]!!.jsonObject.mapValues { it.value.jsonPrimitive.int }
    private fun strs(o: JsonObject, k: String) = o[k]!!.jsonObject.mapValues { it.value.jsonPrimitive.content }
    private fun need(o: JsonObject) = OwnedByCard.Need(str(o, "card_id"), str(o, "board"), str(o, "finish"), o["qty"]!!.jsonPrimitive.int,
        o["lang"]?.jsonPrimitive?.content ?: "en")
    private fun needs(o: JsonObject, k: String) = o[k]!!.jsonArray.map { need(it.jsonObject) }

    @Test fun shorts() {
        for (x in c["shorts"]!!.jsonArray.map { it.jsonObject }) {
            assertEquals(str(x, "name"), x["shorts"]!!.jsonArray.map { it.jsonPrimitive.int },
                OwnedByCard.shorts(needs(x, "lines"), Holdings(ints(x, "owned"), strs(x, "oracles")), basics))
        }
    }

    @Test fun missingLines() {
        val l = c["lines"]!!.jsonObject
        val lists = l["lists"]!!.jsonArray.map { it.jsonObject }.filter { it["event"]?.jsonPrimitive?.content != "true" }
            .map { str(it, "name") to needs(it, "entries") }
        val got = OwnedByCard.lines(lists, Holdings(ints(l, "owned"), strs(l, "oracles")), basics)
        val want = l["expect"]!!.jsonArray.map { it.jsonObject }.map { m ->
            "${str(m, "card_id")}|${str(m, "finish")}|${m["short"]!!.jsonPrimitive.int}|${m["lists"]!!.jsonArray.joinToString("+") { it.jsonPrimitive.content }}"
        }
        assertEquals(want, got.map { "${it.cardId}|${it.finish}|${it.short}|${it.lists.joinToString("+")}" })
    }

    @Test fun addToCollection() {
        for (x in c["add"]!!.jsonArray.map { it.jsonObject }) {
            val entries = needs(x, "entries").map { ListEntry(it.cardId, it.board, it.qty, it.finish, it.lang) }
            val kind = if (str(x, "kind") == "deck") ListKind.Deck else ListKind.Cube
            val mode = if (str(x, "mode") == "all") ListToCollection.Mode.All else ListToCollection.Mode.Missing
            val want = x["ops"]!!.jsonArray.map { it.jsonObject }.map {
                ListToCollection.Op(str(it, "card_id"), str(it, "finish"), it["delta"]!!.jsonPrimitive.int, it["lang"]?.jsonPrimitive?.content ?: "en")
            }
            assertEquals(str(x, "name"), want, ListToCollection.ops(entries, kind, ints(x, "owned"), mode, cardOf = strs(x, "oracles")))
        }
    }

    @Test fun matchCollection() {
        for (x in c["match"]!!.jsonArray.map { it.jsonObject }) {
            val name = str(x, "name")
            val lines = needs(x, "lines")
            val versions = x["versions"]!!.jsonArray.map { it.jsonObject }.map { OwnedByCard.Version(str(it, "card_id"), str(it, "finish"), it["owned"]!!.jsonPrimitive.int) }
            fun picks(k: String) = x[k]!!.jsonArray.map { it.jsonObject }.map { OwnedByCard.Pick(str(it, "card_id"), str(it, "finish"), it["qty"]!!.jsonPrimitive.int) }
            var got = OwnedByCard.autoMatch(lines, versions)
            assertEquals(name, picks("auto"), got)
            val total = lines.sumOf { it.qty }
            for (t in x["taps"]!!.jsonArray.map { a -> a.jsonArray.map { it.jsonPrimitive.content } }) got = OwnedByCard.tap(got, versions, total, t[0], t[1])
            assertEquals(name, picks("picks"), got)
            val want = x["ops"]!!.jsonArray.map { it.jsonObject }.map {
                OwnedByCard.Move(str(it, "card_id"), str(it, "finish"), it["lang"]?.jsonPrimitive?.content ?: "en", str(it, "to_card_id"), str(it, "to_finish"),
                    it["qty"]!!.jsonPrimitive.int)
            }
            assertEquals(name, want, OwnedByCard.matchOps(lines, got))
        }
    }
}
