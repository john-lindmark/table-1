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
}
