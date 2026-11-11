package site.table1.events.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import site.table1.events.library.SelectorRows
import site.table1.events.library.Sheet
import site.table1.events.ui.tracker.TrackerDicePanel

/**
 * Debug builds only: `--es t1Overlays menu|panel|sheet|dice|dialog` opens a screen that shows every kind of bottom
 * surface (contract/android-bottom-bars-2026-11-11.md), so their place over the navigation bar can be checked on an
 * emulator or phone without signing in, with gesture navigation and with the three buttons.
 */
object OverlayDebug {
    var open: String? = null
}

@Composable
fun OverlayGallery(start: String) {
    var open by rememberSaveable { mutableStateOf(start) }
    var note by remember { mutableStateOf("") }
    T1Screen {
        Bar("Bottom surfaces")
        listOf("menu" to "Menu (deck photo source)", "panel" to "Panel with a note", "sheet" to "Selector sheet",
            "dice" to "Roll dice", "dialog" to "Full-screen dialog").forEach { (key, label) ->
            ListRow(label, onClick = { open = key })
        }
        Spacer(Modifier.weight(1f))
        BigAction("Bottom of the screen") {}
    }
    when (open) {
        "menu" -> T1Menu("Ann Ito", listOf(
            T1MenuItem("Take a photo") {},
            T1MenuItem("Choose from photos") {},
        )) { open = "" }
        "panel" -> T1Panel("Ann Ito", onDismiss = { open = "" }, action = { BarAction("Save") { open = "" } }) {
            T1TextField(note, { note = it }, label = "Note", placeholder = "Sideboard plan, changes…")
            Spacer(Modifier.weight(1f))
            BigAction("Save note") { open = "" }
        }
        "sheet" -> Sheet({ open = "" }) {
            SelectorRows(listOf(Triple("nm", "Near mint", null), Triple("lp", "Lightly played", null),
                Triple("mp", "Moderately played", null), Triple("hp", "Heavily played", null), Triple("dmg", "Damaged", null)),
                current = "nm", title = "Condition") { open = "" }
        }
        "dice" -> TrackerDicePanel { open = "" }
        "dialog" -> T1FullScreenDialog({ open = "" }) {
            T1Screen {
                Bar("Deck image", onBack = { open = "" })
                Spacer(Modifier.weight(1f))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    Ghost("Save to Photos") {}
                    Ghost("Share") {}
                }
            }
        }
    }
}
