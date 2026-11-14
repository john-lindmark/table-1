package site.table1.events.util

import io.github.jan.supabase.exceptions.HttpRequestException
import io.github.jan.supabase.exceptions.RestException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import site.table1.events.data.EventPage
import site.table1.events.data.EventRules

/** A player's screenshot showed supabase-kt's whole exception, sign-in token included (contract/android-errors-2026-11-14.md). */
class ErrorTextTest {
    private val token = "eyJhbGciOiJIUzI1NiIsImtpZCI6Imx.eyJzdWIiOiI3NGU1YjExMiJ9.12URaZmGC-JuEz7HxlkZ0pkcivmP"
    private val raw = "That event isn't available\nURL: https://x.supabase.co/rest/v1/rpc/event_bundle\n" +
        "Headers: [Authorization=[Bearer $token], Prefer=[], Content-Profile=[public], apikey=[$token], " +
        "X-Client-Info=[supabase-kt/3.0.3]]\nHttp Method: POST"

    @Test
    fun aRawMessageShowsOnlyTheServersWords() {
        assertTrue(ErrorText.looksRaw(raw))
        assertEquals("That event isn't available", ErrorText.shown(raw))
        assertEquals("That event isn't available", ErrorText.safe(raw))
        assertFalse("eyJ" in ErrorText.safe(raw))
    }

    @Test
    fun plainTextPassesThrough() {
        val plain = "You're in.\nYour event is on the Events tab."
        assertFalse(ErrorText.looksRaw(plain))
        assertEquals(plain, ErrorText.safe(plain))
    }

    @Test
    fun aLoneTokenIsNeverShown() {
        assertEquals(ErrorText.FALLBACK, ErrorText.shown(token))
        assertEquals(ErrorText.FALLBACK, ErrorText.shown(null))
        assertEquals(ErrorText.FALLBACK, ErrorText.shown("\nURL: https://x\nHeaders: [a]"))
    }

    @Test
    fun exceptionsReadAsTheServerOrTheConnection() {
        assertEquals("That event isn't available", ErrorText.of(RestException("That event isn't available", "", 403, raw.substringAfter('\n'))))
        assertEquals(ErrorText.NETWORK, ErrorText.of(HttpRequestException("Unable to resolve host", io.ktor.client.request.HttpRequestBuilder())))
    }

    @Test
    fun reportsKeepTheUrlButNeverTheHeaders() {
        val r = ErrorText.redacted(raw)
        assertTrue("URL: https://x.supabase.co/rest/v1/rpc/event_bundle" in r)
        assertTrue("Http Method: POST" in r)
        assertFalse("Headers" in r)
        assertFalse("eyJ" in r)
    }

    @Test
    fun offlineNoticeNeverCarriesTheRequest() {
        assertEquals("That event isn't available" to true, Offline.notice(true, null, raw))
    }

    @Test
    fun aRefusedEventOpensItsPageForSomeoneNotInIt() {
        val refused = RestException("That event isn't available", "", 403, "")
        assertTrue(EventRules.refusedEvent(refused))
        assertTrue(EventRules.refusedEvent(RestException("That event isn't available", "", 401, "")))
        assertFalse(EventRules.refusedEvent(RestException("Round 1 is paired", "", 409, "")))
        assertFalse(EventRules.refusedEvent(java.io.IOException("That event isn't available")))
        assertTrue(EventRules.opensPage(EventPage(eventId = "e", access = "link")))
        assertTrue(EventRules.opensPage(EventPage(eventId = "e", access = "invited")))
        assertFalse(EventRules.opensPage(EventPage(eventId = "e", access = "player")))
        assertFalse(EventRules.opensPage(EventPage(eventId = "e", access = "none")))
        assertFalse(EventRules.opensPage(EventPage(eventId = null)))
        assertFalse(EventRules.opensPage(null))
    }
}
