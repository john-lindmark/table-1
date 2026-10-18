package site.table1.events.library

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/*
 * Collection CSV import and export (contract/collection-import-2026-10-17.md). Same cases as iOS CollectionCSVTests.swift
 * and web collectionCsv.test.ts. The fixtures in testdata/collection-import are the same 24 cards as seven apps export
 * them; matching runs against the real catalog pack in testdata/scan (shortened ids, so lines match by set + collector
 * number or set + name there, as they would on a phone without Scryfall ids).
 */

internal val importFixtures: File = generateSequence(File("").absoluteFile) { it.parentFile }
    .map { File(it, "testdata/collection-import") }.first { it.isDirectory }

private fun fixture(name: String) = File(importFixtures, name).readText()

internal class ExpectedCard(val set: String, val cn: String, val name: String, val finish: String, val condition: String,
                            val lang: String, val qty: Int)

internal class Expected(val unmatched: String, val cards: List<ExpectedCard>) {
    companion object {
        fun load(): Expected {
            val o = Json.parseToJsonElement(fixture("expected.json")).jsonObject
            return Expected(o["unmatched"]!!.jsonPrimitive.content, o["cards"]!!.jsonArray.map { c ->
                val m = c.jsonObject
                fun s(k: String) = m[k]!!.jsonPrimitive.content
                ExpectedCard(s("set"), s("cn"), s("name"), s("finish"), s("condition"), s("lang"), m["qty"]!!.jsonPrimitive.int)
            })
        }
    }
}

/** The test pack (shared with the scanner tests) and the mtg_sets rows the fixtures need. */
internal object TestImportCatalog {
    val db: PackCatalog get() = testPack
    val setNames: List<Pair<String, String>> by lazy {
        Json.parseToJsonElement(fixture("sets.json")).jsonArray.map {
            it.jsonObject["code"]!!.jsonPrimitive.content to it.jsonObject["name"]!!.jsonPrimitive.content
        }
    }
}

class CollectionCSVParseTest {
    @Test
    fun quotingLineEndsAndBOM() {
        val p = CollectionCSV.parse("﻿Name,Set code,Collector number,Quantity\r\n\"Aragorn, the Uniter\",LTR,192,1\r\n\"Say \"\"Hi\"\"\nTwice\",M11,149,2\r\n\r\n")
        assertEquals(listOf("Aragorn, the Uniter", "Say \"Hi\"\nTwice"), p.rows.map { it.name })
        assertEquals(listOf("ltr", "m11"), p.rows.map { it.setCode })
        assertEquals(listOf(1, 2), p.rows.map { it.qty })
        assertEquals(listOf(2, 3), p.rows.map { it.line })
    }

    @Test
    fun delimiters() {
        val tab = CollectionCSV.parse("Name\tSet\tQuantity\nLightning Bolt\tm11\t3\n")
        assertEquals(3, tab.rows.first().qty)
        assertEquals("m11", tab.rows.first().setCode)
        val semi = CollectionCSV.parse("Name;Edition;Count\nLightning Bolt;Magic 2011;2\n")
        assertEquals("Magic 2011", semi.rows.first().setName)
        assertEquals(2, semi.rows.first().qty)
        val sep = CollectionCSV.parse("\"sep=;\"\nName;Quantity\nShock;4\n")
        assertEquals("Shock", sep.rows.first().name)
        assertEquals(3, sep.rows.first().line)
    }

    @Test
    fun noNameColumnIsRefused() {
        val e = assertThrows(CSVFailure::class.java) { CollectionCSV.parse("Set,Quantity\nm11,1\n") }
        assertEquals("This file has no card name column.", e.message)
        assertThrows(CSVFailure::class.java) { CollectionCSV.parse("") }
    }

    @Test
    fun detectsEveryFixture() {
        val cases = listOf("manabox.csv" to CSVFormat.ManaBox, "moxfield.csv" to CSVFormat.Moxfield, "archidekt.csv" to CSVFormat.Archidekt,
            "deckbox.csv" to CSVFormat.Deckbox, "dragonshield.csv" to CSVFormat.DragonShield, "tcgplayer.csv" to CSVFormat.TCGplayer,
            "delverlens.csv" to CSVFormat.DelverLens)
        for ((file, format) in cases) {
            val p = CollectionCSV.parse(fixture(file))
            assertEquals(file, format, p.format)
            assertEquals(file, 25, p.rows.size) // 24 cards and the unknown line
        }
        assertEquals(CSVFormat.Other, CollectionCSV.parse("Card,Qty\nShock,1\n").format)
    }

    @Test
    fun quantities() {
        assertEquals(2, CollectionCSV.quantity("2x"))
        assertEquals(12, CollectionCSV.quantity(" 12 "))
        assertEquals(1, CollectionCSV.quantity(""))
        assertNull(CollectionCSV.quantity("lots"))
        assertNull(CollectionCSV.quantity("-1"))
    }

    @Test
    fun badQuantityIsAProblemAndZeroIsSkipped() {
        val p = CollectionCSV.parse("Name,Quantity\nShock,lots\nBolt,0\nOpt,\n")
        assertEquals(listOf("Shock", "Opt"), p.rows.map { it.name })
        assertEquals("Quantity isn't a number", p.rows[0].problem)
        assertEquals(1, p.rows[1].qty)
    }

    @Test
    fun finishes() {
        for ((v, f) in listOf("" to "nonfoil", "normal" to "nonfoil", "Normal" to "nonfoil", "Non-foil" to "nonfoil", "false" to "nonfoil",
            "foil" to "foil", "Foil" to "foil", "Double Rainbow Foil" to "foil", "true" to "foil", "1" to "foil",
            "etched" to "etched", "Foil Etched" to "etched")) {
            assertEquals(v, f, CollectionCSV.finish(v))
        }
    }

    @Test
    fun conditionScales() {
        val us = listOf("Mint" to "NM", "Near Mint" to "NM", "NM" to "NM", "" to "NM", "weird" to "NM",
            "Lightly Played" to "LP", "Good (Lightly Played)" to "LP", "Excellent" to "LP",
            "Moderately Played" to "MP", "Played" to "MP", "Heavily Played" to "HP",
            "Damaged" to "DMG", "Poor" to "DMG", "D" to "DMG")
        for ((v, c) in us) assertEquals(v, c, CollectionCSV.condition(v, cardmarket = false))
        val cardmarket = listOf("mint" to "NM", "near_mint" to "NM", "NearMint" to "NM", "excellent" to "LP",
            "good" to "LP", "light_played" to "MP", "LightPlayed" to "MP", "played" to "HP",
            "Played" to "HP", "poor" to "DMG", "Damaged" to "DMG")
        for ((v, c) in cardmarket) assertEquals(v, c, CollectionCSV.condition(v, cardmarket = true))
    }

    @Test
    fun languages() {
        for ((v, l) in listOf("English" to "en", "EN" to "en", "de" to "de", "German" to "de", "Japanese" to "ja", "jp" to "ja",
            "Korean" to "ko", "Chinese Simplified" to "zhs", "Simplified Chinese" to "zhs", "zh_CN" to "zhs",
            "Traditional Chinese" to "zht", "zh-TW" to "zht", "Portuguese (Brazil)" to "pt", "Klingon" to "en", "" to "en")) {
            assertEquals(v, l, CollectionCSV.language(v))
        }
    }

    @Test
    fun formatSpecificColumns() {
        // Moxfield's Edition is a code; Deckbox's and Delver Lens's are names; TCGplayer's Set is a name.
        assertEquals("m11", CollectionCSV.parse(fixture("moxfield.csv")).rows[0].setCode)
        val deckbox = CollectionCSV.parse(fixture("deckbox.csv")).rows[0]
        assertEquals("Magic 2011", deckbox.setName)
        assertEquals("m11", deckbox.setCode)
        assertEquals("Magic 2011", CollectionCSV.parse(fixture("delverlens.csv")).rows[0].setName)
        val tcg = CollectionCSV.parse(fixture("tcgplayer.csv")).rows
        assertEquals("Brazen Borrower", tcg[3].name) // Simple Name, not "Brazen Borrower // Petty Theft"
        assertEquals("etched", tcg.first { it.cn == "300" }.finish) // "(Foil Etched)" in Name
        // Dragon Shield's guild kit codes and TCGplayer seller grades.
        val ds = CollectionCSV.parse("\"sep=,\"\nFolder Name,Quantity,Card Name,Set Code,Card Number,Printing\nA,1,Azorius Herald,GK2_AZORIU,2,Normal\n")
        assertEquals("gk2", ds.rows[0].setCode)
        val seller = CollectionCSV.parse("TCGplayer Id,Product Name,Set Name,Number,Condition,Total Quantity\n1,Shock,M19,156,Near Mint Foil,2\n")
        assertEquals(CSVFormat.TCGplayer, seller.format)
        assertEquals("foil", seller.rows[0].finish)
        assertEquals("NM", seller.rows[0].condition)
        assertEquals(2, seller.rows[0].qty)
    }

    @Test
    fun exportLayoutsReadBack() {
        val cards = Expected.load().cards.map {
            CollectionCSV.ExportCard(it.name, it.set, "Set ${it.set}", it.cn, "r", "id-${it.set}-${it.cn}", it.finish, it.condition, it.lang, it.qty)
        }
        fun key(s: String, cn: String?, f: String, c: String, l: String, q: Int) = "$s|${cn ?: ""}|$f|$c|$l|$q"
        for (layout in CollectionCSV.Layout.entries) {
            val p = CollectionCSV.parse(CollectionCSV.export(cards, layout))
            assertEquals(if (layout == CollectionCSV.Layout.Moxfield) CSVFormat.Moxfield else CSVFormat.ManaBox, p.format)
            assertEquals(layout.wire, cards.map { key(it.set, it.cn, it.finish, it.condition, it.lang, it.qty) }.toSet(),
                p.rows.map { key(it.setCode ?: "", it.cn, it.finish, it.condition, it.lang, it.qty) }.toSet())
            assertEquals(cards.map { it.name }.toSet(), p.rows.map { it.name }.toSet())
            if (layout == CollectionCSV.Layout.ManaBox) {
                assertEquals(cards.map { it.cardId.lowercase() }.toSet(), p.rows.mapNotNull { it.scryfallId }.toSet())
            }
        }
        assertTrue(CollectionCSV.export(cards, CollectionCSV.Layout.Moxfield).startsWith("\"Count\",\"Tradelist Count\",\"Name\",\"Edition\""))
        assertTrue(CollectionCSV.export(cards, CollectionCSV.Layout.ManaBox).startsWith("Name,Set code,Set name,Collector number,Foil,Rarity,Quantity"))
    }
}

class CollectionImportMatchTest {
    private fun resolver() = ImportResolver(TestImportCatalog.db, TestImportCatalog.setNames)
    private fun resolve(file: String) = resolver().resolve(CollectionCSV.parse(fixture(file)).rows)
    private fun name(l: ResolvedLine?) = l?.let { TestImportCatalog.db.oracles(listOf(it.printing.oracleIdx)).values.firstOrNull()?.name }

    /** Files with set codes and collector numbers land on exactly the printing, finish, condition and language. */
    @Test
    fun exactFormats() {
        val want = Expected.load()
        for (file in listOf("manabox.csv", "moxfield.csv", "archidekt.csv", "deckbox.csv", "dragonshield.csv", "tcgplayer.csv")) {
            val (matched, unmatched) = resolve(file)
            assertEquals(file, listOf(want.unmatched), unmatched.map { it.name })
            assertEquals(file, want.cards.size, matched.size)
            for ((got, card) in matched.zip(want.cards)) {
                val label = "$file line ${got.row.line}"
                assertEquals(label, "${card.set} ${card.cn}", "${got.printing.set} ${got.printing.cn}")
                assertEquals(label, card.finish, got.finish)
                assertEquals(label, card.condition, got.row.condition)
                assertEquals(label, card.lang, got.row.lang)
                assertEquals(label, card.qty, got.row.qty)
            }
        }
    }

    /**
     * Delver Lens's own CSV has set names but no collector numbers (and no ids that match the shortened test pack):
     * set + name finds the card in the right set; its foil column can't say etched.
     */
    @Test
    fun delverLensBySetName() {
        val want = Expected.load()
        val (matched, unmatched) = resolve("delverlens.csv")
        assertEquals(listOf(want.unmatched), unmatched.map { it.name })
        assertEquals(want.cards.size, matched.size)
        for ((got, card) in matched.zip(want.cards)) {
            assertEquals(card.name, MatchHow.SetName, got.how)
            assertEquals(card.name, card.set, got.printing.set)
            assertEquals(card.name, name(got))
            assertEquals(card.name, if (card.finish == "etched") "foil" else card.finish, got.finish)
            assertEquals(card.qty, got.row.qty)
        }
    }

    @Test
    fun matchOrder() {
        val resolver = resolver()
        fun row(name: String, set: String? = null, setName: String? = null, cn: String? = null, finish: String = "nonfoil") =
            ImportRow(line = 2, name = name, setCode = set, setName = setName, cn = cn, finish = finish)
        // set + number
        val bolt = resolver.resolve(row("Lightning Bolt", set = "m11", cn = "149"))
        assertEquals(MatchHow.SetNumber, bolt?.how)
        assertEquals("149", bolt?.printing?.cn)
        // a wrong number for the name falls through to set + name
        val wrong = resolver.resolve(row("Lightning Bolt", set = "m11", cn = "1"))
        assertEquals(MatchHow.SetName, wrong?.how)
        assertEquals("149", wrong?.printing?.cn)
        // set by name, a face of a split card, leading zeros
        assertEquals("122", resolver.resolve(row("Armed", setName = "Dragon's Maze", cn = "0122"))?.printing?.cn)
        // name only → the original printing
        val named = resolver.resolve(row("Brazen Borrower"))
        assertEquals(MatchHow.Name, named?.how)
        assertEquals("Brazen Borrower // Petty Theft", name(named))
        assertTrue(named?.printing?.original ?: false)
        // decorations
        assertEquals("Abbey Matron", name(resolver.resolve(row("Abbey Matron [Version 2]"))))
        assertEquals("Lightning Bolt", name(resolver.resolve(row("Lightning Bolt (Borderless)"))))
        assertEquals("Clue", name(resolver.resolve(row("Clue Token", set = "tmh2", cn = "14"))))
        // an unknown set code still matches by name; nothing matches nonsense
        assertEquals(MatchHow.Name, resolver.resolve(row("Lightning Bolt", set = "zzz", cn = "1"))?.how)
        assertNull(resolver.resolve(row("Totally Not A Card", set = "zzz")))
        // a finish the printing lacks: etched → foil
        assertEquals("foil", resolver.resolve(row("Blasphemous Act", set = "2xm", cn = "117", finish = "etched"))?.finish)
        // fixing a line by hand
        assertNotNull(bolt)
        val fixed = resolver.resolve(row("Totally Not A Card", set = "m11"), bolt!!.printing.oracleIdx)
        assertEquals(MatchHow.Fixed, fixed?.how)
        assertEquals("m11", fixed?.printing?.set)
    }

    @Test
    fun itemsMergeSameCopies() {
        val (matched, _) = resolve("manabox.csv")
        val doubled = ImportResolver.items(matched + matched)
        assertEquals(ImportResolver.items(matched).size, doubled.size)
        assertEquals(2 * matched.sumOf { it.row.qty }, doubled.sumOf { it.qty })
    }
}
