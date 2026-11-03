package site.table1.events.util

import io.github.jan.supabase.exceptions.RestException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Bug #30: `catalog_info` called on a return to the app with the old access token, before the session refresh. */
class SessionExpiryTest {
    private val expired = RestException("JWT expired", "", 401, "https://x.supabase.co/rest/v1/rpc/catalog_info")

    @Test
    fun expiredTokenIsRecognised() {
        assertTrue(expired.isExpiredSession())
        assertFalse(RestException("permission denied", "", 401, "").isExpiredSession())
        assertFalse(RestException("JWT expired", "", 400, "").isExpiredSession())
        assertFalse(java.io.IOException("JWT expired").isExpiredSession())
    }

    @Test
    fun expiredTokenRefreshesAndRetriesOnce() = runBlocking {
        var calls = 0
        var refreshes = 0
        val answer = retryOnExpiredSession(refresh = { refreshes++ }) {
            calls++
            if (calls == 1) throw expired
            "ok"
        }
        assertEquals("ok", answer)
        assertEquals(2, calls)
        assertEquals(1, refreshes)
    }

    @Test
    fun otherErrorsAreNotRetried() = runBlocking {
        var calls = 0
        try {
            retryOnExpiredSession(refresh = { fail("no refresh") }) {
                calls++
                throw RestException("permission denied", "", 403, "")
            }
            fail("should throw")
        } catch (e: RestException) {
            assertEquals(1, calls)
        }
    }

    @Test
    fun failedRefreshThrowsTheOriginalError() = runBlocking {
        try {
            retryOnExpiredSession(refresh = { throw java.io.IOException("offline") }) { throw expired }
            fail("should throw")
        } catch (e: RestException) {
            assertTrue(e.isExpiredSession())
        }
    }
}
