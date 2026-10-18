package site.table1.events.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/*
 * Binders, "for trade" and wants on the device (contract/binders-wants-2026-10-17.md): the allocation rules (the
 * server's are tested in supabase/tests/70_binders_wants_test.sql), the Missing view, which want a trade's get meets,
 * and the CSV binder and tradelist columns. Same cases as iOS BindersTests.swift and web binders.test.ts.
 */
class BindersTest {
    private val binders = mapOf(
        "t" to Binder("t", "Trade binder", true, 1), "a" to Binder("a", "Alpha", false, 2), "b" to Binder("b", "Box 3", false, 3),
    )

    @Test
    fun unsortedGoesFirst() {
        assertEquals(mapOf("a" to 1, "b" to 2, "t" to 2), BinderRules.plan(mapOf("a" to 1, "b" to 2, "t" to 2), emptyMap(), 5, binders))
    }

    @Test
    fun nonTradeBindersByNameThenTrade() {
        assertEquals(mapOf("a" to 0, "b" to 0, "t" to 2), BinderRules.plan(mapOf("a" to 1, "b" to 2, "t" to 2), emptyMap(), 2, binders))
        assertEquals(mapOf("a" to 0, "b" to 0, "t" to 1), BinderRules.plan(mapOf("a" to 1, "b" to 2, "t" to 2), emptyMap(), 1, binders))
    }

    @Test
    fun namedBinderGivesFirstAndAddsGoIn() {
        assertEquals(mapOf("b" to 2, "t" to 0), BinderRules.plan(mapOf("b" to 2, "t" to 1), mapOf("t" to -1), 2, binders))
        assertEquals(mapOf("b" to 4), BinderRules.plan(mapOf("b" to 2), mapOf("b" to 2), 6, binders))
        assertEquals(emptyMap<String, Int>(), BinderRules.plan(emptyMap(), mapOf("gone" to 3), 3, binders))
    }

    @Test
    fun wantsMetInOrder() {
        val wants = listOf(Want("o", null, null, 2), Want("o", "p", null, 1), Want("o", "p", "foil", 1)).associateBy { it.key }.toMutableMap()
        assertEquals("foil", BinderRules.wantFor("o", "p", "foil", wants.values)?.finish)
        assertEquals("p", BinderRules.wantFor("o", "p", "nonfoil", wants.values)?.cardId)
        assertNull(BinderRules.wantFor("o", "q", "nonfoil", wants.values)?.cardId)
        assertNull(BinderRules.wantFor("x", "q", "nonfoil", wants.values))
        assertEquals(3, BinderRules.meet("o", "p", "foil", 3, wants).size)
        assertEquals(0, wants[wantKey("o", "p", "foil")]?.qty)
        assertEquals(0, wants[wantKey("o", "p", null)]?.qty)
        assertEquals(1, wants[wantKey("o", null, null)]?.qty)
    }

    @Test
    fun missingTakesTheLargestNeedAcrossLists() {
        fun list(id: String, entries: List<ListEntry>) = CardList(id, ListKind.Deck, "Deck $id", "modern", listOf(ListVersion(1, 0.0, "", entries)))
        val lists = listOf(
            list("1", listOf(ListEntry("bolt", "main", 4), ListEntry("opt", "maybe", 4))),
            list("2", listOf(ListEntry("bolt", "main", 2), ListEntry("bolt", "side", 1), ListEntry("bolt", "main", 2, "foil"))),
        )
        val lines = MissingView.lines(lists, mapOf("bolt|nonfoil" to 1))
        assertEquals(listOf("bolt|nonfoil 3 Deck 1+Deck 2", "bolt|foil 2 Deck 2"), lines.map { "${it.key} ${it.short} ${it.lists.joinToString("+")}" })
        assertTrue(MissingView.lines(lists, mapOf("bolt|nonfoil" to 4, "bolt|foil" to 2)).isEmpty())
    }

    private fun resolve(text: String) = ImportResolver(TestImportCatalog.db, TestImportCatalog.setNames).resolve(CollectionCSV.parse(text).rows).first

    @Test
    fun manaBoxBindersAndLists() {
        val p = CollectionCSV.parse(File(importFixtures, "manabox.csv").readText())
        assertEquals("My collection", p.rows[0].binder)
        assertEquals(16, p.rows.count { it.binder == "Trade binder" })
        val text = "Binder Name,Binder Type,Name,Set code,Collector number,Foil,Quantity\n" +
            "Box 3,binder,Lightning Bolt,M11,149,normal,4\nWishlist,list,Lightning Bolt,M11,149,foil,2\nBurn,deck,Lightning Bolt,M11,149,normal,1\n"
        val rows = CollectionCSV.parse(text).rows
        assertEquals(listOf("Box 3", null, null), rows.map { it.binder })
        assertEquals(listOf(false, true, false), rows.map { it.wanted })
        val m = resolve(text)
        assertEquals(5, ImportResolver.items(m).sumOf { it.qty })
        assertEquals(listOf("Box 3 4"), ImportResolver.placements(m).map { "${it.binder} ${it.qty}" })
        assertEquals(listOf("foil 2"), ImportResolver.wants(m).map { "${it.second} ${it.third}" })
    }

    @Test
    fun tradelistCountsAndFolders() {
        val deckbox = "Count,Tradelist Count,Name,Edition,Edition Code,Card Number\n4,3,Lightning Bolt,Magic 2011,m11,149\n2,9,Opt,Ixalan,xln,65\n1,,Shock,M19,m19,156\n"
        assertEquals(listOf(3, 2, 0), CollectionCSV.parse(deckbox).rows.map { it.tradeQty })
        val mox = "\"Count\",\"Tradelist Count\",\"Name\",\"Edition\",\"Collector Number\"\n\"4\",\"1\",\"Lightning Bolt\",\"m11\",\"149\"\n"
        assertEquals(1, CollectionCSV.parse(mox).rows[0].tradeQty)
        val ds = "\"sep=,\"\nFolder Name,Quantity,Trade Quantity,Card Name,Set Code,Card Number\nBox,4,1,Lightning Bolt,M11,149\n"
        val row = CollectionCSV.parse(ds).rows[0]
        assertEquals("Box", row.binder)
        assertEquals(1, row.tradeQty)
        assertEquals(setOf("Trade binder 1", "Box 3"), ImportResolver.placements(resolve(ds)).map { "${it.binder} ${it.qty}" }.toSet())
    }

    @Test
    fun exportCarriesBindersAndReadsBack() {
        fun card(qty: Int, binder: String?, trade: Boolean = false, wanted: Boolean = false) = CollectionCSV.ExportCard(
            "Lightning Bolt", "m11", "Magic 2011", "149", "c", "bolt", "nonfoil", "NM", "en", qty, binder, trade, wanted)
        val cards = listOf(card(2, "Trade binder", trade = true), card(1, "Box 3"), card(1, null), card(3, null, wanted = true))
        val manabox = CollectionCSV.parse(CollectionCSV.export(cards, CollectionCSV.Layout.ManaBox)).rows
        assertEquals(listOf("- 1", "Box 3 1", "Trade binder 2"), manabox.filter { !it.wanted }.map { "${it.binder ?: "-"} ${it.qty}" }.sorted())
        assertEquals(listOf(3), manabox.filter { it.wanted }.map { it.qty })
        val mox = CollectionCSV.parse(CollectionCSV.export(cards, CollectionCSV.Layout.Moxfield)).rows
        assertEquals(listOf("4/2"), mox.map { "${it.qty}/${it.tradeQty}" })
    }
}
