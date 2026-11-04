package site.table1.events.util

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** contract/test-robots-2026-11-04.md: only Test Lab's own "true" marks the account; anything else is a real phone. */
class TestLabTest {
    @Test fun onlyTestLabsValueCounts() {
        assertTrue(TestLab.isTestLabValue("true"))
        assertFalse(TestLab.isTestLabValue(null))
        assertFalse(TestLab.isTestLabValue(""))
        assertFalse(TestLab.isTestLabValue("false"))
        assertFalse(TestLab.isTestLabValue("TRUE"))
        assertFalse(TestLab.isTestLabValue("1"))
    }
}
