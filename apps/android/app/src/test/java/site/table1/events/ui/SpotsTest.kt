package site.table1.events.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import site.table1.events.ui.spots.Spots

/**
 * The feature spots the app bundles (contract/feature-spots-2026-11-01.md): assets/spots/spots.json decodes, every
 * carousel page has its shot, the copy is within the file's own limits, and the carousel wraps.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35]) // Robolectric 4.14 stops at 35; the app targets 36
class SpotsTest {
    private val context get() = RuntimeEnvironment.getApplication()

    @Test fun bundledSpotsDecode() {
        val file = Spots.load(context)
        assertNotNull("assets/spots/spots.json isn't in the APK (build.gradle.kts sourceSets)", file)
        file!!
        assertTrue(Spots.onboarding(context).size >= 3)
        for (s in file.spots) {
            assertTrue(s.key, s.title.length <= file.limits.title)
            assertTrue(s.key, s.headline.length <= file.limits.headline)
            assertTrue(s.key, s.body.length <= file.limits.body)
        }
        assertEquals("keys are unique", file.spots.size, file.spots.map { it.key }.toSet().size)
    }

    @Test fun everyCarouselPageHasItsShot() {
        for (s in Spots.onboarding(context)) {
            val shot = Spots.shot(context, s.key)
            assertNotNull("${s.key}.png: run tools/spots/run.sh", shot)
            assertTrue(s.key, shot!!.width > 300)
        }
    }

    @Test fun carouselWraps() {
        assertEquals(1, Spots.next(0, 3))
        assertEquals(0, Spots.next(2, 3))
        assertEquals(0, Spots.next(0, 0))
    }
}
