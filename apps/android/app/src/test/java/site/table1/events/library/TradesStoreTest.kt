package site.table1.events.library

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/*
 * Bug #5: deleting a trade from its editor also goes back to the list, which reloads. That read could start before
 * the delete committed and bring the deleted trade back; opening it and editing then failed ("That trade is gone or
 * already confirmed"). The store keeps trades deleted this session out of every read. Same cases as iOS
 * TradesStoreTests.swift and web trades.test.ts.
 */
class TradesStoreTest {
    private fun trade(id: String) = Trade(id = id, status = "draft")

    @Test
    fun aListReadFromBeforeADeleteKeepsItGone() {
        TradesStore.applyLoaded(listOf(trade("a"), trade("b")))
        TradesStore.forget("a")
        assertEquals(listOf("b"), TradesStore.state.value.trades.map { it.id })
        TradesStore.applyLoaded(listOf(trade("a"), trade("b")))
        assertEquals(listOf("b"), TradesStore.state.value.trades.map { it.id })
        assertNull(TradesStore.trade("a"))
    }

    @Test
    fun aSaveOfADeletedTradeIsDropped() = runBlocking {
        TradesStore.applyLoaded(listOf(trade("c")))
        TradesStore.forget("c")
        val t = TradesStore.save(trade("c"), "Sam", emptyList(), emptyList())
        assertEquals("c", t.id)
        assertTrue(TradesStore.state.value.trades.isEmpty())
    }
}
