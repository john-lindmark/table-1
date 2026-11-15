package site.table1.events.library

import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

/** PriceBook.load waits for a fetch another screen started instead of skipping its cards: a confirmed trade showed
 *  no prices when the Collection's fetch of every card was cancelled or failed, and the trade screen, which had
 *  asked meanwhile, was never told. */
class PriceBookTest {
    private val kaldra = "a5a0ae99-d84a-4f27-bed8-889747c78529"
    private fun row(id: String) = JsonArray(listOf(JsonPrimitive(id), JsonPrimitive(9.58), JsonPrimitive(12.5), JsonNull,
                                                   JsonPrimitive(5.3), JsonPrimitive(7.29), JsonPrimitive(0)))
    private val real = PriceBook.fetcher

    @After fun restore() { PriceBook.fetcher = real; PriceBook.resetForTests() }

    @Test fun aFailedFetchIsAskedAgainByTheScreenWaitingOnIt() = runBlocking {
        PriceBook.resetForTests()
        val calls = AtomicInteger()
        PriceBook.fetcher = { ids ->
            val n = calls.incrementAndGet()
            delay(50)
            if (n == 1) error("network")
            ids.map { row(it) }
        }
        val collection = async { PriceBook.load(listOf(kaldra, "other")) }
        yield()
        PriceBook.load(listOf(kaldra))
        assertEquals(8.62, PriceBook.usd(kaldra, "nonfoil", "LP")!!, 0.0001)
        collection.await()
        assertEquals(2, calls.get())
    }

    @Test fun aCancelledScreenDoesNotCancelTheFetch() = runBlocking {
        PriceBook.resetForTests()
        val calls = AtomicInteger()
        PriceBook.fetcher = { ids -> calls.incrementAndGet(); delay(50); ids.map { row(it) } }
        val home = launch { PriceBook.load(listOf(kaldra)) }
        yield()
        home.cancel()
        PriceBook.load(listOf(kaldra))
        assertEquals(9.58, PriceBook.usd(kaldra, "nonfoil")!!, 0.0001)
        assertEquals(1, calls.get())
    }

    @Test fun answeredCardsAreNotAskedAgain() = runBlocking {
        PriceBook.resetForTests()
        val asked = mutableListOf<List<String>>()
        PriceBook.fetcher = { ids -> asked += ids.sorted(); ids.filter { it == kaldra }.map { row(it) } }
        PriceBook.load(listOf(kaldra, "unpriced"))
        PriceBook.load(listOf(kaldra, "unpriced"))
        assertEquals(listOf(listOf(kaldra, "unpriced")), asked)
        assertNull(PriceBook.usd("unpriced", "nonfoil"))
    }
}
