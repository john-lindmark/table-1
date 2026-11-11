package site.table1.events.ui.components

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.focus.FocusManager
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.SoftwareKeyboardController
import androidx.navigation.NavController
import site.table1.events.util.Telemetry

/* Keyboards go away the way people expect (contract/keyboard-2026-11-11.md): a tap on anything that isn't a text box
   or a control (a row's label, a heading, a chart, the empty space under a list), and every move to another screen.
   Compose has neither of its own: a focused box keeps the keyboard up until something clears focus. */

/** Put the keyboard away on a tap that nothing under it took. Text boxes, buttons, rows and lists take their own
 *  taps and drags (they consume them), so typing, Add while typing names, and scrolling are left alone. Put it on a
 *  root (the app, a full-screen dialog, an overlay). */
@OptIn(ExperimentalLayoutApi::class)
fun Modifier.keyboardAwayOnTap(): Modifier = composed {
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val up by rememberUpdatedState(WindowInsets.isImeVisible)
    pointerInput(Unit) {
        awaitEachGesture {
            awaitFirstDown(requireUnconsumed = false)
            // Null when a child took the tap (consumed it), it turned into a drag, or it left the screen.
            waitForUpOrCancellation() ?: return@awaitEachGesture
            KeyboardAway.put(focus, keyboard, if (up) "tap" else null)
        }
    }
}

/** Put the keyboard away whenever the screen changes (a push, Back, a tab), before the next screen is drawn, so a
 *  screen that focuses its own box as it opens still gets the keyboard. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun KeyboardAwayOnNavigate(nav: NavController) {
    val focus = LocalFocusManager.current
    val keyboard by rememberUpdatedState(LocalSoftwareKeyboardController.current)
    val up by rememberUpdatedState(WindowInsets.isImeVisible)
    DisposableEffect(nav) {
        var first = true
        val listener = NavController.OnDestinationChangedListener { _, _, _ ->
            if (first) first = false else KeyboardAway.put(focus, keyboard, if (up) "navigate" else null)
        }
        nav.addOnDestinationChangedListener(listener)
        onDispose { nav.removeOnDestinationChangedListener(listener) }
    }
}

object KeyboardAway {
    /** `how` names the telemetry event's reason; null when the keyboard wasn't up (nothing to count). */
    fun put(focus: FocusManager, keyboard: SoftwareKeyboardController?, how: String?) {
        if (how != null) Telemetry.capture("keyboard_dismissed", mapOf("how" to how))
        focus.clearFocus(force = true)
        keyboard?.hide()
    }
}
