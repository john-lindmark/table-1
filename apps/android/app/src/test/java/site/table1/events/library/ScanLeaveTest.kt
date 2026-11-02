package site.table1.events.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Back on the scanner asks before leaving scanned cards behind (contract/trades-2026-10-16.md § Scanning, "Back"). */
class ScanLeaveTest {
    @Test fun nothingScannedLeavesWithoutAsking() {
        assertNull(ScanLeavePrompt.of(0, "Add"))
    }

    @Test fun scannedCardsAskWithTheScreensOwnAction() {
        val one = ScanLeavePrompt.of(1, "Add")
        assertEquals("Add the 1 card you scanned?", one?.title)
        assertEquals("Add 1", one?.add)
        val wants = ScanLeavePrompt.of(3, "Want")
        assertEquals("Want the 3 cards you scanned?", wants?.title)
        assertEquals("Want 3", wants?.add)
    }
}
