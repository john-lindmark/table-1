package site.table1.events.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import site.table1.events.ui.components.FullScreenDialog
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

    /** The chooser covers the screen with Done at the bottom; drawn in a popup, Done sat behind the navigation bar
     *  and the only way back to the tracker was the back gesture (John, 2026-11-04). */
    @Test fun theChooserIsAFullScreenDialog() {
        val src = File("src/main/java/site/table1/events/ui/tracker/TrackerOptions.kt").readText()
        val chooser = src.substringAfter("internal fun TrackerChooser(").substringBefore("\n}\n")
        assertTrue(chooser.contains("Dialog(onDismissRequest = onDismiss, properties = FullScreenDialog)"))
        assertFalse(chooser.contains("T1Overlay("))
        assertTrue(chooser.contains("navigationBarsPadding()"))
    }
}
