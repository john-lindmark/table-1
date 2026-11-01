package site.table1.events.library

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

/** Card images: one download per image, kept going when the card that asked first goes away (John, 2026-11-01: after a
 *  condition change the card image sometimes never loaded). */
class SharedFlightsTest {
    private val flights = SharedFlights<String>(CoroutineScope(SupervisorJob() + Dispatchers.Default))

    @Test fun aCallerGoingAwayDoesNotCancelTheDownloadForOthers() = runBlocking {
        val gate = CompletableDeferred<Unit>()
        val runs = AtomicInteger()
        val work: suspend () -> String = { runs.incrementAndGet(); gate.await(); "image" }
        val first = async(Dispatchers.Default) { flights.get("bolt", work) }
        val second = async(Dispatchers.Default) { flights.get("bolt", work) }
        while (runs.get() == 0) Thread.sleep(5)
        first.cancel() // the card detail redrawn after a condition change
        gate.complete(Unit)
        assertEquals("image", withTimeout(2_000) { second.await() })
        assertEquals(1, runs.get())
    }

    @Test fun aFailureIsNotKept() = runBlocking {
        val runs = AtomicInteger()
        val failing: suspend () -> String? = { runs.incrementAndGet(); throw java.io.IOException("dropped") }
        assertEquals(null, flights.get("bolt", failing))
        assertEquals("image", flights.get("bolt") { runs.incrementAndGet(); "image" })
        assertEquals(2, runs.get())
    }
}
