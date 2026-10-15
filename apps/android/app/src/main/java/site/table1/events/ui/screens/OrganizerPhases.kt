package site.table1.events.ui.screens

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import site.table1.events.data.EventBundle
import site.table1.events.data.EventRow
import site.table1.events.data.MatchRow
import site.table1.events.data.ParticipantRow
import site.table1.events.data.Repo
import site.table1.events.data.RoundRow
import site.table1.events.data.SeatingPod
import site.table1.events.data.Standing
import site.table1.events.data.StandingsResponse
import site.table1.events.data.TeamStanding
import site.table1.events.data.slotLetter
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.BigNumber
import site.table1.events.ui.components.Ghost
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1AlertDialog
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Panel
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1Stepper
import site.table1.events.ui.components.T1TextAction
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.components.parseInstant
import site.table1.events.ui.components.record
import site.table1.events.ui.theme.T1
import site.table1.events.util.currentFix
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/*
 * The organizer's event screen in three phases (contract/organizer-phases-2026-10-14.md).
 * The phase is derived from the event's state, never stored: Setup → Live → Results.
 */

internal enum class OrganizerPhase { Setup, Live, Results }

internal fun organizerPhase(b: EventBundle): OrganizerPhase {
    val status = b.event.status
    return when {
        status == "completed" || status == "archived" || status == "cancelled" -> OrganizerPhase.Results
        status == "in_progress" || b.rounds.isNotEmpty() -> OrganizerPhase.Live
        else -> OrganizerPhase.Setup
    }
}

/** Tabs per phase as (id, label); the first one is selected when the phase changes. */
private fun phaseTabs(phase: OrganizerPhase, event: EventRow): List<Pair<String, String>> = when (phase) {
    OrganizerPhase.Setup -> buildList {
        add("players" to "Players")
        if (event.isDraft) add("seating" to "Seating")
        if (event.isTeamEvent) add("teams" to "Teams")
        add("details" to "Details")
    }
    OrganizerPhase.Live -> buildList {
        add("round" to "Round")
        add("standings" to "Standings")
        add("players" to "Players")
        if (event.isTeamEvent) add("teams" to "Teams")
    }
    OrganizerPhase.Results -> listOf("standings" to "Standings", "rounds" to "Rounds", "players" to "Players")
}

/** First line of a server error (supabase-kt appends the URL and headers below it). */
internal fun userMessage(e: Throwable): String =
    e.message?.lineSequence()?.firstOrNull { it.isNotBlank() }?.trim() ?: "Something went wrong."

private fun plural(n: Int, one: String, many: String = one + "s") = "$n ${if (n == 1) one else many}"

private fun clockText(seconds: Int): String = "%d:%02d".format(seconds / 60, seconds % 60)

private fun shortDate(s: String?): String? = parseInstant(s)?.let {
    DateTimeFormatter.ofPattern("MMM d").format(Instant.ofEpochMilli(it).atZone(ZoneId.systemDefault()))
}

/** Clock rule: running → ends = timer_last_started_at + timer_remaining_at_change (or timer_ends_at). */
private fun roundEndMillis(r: RoundRow): Long? =
    parseInstant(r.timerLastStartedAt)?.let { it + (r.timerRemainingAtChange ?: r.timerDurationSeconds) * 1000L }
        ?: parseInstant(r.timerEndsAt)

/** Seconds left on [round]'s clock, ticking every second while it runs; paused → timer_remaining_at_change. */
@Composable
private fun rememberSecondsLeft(round: RoundRow?): Int? {
    val running = round != null && round.timerStatus == "running"
    val end = if (running) roundEndMillis(round) else null
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(end) {
        now = System.currentTimeMillis()
        if (end != null) {
            while (true) {
                delay(1000)
                now = System.currentTimeMillis()
            }
        }
    }
    return when {
        round == null -> null
        end != null -> ((end - now + 999) / 1000).coerceAtLeast(0).toInt()
        else -> round.timerRemainingAtChange ?: round.timerDurationSeconds
    }
}

/** Disputed and not yet settled by the organizer. */
private val MatchRow.isDisputedOpen: Boolean get() = !isBye && disputed && status != "confirmed"

/** "2–1" (or "1–1–1" with drawn games), side 0 first. */
private fun score(m: MatchRow): String {
    val base = "${m.side(0)?.gameWins ?: 0}–${m.side(1)?.gameWins ?: 0}"
    return if (m.gameDraws > 0) "$base–${m.gameDraws}" else base
}

private fun matchTitle(m: MatchRow, b: EventBundle): String =
    if (m.isBye) "${b.name(m.side(0)?.participantId)} · Bye"
    else "T${m.tableNumber ?: "–"} · ${b.name(m.side(0)?.participantId)} v ${b.name(m.side(1)?.participantId)}"

/** Server-side team problem that blocks pairing round 1, or null. */
private fun teamProblem(b: EventBundle): String? {
    if (!b.event.isTeamEvent) return null
    if (b.event.formatName == "team_draft" && b.teams.size != 2) return "A team draft needs two teams"
    if (b.teams.isEmpty()) return "Make teams first"
    val loose = b.participants.count { it.status == "active" && it.teamId == null }
    return when {
        loose == 1 -> "1 player isn't on a team yet"
        loose > 1 -> "$loose players aren't on a team yet"
        else -> null
    }
}

/** Game wins and losses from every scored, non-bye match. */
private fun gameRecord(b: EventBundle, participantId: String): Pair<Int, Int> {
    var won = 0
    var lost = 0
    b.rounds.flatMap { it.matches }.filter { !it.isBye && it.status != "pending" }.forEach { m ->
        val mine = m.sides.firstOrNull { it.participantId == participantId } ?: return@forEach
        val theirs = m.sides.firstOrNull { it.side != mine.side }
        won += mine.gameWins
        lost += theirs?.gameWins ?: 0
    }
    return won to lost
}

@Composable
private fun DialogText(text: String) {
    Text(text, fontFamily = T1.mono, color = T1.muted, fontSize = 13.sp)
}

/* ── the screen ─────────────────────────────────────────────────────────────── */

@Composable
internal fun OrganizerScreen(
    b: EventBundle,
    standings: StandingsResponse,
    onBack: () -> Unit,
    onAddPlayers: () -> Unit,
    onOpenTracker: (String) -> Unit,
    onChanged: suspend () -> Unit,
    /** Shows a fresh seating straight from seat_event, before the reload lands. */
    onSeated: (List<SeatingPod>) -> Unit,
) {
    val scope = rememberCoroutineScope()
    val event = b.event
    val phase = organizerPhase(b)
    val tabs = phaseTabs(phase, event)
    // A phase change resets to that phase's first tab.
    var tab by remember(phase) { mutableStateOf(tabs.first().first) }
    val selected = tabs.firstOrNull { it.first == tab }?.first ?: tabs.first().first

    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var editing by remember { mutableStateOf<MatchRow?>(null) }
    var cancelling by remember { mutableStateOf<String?>(null) }
    var moreMenu by remember { mutableStateOf(false) }
    var showQr by remember { mutableStateOf(false) }
    var confirmStart by remember { mutableStateOf(false) }
    var confirmFinish by remember { mutableStateOf(false) }
    var dropping by remember { mutableStateOf<ParticipantRow?>(null) }

    val active = b.activeRound
    val secondsLeft = rememberSecondsLeft(active)
    val paused = active != null && active.timerStatus != "running"
    val tags = teamTags(b, standings)
    val activePlayers = b.participants.count { it.status == "active" }

    fun act(block: suspend () -> Unit) {
        busy = true
        error = null
        scope.launch {
            try {
                block()
                onChanged()
            } catch (e: Exception) {
                error = userMessage(e)
            } finally {
                busy = false
            }
        }
    }

    // Seats (or re-seats): the answer is shown at once and the button frees up; the reload runs after.
    fun seat() {
        busy = true
        error = null
        scope.launch {
            try {
                onSeated(Repo.seatPlayers(event.id).pods)
                busy = false
                onChanged()
            } catch (e: Exception) {
                error = userMessage(e)
            } finally {
                busy = false
            }
        }
    }

    fun pair() = act { Repo.pairNextRound(event.id).error?.let { throw IllegalStateException(it) } }

    val roundsPlayed = b.rounds.maxOfOrNull { it.number } ?: 0
    val subtitle = when (phase) {
        OrganizerPhase.Setup -> "${event.shortCode} · Setup · ${plural(b.participants.size, "player")} · ${event.label}"
        OrganizerPhase.Live -> listOfNotNull(
            "Round ${active?.number ?: event.currentRound} of ${event.numberOfRounds}",
            when {
                active == null || secondsLeft == null -> null
                paused -> "paused"
                secondsLeft == 0 -> "time"
                else -> "${clockText(secondsLeft ?: 0)} left"
            },
            event.label,
        ).joinToString(" · ")
        OrganizerPhase.Results -> if (event.isCancelled) {
            listOfNotNull("Cancelled", shortDate(event.cancelledAt ?: event.updatedAt),
                "after round $roundsPlayed of ${event.numberOfRounds}").joinToString(" · ")
        } else {
            val ended = b.rounds.lastOrNull()?.recordedAt ?: event.updatedAt ?: event.createdAt
            listOfNotNull("Final", shortDate(ended), plural(b.participants.size, "player"), event.label).joinToString(" · ")
        }
    }

    T1Screen {
        Bar(event.name, subtitle) {
            BarAction("Back", onBack)
            if (phase != OrganizerPhase.Results) BarAction("More") { moreMenu = true }
        }
        T1Segmented(tabs.map { it.second }, tabs.indexOfFirst { it.first == selected }) { tab = tabs[it].first }
        error?.let { Notice(it, error = true) }

        Box(Modifier.weight(1f)) {
            when (phase) {
                OrganizerPhase.Setup -> when (selected) {
                    "players" -> SetupPlayers(b, tags, onAddPlayers, onShowQr = { showQr = true })
                    "seating" -> SetupSeating(b, standings, busy) { seat() }
                    "teams" -> TeamsTab(b, onChanged)
                    "details" -> DetailsTab(b, onChanged)
                }
                OrganizerPhase.Live -> when (selected) {
                    "round" -> LiveRound(
                        b, active, secondsLeft, paused, busy,
                        onClock = { action -> active?.let { r -> act { Repo.setRoundClock(r.id, action, 300) } } },
                        onEdit = { editing = it },
                    )
                    "standings" -> {
                        val open = active?.matches?.count { !it.isBye && (it.status == "pending" || it.isDisputedOpen) } ?: 0
                        StandingsList(standings.standings, standings.teams, tags, highlight = null, header = {
                            if (open > 0) item { Notice("Live: updates as results come in. ${plural(open, "match", "matches")} still open.") }
                        })
                    }
                    "players" -> LivePlayers(
                        b, standings.standings, busy,
                        onDrop = { dropping = it },
                        onReinstate = { p -> act { Repo.setParticipantStatus(p.id, "active", null) } },
                    )
                    "teams" -> TeamsTab(b, onChanged)
                }
                OrganizerPhase.Results -> when (selected) {
                    "standings" -> ResultsStandings(b, standings, tags, roundsPlayed)
                    "rounds" -> ResultsRounds(b, onEdit = { editing = it })
                    "players" -> ResultsPlayers(b, standings.standings)
                }
            }
        }

        when (phase) {
            OrganizerPhase.Setup -> {
                val problem = when {
                    activePlayers < 2 -> "Add at least 2 players"
                    else -> teamProblem(b)
                }
                BigAction(problem ?: "Start event · pair round 1", enabled = problem == null, busy = busy, accent = true) {
                    confirmStart = true
                }
            }
            OrganizerPhase.Live -> {
                val nextNumber = roundsPlayed + 1
                val outstanding = active?.matches?.count { !it.isBye && (it.status == "pending" || (it.disputed && it.status != "confirmed")) } ?: 0 // disputes block pairing too
                when {
                    active == null && nextNumber <= event.numberOfRounds ->
                        BigAction("Pair round $nextNumber", accent = true, busy = busy, enabled = activePlayers >= 2) { pair() }
                    active != null && outstanding > 0 ->
                        BigAction("Waiting on ${plural(outstanding, "result")}", enabled = false) {}
                    active != null && active.number < event.numberOfRounds ->
                        BigAction("Pair round ${active.number + 1}", accent = true, busy = busy) { pair() }
                    active != null ->
                        BigAction("Finish event", accent = true, busy = busy) { confirmFinish = true }
                }
            }
            OrganizerPhase.Results -> {}
        }
    }

    /* ── overlays and alerts ── */

    if (moreMenu) {
        T1Menu(
            items = buildList {
                if (phase == OrganizerPhase.Setup) {
                    add(T1MenuItem("Add players", onClick = onAddPlayers))
                    add(T1MenuItem("Show join QR") { showQr = true })
                }
                add(T1MenuItem("Cancel event", danger = true) { cancelling = "" })
            },
            onDismiss = { moreMenu = false },
        )
    }

    if (showQr) {
        T1Panel(title = "Join QR", onDismiss = { showQr = false }) {
            ShareQr(event.id)
        }
    }

    if (confirmStart) {
        val minutes = event.roundLengthSeconds / 60
        T1AlertDialog(
            title = "Start ${event.name}?",
            onDismiss = { confirmStart = false },
            body = {
                DialogText(
                    if (event.isDraft) "Pairs round 1 across the table and starts the $minutes-minute clock. Format, rounds and teams lock."
                    else "Pairs round 1 and starts the $minutes-minute clock. Format, rounds and teams lock.",
                )
            },
            confirm = {
                BarAction("Start") {
                    confirmStart = false
                    pair()
                }
            },
            dismiss = { BarAction("Not yet") { confirmStart = false } },
        )
    }

    if (confirmFinish) {
        T1AlertDialog(
            title = "Finish ${event.name}?",
            onDismiss = { confirmFinish = false },
            body = {
                DialogText("Final standings go to every player and the event moves to Past. You can still correct a result afterwards.")
            },
            confirm = {
                BarAction("Finish") {
                    confirmFinish = false
                    val round = b.activeRound
                    if (round != null) act { Repo.recordRound(event.id, round.id, finalRound = true) }
                }
            },
            dismiss = { BarAction("Not yet") { confirmFinish = false } },
        )
    }

    dropping?.let { p ->
        T1AlertDialog(
            title = "Drop ${p.displayName}?",
            onDismiss = { dropping = null },
            body = { DialogText("They won't be paired again. Their results so far still count.") },
            confirm = {
                BarAction("Drop") {
                    dropping = null
                    val round = b.activeRound?.number ?: event.currentRound
                    act { Repo.setParticipantStatus(p.id, "dropped", round) }
                }
            },
            dismiss = { BarAction("Keep") { dropping = null } },
        )
    }

    cancelling?.let { reason ->
        T1AlertDialog(
            title = "Cancel this event?",
            onDismiss = { cancelling = null },
            body = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    DialogText(
                        "Everyone in it is told it's off. Results already confirmed stay on players' records; " +
                            "unreported matches don't count. This can't be undone.",
                    )
                    T1TextField(reason, { cancelling = it.take(200) }, placeholder = "Reason (optional)")
                }
            },
            confirm = {
                BarAction("Cancel event") {
                    cancelling = null
                    act { Repo.cancelEvent(event.id, reason) }
                }
            },
            dismiss = { BarAction("Keep event") { cancelling = null } },
        )
    }

    editing?.let { m ->
        val live = phase == OrganizerPhase.Live && active != null && m.roundId == active.id
        EditResultDialog(
            m, b,
            onDismiss = { editing = null },
            onWatch = if (live) ({
                editing = null
                onOpenTracker(m.id)
            }) else null,
        ) { s0, s1, draws ->
            editing = null
            act { Repo.setMatchResult(m.id, s0, s1, draws, "Set by organizer") }
        }
    }
}

/* ── setup ──────────────────────────────────────────────────────────────────── */

@Composable
private fun SetupPlayers(b: EventBundle, tags: Map<String, String>, onAddPlayers: () -> Unit, onShowQr: () -> Unit) {
    LazyColumn(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                Ghost("Add players", accent = true, onClick = onAddPlayers)
                Ghost("Show join QR", onClick = onShowQr)
            }
        }
        item {
            ListRow("Join code") {
                Text(b.event.shortCode, color = T1.accent, fontFamily = T1.mono, fontSize = 18.sp, letterSpacing = 4.sp)
            }
        }
        item { Section("Players · ${b.participants.size}") }
        if (b.participants.isEmpty()) item { Notice("No players yet. Add players, or show the join QR to the room.") }
        items(b.participants, key = { it.id }) { p ->
            val team = tags[p.id]?.let { t -> t + (p.teamSlot?.let { " " + slotLetter(it) } ?: "") }
            val detail = listOfNotNull(
                if (p.userId == null) "Guest" else "Joined",
                p.seat?.let { "Seat $it" },
                team,
            ).joinToString(" · ")
            ListRow(p.displayName, detail)
        }
    }
}

@Composable
private fun SetupSeating(b: EventBundle, standings: StandingsResponse, busy: Boolean, onSeat: () -> Unit) {
    val seating = standings.seating.orEmpty()
    LazyColumn(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                Ghost(if (seating.isEmpty()) "Seat players" else "Re-seat", enabled = !busy, onClick = onSeat)
            }
        }
        if (seating.isEmpty()) {
            item { Notice("Seat players for the draft, or pair round 1 to seat them automatically.") }
        } else {
            seatingItems(seating, highlight = null, teamDraft = b.event.formatName == "team_draft")
        }
    }
}

/** Editable copy of the event's details; every save sends all of it. */
private data class DetailsDraft(
    val name: String,
    val formatName: String,
    val formatOther: String,
    val useCube: Boolean,
    val setCode: String?,
    val setName: String,
    val cubeName: String,
    val cubeUrl: String,
    val teamSize: Int,
    val rounds: Int,
    val minutes: Int,
) {
    val limited: Boolean get() = limitedFormats.any { it.first == formatName }
    val team: Boolean get() = formatName == "team_draft" || formatName == "team_sealed"
    val other: Boolean get() = formatName == "other_constructed"
    val cubeUrlOk: Boolean get() = cubeUrl.isBlank() || cubeUrl.trim().startsWith("https://")

    /** Takes the server's values, keeping what's being typed when it only differs by surrounding spaces. */
    fun syncedWith(e: EventRow): DetailsDraft {
        val fresh = from(e)
        fun keep(mine: String, theirs: String) = if (mine.trim() == theirs.trim()) mine else theirs
        return fresh.copy(
            name = keep(name, fresh.name),
            formatOther = keep(formatOther, fresh.formatOther),
            setName = keep(setName, fresh.setName),
            cubeName = keep(cubeName, fresh.cubeName),
            cubeUrl = keep(cubeUrl, fresh.cubeUrl),
            // Switched to Cube but no name typed yet: stay on Cube.
            useCube = fresh.useCube || (useCube && cubeName.isBlank() && fresh.limited),
        )
    }

    companion object {
        fun from(e: EventRow) = DetailsDraft(
            name = e.name,
            formatName = e.formatName ?: when (e.format) {
                "sealed" -> "sealed"
                "constructed" -> "standard"
                else -> "draft"
            },
            formatOther = e.formatOther.orEmpty(),
            useCube = e.cubeName != null,
            setCode = e.setCode,
            setName = e.setName.orEmpty(),
            cubeName = e.cubeName.orEmpty(),
            cubeUrl = e.cubeUrl.orEmpty(),
            teamSize = e.teamSize ?: 4,
            rounds = e.numberOfRounds.coerceIn(1, 15),
            minutes = (e.roundLengthSeconds / 60).coerceIn(10, 240),
        )
    }
}

/**
 * Setup → Details: edits save as they're made (text after 600 ms of quiet, steppers and pickers at once) with
 * update_event_details, always sending the full current state. Errors show inline.
 */
@Composable
private fun DetailsTab(b: EventBundle, onChanged: suspend () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val event = b.event
    var draft by remember(event.id) { mutableStateOf(DetailsDraft.from(event)) }
    var edits by remember { mutableIntStateOf(0) }
    var saved by remember { mutableIntStateOf(0) }
    var textEdits by remember { mutableIntStateOf(0) }
    var error by remember { mutableStateOf<String?>(null) }
    var formatMenu by remember { mutableStateOf(false) }
    var pickingSet by remember { mutableStateOf(false) }
    var setsUnavailable by remember { mutableStateOf(false) }
    var pendingVisibility by remember { mutableStateOf<String?>(null) }
    val saveLock = remember { Mutex() }

    // If the set list is empty (not synced yet), fall back to typing the set name (same as Create).
    LaunchedEffect(Unit) {
        runCatching { Repo.draftableSets("", 1) }.onSuccess { setsUnavailable = it.isEmpty() }
    }

    // Realtime reloads flow in, unless there are edits not saved yet.
    LaunchedEffect(event) {
        if (edits == saved) draft = draft.syncedWith(event)
    }

    fun save() {
        scope.launch {
            saveLock.withLock {
                val d = draft
                val at = edits
                if (!d.cubeUrlOk) return@withLock
                val limited = d.limited
                try {
                    Repo.updateEventDetails(
                        eventId = event.id,
                        name = d.name.trim(),
                        formatName = d.formatName,
                        rounds = d.rounds,
                        roundSeconds = d.minutes * 60,
                        setCode = if (limited && !d.useCube) d.setCode else null,
                        setName = if (limited && !d.useCube) d.setName.trim().ifEmpty { null } else null,
                        cubeName = if (limited && d.useCube) d.cubeName.trim().ifEmpty { null } else null,
                        cubeUrl = if (limited && d.useCube) d.cubeUrl.trim().ifEmpty { null } else null,
                        teamSize = if (d.team) d.teamSize else null,
                        formatOther = if (d.other) d.formatOther.trim().ifEmpty { null } else null,
                    )
                    error = null
                    saved = at
                    onChanged()
                } catch (e: Exception) {
                    error = userMessage(e)
                }
            }
        }
    }

    /** Typing: save after 600 ms without another keystroke. */
    fun editText(next: DetailsDraft) {
        draft = next
        edits++
        textEdits++
    }

    /** Stepper tap or picker choice: save now. */
    fun editNow(next: DetailsDraft) {
        draft = next
        edits++
        save()
    }

    LaunchedEffect(textEdits) {
        if (textEdits > 0) {
            delay(600)
            save()
        }
    }

    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        val chosen = pendingVisibility ?: return@rememberLauncherForActivityResult
        scope.launch {
            try {
                val fix = currentFix(context)
                if (fix == null) {
                    error = "Turn on location to change who can find it."
                } else {
                    Repo.setEventLocation(event.id, fix.lat, fix.lng, event.venueName, chosen)
                    error = null
                    onChanged()
                }
            } catch (e: Exception) {
                error = userMessage(e)
            } finally {
                pendingVisibility = null
            }
        }
    }

    val d = draft
    val options = if (d.limited) limitedFormats else constructedFormats
    val formatLabel = options.firstOrNull { it.first == d.formatName }?.second ?: "Pick a format"
    val visibilities = listOf("nearby" to "Nearby", "link_only" to "Link only", "private" to "Private")
    val visibility = pendingVisibility ?: event.visibility

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
        FormBlock("Event name") {
            T1TextField(d.name, { editText(draft.copy(name = it.take(80))) })
        }

        FormBlock("Format") {
            T1Segmented(listOf("Constructed", "Limited"), if (d.limited) 1 else 0) { i ->
                val toLimited = i == 1
                if (toLimited != draft.limited) editNow(draft.copy(formatName = if (toLimited) "draft" else "standard"))
            }
            T1TextField(value = formatLabel, onChange = {}, trailing = "▾", onClick = { formatMenu = true })
            if (d.other) {
                T1TextField(d.formatOther, { editText(draft.copy(formatOther = it.take(40))) }, label = "Format name")
            }
        }

        if (d.limited) {
            FormBlock("Product") {
                T1Segmented(listOf("Set", "Cube"), if (d.useCube) 1 else 0) { draft = draft.copy(useCube = it == 1) }
                if (!d.useCube) {
                    if (setsUnavailable) {
                        T1TextField(d.setName, { editText(draft.copy(setCode = null, setName = it.take(80))) }, label = "Set name")
                    } else {
                        T1TextField(
                            value = d.setCode?.let { "${d.setName.ifEmpty { it.uppercase() }} (${it.uppercase()})" } ?: "",
                            onChange = {}, label = "Set", placeholder = "Pick a set…", trailing = "›",
                            onClick = { pickingSet = true },
                        )
                    }
                } else {
                    T1TextField(d.cubeName, { editText(draft.copy(cubeName = it.take(80))) }, label = "Cube name")
                    T1TextField(
                        d.cubeUrl, { editText(draft.copy(cubeUrl = it.take(300))) }, label = "CubeCobra link (optional)",
                        placeholder = "https://cubecobra.com/…", keyboardType = KeyboardType.Uri,
                        error = if (!d.cubeUrlOk) "Links start with https://" else null,
                    )
                }
            }
        }

        if (d.team) {
            FormBlock("Team size") {
                T1Segmented(listOf("3", "4"), if (d.teamSize == 3) 0 else 1) { editNow(draft.copy(teamSize = if (it == 0) 3 else 4)) }
            }
        }

        FormBlock("Rounds") {
            T1Stepper(null, d.rounds, 1..15, Modifier.fillMaxWidth()) { editNow(draft.copy(rounds = it)) }
        }

        FormBlock("Round length · minutes") {
            T1Stepper(null, d.minutes, 10..240, Modifier.fillMaxWidth(), step = 5) { editNow(draft.copy(minutes = it)) }
        }

        FormBlock("Who can find it") {
            T1Segmented(
                visibilities.map { it.second },
                visibilities.indexOfFirst { it.first == visibility }.coerceAtLeast(0),
                enabled = pendingVisibility == null,
            ) { i ->
                pendingVisibility = visibilities[i].first
                permission.launch(arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION))
            }
        }

        error?.let { Notice(it, error = true) }
        Notice("Details lock when round 1 is paired. Changes save as you make them.")
    }

    if (formatMenu) {
        T1Menu(
            title = "Format",
            items = options.map { (wire, label) ->
                T1MenuItem(label, selected = wire == d.formatName) { editNow(draft.copy(formatName = wire)) }
            },
            onDismiss = { formatMenu = false },
        )
    }

    if (pickingSet) {
        T1Panel(title = "Pick a set", onDismiss = { pickingSet = false }) {
            SetPickerList { s ->
                pickingSet = false
                editNow(draft.copy(setCode = s.code, setName = s.name, useCube = false))
            }
        }
    }
}

/* ── live ───────────────────────────────────────────────────────────────────── */

@Composable
private fun LiveRound(
    b: EventBundle,
    active: RoundRow?,
    secondsLeft: Int?,
    paused: Boolean,
    busy: Boolean,
    onClock: (String) -> Unit,
    onEdit: (MatchRow) -> Unit,
) {
    val event = b.event
    LazyColumn(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        if (active == null) {
            val next = (b.rounds.maxOfOrNull { it.number } ?: 0) + 1
            item {
                Notice(
                    if (next <= event.numberOfRounds) "No round running. Pair round $next when everyone is ready."
                    else "Every round has been played.",
                )
            }
            return@LazyColumn
        }

        val matches = active.matches
        val disputed = matches.filter { it.isDisputedOpen }
        val waiting = matches.filter { !it.isBye && !it.isDisputedOpen && it.status == "pending" }
        val resultsIn = matches.filter { !it.isBye && !it.isDisputedOpen && it.status != "pending" } + matches.filter { it.isBye }
        val games = matches.count { !it.isBye }
        val inCount = resultsIn.count { !it.isBye }
        val roundLine = "Round ${active.number} of ${event.numberOfRounds}"
        val caption = if (paused) "Paused · $roundLine"
        else listOfNotNull(roundLine, "$inCount of $games results in", disputed.size.takeIf { it > 0 }?.let { "$it disputed" })
            .joinToString(" · ")

        item(key = "clock") { BigNumber(clockText(secondsLeft ?: 0), caption) }
        item(key = "clock-actions") {
            Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                Ghost(if (paused) "Resume clock" else "Pause clock", enabled = !busy) { onClock(if (paused) "resume" else "pause") }
                Ghost("+5 min", enabled = !busy) { onClock("add") }
            }
        }

        if (disputed.isNotEmpty()) {
            item(key = "h-disputed") { Section("Disputed · ${disputed.size}") }
            items(disputed, key = { it.id }) { m ->
                MatchResultRow(matchTitle(m, b), "Reported differently · tap to set", "Set", accent = false) { onEdit(m) }
            }
        }
        if (waiting.isNotEmpty()) {
            item(key = "h-waiting") { Section("Waiting · ${waiting.size}") }
            items(waiting, key = { it.id }) { m ->
                MatchResultRow(matchTitle(m, b), "No result yet", "Set", accent = false) { onEdit(m) }
            }
        }
        if (resultsIn.isNotEmpty()) {
            item(key = "h-in") { Section("Results in · ${resultsIn.size}") }
            items(resultsIn, key = { it.id }) { m ->
                if (m.isBye) {
                    MatchResultRow(matchTitle(m, b), null, "Bye", accent = false, onClick = null)
                } else {
                    val detail = when {
                        m.resultSource == "organizer" -> "Set by organizer"
                        m.status == "confirmed" -> "Confirmed"
                        m.reportedByParticipant != null -> "Reported by ${b.name(m.reportedByParticipant)}"
                        else -> "Reported"
                    }
                    MatchResultRow(matchTitle(m, b), detail, score(m), accent = true) { onEdit(m) }
                }
            }
        }
    }
}

@Composable
private fun MatchResultRow(title: String, detail: String?, value: String, accent: Boolean, onClick: (() -> Unit)?) {
    ListRow(title, detail, onClick = onClick) {
        Text(value, color = if (accent) T1.accent else T1.text, fontFamily = T1.mono, fontSize = 16.sp, maxLines = 1)
    }
}

@Composable
private fun LivePlayers(
    b: EventBundle,
    standings: List<Standing>,
    busy: Boolean,
    onDrop: (ParticipantRow) -> Unit,
    onReinstate: (ParticipantRow) -> Unit,
) {
    val byId = standings.associateBy { it.participantId }
    val playing = b.participants.filter { it.status != "dropped" }
    val dropped = b.participants.filter { it.status == "dropped" }
    LazyColumn(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        item(key = "h-playing") { Section("Playing · ${playing.size}") }
        items(playing, key = { it.id }) { p ->
            val s = byId[p.id]
            ListRow(p.displayName, s?.let { "${record(it.matchWins, it.matchLosses, it.matchDraws)} · ${it.matchPoints} pts" }) {
                T1TextAction("Drop", enabled = !busy, color = T1.danger) { onDrop(p) }
            }
        }
        if (dropped.isNotEmpty()) {
            item(key = "h-dropped") { Section("Dropped · ${dropped.size}") }
            items(dropped, key = { it.id }) { p ->
                ListRow(p.displayName, "Dropped after round ${p.droppedInRound ?: "–"} · still counts in tiebreakers") {
                    T1TextAction("Reinstate", enabled = !busy) { onReinstate(p) }
                }
            }
        }
    }
}

/* ── results ────────────────────────────────────────────────────────────────── */

/** Surface block: small accent label, the winner's name large, a caption, and (teams) the members. */
@Composable
private fun WinnerCard(label: String, name: String, caption: String, members: String? = null) {
    Column(
        Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 20.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Label(label, color = T1.accent)
        Text(name, color = T1.text, fontFamily = T1.mono, fontSize = 22.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Label(caption)
        members?.let { Text(it, color = T1.muted, fontFamily = T1.mono, fontSize = 13.sp) }
    }
}

@Composable
private fun ResultsStandings(b: EventBundle, standings: StandingsResponse, tags: Map<String, String>, roundsPlayed: Int) {
    val event = b.event
    val teams: List<TeamStanding>? = standings.teams
    StandingsList(
        standings.standings, teams, tags, highlight = null,
        header = {
            if (event.isCancelled) {
                item(key = "cancelled") {
                    Notice(event.cancelReason?.takeIf { it.isNotBlank() }?.let { "Cancelled: $it" } ?: "Cancelled by the organizer.", error = true)
                }
                item(key = "h-after") { Section("Standings after round $roundsPlayed") }
            } else {
                val topTeam = teams?.firstOrNull()
                val top = standings.standings.firstOrNull()
                if (event.isTeamEvent && topTeam != null) {
                    item(key = "winner") {
                        WinnerCard(
                            label = "WINNING TEAM",
                            name = topTeam.name,
                            caption = "${record(topTeam.wins, topTeam.losses, topTeam.draws)} · ${topTeam.points} points · " +
                                plural(topTeam.matchWins, "match win"),
                            members = topTeam.members.sortedBy { it.slot ?: 99 }.joinToString(" · ") { it.displayName },
                        )
                    }
                } else if (top != null) {
                    val (gw, gl) = gameRecord(b, top.participantId)
                    item(key = "winner") {
                        WinnerCard(
                            label = "WINNER",
                            name = top.displayName,
                            caption = "${top.matchWins}-${top.matchLosses}-${top.matchDraws} · ${top.matchPoints} points · games $gw-$gl",
                        )
                    }
                }
                item(key = "h-final") { Section("Final standings") }
            }
        },
        footer = {
            if (event.isCancelled) item(key = "cancel-note") { Notice("Confirmed results count toward records. Unplayed rounds never do.") }
        },
    )
}

@Composable
private fun ResultsRounds(b: EventBundle, onEdit: (MatchRow) -> Unit) {
    LazyColumn(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        if (b.rounds.isEmpty()) item { Notice("No rounds were played.") }
        b.rounds.sortedByDescending { it.number }.forEach { r ->
            item(key = "round-${r.id}") { Section("Round ${r.number}") }
            items(r.matches.sortedWith(compareBy({ it.isBye }, { it.tableNumber ?: 0 })), key = { it.id }) { m ->
                if (m.isBye) {
                    MatchResultRow(matchTitle(m, b), null, "Bye", accent = false, onClick = null)
                } else {
                    val scored = m.status != "pending"
                    val detail = when {
                        m.resultSource == "organizer" -> "Set by organizer"
                        !scored -> "No result"
                        else -> null
                    }
                    MatchResultRow(matchTitle(m, b), detail, if (scored) score(m) else "Set", accent = scored) { onEdit(m) }
                }
            }
        }
        if (b.rounds.isNotEmpty()) item(key = "rounds-note") { Notice("Tap a match to correct its result. Standings and records update.") }
    }
}

@Composable
private fun ResultsPlayers(b: EventBundle, standings: List<Standing>) {
    val byId = standings.associateBy { it.participantId }
    val ordered = b.participants.sortedBy { byId[it.id]?.rank ?: Int.MAX_VALUE }
    LazyColumn(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        item { Section("Players · ${ordered.size}") }
        items(ordered, key = { it.id }) { p ->
            val s = byId[p.id]
            val detail = if (p.status == "dropped") "Dropped after round ${p.droppedInRound ?: "–"}" else s?.let { "#${it.rank}" }
            ListRow(p.displayName, detail) {
                if (s != null) {
                    Text(record(s.matchWins, s.matchLosses, s.matchDraws), color = T1.text, fontFamily = T1.mono, fontSize = 14.sp)
                    Label("${s.matchPoints} pts")
                }
            }
        }
    }
}
