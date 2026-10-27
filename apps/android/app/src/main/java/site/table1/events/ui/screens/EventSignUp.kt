package site.table1.events.ui.screens

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import site.table1.events.data.BracketStage
import site.table1.events.data.EventBundle
import site.table1.events.data.EventPage
import site.table1.events.data.EventRow
import site.table1.events.data.EventRules
import site.table1.events.data.ParticipantRow
import site.table1.events.data.Repo
import site.table1.events.data.WebLink
import site.table1.events.library.CatalogStore
import site.table1.events.library.ListExport
import site.table1.events.library.ListKind
import site.table1.events.library.ListsStore
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Ghost
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1AlertDialog
import site.table1.events.ui.components.T1Panel
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1Stepper
import site.table1.events.ui.components.T1Switch
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

// Scheduled events, the sign-up link, the waitlist, top 8 and decklists (contract/scheduled-events-2026-10-27.md):
// the form pieces Create and Setup → Details share, the waitlist and bracket rows, the decklist panel and the in-app
// event page behind https://table-1.site/s/<id>.

/** The share sheet with the event's sign-up link (the standings page once round 1 is paired). */
fun shareEventLink(context: android.content.Context, e: EventRow) {
    val whenText = EventRules.whenText(e.startsAt)?.let { " · $it" } ?: ""
    val text = "${e.name}$whenText\n${if (e.beforeRoundOne) "Sign up" else "Standings"}: ${WebLink.standingsUrl(e.id)}"
    Telemetry.capture("event_link_shared", mapOf("before_round_1" to e.beforeRoundOne))
    context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), null))
}

/** When, where and the cap (create_event_v2's schedule fields, set_event_schedule). */
data class ScheduleDraft(val startsAt: LocalDateTime? = null, val venue: String = "", val capacity: Int? = null) {
    val iso: String? get() = startsAt?.atZone(ZoneId.systemDefault())?.toInstant()?.toString()
    val localDate: String get() = (startsAt?.toLocalDate() ?: LocalDate.now()).toString()

    companion object {
        fun from(e: EventRow) = ScheduleDraft(
            startsAt = e.startsAt?.let { s -> runCatching { java.time.OffsetDateTime.parse(s).atZoneSameInstant(ZoneId.systemDefault()).toLocalDateTime() }.getOrNull() },
            venue = e.venueName ?: "",
            capacity = e.capacity,
        )
        /** Tomorrow at 18:00 here, a usual store night. */
        fun defaultStart(): LocalDateTime = LocalDate.now().plusDays(1).atTime(18, 0)
    }
}

/** − value + for the day and the time (15-minute steps), in the T1 style. */
@Composable
private fun StepRow(title: String, value: String, minusEnabled: Boolean = true, onMinus: () -> Unit, onPlus: () -> Unit) {
    Row(Modifier.fillMaxWidth().background(T1.surface), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f).padding(horizontal = 16.dp, vertical = 12.dp)) {
            Label(title)
            Text(value, color = T1.text, fontFamily = T1.mono, fontSize = 16.sp)
        }
        Text("−", color = if (minusEnabled) T1.text else T1.muted, fontSize = 20.sp,
            modifier = Modifier.background(T1.bg).clickable(enabled = minusEnabled, onClick = onMinus).padding(horizontal = 22.dp, vertical = 14.dp))
        Text("+", color = T1.text, fontSize = 20.sp,
            modifier = Modifier.padding(start = 1.dp).background(T1.bg).clickable(onClick = onPlus).padding(horizontal = 22.dp, vertical = 14.dp))
    }
}

@Composable
fun ScheduleBlock(value: ScheduleDraft, onChange: (ScheduleDraft) -> Unit) {
    val start = value.startsAt
    FormBlock("When") {
        T1Segmented(listOf("Now", "Later"), if (start == null) 0 else 1) {
            onChange(value.copy(startsAt = if (it == 1) start ?: ScheduleDraft.defaultStart() else null))
        }
    }
    if (start != null) {
        val now = LocalDateTime.now()
        val max = now.plusDays(365)
        StepRow("Day", DateTimeFormatter.ofPattern("EEE d MMM yyyy", Locale.getDefault()).format(start),
            minusEnabled = start.minusDays(1).isAfter(now),
            onMinus = { onChange(value.copy(startsAt = start.minusDays(1))) },
            onPlus = { if (start.plusDays(1).isBefore(max)) onChange(value.copy(startsAt = start.plusDays(1))) })
        StepRow("Time", DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).format(start),
            minusEnabled = start.minusMinutes(15).isAfter(now),
            onMinus = { onChange(value.copy(startsAt = start.minusMinutes(15))) },
            onPlus = { onChange(value.copy(startsAt = start.plusMinutes(15))) })
        Notice("Shown on the event and its sign-up link. You still start round 1 yourself.")
    }
    FormBlock("Where") {
        T1TextField(value.venue, { onChange(value.copy(venue = it.take(80))) }, placeholder = "Venue (optional)")
    }
    ListRow("Player cap", value.capacity?.let { "$it players" } ?: "No cap",
        onClick = { onChange(value.copy(capacity = if (value.capacity == null) 8 else null)) }) {
        T1Switch(value.capacity != null) { onChange(value.copy(capacity = if (it) value.capacity ?: 8 else null)) }
    }
    value.capacity?.let { cap ->
        FormBlock("Cap") { T1Stepper(null, cap, 4..512, Modifier.fillMaxWidth()) { onChange(value.copy(capacity = it)) } }
        Notice("Sign-ups past the cap join a waitlist. You can still add players yourself.")
    }
}

/** Automatic rounds and the top cut (Swiss events of players), then the rounds stepper when set by hand. */
@Composable
fun CutRoundsBlock(
    autoRounds: Boolean, onAutoRounds: (Boolean) -> Unit, rounds: Int, onRounds: (Int) -> Unit,
    topCut: Int, onTopCut: (Int) -> Unit, players: Int, swiss: Boolean,
) {
    if (swiss) {
        ListRow("Automatic rounds", if (autoRounds) EventRules.autoLabel(players) else "Set by hand", onClick = { onAutoRounds(!autoRounds) }) {
            T1Switch(autoRounds) { onAutoRounds(it) }
        }
    }
    if (!swiss || !autoRounds) {
        FormBlock("Rounds") { T1Stepper(null, rounds, 1..15, Modifier.fillMaxWidth()) { onRounds(it) } }
    }
    if (swiss) {
        FormBlock("Top cut") { T1Segmented(listOf("None", "Top 8"), if (topCut == 8) 1 else 0) { onTopCut(if (it == 1) 8 else 0) } }
        if (topCut == 8) {
            Notice(if (players > 8 || players < 2) "After Swiss, the top 8 play single elimination: quarterfinals, semifinals, final."
                   else "Top 8 needs 9 or more players: with $players the event ends after Swiss.")
        }
    }
}

private val decklistModes = listOf("off" to "Off", "optional" to "Optional", "required" to "Required")

/** Decklists for constructed events: off, optional or required before round 1. */
@Composable
fun DecklistsBlock(mode: String, onMode: (String) -> Unit) {
    FormBlock("Decklists") {
        T1Segmented(decklistModes.map { it.second }, decklistModes.indexOfFirst { it.first == mode }.coerceAtLeast(0)) {
            onMode(decklistModes[it].first)
        }
    }
    when (mode) {
        "required" -> Notice("Players add their list as text or from their Table 1 decks. Round 1 waits until every list is in.")
        "optional" -> Notice("Players can add their list as text or from their Table 1 decks. Only you see them.")
    }
}

/** "Decklist ✓" / "No decklist" for a player's row (events that take lists). */
fun EventBundle.decklistDetail(p: ParticipantRow): String? =
    if (!event.takesDecklists) null else if (decklist(p.id) == null) "No decklist" else "Decklist ✓"

/** Setup → Players: the waitlist with Let in (past the cap) and Remove. */
fun LazyListScope.waitlistItems(b: EventBundle, busy: Boolean, act: (suspend () -> Unit) -> Unit) {
    if (b.waitlist.isEmpty()) return
    item { Section("Waitlist · ${b.waitlist.size}") }
    items(b.waitlist, key = { "w-${it.userId}" }) { w ->
        ListRow("#${w.position} ${w.displayName}", if (b.event.beforeRoundOne) null else "Didn't get in") {
            if (b.event.beforeRoundOne) {
                Label("Let in", Modifier.clickable(enabled = !busy) { act { Repo.waitlistAdmit(b.event.id, w.userId) } }, color = T1.accent)
                Label("Remove", Modifier.padding(start = 16.dp).clickable(enabled = !busy) { act { Repo.waitlistRemove(b.event.id, w.userId) } }, color = T1.danger)
            }
        }
    }
}

/** Standings → Top 8: each playoff stage paired so far, "(1) Ana 2–0 (8) Bo", the winner in the accent. */
fun LazyListScope.bracketItems(bracket: List<BracketStage>) {
    if (bracket.isEmpty()) return
    item { Section("Top 8") }
    for (stage in bracket) {
        item(key = "stage-${stage.stage}") { Label(stage.title, Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) }
        items(stage.matches, key = { "bm-${it.matchId}" }) { m ->
            Row(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                BracketSide(m, 0, Modifier.weight(1f))
                Text(if (m.status == "pending") "v" else "${m.sides.getOrNull(0)?.gameWins ?: 0}–${m.sides.getOrNull(1)?.gameWins ?: 0}",
                    color = T1.muted, fontFamily = T1.mono, fontSize = 14.sp)
                BracketSide(m, 1, Modifier.weight(1f))
            }
        }
    }
    item { Section("Standings") }
}

@Composable
private fun BracketSide(m: BracketStage.Match, n: Int, modifier: Modifier) {
    val s = m.sides.getOrNull(n)
    val won = s?.participantId != null && s.participantId == m.winner
    Text("(${s?.seed ?: "–"}) ${s?.displayName ?: "—"}", modifier, color = if (won) T1.accent else T1.text, fontFamily = T1.mono,
        fontSize = 14.sp, fontWeight = if (won) FontWeight.Bold else FontWeight.Normal, maxLines = 1,
        textAlign = if (n == 0) androidx.compose.ui.text.style.TextAlign.Start else androidx.compose.ui.text.style.TextAlign.End)
}

/**
 * A player's decklist for a constructed event (or, for the organizer, anyone's): from your decks in the event's format,
 * or pasted text, with the counts as you type. Players change theirs until round 1; organizers any time.
 */
@Composable
fun DecklistPanel(event: EventRow, participantId: String, playerName: String, byOrganizer: Boolean, onClose: (Boolean) -> Unit) {
    val scope = rememberCoroutineScope()
    val lists by ListsStore.state.collectAsState()
    var source by remember { mutableStateOf(if (byOrganizer) "text" else "deck") }
    var text by remember { mutableStateOf("") }
    var listId by remember { mutableStateOf<String?>(null) }
    var sent by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val locked = !byOrganizer && !event.beforeRoundOne
    val want = EventRules.deckFormat(event.formatName)
    val decks = lists.lists.filter { it.kind == ListKind.Deck && (want == null || it.format == want) }
    val counts = EventRules.decklistCounts(text)

    LaunchedEffect(participantId) {
        if (!byOrganizer) Repo.userId?.let { runCatching { ListsStore.start(it) } }
        CatalogStore.load(userInitiated = true)
        runCatching { Repo.decklist(participantId) }.getOrNull()?.let { d ->
            text = d.body
            listId = d.listId
            if (d.listId == null) source = "text"
            sent = EventRules.countsText(d.mainCount, d.sideCount) + (d.listName?.let { " · from $it" } ?: "")
        }
    }

    fun run(block: suspend () -> Unit) {
        busy = true
        error = null
        scope.launch {
            try {
                block()
                onClose(true)
            } catch (e: Exception) {
                error = userMessage(e)
            } finally {
                busy = false
            }
        }
    }

    T1Panel(title = "Decklist", onDismiss = { onClose(false) }) {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            ListRow(playerName, event.label)
            sent?.let { ListRow("Sent", it) }
            if (locked) {
                Notice("Decklists lock when round 1 is paired. Ask the organizer to change yours.")
                if (text.isNotEmpty()) Text(text, Modifier.fillMaxWidth().background(T1.surface).padding(16.dp), color = T1.text, fontFamily = T1.mono, fontSize = 13.sp)
            } else {
                if (!byOrganizer) T1Segmented(listOf("From my decks", "Paste text"), if (source == "deck") 0 else 1) { source = if (it == 0) "deck" else "text" }
                if (source == "deck" && !byOrganizer) {
                    if (decks.isEmpty()) Notice("No decks in this format in your Library yet. Paste the list instead.")
                    for (d in decks) {
                        ListRow(d.name, "${d.count("main")} main · ${d.count("side")} sideboard", onClick = {
                            val db = CatalogStore.db
                            if (db == null) {
                                error = "The card data is still loading. Try again in a moment, or paste the list."
                            } else {
                                val (lines, left) = ListExport.lines(d.entries.filter { it.board != "maybe" }, db)
                                text = ListExport.render(lines, ListKind.Deck, ListExport.Format.Text)
                                listId = d.id
                                error = if (left > 0) "$left card${if (left == 1) "" else "s"} in that deck aren't in the card data yet and were left out." else null
                            }
                        }) { if (listId == d.id) Label("Picked", color = T1.accent) }
                    }
                }
                if (source == "text" || byOrganizer || listId != null) {
                    FormBlock(if (listId == null) "The list" else "From your deck") {
                        BasicTextField(text, { if (listId == null || source == "text") { text = it; listId = null } },
                            Modifier.fillMaxWidth().heightIn(min = 180.dp),
                            textStyle = TextStyle(color = T1.text, fontFamily = T1.mono, fontSize = 13.sp), cursorBrush = SolidColor(T1.accent))
                    }
                    ListRow(EventRules.countsText(counts.main, counts.side), "One card a line: 4 Lightning Bolt. Sideboard after a Sideboard line or a blank line.")
                }
                error?.let { Notice(it, error = true) }
                Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    if (sent != null) Ghost("Remove", enabled = !busy) { run { Repo.removeDecklist(participantId) } }
                    Ghost(if (busy) "Sending…" else if (sent == null) "Send" else "Send again", enabled = !busy && counts.main > 0, accent = true) {
                        run { Repo.submitDecklist(participantId, text, listId, byOrganizer) }
                    }
                }
            }
        }
    }
}

/**
 * What anyone with the link sees before round 1: when, where, how many are in, and Sign up / the waitlist.
 * Organizers and players go to the event itself; after round 1 the link is the standings page on the web.
 */
@Composable
fun EventPageScreen(eventId: String, signUpNow: Boolean, onBack: () -> Unit, onOpenEvent: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    var page by remember { mutableStateOf<EventPage?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    var confirmLeave by remember { mutableStateOf(false) }
    var signedUpOnce by remember { mutableStateOf(false) }
    val state = EventRules.button(true, page?.signUp, page?.me)

    fun load(then: (() -> Unit)? = null) = scope.launch {
        page = runCatching { Repo.eventPage(eventId) }.getOrElse { EventPage() }
        then?.invoke()
    }

    fun signUp() {
        signedUpOnce = true
        busy = true
        error = null
        scope.launch {
            try {
                val r = Repo.signUp(eventId, signUpNow)
                message = if (r.status == "waitlisted" || r.status == "already_waitlisted") "It's full, so you're on the waitlist (number ${r.position ?: 1})." else "You're signed up."
                page = Repo.eventPage(eventId)
            } catch (e: Exception) {
                error = userMessage(e)
            } finally {
                busy = false
            }
        }
    }

    LaunchedEffect(eventId) {
        load {
            Telemetry.capture("event_page_viewed", mapOf("state" to state))
            val s = EventRules.button(true, page?.signUp, page?.me)
            if (signUpNow && !signedUpOnce && (s == "sign_up" || s == "waitlist")) signUp()
        }
    }

    val p = page
    T1Screen {
        Bar(p?.name ?: "Event", p?.shortCode?.let { "Event $it" }, onBack = onBack)
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (p != null && p.available) {
                Column(Modifier.fillMaxWidth().background(T1.surface).padding(20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(p.name ?: "Event", color = T1.text, fontFamily = T1.mono, fontSize = 22.sp)
                    if (p.facts.isNotEmpty()) Text(p.facts, color = T1.muted, fontFamily = T1.mono, fontSize = 12.sp)
                    Label(p.roundsLine)
                    if (p.decklists != "off") Label(if (p.decklists == "required") "Decklist required" else "Decklists welcome")
                }
                ListRow(p.signUpLine)
                message?.let { Notice(it) }
                error?.let { Notice(it, error = true) }
                when (state) {
                    "in" -> Notice("You're in. Your event is on the Events tab.")
                    "waitlisted" -> Notice("You're number ${p.position ?: 1} on the waitlist. We'll tell you if a place opens.")
                    "organizer" -> Notice("You're running this event.")
                    "closed" -> Notice("Sign-ups are closed.")
                }
            } else if (p != null) {
                Notice("That event isn't available.", error = true)
            }
        }
        when (state) {
            "sign_up", "sign_in" -> BigAction("Sign up", accent = true, busy = busy) { signUp() }
            "waitlist" -> BigAction("Join the waitlist", accent = true, busy = busy) { signUp() }
            "in", "organizer" -> Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                if (state == "in") Ghost("Leave") { confirmLeave = true }
                Ghost("Open event", accent = true) { onOpenEvent(eventId) }
            }
            "waitlisted" -> BigAction("Leave the waitlist", busy = busy) { confirmLeave = true }
        }
    }
    if (confirmLeave) {
        T1AlertDialog(
            title = "Leave ${p?.name ?: "the event"}?",
            onDismiss = { confirmLeave = false },
            body = {
                Text(if (state == "waitlisted") "You'll lose your place on the waitlist."
                     else if ((p?.waitlist ?: 0) > 0) "Your place goes to the next person on the waitlist."
                     else "You can sign up again while there's room.", color = T1.text, fontFamily = T1.mono, fontSize = 13.sp)
            },
            confirm = {
                BarAction("Leave") {
                    confirmLeave = false
                    val waiting = state == "waitlisted"
                    busy = true
                    scope.launch {
                        try {
                            Repo.leaveEvent(eventId, waiting)
                            message = if (waiting) "You left the waitlist." else "You left the event."
                            page = Repo.eventPage(eventId)
                        } catch (e: Exception) {
                            error = userMessage(e)
                        } finally {
                            busy = false
                        }
                    }
                }
            },
            dismiss = { BarAction("Stay") { confirmLeave = false } },
        )
    }
}

/** Over sign-in when a sign-up link is waiting: which event, and that any way in makes the account. */
@Composable
fun SignUpHeader(page: EventPage, naming: Boolean = false) {
    Column(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Label("Signing up for")
        Text(page.name ?: "An event", color = T1.text, fontFamily = T1.mono, fontSize = 17.sp, fontWeight = FontWeight.Bold)
        if (page.facts.isNotEmpty()) Text(page.facts, color = T1.muted, fontFamily = T1.mono, fontSize = 12.sp)
        Text(page.signUpLine, color = T1.muted, fontFamily = T1.mono, fontSize = 12.sp)
        Text(if (naming) "Add your name and you're signed up." else "New to Table 1? Any option below makes your account, then you're signed up.",
            color = T1.muted, fontFamily = T1.mono, fontSize = 12.sp)
    }
}
