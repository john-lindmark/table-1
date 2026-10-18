package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File

/*
 * Deck and cube export (contract/lists-2026-10-15.md, Export). Same cases as apps/ios/Table1Tests/ListExportTests.swift
 * and web listExport.test.ts. testdata/list-export/lists.json is a deck and a cube of real printings from the test
 * pack; each format must come out as the file next to it byte for byte. list-import's parser reads those files as
 * parsed.json (supabase/functions/list-import/parse.test.ts), and here those lines resolve back to the same entries:
 * export → paste → import gives the list back.
 */

private val dir: File = generateSequence(File("").absoluteFile) { it.parentFile }
    .map { File(it, "testdata/list-export") }.first { it.isDirectory }

private fun file(name: String) = File(dir, name).readText()

private object Fixture {
    private val json = Json.parseToJsonElement(file("lists.json")).jsonObject
    val cards: Map<String, ListExport.Card> = json["cards"]!!.jsonObject.mapValues { (_, v) ->
        val o = v.jsonObject
        fun s(k: String) = o[k]!!.jsonPrimitive.content
        ListExport.Card(s("name"), s("type_line"), o["cmc"]!!.jsonPrimitive.double, s("colors"), s("set"), s("cn"), s("rarity"))
    }
    private fun entries(key: String) = json[key]!!.jsonObject["entries"]!!.jsonArray.map { e ->
        val a = e.jsonArray
        ListEntry(a[0].jsonPrimitive.content, a[1].jsonPrimitive.content, a[2].jsonPrimitive.int, a.getOrNull(3)?.jsonPrimitive?.content ?: "nonfoil")
    }
    val deck = entries("deck")
    val cube = entries("cube")
    fun lines(es: List<ListEntry>) = es.map { ListExport.Line(cards[it.cardId]!!, it.board, it.qty, it.finish) }
}

class ListExportTest {
    @Test
    fun eachFormatMatchesTheFixture() {
        for ((name, kind, format) in listOf(
            Triple("deck.arena.txt", ListKind.Deck, ListExport.Format.Arena), Triple("deck.moxfield.txt", ListKind.Deck, ListExport.Format.Moxfield),
            Triple("deck.mtgo.txt", ListKind.Deck, ListExport.Format.Mtgo), Triple("deck.text.txt", ListKind.Deck, ListExport.Format.Text),
            Triple("cube.cubecobra.csv", ListKind.Cube, ListExport.Format.CubeCobra), Triple("cube.text.txt", ListKind.Cube, ListExport.Format.Text),
        )) {
            val list = if (kind == ListKind.Deck) Fixture.deck else Fixture.cube
            // Input order mustn't matter.
            assertEquals(name, file(name), ListExport.render(Fixture.lines(list).reversed(), kind, format))
        }
    }

    @Test
    fun names() {
        fun card(name: String, type: String, set: String = "", cn: String = "") = ListExport.Card(name, type, 0.0, "", set, cn, "")
        assertEquals("Fire // Ice", ListExport.name(card("Fire // Ice", "Instant // Instant")))
        assertEquals("Alive // Well", ListExport.name(card("Alive // Well", "Enchantment — Room // Enchantment — Room")))
        assertEquals("There // They're // Their", ListExport.name(card("There // They're // Their", "Instant — Lesson // Instant — Lesson // Instant — Lesson")))
        assertEquals("Bonecrusher Giant", ListExport.name(card("Bonecrusher Giant // Stomp", "Creature — Giant // Instant — Adventure")))
        assertEquals("Petty Theft Test", ListExport.name(card("Petty Theft Test // Theft", "Instant // Instant — Adventure")))
        assertEquals("Agadeem's Awakening", ListExport.name(card("Agadeem's Awakening // Agadeem, the Undercrypt", "Sorcery // Land")))
        assertNull(ListExport.printing(card("Jaya", "", "pmps08", "a1 2007")))
        assertEquals("(PMPS08) a1_2007", ListExport.printing(card("Jaya", "", "pmps08", "a1_2007")))
    }

    @Test
    fun emptyAndFileNames() {
        assertEquals("", ListExport.render(emptyList(), ListKind.Deck, ListExport.Format.Arena))
        assertEquals(ListExport.CUBE_COBRA_HEADER + "\r\n", ListExport.render(emptyList(), ListKind.Cube, ListExport.Format.CubeCobra))
        assertEquals("Izzet Tempo test.txt", ListExport.fileName("Izzet: \"Tempo\" / test", ListKind.Deck, ListExport.Format.Mtgo))
        assertEquals("cube.csv", ListExport.fileName("///", ListKind.Cube, ListExport.Format.CubeCobra))
    }

    /** The catalog gives each entry the card the fixture says (the test pack trims cmc and colors). */
    @Test
    fun linesFromTheCatalog() {
        val (lines, left) = ListExport.lines(Fixture.deck + ListEntry("not-a-card", "main", 3), testPack)
        assertEquals(3, left)
        fun pick(l: ListExport.Line) = listOf(l.card.name, l.card.typeLine, l.card.set, l.card.cn, l.card.rarity, l.board, l.qty, l.finish)
        assertEquals(Fixture.lines(Fixture.deck).map(::pick), lines.map(::pick))
    }

    /** What the server's parser reads from each file resolves back to the list. */
    @Test
    fun roundTrip() {
        val parsed = Json.parseToJsonElement(file("parsed.json")).jsonObject.mapValues { (_, v) ->
            v.jsonArray.map { Json { ignoreUnknownKeys = true }.decodeFromJsonElement<ImportedList.Line>(it) }
        }
        fun resolve(name: String, kind: ListKind) = resolveImport(parsed[name]!!, kind, testPack)
        val key = { e: ListEntry -> "${e.board}|${e.cardId}|${e.finish}|${e.qty}" }
        // Moxfield and Cube Cobra carry everything: the same printings, finishes, sections and counts.
        assertEquals(Fixture.deck.map(key).sorted(), resolve("deck.moxfield.txt", ListKind.Deck).entries.map(key).sorted())
        assertEquals(Fixture.cube.map(key).sorted(), resolve("cube.cubecobra.csv", ListKind.Cube).entries.map(key).sorted())
        // Arena: the same printings and sections, non-foil, without Considering.
        val arena = Fixture.deck.filter { it.board != "maybe" }.groupBy { it.board to it.cardId }
            .map { (k, es) -> ListEntry(k.second, k.first, es.sumOf { it.qty }) }
        assertEquals(arena.map(key).sorted(), resolve("deck.arena.txt", ListKind.Deck).entries.map(key).sorted())
        // Names only: every card is found, with the same counts per section.
        for ((name, kind, want) in listOf(
            Triple("deck.text.txt", ListKind.Deck, Fixture.deck), Triple("cube.text.txt", ListKind.Cube, Fixture.cube),
            Triple("deck.mtgo.txt", ListKind.Deck, Fixture.deck.filter { it.board != "maybe" }),
        )) {
            val r = resolve(name, kind)
            assertEquals(name, emptyList<String>(), r.missing)
            fun counts(es: List<ListEntry>) = es.groupBy { if (name == "deck.mtgo.txt" && it.board == "commander") "side" else it.board }
                .mapValues { (_, v) -> v.sumOf { it.qty } }
            assertEquals(name, counts(want), counts(r.entries))
        }
    }
}
