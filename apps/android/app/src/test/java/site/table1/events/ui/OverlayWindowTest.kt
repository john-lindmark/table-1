package site.table1.events.ui

import android.app.Application
import android.view.ViewGroup
import android.view.Window
import android.view.WindowManager
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
import site.table1.events.ui.components.T1Overlay
import java.io.File

/**
 * Bottom menus, panels and sheets (contract/android-bottom-bars-2026-11-11.md). T1Overlay was a Compose Popup, laid
 * out between the system bars but measured for the whole screen on Android 15+, so its bottom was cut off by the
 * bars' height: the deck photo menu showed Take a photo without Choose from photos or Cancel, with three-button and
 * gesture navigation alike (John, 2026-11-11; seen on an Android 15 emulator).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class, qualifiers = "w411dp-h914dp-xxhdpi")
class OverlayWindowTest {
    @get:Rule val rule = createComposeRule()

    @Test fun theOverlayFillsTheScreenWithOnlyOurScrim() {
        var window: Window? = null
        rule.setContent {
            T1Overlay(onDismiss = {}) {
                window = (LocalView.current.parent as? DialogWindowProvider)?.window
                Box(Modifier.fillMaxSize())
            }
        }
        rule.waitForIdle()
        assertNotNull("an overlay is a dialog window now, not a popup", window)
        val attrs = window!!.attributes
        val screen = window!!.context.resources.displayMetrics
        assertTrue(attrs.width == ViewGroup.LayoutParams.MATCH_PARENT || attrs.width >= screen.widthPixels)
        assertTrue(attrs.height == ViewGroup.LayoutParams.MATCH_PARENT || attrs.height >= screen.heightPixels)
        assertEquals(0, attrs.fitInsetsTypes)
        // The scrim is ours: no platform dim on top of it, and no dialog animation (the popup had none).
        assertEquals(0, attrs.flags and WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        assertEquals(0, attrs.windowAnimations)
    }

    /** No screen draws a Popup of its own, and nothing drawn over the scrim pads its bottom for the navigation bar
     *  alone: sheetInsets() also clears the keyboard and a side bar or cutout in landscape. */
    @Test fun everyOverlayUsesTheSameRule() {
        val src = File("src/main/java")
        assertTrue("run from the app module", src.isDirectory)
        val files = src.walk().filter { it.extension == "kt" }.toList()
        assertEquals(emptyList<String>(), files.filter { "Popup(" in it.readText() }.map { it.name })
        val offenders = files.flatMap { f ->
            val text = f.readText()
            text.split("T1Overlay(").drop(1).mapNotNull { body ->
                // The overlay's own body: up to the next top-level declaration.
                val own = body.substringBefore("\n}\n")
                if ("navigationBarsPadding()" in own || "statusBarsPadding()" in own) f.name else null
            }
        }
        assertEquals(emptyList<String>(), offenders.distinct())
    }
}
