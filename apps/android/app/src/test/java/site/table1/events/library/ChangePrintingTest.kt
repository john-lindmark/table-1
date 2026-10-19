package site.table1.events.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/*
 * Change printing (contract/change-printing-2026-10-18.md): the collection ops that move owned copies to another
 * printing in the same place, and a trade get pointed at another printing merging into an existing line. Same cases
 * as iOS ChangePrintingTests and web changePrinting.test.ts. Deck and cube lines use list_edit's swap op, tested on
 * the server.
 */
class ChangePrintingTest {
    private val item = CollectionItem("old", "nonfoil", "LP", "en", 4, 1)

    @Test
    fun ownedCopiesMoveInTheSamePlace() {
        val ops = PrintingChange.ops(item, "binder-1", "new", "foil", qty = 2)!!
        assertEquals(2, ops.size)
        assertEquals(item.key, ops[0].key)
        assertEquals(-2, ops[0].delta)
        assertEquals("binder-1", ops[0].binderId)
        assertEquals(itemKey("new", "foil", "LP", "en"), ops[1].key)
        assertEquals(2, ops[1].delta)
        assertEquals("binder-1", ops[1].binderId)
    }

    @Test
    fun unsortedNamesNoBinder() {
        val ops = PrintingChange.ops(item, UNSORTED, "new", "nonfoil", qty = 1)!!
        assertNull(ops[0].binderId)
        assertNull(ops[1].binderId)
    }

    @Test
    fun finishOnlyIsAChange() {
        assertEquals(itemKey("old", "foil", "LP", "en"), PrintingChange.ops(item, null, "old", "foil", qty = 4)!![1].key)
    }

    @Test
    fun languageFollowsANonEnglishPrinting() {
        assertEquals("ja", PrintingChange.ops(item, null, "ja", "nonfoil", "ja", 1)!![1].lang)
        val jp = CollectionItem("old", "nonfoil", "NM", "ja", 1, 1)
        // An English printing keeps the copy's own language.
        assertEquals("ja", PrintingChange.ops(jp, null, "new", "nonfoil", "en", 1)!![1].lang)
    }

    @Test
    fun nothingToChange() {
        assertNull(PrintingChange.ops(item, null, "old", "nonfoil", qty = 1))
        assertNull(PrintingChange.ops(item, null, "new", "nonfoil", qty = 0))
        assertNull(PrintingChange.ops(item, null, "new", "nonfoil", qty = 5))
    }

    @Test
    fun placePicksChosenThenOpenedFromThenMost() {
        val places = listOf(PrintingChange.Place("a", "A", 1), PrintingChange.Place("b", "B", 3), PrintingChange.Place(UNSORTED, "Unsorted", 2))
        assertEquals("a", PrintingChange.pick(places, "a", "b"))
        assertEquals(UNSORTED, PrintingChange.pick(places, null, UNSORTED))
        assertEquals("b", PrintingChange.pick(places, "gone", "gone"))
        assertNull(PrintingChange.pick(emptyList(), null, null))
    }

    /** Through the allocation rules collection_apply uses: copies changed in a binder stay in it, the other place keeps its copies. */
    @Test
    fun binderCopiesStayInTheBinder() {
        val binders = mapOf("box" to Binder("box", "Box", false, 1))
        val it3 = CollectionItem("old", "nonfoil", "NM", "en", 3, 1) // Box 2, Unsorted 1
        val ops = PrintingChange.ops(it3, "box", "new", "foil", qty = 2)!!
        val hints = ops.groupBy { it.key }.mapValues { (_, os) -> os.filter { it.binderId != null }.associate { it.binderId!! to (it.delta ?: 0) } }
        assertEquals(mapOf("box" to 0), BinderRules.plan(mapOf("box" to 2), hints[it3.key]!!, 1, binders))
        assertEquals(mapOf("box" to 2), BinderRules.plan(emptyMap(), hints[itemKey("new", "foil", "NM", "en")]!!, 2, binders))
    }

    @Test
    fun tradeGetRepoints() {
        val a = TradeLine("a", "nonfoil", "NM", "en", 2)
        val b = TradeLine("b", "nonfoil", "NM", "en", 1)
        val out = listOf(a, b).repoint(a.key, "c", "foil")
        assertEquals(listOf("c", "b"), out.map { it.cardId })
        assertEquals("foil", out[0].finish)
        assertEquals(2, out[0].qty)
    }

    @Test
    fun tradeGetMergesIntoAnExistingLine() {
        val a = TradeLine("a", "nonfoil", "NM", "en", 2)
        val b = TradeLine("b", "foil", "NM", "en", 1)
        val out = listOf(a, b).repoint(a.key, "b", "foil")
        assertEquals(1, out.size)
        assertEquals(b.key, out[0].key)
        assertEquals(3, out[0].qty)
        assertEquals(listOf(a, b), listOf(a, b).repoint(a.key, "a", "nonfoil"))
    }
}
