package site.table1.events.ui

import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import site.table1.events.ui.screens.DeckListBrief
import site.table1.events.ui.screens.DeckListEntry
import site.table1.events.ui.screens.DeckPhoto
import site.table1.events.ui.screens.DeckPhotoList
import site.table1.events.ui.screens.DeckPhotoListData
import java.io.File

/** The decklist read from a deck photo (contract/deck-photo-lists-2026-11-13.md § Clients, Rules) against
 *  testdata/deck-photo-lists/cases.json from make_cases.py (also iOS DeckPhotoListTests and web deckPhotoList.test.ts). */
class DeckPhotoListTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val c = Json.parseToJsonElement(
        File(generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "testdata/deck-photo-lists") }.first { it.isDirectory }, "cases.json").readText(),
    ).jsonObject

    private fun cases(name: String): List<JsonObject> = c[name]!!.jsonArray.map { it.jsonObject }.also { assertTrue(name, it.isNotEmpty()) }
    private fun JsonObject.text(key: String): String? = this[key]?.takeIf { it != JsonNull }?.jsonPrimitive?.contentOrNull
    private fun JsonObject.num(key: String): Int? = this[key]?.takeIf { it != JsonNull }?.jsonPrimitive?.intOrNull
    private fun entries(el: JsonElement): List<DeckListEntry> = json.decodeFromJsonElement(ListSerializer(DeckListEntry.serializer()), el)

    @Test fun rowUnderAPhoto() {
        for (r in cases("row")) {
            val brief = r["brief"]?.takeIf { it != JsonNull }?.let { json.decodeFromJsonElement(DeckListBrief.serializer(), it) }
            assertEquals(r.text("text"), DeckPhotoList.row(brief))
        }
    }

    @Test fun targetCountsAndSizeLine() {
        for (t in cases("target")) {
            assertEquals("${t.text("event_type")} ${t.text("format")}", t.num("target"), DeckPhotoList.target(t.text("event_type"), t.text("format")))
        }
        for (k in cases("counts")) {
            val got = DeckPhotoList.counts(entries(k["entries"]!!))
            val want = k["counts"]!!.jsonObject
            assertEquals(DeckPhotoList.Counts(want.num("main")!!, want.num("side")!!, want.num("out")!!, want.num("check")!!), got)
        }
        for (s in cases("sizeLine")) assertEquals(s.text("text"), DeckPhotoList.sizeLine(s.num("main")!!, s.num("target")))
    }

    @Test fun edits() {
        val all = cases("edits")
        assertTrue(all.size > 10)
        for (e in all) {
            val op = e.text("op")!!
            val before = entries(e["entries"]!!)
            val card = e["card"]?.takeIf { it != JsonNull }?.jsonObject?.let { DeckPhotoList.Card(it.text("card_id")!!, it.text("name")!!) }
            val got = when (op) {
                "setQty" -> DeckPhotoList.setQty(before, e.num("i")!!, e.num("qty")!!)
                "move" -> DeckPhotoList.move(before, e.num("i")!!, e.text("board")!!)
                "replace" -> DeckPhotoList.replace(before, e.num("i")!!, card!!)
                "confirm" -> DeckPhotoList.confirm(before, e.num("i")!!)
                "add" -> DeckPhotoList.add(before, card!!, e.text("board")!!)
                else -> error("unknown op $op")
            }
            assertEquals("$op ${e.num("i")}", entries(e["out"]!!), got)
        }
    }

    @Test fun intoADeck() {
        for (d in cases("deckEntries")) {
            val got = DeckPhotoList.deckEntries(entries(d["entries"]!!))
            val out = d["out"]!!.jsonObject
            val want = out["entries"]!!.jsonArray.map { it.jsonArray }.map { Triple(it[0].jsonPrimitive.content, it[1].jsonPrimitive.content, it[2].jsonPrimitive.int) }
            assertEquals(want, got.entries.map { Triple(it.cardId, it.board, it.qty) })
            assertEquals(out.num("skipped"), got.skipped)
        }
        for (n in cases("deckName")) {
            assertEquals(n.text("name"), DeckPhotoList.deckName(n.text("event"), n.text("player"), n["mine"]!!.jsonPrimitive.booleanOrNull == true))
        }
        for (f in cases("deckFormat")) assertEquals(f.text("deck"), DeckPhotoList.deckFormat(f.text("event_type"), f.text("format")))
        assertEquals("1 line without a card was left out.", DeckPhotoList.skippedLine(1))
        assertEquals("2 lines without a card were left out.", DeckPhotoList.skippedLine(2))
    }

    @Test fun entriesDecodeLeniently() {
        val got = entries(Json.parseToJsonElement(
            """[{"name": "Island", "qty": 3, "board": "weird"}, {"card_id": "x", "name": "Bolt", "qty": 1, "board": "out", "sure": false, "read": "blurred"}, {"card_id": null, "name": "Room of"}]"""))
        assertEquals(listOf(
            DeckListEntry(null, "Island", 3, "main"),
            DeckListEntry("x", "Bolt", 1, "out", sure = false, read = "blurred"),
            DeckListEntry(null, "Room of", 1, "main"),
        ), got)
        // As deck_photo_list_save takes a line: no card_id or read when there is none.
        assertEquals("""{"name":"Island","qty":3,"board":"main","sure":true}""", got[0].json.toString())
        assertEquals("""{"card_id":"x","name":"Bolt","qty":1,"board":"out","sure":false,"read":"blurred"}""", got[1].json.toString())
    }

    @Test fun readsTheServersShapes() {
        val photo = json.decodeFromString(DeckPhoto.serializer(),
            """{"id": "d1", "participant_id": "p1", "path": "e/d1.jpg", "list": {"status": "done", "cards": 40, "check": 2, "checked": false}}""")
        assertEquals("Decklist · 40 cards · 2 to check", DeckPhotoList.row(photo.list))
        assertEquals("Read decklist", DeckPhotoList.row(json.decodeFromString(DeckPhoto.serializer(), """{"id": "d2", "participant_id": "p1", "path": "e/d2.jpg"}""").list))
        val d = json.decodeFromString(DeckPhotoListData.serializer(), """{"photo_id": "d1", "event_id": "e1", "participant_id": "p1", "player": "Bea",
            "path": "e1/d1.jpg", "turns": 1, "note": "", "status": "reading", "steps": ["Looking at the photo"], "entries": [], "message": null,
            "notes": null, "pool": {"kind": "set", "label": "Reality Fracture · 285 cards", "size": 285}, "checked": false, "editable": true,
            "mine": true, "reads_left": 4, "finished_at": null, "event": {"name": "Friday draft", "format": "draft", "event_type": "limited", "format_label": "Draft"}}""")
        assertTrue(d.reading)
        assertEquals(listOf(4, 1, 285), listOf(d.readsLeft, d.turns, d.pool?.size))
        assertEquals(40, DeckPhotoList.target(d.event?.eventType, d.event?.format))
        assertEquals("Friday draft", DeckPhotoList.deckName(d.event?.name, d.player, d.mine == true))
    }
}
