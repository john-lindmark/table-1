package site.table1.events.widgets

import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The home screen widgets' size and text rules (WidgetViews.kt); what they draw is checked in WidgetGalleryTest. */
class WidgetLayoutTest {
    @Test fun shapeFollowsTheLaunchersCells() {
        // Legacy cell sizes (73n − 16) and a Pixel's.
        assertEquals(WShape.STRIP, WShape.of(DpSize(130.dp, 57.dp)))
        assertEquals(WShape.WIDE_STRIP, WShape.of(DpSize(276.dp, 57.dp)))
        assertEquals(WShape.WIDE_STRIP, WShape.of(DpSize(390.dp, 90.dp)))
        assertEquals(WShape.SMALL, WShape.of(DpSize(130.dp, 130.dp)))
        assertEquals(WShape.SMALL, WShape.of(DpSize(203.dp, 170.dp)))
        assertEquals(WShape.MEDIUM, WShape.of(DpSize(276.dp, 130.dp)))
        assertEquals(WShape.TALL, WShape.of(DpSize(130.dp, 203.dp)))
        assertEquals(WShape.LARGE, WShape.of(DpSize(390.dp, 420.dp)))
        assertTrue(WShape.LARGE.tall && WShape.LARGE.wide && !WShape.LARGE.strip)
    }

    @Test fun moneyAsIOS() {
        assertEquals("$812.40", WidgetText.money(812.4))
        assertEquals("$4,275", WidgetText.money(4275.0))
        assertEquals("$0.00", WidgetText.money(0.0))
    }

    @Test fun changeSaysDaysNotMarket() {
        assertEquals("+$87.42 · 7 days", WidgetText.change(87.42 to 7))
        assertEquals("−$3.10 · 1 day", WidgetText.change(-3.1 to 1))
        assertEquals("+$1,204 · 7 days", WidgetText.change(1204.0 to 7))
    }

    @Test fun valueShrinksToFit() {
        assertEquals(22f, WidgetText.fit("$4,275", 136.dp, 22f), 0.01f)
        assertEquals(19.4f, WidgetText.fit("$123,456,789", 140.dp, 22f), 0.1f)
        assertEquals(13.2f, WidgetText.fit("$123,456,789,012,345", 100.dp, 22f), 0.01f)
    }

    @Test fun laterRowsFitTheHeight() {
        assertEquals(0, WidgetText.laterRows(203.dp, wide = true, invites = true, available = 4))
        assertEquals(2, WidgetText.laterRows(270.dp, wide = true, invites = true, available = 4))
        assertEquals(1, WidgetText.laterRows(270.dp, wide = false, invites = true, available = 4))
        assertEquals(4, WidgetText.laterRows(370.dp, wide = true, invites = true, available = 4))
        assertEquals(8, WidgetText.laterRows(900.dp, wide = true, invites = false, available = 20))
    }

    @Test fun outcomesMineFirst() {
        assertEquals(listOf("2-0", "2-1", "1-1", "1-2", "0-2"), WidgetText.outcomes.map { "${it.first}-${it.second}" })
    }
}
