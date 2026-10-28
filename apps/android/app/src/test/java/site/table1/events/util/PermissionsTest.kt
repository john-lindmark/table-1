package site.table1.events.util

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import site.table1.events.util.PermissionState.Off
import site.table1.events.util.PermissionState.On
import site.table1.events.util.PermissionState.Unasked

/** contract/permissions-onboarding-2026-10-28.md § When it shows. */
class PermissionsTest {
    @Test fun showsWhileSomethingIsUnasked() {
        assertTrue(PermissionsStep.shouldShow(false, Unasked, Unasked))
        assertTrue(PermissionsStep.shouldShow(false, On, Unasked))
        assertTrue(PermissionsStep.shouldShow(false, Unasked, Off))
    }

    @Test fun notWhenBothAnswered() {
        assertFalse(PermissionsStep.shouldShow(false, On, Off))
        assertFalse(PermissionsStep.shouldShow(false, Off, On))
    }

    @Test fun neverAgainOnceSeenOrSkipped() {
        assertFalse(PermissionsStep.shouldShow(true, Unasked, Unasked))
    }
}
