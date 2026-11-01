package site.table1.events.util

import io.sentry.Breadcrumb
import io.sentry.SentryEvent
import io.sentry.SpanId
import io.sentry.SpanStatus
import io.sentry.protocol.Request
import io.sentry.protocol.SentryId
import io.sentry.protocol.SentrySpan
import io.sentry.protocol.SentryTransaction
import io.sentry.protocol.TransactionInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/** contract/telemetry-2026-10-15.md § Sentry: query strings never leave the device (PostgREST filters carry ids). */
class TelemetryTest {
    private val base = "https://aaozhfcbvqrgkkrihkrd.supabase.co/rest/v1/match_sides"
    private val withQuery = "$base?select=*&match_id=eq.7b0c4f0e-2a8e-4a51-9c33-1f0b6f0a9d21"

    @Test fun stripsQueryAndFragment() {
        assertEquals(base, Telemetry.stripQuery(withQuery))
        assertEquals(base, Telemetry.stripQuery("$base#token=abc"))
        assertEquals(base, Telemetry.stripQuery("$base?a=1#b"))
        assertEquals(base, Telemetry.stripQuery(base))
        assertEquals("", Telemetry.stripQuery("?event_id=eq.1"))
    }

    @Test fun scrubsHttpBreadcrumbs() {
        val crumb = Breadcrumb.http(withQuery, "GET", 200).apply {
            setData("http.query", "select=*&match_id=eq.7b0c4f0e")
            setData("http.fragment", "x")
        }
        Telemetry.scrub(crumb)
        assertEquals(base, crumb.getData("url"))
        assertNull(crumb.getData("http.query"))
        assertNull(crumb.getData("http.fragment"))
        assertEquals("GET", crumb.getData("method"))
    }

    @Test fun leavesOtherBreadcrumbsAlone() {
        val crumb = Breadcrumb.navigation("event", "account")
        Telemetry.scrub(crumb)
        assertEquals("event", crumb.getData("from"))
        assertEquals("account", crumb.getData("to"))
    }

    @Test fun scrubsFailedRequestEvents() {
        val event = SentryEvent().apply {
            request = Request().apply {
                url = withQuery
                queryString = "select=*&match_id=eq.7b0c4f0e"
                fragment = "f"
                method = "POST"
            }
        }
        Telemetry.scrub(event)
        assertEquals(base, event.request?.url)
        assertNull(event.request?.queryString)
        assertNull(event.request?.fragment)
        assertEquals("POST", event.request?.method)
    }

    @Test fun eventWithoutRequestIsUnchanged() {
        val event = SentryEvent()
        Telemetry.scrub(event)
        assertNull(event.request)
    }

    @Test fun scrubsTransactionSpans() {
        val span = SentrySpan(
            0.0, 1.0, SentryId(), SpanId(), null, "http.client", "GET $base", SpanStatus.OK, "auto.http.okhttp",
            mutableMapOf(), mutableMapOf(), mutableMapOf<String, Any>("url" to withQuery, "http.query" to "match_id=eq.1"),
        )
        val tx = SentryTransaction("event", 0.0, 1.0, mutableListOf(span), mutableMapOf(), TransactionInfo("custom"))
        Telemetry.scrub(tx)
        val data = tx.spans.single().data!!
        assertEquals(base, data["url"])
        assertFalse(data.containsKey("http.query"))
    }

    // contract/telemetry-2026-10-15.md § Push, Live Activities, widgets: `widgets_changed` only when the set changes.
    @Test fun widgetsChangedOnlyWhenTheSetChanges() {
        assertEquals("" to false, Telemetry.widgetsDiff(null, emptyList()))                           // first look, none: kept, not sent
        assertEquals("match,value" to true, Telemetry.widgetsDiff(null, listOf("value", "match")))   // first look, some: sent
        assertNull(Telemetry.widgetsDiff("match,value", listOf("value", "match")))                   // same set, any order
        assertEquals("match,match,value" to true, Telemetry.widgetsDiff("match,value", listOf("match", "value", "match")))
        assertEquals("" to true, Telemetry.widgetsDiff("next_event", emptyList()))                   // all removed: sent
    }
}
