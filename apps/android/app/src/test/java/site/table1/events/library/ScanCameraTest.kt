package site.table1.events.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The scanner's camera zoom (ScanCamera): far enough out to focus, short of a 2× telephoto. */
class ScanCameraTest {
    @Test fun zoomsTheMainCamera() {
        assertEquals(1.6f, ScanCamera.zoom(1f, 8f))
        // A logical camera with an ultra wide starts below 1×: still 1.6× of the main camera.
        assertEquals(1.6f, ScanCamera.zoom(0.6f, 10f))
    }

    @Test fun withinWhatTheCameraAllows() {
        assertEquals(1.4f, ScanCamera.zoom(1f, 1.4f))
        assertNull(ScanCamera.zoom(1f, 1f))
        assertNull(ScanCamera.zoom(2f, 1f))
    }

    @Test fun neverReachesATwoTimesTelephoto() {
        assertTrue(ScanCamera.ZOOM < 2f)
    }

    /** At 1× a card fills the guide about 9 cm out (inside most main cameras' focus limit); zoomed, about 15 cm. */
    @Test fun fillDistance() {
        assertEquals(9.2f, ScanCamera.fillDistanceCm(1f), 0.3f)
        assertTrue(ScanCamera.fillDistanceCm(ScanCamera.ZOOM) > 14f)
    }

    @Test fun timingCarriesTheCamera() {
        val t = ScanTiming(started = 0)
        t.read(100, cjkReader = false, ok = true, width = 1280, height = 960)
        t.camera(1.6f, 10)
        val s = t.summary(now = 1000)!!
        assertEquals(1.6, s["zoom"])
        assertEquals(10, s["min_focus_cm"])
    }
}
