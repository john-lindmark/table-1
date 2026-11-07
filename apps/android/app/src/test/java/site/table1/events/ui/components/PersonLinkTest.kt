package site.table1.events.ui.components

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Tapping a person opens their profile (contract/friends-sharing-2026-10-18.md § Tapping a person). */
class PersonLinkTest {
    @Test fun guestsAreNotTappable() {
        assertNull(PersonLink.target(null))
        assertNull(PersonLink.target(""))
        assertNull(PersonLink.target("  "))
    }

    @Test fun anAccountOpensItsProfile() {
        assertEquals("d0000000-0000-0000-0000-0000000f0001", PersonLink.target("D0000000-0000-0000-0000-0000000F0001"))
    }
}
