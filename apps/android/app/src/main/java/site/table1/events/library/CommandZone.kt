package site.table1.events.library

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.sp
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
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Overlay
import androidx.compose.foundation.layout.safeDrawingPadding
import site.table1.events.ui.theme.T1

/* The command zone of a Commander or Oathbreaker deck (contract/command-zone-2026-10-27.md): its cards live in the
   deck's "commander" section. Commander decks name a commander and may add a partner or background; Oathbreaker decks
   name an oathbreaker (a planeswalker) and its signature spell (an instant or sorcery). Picked when the deck is made
   and changed from the deck screen. Cases shared with iOS and web in testdata/command-zone/cases.json. */

object CommandZone {
    const val BOARD = "commander"
    val FORMATS = setOf("commander", "oathbreaker")

    /** `label` sits above the slot's card, short enough for half a phone's width. */
    enum class Role(val wire: String, val title: String, val choose: String, val hint: String, val label: String = title) {
        Commander("commander", "Commander", "Choose a commander", "A legendary creature"),
        Partner("partner", "Partner or background", "Add a partner or background", "Optional: a second commander", "Partner"),
        Oathbreaker("oathbreaker", "Oathbreaker", "Choose an oathbreaker", "A planeswalker"),
        Signature("signature", "Signature spell", "Choose a signature spell", "An instant or sorcery");

        /** Whether a card of this type line can fill the slot. Lenient: the deck's legality check has the last word. */
        fun fits(typeLine: String): Boolean {
            val front = typeLine.split(" // ").first()
            val legend = front.contains("Legendary") && (front.contains("Creature") || front.contains("Planeswalker"))
            return when (this) {
                Commander -> legend
                // A Background only partners a commander that chooses one ([pairs]).
                Partner -> legend || front.contains("Background")
                Oathbreaker -> front.contains("Planeswalker")
                Signature -> front.contains("Instant") || front.contains("Sorcery")
            }
        }
    }

    /** `pair`: who the card shares the command zone with ([Mate]), null when the catalog doesn't say. */
    data class Line(val cardId: String, val typeLine: String, val finish: String = "nonfoil", val lang: String = "en", val pair: String? = null,
                    val cond: String = "NM")

    /** A card as a partner sees it (contract § Partners). `pair`: P partner, P:<name> partner with, G:<group>
     *  partner—group, F friends forever, B choose a Background, D doctor's companion, "" none, null unknown (an older
     *  catalog pack: lenient). */
    data class Mate(val typeLine: String, val pair: String?, val name: String) {
        val doctor get() = "Time Lord Doctor" in typeLine.split(" // ").first()
    }

    /** Whether a commander takes a second card in the command zone. */
    fun canPair(typeLine: String, pair: String?): Boolean = pair == null || pair.isNotEmpty() || Mate(typeLine, pair, "").doctor

    /** Whether [b] can be [a]'s partner: both partner, the named partner, the same group, both friends forever, a
     *  Background for a commander that chooses one, the Doctor and a companion. Unknown on either side is allowed. */
    fun pairs(a: Mate, b: Mate): Boolean {
        val pa = a.pair ?: return Role.Partner.fits(b.typeLine)
        val pb = b.pair ?: return Role.Partner.fits(b.typeLine)
        if (a.doctor && pb == "D") return true
        return when {
            pa == "P" || pa == "F" -> pb == pa
            pa == "B" -> "Background" in b.typeLine
            pa == "D" -> b.doctor
            pa.startsWith("P:") -> b.name == pa.removePrefix("P:")
            pa.startsWith("G:") -> pb == pa
            else -> false
        }
    }

    /** What the empty partner slot asks for, from the commander. */
    fun partnerHint(a: Mate): String {
        val pair = a.pair ?: return Role.Partner.hint
        if (pair.isEmpty() && a.doctor) return "A doctor's companion"
        return when {
            pair == "P" -> "Another commander with partner"
            pair == "F" -> "Another commander with friends forever"
            pair == "B" -> "A Background"
            pair == "D" -> "The Doctor"
            pair.startsWith("P:") -> pair.removePrefix("P:")
            pair.startsWith("G:") -> "Another with partner—${pair.removePrefix("G:")}"
            else -> Role.Partner.hint
        }
    }
    data class Slot(val role: Role, val cardId: String? = null, val finish: String = "nonfoil", val lang: String = "en", val cond: String = "NM")

    /** The slots a deck of this format shows, filled from its command-zone lines in order (see the contract). */
    fun slots(format: String, lines: List<Line>): List<Slot> = when (format) {
        "commander" -> {
            val out = lines.take(2).mapIndexed { i, l -> Slot(if (i == 0) Role.Commander else Role.Partner, l.cardId, l.finish, l.lang, l.cond) }.toMutableList()
            if (out.isEmpty()) out += Slot(Role.Commander)
            else if (out.size == 1 && canPair(lines[0].typeLine, lines[0].pair)) out += Slot(Role.Partner)
            out
        }
        "oathbreaker" -> listOf(Role.Oathbreaker, Role.Signature).map { role ->
            lines.firstOrNull { role.fits(it.typeLine) }?.let { Slot(role, it.cardId, it.finish, it.lang, it.cond) } ?: Slot(role)
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

    /** A deck line outside the command zone that could be moved in. */
    data class DeckLine(val cardId: String, val board: String, val typeLine: String, val finish: String = "nonfoil",
                        val lang: String = "en", val qty: Int = 1, val pair: String? = null, val cond: String = "NM")

    /** The deck's own cards a slot's picker offers first: main deck, then sideboard, those that fit. A deck made before
     *  the command zone has its commander in the main deck. */
    fun inDeck(role: Role, lines: List<DeckLine>): List<DeckLine> =
        listOf("main", "side").flatMap { b -> lines.filter { it.board == b && role.fits(it.typeLine) } }

    /** A list_edit change that moves a deck card into a slot. */
    sealed interface Op {
        /** Every copy of a line to another section. */
        data class Move(val cardId: String, val finish: String, val lang: String, val from: String, val to: String, val cond: String = "NM") : Op
        data class Delta(val cardId: String, val finish: String, val lang: String, val board: String, val by: Int, val cond: String = "NM") : Op
    }

    /** The changes that put one copy of [line] in [slot]: the slot's card (if any) goes to the main deck; a single copy
     *  moves, one of several moves by deltas. */
    fun movingIn(line: DeckLine, slot: Slot): List<Op> = buildList {
        slot.cardId?.let { add(Op.Move(it, slot.finish, slot.lang, BOARD, "main", slot.cond)) }
        if (line.qty <= 1) add(Op.Move(line.cardId, line.finish, line.lang, line.board, BOARD, line.cond))
        else {
            add(Op.Delta(line.cardId, line.finish, line.lang, line.board, -1, line.cond))
            add(Op.Delta(line.cardId, line.finish, line.lang, BOARD, 1, line.cond))
        }
    }

    /** What a command-zone line is called on the deck screen. */
    fun roleName(format: String, typeLine: String) =
        if (format == "oathbreaker") (if (Role.Oathbreaker.fits(typeLine)) "Oathbreaker" else "Signature spell") else "Commander"
}

/** A card already in the deck, outside the command zone, with its name and art. */
data class ZoneDeckCard(val line: CommandZone.DeckLine, val name: String, val printing: CatalogPrinting?)

/** Full screen: the catalog by name (or Scryfall syntax), filtered to cards that can fill the slot. A tap picks the card
 *  in its original paper printing. On a deck screen the deck's own cards that fit come first, and a tap moves that copy
 *  in (a deck made before the command zone has its commander in the main deck). */
@Composable
fun CommandZonePicker(role: CommandZone.Role, onDismiss: () -> Unit, deck: List<ZoneDeckCard> = emptyList(),
                      onPickDeck: ((ZoneDeckCard) -> Unit)? = null, partnerOf: CommandZone.Mate? = null,
                      onPick: (CatalogOracle, CatalogPrinting) -> Unit) {
    val cat by CatalogStore.state.collectAsState()
    // Partner with names its partner: search for it straight away.
    var query by remember { mutableStateOf(partnerOf?.pair?.takeIf { it.startsWith("P:") }?.removePrefix("P:") ?: "") }
    val result = rememberCardSearch(query)
    fun mates(typeLine: String, pair: String?, name: String) =
        role != CommandZone.Role.Partner || partnerOf == null || CommandZone.pairs(partnerOf, CommandZone.Mate(typeLine, pair, name))
    val hint = partnerOf?.let(CommandZone::partnerHint) ?: role.hint
    val fit = CommandZone.inDeck(role, deck.map { it.line }).toSet()
    val fromDeck = if (onPickDeck == null) emptyList()
        else deck.filter { it.line in fit && mates(it.line.typeLine, it.line.pair, it.name) && (query.isBlank() || CardSearch.matches(query, it.name, it.line.typeLine)) }
    val hits = if (query.isBlank()) emptyList() else result?.hits.orEmpty().filter { role.fits(it.typeLine) && mates(it.typeLine, it.pair, it.name) }
    val covers = result?.covers ?: emptyMap()
    LaunchedEffect(Unit) { CatalogStore.load(userInitiated = true) }
    fun pick(o: CatalogOracle) {
        val p = covers[o.idx] ?: return
        onDismiss()
        onPick(o, p)
    }
    T1Overlay(onDismiss) {
        Column(Modifier.fillMaxSize().background(T1.bg).safeDrawingPadding(), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Bar(role.title, subtitle = hint) { BarAction("Cancel", onDismiss) }
            CatalogStatus(cat)
            CardSearchBar(query, { query = it }, placeholder = role.hint, label = "Card", onSubmit = { hits.firstOrNull()?.let(::pick) })
            LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                if (fromDeck.isNotEmpty()) {
                    item { Section("In this deck") }
                    items(fromDeck, key = { "deck|${it.line}" }) { d ->
                        CardRow(d.printing, d.name, d.line.typeLine, onClick = { onDismiss(); onPickDeck?.invoke(d) }) { Label("Move in", color = T1.text) }
                    }
                    if (hits.isNotEmpty()) item { Section("All cards") }
                }
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

/** "Command zone" and its cards side by side: commander | partner or background, oathbreaker | signature spell. A filled
 *  card offers Open card / Change / Remove; an empty one opens the picker. `card` gives a slot's name and printing. */
@Composable
fun CommandZoneCards(slots: List<CommandZone.Slot>, card: (CommandZone.Slot) -> Pair<String, CatalogPrinting?>?, onChoose: (CommandZone.Slot) -> Unit,
                     onRemove: (CommandZone.Slot) -> Unit, onOpen: ((CommandZone.Slot) -> Unit)? = null,
                     /** The commander, so an empty partner slot names what it pairs with. */
                     commander: CommandZone.Mate? = null) {
    var menu by remember { mutableStateOf<CommandZone.Slot?>(null) }
    Section("Command zone")
    BoxWithConstraints(Modifier.fillMaxWidth().background(T1.bg).padding(16.dp)) {
        val w = ((maxWidth - 16.dp) / 2).coerceAtMost(220.dp)
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.Top) {
            slots.forEach { slot ->
                val c = card(slot)
                Column(Modifier.width(w).clickable { if (slot.cardId == null) onChoose(slot) else menu = slot },
                       verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Label(slot.role.label)
                    if (slot.cardId != null && c?.second != null) {
                        CardArt(c.second, w, finish = slot.finish)
                    } else {
                        Column(Modifier.size(w, w / CARD_ASPECT).clip(RoundedCornerShape(w * 0.0432f)).background(T1.surface).padding(12.dp),
                               verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically), horizontalAlignment = Alignment.CenterHorizontally) {
                            if (slot.cardId == null) Text("+", color = T1.text, fontFamily = T1.mono, fontSize = 28.sp)
                            Text(if (slot.cardId == null) slot.role.choose else c?.first ?: "…", color = T1.text, fontFamily = T1.mono, fontSize = 13.sp, textAlign = TextAlign.Center)
                            if (slot.cardId == null) Text(if (slot.role == CommandZone.Role.Partner && commander != null) CommandZone.partnerHint(commander) else slot.role.hint, color = T1.muted, fontFamily = T1.mono, fontSize = 11.sp, textAlign = TextAlign.Center)
                        }
                    }
                }
            }
        }
    }
    menu?.let { slot ->
        T1Menu(card(slot)?.first, listOfNotNull(
            onOpen?.let { T1MenuItem("Open card") { it(slot) } },
            T1MenuItem("Change ${slot.role.title.lowercase()}") { onChoose(slot) },
            T1MenuItem("Remove", danger = true) { onRemove(slot) },
        ), onDismiss = { menu = null })
    }
}
