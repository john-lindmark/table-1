package site.table1.events.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import site.table1.events.ui.components.FullScreenDialog
import site.table1.events.ui.components.FullScreenWindow
import java.io.File

/** The scanner's and Add cards' bottom buttons sat under the navigation bar (John, 2026-11-01): a full-screen dialog
 *  that fits the system bars gets no insets for its T1Screen to pad on Android 15+. */
class FullScreenDialogTest {
    @Test fun drawsEdgeToEdge() {
        assertFalse(FullScreenDialog.usePlatformDefaultWidth)
        assertFalse(FullScreenDialog.decorFitsSystemWindows)
    }

    /** Every full-screen dialog goes through FullScreenDialog, so a new one can't bring the bug back. */
    @Test fun everyFullScreenDialogUsesIt() {
        val src = File("src/main/java")
        assertTrue("run from the app module", src.isDirectory)
        val offenders = src.walk().filter { it.extension == "kt" && it.name != "Kit.kt" }
            .filter { "usePlatformDefaultWidth = false" in it.readText() }.map { it.name }.toList()
        assertEquals(emptyList<String>(), offenders)
    }

    /** Every full-screen dialog goes through T1FullScreenDialog, which sizes the window to what Compose measures the
     *  content for: Dialog(properties = FullScreenDialog) on its own cut off the bottom on Android 15+ (Save to Photos
     *  and Share under the deck and ranking images, John 2026-11-06). */
    @Test fun everyFullScreenDialogGoesThroughTheWrapper() {
        val src = File("src/main/java")
        val offenders = src.walk().filter { it.extension == "kt" && it.name != "Kit.kt" }
            .filter { "properties = FullScreenDialog" in it.readText() }.map { it.name }.toList()
        assertEquals(emptyList<String>(), offenders)
    }

    /** Pixel 8-ish, density 2.625, an edge-to-edge app window of 1080 × 2400 px (411 × 914 dp). */
    @Test fun fillsTheScreenOnlyWhenTheContentIsMeasuredForIt() {
        // Android 15+ (target 35+): the Configuration counts the bars, so the window must cover them.
        assertTrue(FullScreenWindow.coversBars(914, 411, 2.625f, 2400, 1080))
        // Rounding down to whole dp still counts.
        assertTrue(FullScreenWindow.coversBars(913, 411, 2.625f, 2400, 1080))
        // Android 14 and older: the Configuration leaves out the status bar and the navigation bar (24 + 48 dp),
        // which is what the floating window covers already.
        assertFalse(FullScreenWindow.coversBars(842, 411, 2.625f, 2400, 1080))
        // Gesture navigation only leaves out the status bar and the gesture strip.
        assertFalse(FullScreenWindow.coversBars(866, 411, 2.625f, 2400, 1080))
        // Not laid out yet: leave the window alone.
        assertFalse(FullScreenWindow.coversBars(914, 411, 2.625f, 0, 0))
    }

    /** The chooser covers the screen with Done at the bottom. In a popup John saw no Done and got back to the
     *  tracker only with the back gesture (2026-11-04, gesture navigation, cause not found); it is drawn like the
     *  other full-screen screens now. */
    @Test fun theChooserIsAFullScreenDialog() {
        val src = File("src/main/java/site/table1/events/ui/tracker/TrackerOptions.kt").readText()
        val chooser = src.substringAfter("internal fun TrackerChooser(").substringBefore("\n}\n")
        assertTrue(chooser.contains("T1FullScreenDialog(onDismissRequest = onDismiss)"))
        assertFalse(chooser.contains("T1Overlay("))
        assertTrue(chooser.contains("navigationBarsPadding()"))
    }
}
