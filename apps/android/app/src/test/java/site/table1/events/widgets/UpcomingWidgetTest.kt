package site.table1.events.widgets

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import site.table1.events.data.FindFilters
import site.table1.events.data.FoundEvent
import site.table1.events.data.WebLink
import java.io.File
import java.time.ZoneId
import java.util.Locale

/** The Upcoming events widget's rows, what it asks find_events and where its taps go
 *  (contract/public-events-leagues-2026-11-13.md § 6). */
class UpcomingWidgetTest {
    private val zone = ZoneId.of("America/Denver")

    @Test fun rows() {
        val e = FoundEvent("e1", "Modern Open", formatLabel = "Modern", startsAt = "2026-03-29T16:00:00+00:00", venueName = "MeH Games", me = "player")
        val r = UpcomingWidgets.row(e, zone, Locale.UK)
        assertEquals("SUN 29 · 10:00", r.at)
        assertEquals("Modern Open", r.name)
        assertEquals("MODERN · MEH GAMES", r.line)
        assertTrue(r.joined)
        assertFalse(r.live)
        val running = UpcomingWidgets.row(e.copy(status = "in_progress", currentRound = 3, me = null, venueName = null), zone, Locale.UK)
        assertEquals("NOW · ROUND 3", running.at)
        assertEquals("MODERN", running.line)
        assertTrue(running.live)
        assertFalse(running.joined)
        assertEquals("SOON", UpcomingWidgets.row(e.copy(startsAt = null), zone, Locale.UK).at)
    }

    /** Near me uses the app's rough place with 100 km, and reads Everywhere until there is one. */
    @Test fun whatItAsks() {
        val place = 39.7 to -105.0
        assertEquals(FindFilters(formats = listOf("modern", "cube"), km = 100) to place, UpcomingWidgets.filters(UpcomingPicks(listOf("cube", "modern")), place))
        assertEquals(FindFilters() to null, UpcomingWidgets.filters(UpcomingPicks(), null))
        assertEquals(FindFilters() to null, UpcomingWidgets.filters(UpcomingPicks(near = false), place))
        val (f, here) = UpcomingWidgets.filters(UpcomingPicks(listOf("modern")), place)
        assertEquals("""{"formats":["modern"],"lat":39.7,"lng":-105.0,"km":100}""", f.json(here = here).toString())
    }

    @Test fun wording() {
        assertEquals("ALL FORMATS", UpcomingWidgets.formatsLine(UpcomingPicks()))
        assertEquals("MODERN", UpcomingWidgets.formatsLine(UpcomingPicks(listOf("modern"))))
        assertEquals("MODERN · LEGACY", UpcomingWidgets.formatsLine(UpcomingPicks(listOf("legacy", "modern"))))
        assertEquals("3 FORMATS", UpcomingWidgets.formatsLine(UpcomingPicks(listOf("legacy", "modern", "cube"))))
        // Medium (4×2, 170 dp) lists three rows; large and tall ones more; never none.
        assertEquals(3, UpcomingWidgets.rowCount(170f, wide = true))
        assertEquals(2, UpcomingWidgets.rowCount(170f, wide = false))
        assertEquals(5, UpcomingWidgets.rowCount(270f, wide = true))
        assertEquals(8, UpcomingWidgets.rowCount(900f, wide = true))
        assertEquals(1, UpcomingWidgets.rowCount(60f, wide = false))
    }

    /** A row opens its event and the header opens Find, through the app's table1:// addresses. */
    @Test fun taps() {
        assertEquals(WebLink.Screens("events", listOf("event/e1")) to "widget_upcoming", WebLink.parseApp(UpcomingWidgets.eventLink("e1")))
        assertEquals(WebLink.Screens("events", listOf("find")) to "widget_upcoming", WebLink.parseApp(UpcomingWidgets.FIND_LINK))
        assertNull(WebLink.parseApp("table1://league"))
    }

    /** Refreshes every 30 minutes, any size from one row, with its settings screen and under its own name after R8. */
    @Test fun registered() {
        val main = generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "app/src/main") }.first { it.isDirectory }
        val xml = File(main, "res/xml/widget_upcoming.xml").readText()
        assertTrue("android:updatePeriodMillis=\"1800000\"" in xml)
        assertTrue("android:minResizeHeight=\"40dp\"" in xml)
        assertTrue("UpcomingWidgetConfigActivity" in xml)
        val manifest = File(main, "AndroidManifest.xml").readText()
        assertTrue(".widgets.UpcomingWidgetReceiver" in manifest && ".widgets.UpcomingWidgetConfigActivity" in manifest)
        assertTrue("-keep class * extends androidx.glance.appwidget.GlanceAppWidget" in File(main.parentFile!!.parentFile, "proguard-rules.pro").readText())
    }
}
