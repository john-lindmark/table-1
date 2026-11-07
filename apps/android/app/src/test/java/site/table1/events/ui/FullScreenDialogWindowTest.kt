package site.table1.events.ui

import android.app.Application
import android.view.ViewGroup
import android.view.Window
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.window.DialogWindowProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import site.table1.events.ui.components.T1FullScreenDialog

/** On Android 15+ the dialog's window is made to cover the whole screen, so nothing at its bottom is cut off
 *  (Save to Photos / Share under the deck and ranking images, John 2026-11-06). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class, qualifiers = "w411dp-h914dp-xxhdpi")
class FullScreenDialogWindowTest {
    @get:Rule val rule = createComposeRule()

    @Test fun theWindowFillsTheScreen() {
        var window: Window? = null
        rule.setContent {
            T1FullScreenDialog(onDismissRequest = {}) {
                window = (LocalView.current.parent as? DialogWindowProvider)?.window
                Box(Modifier.fillMaxSize())
            }
        }
        rule.waitForIdle()
        assertNotNull(window)
        val attrs = window!!.attributes
        // MATCH_PARENT, or the display's pixels once the window has been laid out (Robolectric writes them back).
        val screen = window!!.context.resources.displayMetrics
        assertTrue(attrs.width == ViewGroup.LayoutParams.MATCH_PARENT || attrs.width >= screen.widthPixels)
        assertTrue(attrs.height == ViewGroup.LayoutParams.MATCH_PARENT || attrs.height >= screen.heightPixels)
        // Not kept between the system bars, where Compose's content (measured for the whole screen) didn't fit.
        assertEquals(0, attrs.fitInsetsTypes)
    }
}
