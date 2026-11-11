package site.table1.events.ui

import android.app.Application
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeUp
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import site.table1.events.ui.components.KeyboardAwayOnNavigate
import site.table1.events.ui.components.keyboardAwayOnTap

/** Keyboards go away on a tap outside the box and on every screen change (John, 2026-11-11: on Insights a tap on
 *  anything but a control left the keyboard up, and it was still up after going back; contract/keyboard-2026-11-11.md). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class KeyboardAwayTest {
    @get:Rule val rule = createComposeRule()

    private var focused = false
    private val history = mutableListOf<Boolean>()
    private var added = 0
    private val focus = FocusRequester()

    @Composable
    private fun Screen(content: @Composable () -> Unit = {}) {
        var text by remember { mutableStateOf("bolt") }
        Column(Modifier.fillMaxSize().keyboardAwayOnTap()) {
            BasicTextField(text, { text = it }, Modifier.fillMaxWidth().height(48.dp).testTag("box")
                .focusRequester(focus).onFocusChanged { focused = it.isFocused; history += it.isFocused })
            Text("Lightning Bolt · 4 decks", Modifier.height(48.dp)) // a row's label: takes no taps
            Text("Add", Modifier.height(48.dp).clickable { added++ })
            content()
        }
    }

    private fun focusBox() {
        rule.runOnIdle { focus.requestFocus() }
        rule.waitForIdle()
        assertTrue(focused)
        history.clear()
    }

    /** Whether the box gave up focus since `focusBox`. Robolectric's window isn't in touch mode, so Compose hands
     *  focus straight back to the first box after a clear (a phone being touched doesn't): watch the change. */
    private val lost get() = false in history

    @Test fun aTapOnSomethingThatTakesNoTapsPutsItAway() {
        rule.setContent { Screen() }
        focusBox()
        rule.onNodeWithText("Lightning Bolt · 4 decks").performClick()
        rule.waitForIdle()
        assertTrue(lost)
    }

    @Test fun aTapInTheBoxKeepsIt() {
        rule.setContent { Screen() }
        focusBox()
        rule.onNodeWithTag("box").performClick()
        rule.waitForIdle()
        assertFalse(lost)
    }

    @Test fun aButtonKeepsIt() {
        rule.setContent { Screen() }
        focusBox()
        rule.onNodeWithText("Add").performClick()
        rule.waitForIdle()
        assertEquals(1, added)
        assertFalse(lost)
    }

    @Test fun aDragIsntATap() {
        rule.setContent {
            Screen { LazyColumn(Modifier.height(200.dp).testTag("list")) { items(50) { Text("row $it", Modifier.height(40.dp)) } } }
        }
        focusBox()
        rule.onNodeWithTag("list").performTouchInput { swipeUp() }
        rule.waitForIdle()
        assertFalse(lost)
    }

    /** A screen that focuses its box as it opens (as Add cards does). */
    @Composable
    private fun Searching(seen: (Boolean) -> Unit) {
        val f = remember { FocusRequester() }
        LaunchedEffect(Unit) { f.requestFocus() }
        BasicTextField("", {}, Modifier.fillMaxWidth().height(48.dp).focusRequester(f).onFocusChanged { seen(it.isFocused) })
    }

    @Test fun screenChangesPutItAwayButAnOpeningScreenStillFocusesItsBox() {
        lateinit var nav: NavHostController
        val home = mutableListOf<Boolean>()
        val search = mutableListOf<Boolean>()
        rule.setContent {
            nav = rememberNavController()
            KeyboardAwayOnNavigate(nav)
            NavHost(nav, startDestination = "home") {
                composable("home") { Searching { home += it } }
                composable("search") { Searching { search += it } }
            }
        }
        rule.waitForIdle()
        assertEquals(true, home.lastOrNull())
        rule.runOnIdle { nav.navigate("search") }
        rule.waitForIdle()
        assertTrue("leaving put the first box's keyboard away", false in home)
        assertEquals("the opening screen takes the keyboard", true, search.lastOrNull())
        search.clear()
        rule.runOnIdle { nav.popBackStack() }
        rule.waitForIdle()
        assertTrue("Back put the second box's keyboard away", false in search)
    }
}
