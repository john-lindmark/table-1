package site.table1.events.library

import android.app.Application
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Back from card detail, a card list opens where it was (John, 2026-11-01: it went back to the top). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class KeptScrollTest {
    @get:Rule val rule = createComposeRule()

    /** A deck screen in small: the rows come a frame after the screen is drawn, as card details are looked up again. */
    @Composable
    private fun Deck(kept: Boolean, seen: (LazyListState, CoroutineScope) -> Unit) {
        var ready by remember { mutableStateOf(false) }
        LaunchedEffect(Unit) { withFrameNanos {}; withFrameNanos {}; ready = true }
        val state = if (kept) rememberKeptListState(ready) else rememberLazyListState()
        seen(state, rememberCoroutineScope())
        LazyColumn(Modifier.height(400.dp), state) {
            item(key = "top") { Box(Modifier.height(120.dp)) }
            if (ready) items((0 until 100).toList(), key = { "r-$it" }) { Box(Modifier.height(48.dp)) }
        }
    }

    /** Scrolls to row 40, goes to card detail and back (the screen's composition is dropped, its saved state kept). */
    private fun backFromCard(kept: Boolean): Pair<Int, Int> {
        val tester = StateRestorationTester(rule)
        lateinit var state: LazyListState
        lateinit var scope: CoroutineScope
        tester.setContent { Deck(kept) { s, c -> state = s; scope = c } }
        rule.waitForIdle()
        rule.runOnIdle { scope.launch { state.scrollToItem(41, 17) } }
        rule.waitForIdle()
        tester.emulateSavedInstanceStateRestore()
        rule.waitForIdle()
        return rule.runOnIdle { state.firstVisibleItemIndex to state.firstVisibleItemScrollOffset }
    }

    @Test fun keptListOpensWhereItWas() {
        assertEquals(41 to 17, backFromCard(kept = true))
    }

    /** Compose's own saved position is clamped while the rows aren't in yet: the bug this guards against. */
    @Test fun plainListStateLosesItsPlace() {
        assertNotEquals(41 to 17, backFromCard(kept = false))
    }

    @Test fun openedPrintingsAreKept() {
        val tester = StateRestorationTester(rule)
        lateinit var printings: androidx.compose.runtime.MutableState<PrintingsDisclosure>
        tester.setContent { printings = rememberPrintingsDisclosure() }
        rule.runOnIdle { printings.value = printings.value.setAll(true).toggle("bolt") }
        tester.emulateSavedInstanceStateRestore()
        rule.runOnIdle { assertEquals(PrintingsDisclosure(all = true, flipped = setOf("bolt")), printings.value) }
    }
}
