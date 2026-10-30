package site.table1.events.util

import kotlinx.coroutines.CancellationException
import org.junit.Assert.assertThrows
import org.junit.Test

/* A load restarted at launch (the app coming to the foreground) was shown as an error until the newer one landed:
   cancellations rethrow, real failures don't. */
class CancellationTest {
    @Test fun cancellationRethrows() {
        assertThrows(CancellationException::class.java) { CancellationException("replaced").rethrowIfCancelled() }
    }

    @Test fun failuresDoNot() {
        java.io.IOException("offline").rethrowIfCancelled()
        IllegalStateException("refused").rethrowIfCancelled()
    }
}
