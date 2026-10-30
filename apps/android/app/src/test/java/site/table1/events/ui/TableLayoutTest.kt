package site.table1.events.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import site.table1.events.ui.screens.TableLayout

/* Draft seating drawn as one long table (contract/event-night-2026-10-16.md § 3), as iOS TableLayout. */
class TableLayoutTest {
    @Test fun sidesOnly() {
        val t = TableLayout(8, ends = false)
        assertEquals(4, t.right); assertEquals(4, t.left); assertFalse(t.ends)
        val p = t.positions(360f, 120f)
        // Seat 1 at the top of the right side, down the right, then up the left: seat 8 top left, across from seat 1.
        assertTrue(p[0].first > 180f && p[3].first > 180f && p[4].first < 180f)
        assertTrue(p[0].second < p[3].second && p[4].second > p[7].second)
        assertEquals(p[0].second, p[7].second, 0.01f)
    }

    @Test fun endsNeedFourAndTakeHeadAndFoot() {
        assertFalse(TableLayout(3, ends = true).ends)
        val t = TableLayout(8, ends = true)
        assertTrue(t.ends)
        assertEquals(3, t.right); assertEquals(3, t.left)
        val p = t.positions(360f, 120f)
        assertEquals(180f, p[0].first, 0.01f)   // seat 1 at the head
        assertEquals(180f, p[4].first, 0.01f)   // seat 5 at the foot
        assertTrue(p[4].second > p[3].second)
        assertTrue(TableLayout(8, true).height > TableLayout(8, false).height)
    }

    @Test fun oddSidesPutTheExtraOnTheRight() {
        val t = TableLayout(7, ends = false)
        assertEquals(4, t.right); assertEquals(3, t.left)
    }
}
