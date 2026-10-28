package site.table1.events.library

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Overlay
import site.table1.events.ui.theme.T1

/* The command zone of a Commander or Oathbreaker deck (contract/command-zone-2026-10-27.md): its cards live in the
   deck's "commander" section. Commander decks name a commander and may add a partner or background; Oathbreaker decks
   name an oathbreaker (a planeswalker) and its signature spell (an instant or sorcery). Picked when the deck is made
   and changed from the deck screen. Cases shared with iOS and web in testdata/command-zone/cases.json. */

object CommandZone {
    const val BOARD = "commander"
    val FORMATS = setOf("commander", "oathbreaker")

    enum class Role(val wire: String, val title: String, val choose: String, val hint: String) {
        Commander("commander", "Commander", "Choose a commander", "A legendary creature"),
        Partner("partner", "Partner or background", "Add a partner or background", "Optional: a second commander"),
        Oathbreaker("oathbreaker", "Oathbreaker", "Choose an oathbreaker", "A planeswalker"),
        Signature("signature", "Signature spell", "Choose a signature spell", "An instant or sorcery");

        /** Whether a card of this type line can fill the slot. Lenient: the deck's legality check has the last word. */
        fun fits(typeLine: String): Boolean {
            val front = typeLine.split(" // ").first()
            return when (this) {
                Commander, Partner -> front.contains("Background") ||
                    (front.contains("Legendary") && (front.contains("Creature") || front.contains("Planeswalker")))
                Oathbreaker -> front.contains("Planeswalker")
                Signature -> front.contains("Instant") || front.contains("Sorcery")
            }
        }
    }

    data class Line(val cardId: String, val typeLine: String, val finish: String = "nonfoil", val lang: String = "en")
    data class Slot(val role: Role, val cardId: String? = null, val finish: String = "nonfoil", val lang: String = "en")

    /** The slots a deck of this format shows, filled from its command-zone lines in order (see the contract). */
    fun slots(format: String, lines: List<Line>): List<Slot> = when (format) {
        "commander" -> {
            val out = lines.take(2).mapIndexed { i, l -> Slot(if (i == 0) Role.Commander else Role.Partner, l.cardId, l.finish, l.lang) }.toMutableList()
            if (out.size < 2) out += Slot(if (out.isEmpty()) Role.Commander else Role.Partner)
            out
        }
        "oathbreaker" -> listOf(Role.Oathbreaker, Role.Signature).map { role ->
            lines.firstOrNull { role.fits(it.typeLine) }?.let { Slot(role, it.cardId, it.finish, it.lang) } ?: Slot(role)
        }
        else -> emptyList()
    }

    /** The lines after filling a slot: its card replaced in place, or the new card added after the others. */
    fun filling(lines: List<Line>, slotCard: String?, next: Line): List<Line> {
        val out = lines.filter { it.cardId != next.cardId || it.cardId == slotCard }.toMutableList()
        val i = if (slotCard == null) -1 else out.indexOfFirst { it.cardId == slotCard }
        if (i >= 0) out[i] = next else out += next
        return out
    }

    /** What a command-zone line is called on the deck screen. */
    fun roleName(format: String, typeLine: String) =
        if (format == "oathbreaker") (if (Role.Oathbreaker.fits(typeLine)) "Oathbreaker" else "Signature spell") else "Commander"
}

/** Full screen: the catalog by name (or Scryfall syntax), filtered to cards that can fill the slot. A tap picks the card
 *  in its original paper printing. */
@Composable
fun CommandZonePicker(role: CommandZone.Role, onDismiss: () -> Unit, onPick: (CatalogOracle, CatalogPrinting) -> Unit) {
    val cat by CatalogStore.state.collectAsState()
    var query by remember { mutableStateOf("") }
    val result = rememberCardSearch(query)
    val hits = if (query.isBlank()) emptyList() else result?.hits.orEmpty().filter { role.fits(it.typeLine) }
    val covers = result?.covers ?: emptyMap()
    LaunchedEffect(Unit) { CatalogStore.load(userInitiated = true) }
    fun pick(o: CatalogOracle) {
        val p = covers[o.idx] ?: return
        onDismiss()
        onPick(o, p)
    }
    T1Overlay(onDismiss) {
        Column(Modifier.fillMaxSize().background(T1.bg).statusBarsPadding(), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Bar(role.title, subtitle = role.hint) { BarAction("Cancel", onDismiss) }
            CatalogStatus(cat)
            CardSearchBar(query, { query = it }, placeholder = role.hint, label = "Card", onSubmit = { hits.firstOrNull()?.let(::pick) })
            LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                if (cat.phase == "ready" && result != null && CardName.norm(query).length >= 2 && hits.isEmpty()) {
                    item { QuietRow("No ${role.title.lowercase()} by that name") }
                }
                items(hits, key = { it.idx }) { o ->
                    CardRow(covers[o.idx], o.name, if (o.manaCost.isEmpty()) o.typeLine else "${o.typeLine} · ${o.manaCost}", onClick = { pick(o) })
                }
            }
        }
    }
}

/** One slot as a row: the card (tap for Change / Remove) or the empty slot (tap to choose). */
@Composable
fun CommandZoneRow(slot: CommandZone.Slot, printing: CatalogPrinting?, name: String?, onChoose: () -> Unit, onRemove: () -> Unit,
                   onOpen: (() -> Unit)? = null) {
    var menu by remember { mutableStateOf(false) }
    if (slot.cardId == null) {
        ListRow(slot.role.choose, slot.role.hint, onClick = onChoose) { Label("Choose", color = T1.text) }
        return
    }
    CardRow(printing, name ?: "…", slot.role.title, onClick = { menu = true }) { Label("Change", color = T1.text) }
    if (menu) {
        T1Menu(name, listOfNotNull(
            onOpen?.let { T1MenuItem("Open card", onClick = it) },
            T1MenuItem("Change ${slot.role.title.lowercase()}", onClick = onChoose),
            T1MenuItem("Remove", danger = true, onClick = onRemove),
        ), onDismiss = { menu = false })
    }
}
