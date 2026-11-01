package site.table1.events.library

import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow

/*
 * Scroll positions for card lists whose rows are built off the main thread each time the screen is drawn (decks, cubes,
 * binders, All cards, shared lists). Back from card detail, the screen is drawn again with no rows for a moment; the list
 * state Compose saved is clamped to that short list, so the screen opened at the top. These keep the position themselves
 * and put it back once [ready] says the rows are in.
 */

@Composable
fun rememberKeptListState(ready: Boolean): LazyListState {
    val state = rememberLazyListState()
    KeepPosition(ready, { state.firstVisibleItemIndex to state.firstVisibleItemScrollOffset }) { i, o -> state.scrollToItem(i, o) }
    return state
}

@Composable
fun rememberKeptGridState(ready: Boolean): LazyGridState {
    val state = rememberLazyGridState()
    KeepPosition(ready, { state.firstVisibleItemIndex to state.firstVisibleItemScrollOffset }) { i, o -> state.scrollToItem(i, o) }
    return state
}

@Composable
private fun KeepPosition(ready: Boolean, position: () -> Pair<Int, Int>, scrollTo: suspend (Int, Int) -> Unit) {
    var index by rememberSaveable { mutableIntStateOf(0) }
    var offset by rememberSaveable { mutableIntStateOf(0) }
    // Not saved: each time the screen is drawn again, the position goes back once.
    var restored by remember { mutableStateOf(false) }
    LaunchedEffect(ready) {
        if (!ready || restored) return@LaunchedEffect
        if (index > 0 || offset > 0) scrollTo(index, offset)
        restored = true
    }
    // Only after that: before, the position is the clamped one.
    LaunchedEffect(restored) {
        if (restored) snapshotFlow(position).collect { (i, o) -> index = i; offset = o }
    }
}
