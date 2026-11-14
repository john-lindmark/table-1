package site.table1.events.ui.screens

import site.table1.events.ui.components.FoldMode
import site.table1.events.ui.components.FoldSplit
import site.table1.events.ui.components.paneInsets
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.ui.Alignment
import androidx.compose.foundation.clickable
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
import site.table1.events.data.DraftPods
import site.table1.events.data.EventBundle
import site.table1.events.data.EventDemo
import site.table1.events.data.EventExtras
import site.table1.events.data.EventMoney
import site.table1.events.data.EventRoom
import site.table1.events.data.Fees
import site.table1.events.data.RoomRules
import site.table1.events.data.TeamRules
import site.table1.events.data.eventAbout
import site.table1.events.data.setEventTrios
import site.table1.events.data.EventRow
import site.table1.events.data.EventRules
import site.table1.events.data.MatchRow
import site.table1.events.data.ParticipantRow
import site.table1.events.data.RepairRound
import site.table1.events.data.Repo
import site.table1.events.data.SeatingSeat
import site.table1.events.data.RoundRow
import site.table1.events.data.SeatingPod
import site.table1.events.data.Standing
import site.table1.events.data.StandingsResponse
import site.table1.events.data.TeamClinch
import site.table1.events.util.Telemetry
import site.table1.events.data.TeamStanding
import site.table1.events.data.slotLetter
import site.table1.events.ui.components.Avatar
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.BigNumber
import site.table1.events.ui.components.Ghost
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.T1Switch
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.PodHeader
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
import site.table1.events.ui.components.rememberOpenProfile

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
private fun phaseTabs(phase: OrganizerPhase, b: EventBundle, hasFee: Boolean = false, event: EventRow = b.event): List<Pair<String, String>> = when (phase) {
    OrganizerPhase.Setup -> buildList {
        add("players" to "Players")
        if (event.isDraft) add("seating" to "Seating")
        if (event.isRoto) add("seating" to "Pick order")
        if (event.isTeamEvent) add("teams" to "Teams")
        add("details" to "Details")
    }
    OrganizerPhase.Live -> buildList {
        add("round" to "Round")
        // Earlier: the rounds before this one, to correct a result (then re-pair; contract/repair-round-2026-11-09.md).
        if (b.rounds.any { it.status != "active" }) add("rounds" to "Earlier")
        add("standings" to "Standings")
        add("players" to "Players")
        if (event.isTeamEvent) add("teams" to "Teams")
    }
    // Prizes (contract/entry-fees-2026-11-13.md § 4) for an event with a fee.
    OrganizerPhase.Results -> listOfNotNull("standings" to "Standings", "rounds" to "Rounds", "players" to "Players", if (hasFee) "prizes" to "Prizes" else null)
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

/** A draft's pods in order (from the engine's seating), for pod headers; other formats: none. */
private fun podList(b: EventBundle, standings: StandingsResponse): List<Pair<String, String?>> =
    if (b.event.formatName == "draft") standings.seating.orEmpty().map { it.podId to it.name } else emptyList()

/** Drafts with 2+ pods: a round's matches under Pod 1 / Pod 2 / Across pods (null: one list, as before). */
private fun matchSections(b: EventBundle, pods: List<Pair<String, String?>>, matches: List<MatchRow>, stage: String?) =
    DraftPods.sections(matches, pods, b.participants.associate { it.id to it.podId }, stage,
        players = { m -> m.sides.map { it.participantId } }, table = { it.tableNumber }, isBye = { it.isBye })

/** "2 of 4 in · 1 disputed", "All in" for a pod's matches (byes don't count). */
private fun podProgress(ms: List<MatchRow>): String {
    val played = ms.filter { !it.isBye }
    if (played.isEmpty()) return "Bye"
    val disputed = played.count { it.isDisputedOpen }
    val done = played.count { !it.isDisputedOpen && it.status != "pending" }
    val text = if (done == played.size) "All in" else "$done of ${played.size} in"
    return if (disputed > 0) "$text · $disputed disputed" else text
}

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
    /** Everyone's deck photos; the organizer can add one for any player. */
    onOpenPhotos: () -> Unit,
    onOpenRedraft: () -> Unit = {},
    /** A Library list (a roto deck). */
    onOpenList: (String) -> Unit = {},
    /** The event's money and room; each part null while the server doesn't have it. */
    extras: EventExtras = EventExtras(),
) {
    val scope = rememberCoroutineScope()
    val event = b.event
    val phase = organizerPhase(b)
    val money = extras.money
    val room = extras.room
    val tabs = phaseTabs(phase, b, hasFee = money?.fee != null)
    // A phase change resets to that phase's first tab (Debug `--es t1Events …` opens on its own).
    var tab by remember(phase) { mutableStateOf(EventDemo.tab ?: tabs.first().first) }
    val selected = tabs.firstOrNull { it.first == tab }?.first ?: tabs.first().first

    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var editing by remember { mutableStateOf<MatchRow?>(null) }
    var cancelling by remember { mutableStateOf<String?>(null) }
    var moreMenu by remember { mutableStateOf(false) }
    var showQr by remember { mutableStateOf(false) }
    var confirmStart by remember { mutableStateOf(false) }
    var confirmFinish by remember { mutableStateOf(false) }
    var confirmCut by remember { mutableStateOf(false) }
    var displayOpen by remember { mutableStateOf(EventDemo.screen == "display") }
    var extraFor by remember { mutableStateOf<MatchRow?>(null) }
    // The second screen ends when the organizer leaves the event.
    androidx.compose.runtime.DisposableEffect(event.id) { onDispose { SecondScreen.stop() } }
    var dropping by remember { mutableStateOf<ParticipantRow?>(null) }
    var listFor by remember { mutableStateOf<ParticipantRow?>(null) }
    var rotoOverlay by remember { mutableStateOf(false) }
    var rotoSchedule by remember { mutableStateOf(false) }
    // Re-pair: where it was asked from ("notice" | "menu") while the alert is up.
    var repairFrom by remember { mutableStateOf<String?>(null) }
    val context = LocalContext.current

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

    // A seating change (move, swap): its answer is shown at once, the reload runs after.
    fun reseat(block: suspend () -> List<SeatingPod>) {
        busy = true
        error = null
        scope.launch {
            try {
                onSeated(block())
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

    val repairable = if (phase == OrganizerPhase.Live) RepairRound.repairable(b.rounds) else null
    val repairName = repairable?.let { RepairRound.label(it.stage, it.number) } ?: ""

    val roundsPlayed = b.rounds.maxOfOrNull { it.number } ?: 0
    val subtitle = when (phase) {
        OrganizerPhase.Setup -> "${event.shortCode} · Setup · ${plural(b.participants.size, "player")} · ${event.label}"
        OrganizerPhase.Live -> listOfNotNull(
            (active ?: b.rounds.maxByOrNull { it.number })?.name(event.numberOfRounds) ?: "Round ${event.currentRound} of ${event.numberOfRounds}",
            when {
                active == null || secondsLeft == null || !event.showClock -> null
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

    /** The organizer screen; `hero` false leaves the round clock to a tabletop fold's upright half. */
    @Composable
    fun ColumnScope.Screen(hero: Boolean) {
        Bar(event.name, subtitle, onBack = onBack) {
            if (!event.isCancelled) BarAction("More") { moreMenu = true }
        }
        T1Segmented(tabs.map { it.second }, tabs.indexOfFirst { it.first == selected }) { tab = tabs[it].first }
        error?.let { Notice(it, error = true) }

        Box(Modifier.weight(1f)) {
            when (phase) {
                OrganizerPhase.Setup -> when (selected) {
                    "players" -> SetupPlayers(b, tags, podList(b, standings), busy, onAddPlayers, onShowQr = { showQr = true }, onChanged = onChanged, money = money,
                        onError = { error = it }) { block -> act(block) }
                    "seating" -> if (event.isRoto) site.table1.events.roto.RotoPickOrder(
                        b.participants.filter { it.status == "active" && it.seat != null }.sortedBy { it.seat }.map { it.seat!! to it.displayName }, busy,
                    ) { seat() } else SetupSeating(b, standings, busy, act = { block -> act(block) }, reseat = { block -> reseat(block) }) { seat() }
                    "teams" -> TeamsTab(b, onChanged)
                    "details" -> DetailsTab(b, onChanged, money)
                }
                OrganizerPhase.Live -> when (selected) {
                    "round" -> LiveRound(
                        b, active, secondsLeft, paused, busy, standings.clinched, hero = hero, pods = podList(b, standings),
                        onClock = { action -> active?.let { r -> act { Repo.setRoundClock(r.id, action, 300) } } },
                        onEdit = { editing = it },
                        onRepair = { repairFrom = "notice" },
                        room = room, onChanged = onChanged, onError = { error = it },
                    )
                    "rounds" -> ResultsRounds(
                        b, onEdit = { editing = it }, rounds = b.rounds.filter { it.id != active?.id }, pods = podList(b, standings),
                        note = if (active != null) "Tap a match to correct its result. If that changes who should have played whom, re-pair $repairName."
                        else "Tap a match to correct its result. Standings and records update.",
                    )
                    "standings" -> {
                        val open = active?.matches?.count { !it.isBye && (it.status == "pending" || it.isDisputedOpen) } ?: 0
                        StandingsList(standings.standings, standings.teams, tags, highlight = null, userIds = b.userIds, bracket = standings.bracket, seating = standings.seating,
                            teamBracket = standings.teamBracket, seatFormats = event.seatFormats, header = {
                            if (open > 0) item { Notice("Live: updates as results come in. ${plural(open, "match", "matches")} still open.") }
                        })
                    }
                    "players" -> LivePlayers(
                        b, standings.standings, podList(b, standings), busy, onList = { listFor = it },
                        onDrop = { dropping = it },
                        onReinstate = { p -> act { Repo.setParticipantStatus(p.id, "active", null) } },
                        money = money, onChanged = onChanged, onError = { error = it },
                    )
                    "teams" -> TeamsTab(b, onChanged)
                }
                OrganizerPhase.Results -> when (selected) {
                    "standings" -> ResultsStandings(b, standings, tags, roundsPlayed)
                    "rounds" -> ResultsRounds(b, onEdit = { editing = it }, pods = podList(b, standings))
                    "players" -> ResultsPlayers(b, standings.standings, podList(b, standings))
                    "prizes" -> PrizesTab(event.id, money, onChanged)
                }
            }
        }

        when (phase) {
            OrganizerPhase.Setup -> {
                val problem = when {
                    activePlayers < 2 -> "Add at least 2 players"
                    b.event.decklists == "required" && b.decklistsMissing > 0 ->
                        "Waiting on ${plural(b.decklistsMissing, "decklist")}"
                    else -> teamProblem(b)
                }
                // Roto: Start draft (roto_start) replaces Pair round 1 until the draft is done.
                if (event.isRoto) site.table1.events.roto.RotoStartAction(event.id, activePlayers) { scope.launch { onChanged() } }
                else BigAction(problem ?: "Start event · pair round 1", enabled = problem == null, busy = busy, accent = true) {
                    confirmStart = true
                }
            }
            OrganizerPhase.Live -> {
                val nextNumber = roundsPlayed + 1
                val outstanding = active?.matches?.count { !it.isBye && (it.status == "pending" || (it.disputed && it.status != "confirmed")) } ?: 0 // disputes block pairing too
                val disputed = active?.matches?.any { it.disputed && it.status != "confirmed" } == true
                val clinch = standings.clinched?.takeIf { !disputed }
                // A team event follows the steps only with a top 4 (team sealed, Team Trios); without a cut it keeps its
                // own flow (clinch, Play on).
                val step = if (event.pairing == "round_robin" || (event.isTeamEvent && event.topCut == 0)) "" else b.nextStep
                when {
                    // Swiss, then the top 8 or top 4 (contract/scheduled-events-2026-10-27.md §6; top 4 and team
                    // playoffs: contract/teams-finals-alerts-2026-11-13.md § 1).
                    step == "cut" -> BigAction("Cut to top 8", accent = true, busy = busy) { confirmCut = true }
                    step == "cut4" -> BigAction("Cut to top 4", accent = true, busy = busy) { confirmCut = true }
                    step == "semifinals" -> BigAction("Pair semifinals", accent = true, busy = busy) { pair() }
                    step == "final" -> BigAction("Pair the final", accent = true, busy = busy) { pair() }
                    step == "finish" && active?.isPlayoff != false && b.rounds.lastOrNull()?.isPlayoff == true ->
                        BigAction("Finish event", accent = true, busy = busy) { confirmFinish = true }
                    // A team can't be caught: finish now (open matches don't count), or play on when the round is in.
                    clinch != null -> Column {
                        if (outstanding == 0 && nextNumber <= event.numberOfRounds) Row {
                            Ghost("Play on · pair round $nextNumber", enabled = !busy) { pair() }
                        }
                        BigAction("Finish event", accent = true, busy = busy) { confirmFinish = true }
                    }
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

    // Foldables (contract/foldables-2026-11-10.md § The screens): tabletop turns the upright half into the venue's
    // round clock; wide or book put standings beside the round.
    val foldModes = buildSet {
        if (phase == OrganizerPhase.Live && active != null && event.showClock) add(FoldMode.Tabletop)
        if (phase == OrganizerPhase.Live && selected == "round") { add(FoldMode.Wide); add(FoldMode.Book) }
    }
    FoldSplit("organizer_live", allow = foldModes, enabled = foldModes.isNotEmpty(), single = { T1Screen { Screen(hero = true) } },
        first = { layout ->
            val round = active
            if (layout.mode == FoldMode.Tabletop && round != null) {
                Column(Modifier.fillMaxSize().background(T1.surface).paneInsets(layout.mode, first = true).padding(16.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically)) {
                    BoxWithConstraints(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                        // As large as the half allows: five characters at about 0.62 em each.
                        val size = minOf(maxWidth.value / 3.4f, maxHeight.value * 0.8f)
                        Text(clockText(secondsLeft ?: 0), color = if (paused) T1.muted else if (secondsLeft == 0) T1.danger else T1.text,
                            fontFamily = T1.mono, fontSize = size.sp, letterSpacing = 4.sp, maxLines = 1)
                    }
                    Label(if (paused) "Paused · ${round.name(event.numberOfRounds)}" else round.name(event.numberOfRounds))
                }
            } else {
                Column(Modifier.fillMaxSize().background(T1.bg).paneInsets(layout.mode, first = true),
                    verticalArrangement = Arrangement.spacedBy(1.dp)) { Screen(hero = true) }
            }
        },
        second = { layout ->
            Column(Modifier.fillMaxSize().background(T1.bg).paneInsets(layout.mode, first = false),
                verticalArrangement = Arrangement.spacedBy(1.dp)) {
                if (layout.mode == FoldMode.Tabletop) {
                    Screen(hero = false)
                } else {
                    Bar("Standings", active?.name(event.numberOfRounds))
                    Box(Modifier.weight(1f)) {
                        StandingsList(standings.standings, standings.teams, tags, highlight = null, userIds = b.userIds,
                            bracket = standings.bracket, seating = standings.seating)
                    }
                }
            }
        })

    /* ── overlays and alerts ── */

    if (moreMenu) {
        T1Menu(
            items = buildList {
                if (phase == OrganizerPhase.Setup) {
                    add(T1MenuItem("Add players", onClick = onAddPlayers))
                    add(T1MenuItem("Show join QR") { showQr = true })
                }
                add(T1MenuItem("Share link") { shareEventLink(context, event) })
                // The room's screens (contract/room-tools-2026-11-13.md § 1); hidden while the server has no room tools.
                if (phase == OrganizerPhase.Live && room != null) add(T1MenuItem("Display") { displayOpen = true })
                add(T1MenuItem("Deck photos", onClick = onOpenPhotos))
                if (event.canRedraft) add(T1MenuItem("Redraft", onClick = onOpenRedraft))
                // Roto: the draft stays readable over Live and Results; round robin has its schedule.
                if (event.isRoto && b.rounds.isNotEmpty()) add(T1MenuItem("Draft picks") { rotoOverlay = true })
                if (event.isRoto && event.pairing == "round_robin" && b.rounds.isNotEmpty()) add(T1MenuItem("Schedule") { rotoSchedule = true })
                if (repairable != null) add(T1MenuItem("Re-pair $repairName") { repairFrom = "menu" })
                if (phase != OrganizerPhase.Results) add(T1MenuItem("Cancel event", danger = true) { cancelling = "" })
            },
            onDismiss = { moreMenu = false },
        )
    }

    val repairing = repairFrom
    if (repairing != null && repairable != null) {
        val copy = RepairRound.confirm(repairName, repairable.matches.map { it.isBye to it.status })
        T1AlertDialog(
            title = copy.title,
            onDismiss = { repairFrom = null },
            body = { DialogText(copy.message) },
            confirm = {
                BarAction("Re-pair") {
                    repairFrom = null
                    tab = "round"
                    act { Repo.repairRound(event.id, repairable.id, copy.results > 0, repairing) }
                }
            },
            dismiss = { BarAction("Not yet") { repairFrom = null } },
        )
    }

    if (showQr) {
        T1Panel(title = "Join QR", onDismiss = { showQr = false }) {
            ShareQr(event.id)
        }
    }

    if (displayOpen) DisplayPanel(event.id, room, { displayOpen = false }, onChanged)
    extraFor?.let { m -> ExtraTimeMenu(m, room, { extraFor = null }, onChanged) { error = it } }

    if (confirmCut) {
        val four = event.topCut == 4
        T1AlertDialog(
            title = if (four) "Cut to top 4?" else "Cut to top 8?",
            onDismiss = { confirmCut = false },
            body = { DialogText("Pairs the ${if (four) "semifinals" else "quarterfinals"} from the Swiss standings. Swiss is over: no more Swiss rounds.") },
            confirm = { BarAction("Cut") { confirmCut = false; pair() } },
            dismiss = { BarAction("Not yet") { confirmCut = false } },
        )
    }

    listFor?.let { p ->
        DecklistPanel(event, p.id, p.displayName, byOrganizer = true) { changed ->
            listFor = null
            if (changed) scope.launch { onChanged() }
        }
    }

    if (confirmStart) {
        val minutes = event.roundLengthSeconds / 60
        val clock = if (event.showClock) "the $minutes-minute clock" else "the round (clocks hidden)"
        // Pairing round 1 with unpaid players asks first (contract/entry-fees-2026-11-13.md § 4).
        val unpaid = money?.takeIf { (it.fee?.amountCents ?: 0) > 0 }?.organizer?.unpaid ?: 0
        T1AlertDialog(
            title = "Start ${event.name}?",
            onDismiss = { confirmStart = false },
            body = {
                DialogText(
                    (if (unpaid > 0) Fees.unpaidQuestion(unpaid) + "\n\n" else "") +
                    if (event.isDraft) "Pairs round 1 across the table and starts $clock. Format, rounds and teams lock."
                    else "Pairs round 1 and starts $clock. Format, rounds and teams lock.",
                )
            },
            confirm = {
                BarAction(if (unpaid > 0) "Pair anyway" else "Start") {
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
                DialogText(
                    standings.clinched?.let { "${it.text} Open matches won't count. Final standings go to every player and the event moves to Past." }
                        ?: "Final standings go to every player and the event moves to Past. You can still correct a result afterwards.",
                )
            },
            confirm = {
                BarAction("Finish") {
                    confirmFinish = false
                    // Between rounds (finishing a clinched event early) the last round is the one to record.
                    val round = b.activeRound ?: b.rounds.maxByOrNull { it.number }
                    val clinch = standings.clinched
                    if (round != null) act {
                        Repo.recordRound(event.id, round.id, finalRound = true)
                        clinch?.let { Telemetry.capture("event_finished_clinched", mapOf("remaining" to it.remaining)) }
                    }
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
            onExtra = if (live && room != null && !m.isBye) ({
                editing = null
                extraFor = m
            }) else null,
            extra = room?.extra(m.id) ?: 0,
        ) { s0, s1, draws ->
            editing = null
            act { Repo.setMatchResult(m.id, s0, s1, draws, "Set by organizer") }
        }
    }
    if (rotoOverlay) site.table1.events.roto.RotoDraftOverlay(event.id, event.name, true, event.pairing, onOpenList) { rotoOverlay = false }
    if (rotoSchedule) site.table1.events.roto.RotoScheduleSheet(b, null) { rotoSchedule = false }
}

/* ── setup ──────────────────────────────────────────────────────────────────── */

@Composable
private fun SetupPlayers(
    b: EventBundle,
    tags: Map<String, String>,
    pods: List<Pair<String, String?>>,
    busy: Boolean,
    onAddPlayers: () -> Unit,
    onShowQr: () -> Unit,
    onChanged: suspend () -> Unit,
    money: EventMoney? = null,
    onError: (String?) -> Unit = {},
    act: (suspend () -> Unit) -> Unit,
) {
    val scope = rememberCoroutineScope()
    // Players removed here are hidden at once while the server call and reload catch up.
    var removed by remember { mutableStateOf(emptySet<String>()) }
    var removeError by remember { mutableStateOf<String?>(null) }
    val participants = b.participants.filter { it.id !in removed }
    val myId = Repo.userId
    val me = participants.firstOrNull { it.userId != null && it.userId == myId }
    var guestName by remember { mutableStateOf("") }
    var removing by remember { mutableStateOf<ParticipantRow?>(null) }
    var listFor by remember { mutableStateOf<ParticipantRow?>(null) }
    val context = LocalContext.current
    val guest = tidyName(guestName)
    val dup = guest.isNotEmpty() && participants.any { it.displayName.equals(guest, ignoreCase = true) }
    LazyColumn(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                Ghost("Add players", accent = true, onClick = onAddPlayers)
                Ghost("Show join QR", onClick = onShowQr)
                Ghost("Share link") { shareEventLink(context, b.event) }
            }
        }
        item {
            ListRow("Join code", listOfNotNull(EventRules.whenText(b.event.startsAt), b.event.venueName).joinToString(" · ").ifEmpty { null }) {
                Text(b.event.shortCode, color = T1.accent, fontFamily = T1.mono, fontSize = 18.sp, letterSpacing = 4.sp)
            }
        }
        // The prize pool as it stands (contract/entry-fees-2026-11-13.md § 2), for an event with a fee.
        if (money?.fee != null) item(key = "pool") { PrizePoolRow(money) }
        // A season's final you organize: who qualified, and Invite (contract/teams-finals-alerts-2026-11-13.md § 3).
        item(key = "qualified") { QualifiedRow(b.event.id, startOpen = EventDemo.screen == "qualified", onChanged = onChanged) }
        val active = participants.count { it.status == "active" }
        item { Section(listOfNotNull(b.event.capacity?.let { "Players · $active/$it" } ?: "Players · ${participants.size}", unpaidHeader(money)).joinToString(" · ")) }
        if (b.event.takesDecklists) item {
            Notice(EventRules.decklistsLine(active - b.decklistsMissing, active) + if (b.event.decklists == "required") " · required before round 1" else "")
        }
        removeError?.let { item { Notice(it, error = true) } }
        if (myId != null && me == null) item {
            ListRow("You're not playing", "Organizing only", onClick = if (busy) null else ({ act { Repo.addSelf(b.event.id) } })) {
                Label("Join as a player", color = T1.accent)
            }
        }
        if (participants.isEmpty()) item { Notice("No players yet. Add players, or show the join QR to the room.") }
        val setupRow: @Composable (ParticipantRow) -> Unit = { p ->
            val team = tags[p.id]?.let { t -> t + (p.teamSlot?.let { " " + slotLetter(it) } ?: "") }
            val detail = listOfNotNull(
                if (p.userId == null) "Guest" else "Joined",
                p.seat?.let { "Seat $it" },
                team,
                b.decklistDetail(p),
            ).joinToString(" · ")
            ListRow(if (p.id == me?.id) "You · ${p.displayName}" else p.displayName, detail,
                onClick = rememberOpenProfile("event_players")(p.userId), avatar = { Avatar(p.displayName, p.userId) },
                // The payment tag leads the quiet line (`PAID · APP`); a tap on it opens Paid at the door, Comp, Unpaid, Refund.
                detailLead = if (money?.payment(p.id) != null && (money.fee?.amountCents ?: 0) > 0) ({
                    PayTag(b.event.id, money, p.id, p.displayName, enabled = !busy, onChanged = onChanged, onError = onError)
                }) else null) {
                if (b.event.takesDecklists) {
                    Label(if (b.decklist(p.id) == null) "Enter list" else "List",
                        Modifier.padding(end = 16.dp).clickable { listFor = p }, color = T1.accent)
                }
                if (b.event.beforeRoundOne) {
                    Label("Remove", Modifier.clickable(enabled = !busy) { removing = p }, color = T1.danger)
                }
            }
        }
        val podsOf = DraftPods.playerSections(participants, pods, { it.podId }, { it.seat })
        if (podsOf != null) {
            // A seated draft with 2+ pods: each pod's players by seat, then anyone who joined after the draw.
            podsOf.forEach { sec ->
                item(key = "pod-${sec.key}") { PodHeader(sec.title, plural(sec.items.size, "player")) }
                items(sec.items, key = { it.id }) { setupRow(it) }
            }
        } else {
            items(participants, key = { it.id }) { setupRow(it) }
        }
        item {
            AddByNameRow(guestName, { guestName = it }, enabled = guest.isNotEmpty() && !dup && !busy) {
                val name = guest
                guestName = ""
                act { Repo.addGuest(b.event.id, name) }
            }
        }
        if (dup) item { Notice("$guest is already in this event.", error = true) }
        waitlistItems(b, busy, act)
    }
    listFor?.let { p ->
        DecklistPanel(b.event, p.id, p.displayName, byOrganizer = true) { changed ->
            listFor = null
            if (changed) scope.launch { onChanged() }
        }
    }
    removing?.let { p ->
        T1AlertDialog(
            title = "Remove ${p.displayName}?",
            onDismiss = { removing = null },
            body = {
                DialogText(
                    if (p.seat != null && b.event.status == "seated") "They'll leave the event. Seats after theirs move up one."
                    else "They'll leave the event.",
                )
            },
            confirm = {
                BarAction("Remove") {
                    // The row goes at once; the reload follows. If the server refuses, the player comes back.
                    removing = null
                    removeError = null
                    removed = removed + p.id
                    scope.launch {
                        try {
                            Repo.removeParticipant(p.id)
                            onChanged()
                        } catch (e: Exception) {
                            removed = removed - p.id
                            removeError = userMessage(e)
                        }
                    }
                }
            },
            dismiss = { BarAction("Keep") { removing = null } },
        )
    }
}

@Composable
private fun SetupSeating(b: EventBundle, standings: StandingsResponse, busy: Boolean, act: (suspend () -> Unit) -> Unit,
                         reseat: (suspend () -> List<SeatingPod>) -> Unit, onSeat: () -> Unit) {
    val seating = standings.seating.orEmpty()
    val event = b.event
    // Drafts (not team drafts or rotos): pods, how rounds 2+ pair, seats moved by hand (contract/draft-pods-2026-11-09.md).
    val hasPods = event.formatName == "draft"
    val active = b.participants.filter { it.status == "active" }
    val seatedIds = seating.flatMap { p -> p.seats.map { it.participantId } }.toSet()
    val unseated = if (event.status == "seated") active.filter { it.id !in seatedIds } else emptyList()
    var swapFrom by remember { mutableStateOf<SeatingSeat?>(null) }
    var menu by remember { mutableStateOf<Pair<String, List<T1MenuItem>>?>(null) }

    fun tap(seat: SeatingSeat, pod: SeatingPod) {
        swapFrom?.let { from ->
            swapFrom = null
            if (from.participantId != seat.participantId) reseat { Repo.seatSwap(from.participantId, seat.participantId).pods }
            return
        }
        val items = seating.filter { it.podId != pod.podId }.map { other ->
            T1MenuItem("Move to ${other.name ?: "pod"} · ${other.seats.size}") { reseat { Repo.seatMove(seat.participantId, other.podId).pods } }
        }.toMutableList()
        if (pod.seats.size > 1) items += T1MenuItem("Move to a new pod") { reseat { Repo.seatMove(seat.participantId, null).pods } }
        items += T1MenuItem("Swap with…") { swapFrom = seat }
        menu = "${pod.name ?: "Pod"} · seat ${seat.seat} · ${seat.displayName}" to items
    }

    menu?.let { (title, items) -> T1Menu(title, items) { menu = null } }
    LazyColumn(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        if (hasPods) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    DraftPodsBlock(event.pods, event.podPairing, active.size, seated = seating.isNotEmpty(), enabled = !busy) { n, p ->
                        act { Repo.setEventPods(event.id, n, p) }
                    }
                }
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                Ghost(if (seating.isEmpty()) "Seat players" else "Randomize", enabled = !busy, onClick = onSeat)
            }
        }
        swapFrom?.let { from ->
            item {
                ListRow("Swap ${from.displayName} with…", "Tap the other player", onClick = { swapFrom = null }) {
                    Label("Cancel", color = T1.accent)
                }
            }
        }
        if (seating.isEmpty()) {
            item { Notice("Seat players for the draft, or pair round 1 to seat them automatically.") }
        } else {
            item {
                ListRow("Seat the ends", "Players at both ends of the table, not just the sides") {
                    T1Switch(b.event.seatEnds, enabled = !busy) { on ->
                        act {
                            Repo.setSeatEnds(b.event.id, on)
                            Telemetry.capture("seat_ends_changed", mapOf("on" to on, "players" to seating.sumOf { it.seats.size }))
                        }
                    }
                }
            }
            seatingItems(seating, highlight = swapFrom?.participantId, teamDraft = b.event.formatName == "team_draft", seatEnds = b.event.seatEnds,
                         onTap = if (hasPods && event.status == "seated" && !busy) ::tap else null)
            if (unseated.isNotEmpty()) {
                item { Section("Not seated · ${unseated.size}") }
                unseated.forEach { p -> item(key = "unseated-${p.id}") { ListRow(p.displayName, "Seated at round 1, in the smallest pod") } }
            }
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
    val showClock: Boolean,
    /** Named by the server while [name] is empty. */
    val autoName: Boolean,
    val topCut: Int = 0,
    val autoRounds: Boolean = false,
    val decklists: String = "off",
) {
    val swiss: Boolean get() = !team
    val limited: Boolean get() = limitedFormats.any { it.first == formatName }
    /** Team Trios: a constructed team event, always three a team, each seat its own format. */
    val trios: Boolean get() = formatName == "team_trios"
    val team: Boolean get() = formatName == "team_draft" || formatName == "team_sealed" || trios
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
            showClock = e.showClock,
            autoName = e.autoName,
            topCut = e.topCut,
            autoRounds = e.autoRounds,
            decklists = e.decklists,
        ).let { if (e.autoName) it.copy(name = "") else it }
    }
}

/**
 * Setup → Details: edits save as they're made (text after 600 ms of quiet, steppers and pickers at once) with
 * update_event_details, always sending the full current state. Errors show inline.
 */
@Composable
private fun DetailsTab(b: EventBundle, onChanged: suspend () -> Unit, money: EventMoney? = null) {
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
    var listing by remember { mutableStateOf<Boolean?>(null) }
    LaunchedEffect(Unit) { listing = ListingLive.check() }
    val saveLock = remember { Mutex() }
    var schedule by remember(event.id) { mutableStateOf(ScheduleDraft.from(event)) }
    var scheduleEdits by remember { mutableIntStateOf(0) }
    /** Roto: swiss | round_robin, editable until round 1 (update_event_details p_pairing). */
    var rotoPairing by remember(event.id) { mutableStateOf(event.pairing) }
    /** The league's name for the fee's "$7 an entry goes to <league>". */
    var leagueName by remember(event.id) { mutableStateOf<String?>(null) }
    LaunchedEffect(event.id) { runCatching { Repo.eventAbout(event.id) }.onSuccess { leagueName = it.league?.takeIf { l -> !l.final }?.name } }

    /** When / where / cap through set_event_schedule: the venue after a pause, the rest at once. */
    fun saveSchedule() {
        val s = schedule
        scope.launch {
            try {
                Repo.setEventSchedule(event.id, s.iso, s.venue, s.capacity, s.localDate)
                error = null
                onChanged()
            } catch (e: Exception) {
                error = userMessage(e)
            }
        }
    }
    LaunchedEffect(scheduleEdits) {
        if (scheduleEdits > 0) {
            delay(600)
            saveSchedule()
        }
    }

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
                    val typed = tidyName(d.name)
                    Repo.updateEventDetails(
                        eventId = event.id,
                        name = typed.ifEmpty { null },
                        autoName = typed.isEmpty(),
                        topCut = d.topCut.takeIf { it in TeamRules.cutChoices(d.formatName, if (d.formatName == "roto") rotoPairing else "swiss") } ?: 0,
                        autoRounds = d.swiss && d.autoRounds,
                        decklists = if (limited) "off" else d.decklists,
                        formatName = d.formatName,
                        rounds = d.rounds,
                        showClock = d.showClock,
                        setCode = if (limited && !d.useCube) d.setCode else null,
                        setName = if (limited && !d.useCube) d.setName.trim().ifEmpty { null } else null,
                        cubeName = if (limited && d.useCube) d.cubeName.trim().ifEmpty { null } else null,
                        cubeUrl = if (limited && d.useCube) d.cubeUrl.trim().ifEmpty { null } else null,
                        teamSize = if (d.trios) 3 else if (d.team) d.teamSize else null,
                        formatOther = if (d.other) d.formatOther.trim().ifEmpty { null } else null,
                        pairing = if (d.formatName == "roto") rotoPairing else null,
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
            T1TextField(d.name, { editText(draft.copy(name = it.take(80))) },
                placeholder = if (event.autoName) event.name else "Named from the format and date")
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

        if (d.limited && d.formatName == "roto" && event.isRoto) {
            // The pool is one of your Library cubes (roto_set_cube), not a typed name.
            site.table1.events.roto.RotoSetupFields(event.id, b.participants.count { it.status == "active" }) { scope.launch { onChanged() } }
            FormBlock("Pairing") {
                site.table1.events.roto.RotoPairingFields(rotoPairing, b.participants.count { it.status == "active" }) { rotoPairing = it; editNow(draft) }
            }
        } else if (d.limited) {
            FormBlock("Product") {
                T1Segmented(listOf("Set", "Cube"), if (d.useCube) 1 else 0) { draft = draft.copy(useCube = it == 1) }
                if (!d.useCube) {
                    if (setsUnavailable) {
                        T1TextField(d.setName, { editText(draft.copy(setCode = null, setName = it.take(80))) }, label = "Set name")
                    } else {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            d.setCode?.let { SetIcon(it, size = 22.dp) }
                            Box(Modifier.weight(1f)) {
                                T1TextField(
                                    value = d.setCode?.let { "${d.setName.ifEmpty { it.uppercase() }} (${it.uppercase()})" } ?: "",
                                    onChange = {}, label = "Set", placeholder = "Pick a set…", trailing = "›",
                                    onClick = { pickingSet = true },
                                )
                            }
                        }
                    }
                } else {
                    CubeFields(
                        cubeName = d.cubeName, onCubeName = { editText(draft.copy(cubeName = it)) },
                        cubeUrl = d.cubeUrl, onCubeUrl = { editText(draft.copy(cubeUrl = it)) },
                        onLookedUp = { name, url -> editNow(draft.copy(cubeName = name, cubeUrl = url)) },
                    )
                }
            }
        }

        if (d.team && !d.trios) {
            FormBlock("Team size") {
                T1Segmented(listOf("3", "4"), if (d.teamSize == 3) 0 else 1) { editNow(draft.copy(teamSize = if (it == 0) 3 else 4)) }
            }
        }
        // Team Trios: each seat's format, once the event is one on the server (set_event_trios).
        if (d.trios && event.isTrios) TrioSeatsRow(event.seatFormats ?: TeamRules.defaultSeats) { seats ->
            scope.launch {
                runCatching { Repo.setEventTrios(event.id, seats) }.onSuccess { error = null }.onFailure { error = userMessage(it) }
                onChanged()
            }
        }

        ScheduleBlock(schedule) { next ->
            val typing = next.startsAt == schedule.startsAt && next.capacity == schedule.capacity
            schedule = next
            scheduleEdits++
            if (!typing) saveSchedule()
        }

        if (!(d.formatName == "roto" && rotoPairing == "round_robin")) CutRoundsBlock(d.autoRounds, { editNow(draft.copy(autoRounds = it)) }, d.rounds, { editNow(draft.copy(rounds = it)) },
            d.topCut, { editNow(draft.copy(topCut = it)) }, b.participants.count { it.status == "active" }, d.swiss && !(d.formatName == "roto" && rotoPairing == "round_robin"),
            cuts = TeamRules.cutChoices(d.formatName, if (d.formatName == "roto") rotoPairing else "swiss"), teams = d.team)

        RoundTimerRow(d.showClock) { editNow(draft.copy(showClock = it)) }
        if (!d.limited) DecklistsBlock(d.decklists) { editNow(draft.copy(decklists = it)) }
        // The entry fee (contract/entry-fees-2026-11-13.md § 2); hidden while the server has no fees.
        EventFeeRow(event.id, money, leagueName, startOpen = EventDemo.screen == "fee", onChanged = onChanged)

        // Who can find it, the description, the address and the league (contract/public-events-leagues-2026-11-13.md
        // § 1, § 3). Until the server lists events, the three choices Details had.
        if (listing == true) {
            EventListingBlock(event, onChanged, onError = { error = it }, pending = pendingVisibility != null) { v ->
                pendingVisibility = v
                permission.launch(arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION))
            }
        } else if (listing == false) FormBlock("Who can find it") {
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
    clinch: TeamClinch?,
    onClock: (String) -> Unit,
    onEdit: (MatchRow) -> Unit,
    onRepair: () -> Unit,
    /** False when a tabletop fold draws the clock on the upright half. */
    hero: Boolean = true,
    /** Drafts: the pods in order, so the round's tables sit under Pod 1 / Pod 2 / Across pods. */
    pods: List<Pair<String, String?>> = emptyList(),
    /** Open judge calls and tables with extra time (contract/room-tools-2026-11-13.md §§ 2–3). */
    room: EventRoom? = null,
    onChanged: suspend () -> Unit = {},
    onError: (String?) -> Unit = {},
) {
    val event = b.event
    /** A row's quiet line: a team event's seat first (`A · MODERN`), the table's extra time last (`No result yet · +5:00`). */
    fun withExtra(m: MatchRow, detail: String?): String? {
        val seat = if (!event.isTeamEvent) null
            else b.participants.firstOrNull { it.id == m.side(0)?.participantId }?.teamSlot?.let { TeamRules.seatLabel(it, event.seatFormats) }
        return listOfNotNull(seat, detail, RoomRules.extensionText(room?.extra(m.id) ?: 0).takeIf { it.isNotEmpty() }).joinToString(" · ").ifEmpty { null }
    }
    LazyColumn(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        // Open judge calls lead the tab, oldest first.
        judgeCallItems(room?.calls, onChanged, onError)
        // An earlier result was corrected after this round was paired: offer to pair it again.
        RepairRound.prompt(b.rounds)?.let { prompt ->
            item(key = "repair") {
                Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    Notice(prompt.text)
                    Row { Ghost("Re-pair ${RepairRound.label(active?.stage, prompt.round)}", enabled = !busy) { onRepair() } }
                }
            }
        }
        clinch?.let { item(key = "clinch") { Notice("${it.text} You can finish now; open matches won't count.") } }
        if (active == null) {
            val next = (b.rounds.maxOfOrNull { it.number } ?: 0) + 1
            item {
                Notice(
                    when (if (event.isTeamEvent && event.topCut == 0) "" else b.nextStep) {
                        "cut" -> "Swiss is done. Cut to the top 8 to pair the quarterfinals."
                        "cut4" -> "Swiss is done. Cut to the top 4 to pair the semifinals."
                        "semifinals", "final" -> "No round running. Pair the next playoff round when everyone is ready."
                        "finish" -> "Every round has been played."
                        else -> if (next <= event.numberOfRounds) "No round running. Pair round $next when everyone is ready." else "Every round has been played."
                    },
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
        val roundLine = active.name(event.numberOfRounds)
        val caption = if (paused) "Paused · $roundLine"
        else listOfNotNull(roundLine, "$inCount of $games results in", disputed.size.takeIf { it > 0 }?.let { "$it disputed" })
            .joinToString(" · ")

        if (event.showClock) {
            if (hero) item(key = "clock") { BigNumber(clockText(secondsLeft ?: 0), caption) }
            item(key = "clock-actions") {
                Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    Ghost(if (paused) "Resume clock" else "Pause clock", enabled = !busy) { onClock(if (paused) "resume" else "pause") }
                    Ghost("+5 min", enabled = !busy) { onClock("add") }
                }
            }
        } else {
            // Round timer off: no clock anywhere for this event (rounds still run 50 minutes).
            item(key = "clock") { Notice(caption) }
        }

        val byPod = matchSections(b, pods, matches, active.stage)
        if (byPod != null) {
            // Drafts with 2+ pods: each pod's tables as their own block, in table order, disputes included.
            byPod.forEach { sec ->
                item(key = "pod-${sec.key}") { PodHeader(sec.title, podProgress(sec.items)) }
                items(sec.items, key = { it.id }) { m -> LiveMatchRow(m, b, onEdit, RoomRules.extensionText(room?.extra(m.id) ?: 0)) }
            }
            return@LazyColumn
        }
        if (disputed.isNotEmpty()) {
            item(key = "h-disputed") { Section("Disputed · ${disputed.size}") }
            items(disputed, key = { it.id }) { m ->
                MatchResultRow(matchTitle(m, b), withExtra(m, "Reported differently · tap to set"), "Set", accent = false) { onEdit(m) }
            }
        }
        if (waiting.isNotEmpty()) {
            item(key = "h-waiting") { Section("Waiting · ${waiting.size}") }
            items(waiting, key = { it.id }) { m ->
                MatchResultRow(matchTitle(m, b), withExtra(m, "No result yet"), "Set", accent = false) { onEdit(m) }
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
                    MatchResultRow(matchTitle(m, b), withExtra(m, detail), score(m), accent = true) { onEdit(m) }
                }
            }
        }
    }
}

/** One match on the Live round inside its pod: disputed, waiting, a result in, or the bye. [extra]: `+5:00`. */
@Composable
private fun LiveMatchRow(m: MatchRow, b: EventBundle, onEdit: (MatchRow) -> Unit, extra: String = "") {
    fun line(detail: String) = listOf(detail, extra).filter { it.isNotEmpty() }.joinToString(" · ")
    when {
        m.isBye -> MatchResultRow(matchTitle(m, b), null, "Bye", accent = false, onClick = null)
        m.isDisputedOpen -> MatchResultRow(matchTitle(m, b), line("Reported differently · tap to set"), "Set", accent = false, danger = true) { onEdit(m) }
        m.status == "pending" -> MatchResultRow(matchTitle(m, b), line("No result yet"), "Set", accent = false) { onEdit(m) }
        else -> {
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

@Composable
private fun MatchResultRow(title: String, detail: String?, value: String, accent: Boolean, danger: Boolean = false, onClick: (() -> Unit)?) {
    ListRow(title, detail, onClick = onClick) {
        Text(value, color = if (danger) T1.danger else if (accent) T1.accent else T1.text, fontFamily = T1.mono, fontSize = 16.sp, maxLines = 1)
    }
}

@Composable
private fun LivePlayers(
    b: EventBundle,
    standings: List<Standing>,
    pods: List<Pair<String, String?>>,
    busy: Boolean,
    onList: (ParticipantRow) -> Unit,
    onDrop: (ParticipantRow) -> Unit,
    onReinstate: (ParticipantRow) -> Unit,
    money: EventMoney? = null,
    onChanged: suspend () -> Unit = {},
    onError: (String?) -> Unit = {},
) {
    val byId = standings.associateBy { it.participantId }
    val playing = b.participants.filter { it.status != "dropped" }
    val dropped = b.participants.filter { it.status == "dropped" }
    LazyColumn(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        val playingRow: @Composable (ParticipantRow, Int?) -> Unit = { p, seat ->
            val s = byId[p.id]
            ListRow(p.displayName, listOfNotNull(seat?.let { "Seat $it" }, s?.let { "${record(it.matchWins, it.matchLosses, it.matchDraws)} · ${it.matchPoints} pts" },
                    b.decklistDetail(p)).joinToString(" · ").ifEmpty { null },
                onClick = rememberOpenProfile("event_players")(p.userId), avatar = { Avatar(p.displayName, p.userId) },
                detailLead = if (money?.payment(p.id) != null && (money.fee?.amountCents ?: 0) > 0) ({
                    PayTag(b.event.id, money, p.id, p.displayName, enabled = !busy, onChanged = onChanged, onError = onError)
                }) else null) {
                if (b.event.takesDecklists) T1TextAction("List", enabled = !busy, color = T1.accent) { onList(p) }
                T1TextAction("Drop", enabled = !busy, color = T1.danger) { onDrop(p) }
            }
        }
        val byPod = DraftPods.playerSections(playing, pods, { it.podId }, { it.seat })
        if (byPod != null) {
            // Drafts with 2+ pods: each pod's players by seat, then anyone not seated yet.
            byPod.forEach { sec ->
                item(key = "pod-${sec.key}") { PodHeader(sec.title, plural(sec.items.size, "player")) }
                items(sec.items, key = { it.id }) { p -> playingRow(p, if (sec.pod != null) p.seat else null) }
            }
        } else {
            item(key = "h-playing") { Section(listOfNotNull("Playing · ${playing.size}", unpaidHeader(money)).joinToString(" · ")) }
            items(playing, key = { it.id }) { p -> playingRow(p, null) }
        }
        if (dropped.isNotEmpty()) {
            item(key = "h-dropped") { Section("Dropped · ${dropped.size}") }
            items(dropped, key = { it.id }) { p ->
                ListRow(p.displayName, "Dropped after round ${p.droppedInRound ?: "–"} · still counts in tiebreakers",
                    onClick = rememberOpenProfile("event_players")(p.userId), avatar = { Avatar(p.displayName, p.userId) }) {
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
        standings.standings, teams, tags, highlight = null, userIds = b.userIds, bracket = standings.bracket, seating = standings.seating,
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
private fun ResultsRounds(
    b: EventBundle,
    onEdit: (MatchRow) -> Unit,
    rounds: List<RoundRow> = b.rounds,
    note: String = "Tap a match to correct its result. Standings and records update.",
    pods: List<Pair<String, String?>> = emptyList(),
) {
    LazyColumn(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        if (rounds.isEmpty()) item { Notice("No rounds were played.") }
        val row: @Composable (MatchRow) -> Unit = { m ->
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
        rounds.sortedByDescending { it.number }.forEach { r ->
            val byPod = matchSections(b, pods, r.matches, r.stage)
            if (byPod != null) {
                // Drafts with 2+ pods: "Round 2 · Pod 1", "Round 2 · Across pods", each its own block.
                byPod.forEach { sec ->
                    item(key = "round-${r.id}-${sec.key}") { PodHeader("Round ${r.number} · ${sec.title}", DraftPods.matchCount(sec.items.count { !it.isBye })) }
                    items(sec.items, key = { it.id }) { row(it) }
                }
            } else {
                item(key = "round-${r.id}") { Section(if (r.isPlayoff) r.name(b.event.numberOfRounds) else "Round ${r.number}") }
                items(r.matches.sortedWith(compareBy({ it.isBye }, { it.tableNumber ?: 0 })), key = { it.id }) { row(it) }
            }
        }
        if (rounds.isNotEmpty()) item(key = "rounds-note") { Notice(note) }
    }
}

@Composable
private fun ResultsPlayers(b: EventBundle, standings: List<Standing>, pods: List<Pair<String, String?>> = emptyList()) {
    val byId = standings.associateBy { it.participantId }
    val ordered = b.participants.sortedBy { byId[it.id]?.rank ?: Int.MAX_VALUE }
    LazyColumn(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        val finalRow: @Composable (ParticipantRow) -> Unit = { p ->
            val s = byId[p.id]
            val detail = if (p.status == "dropped") "Dropped after round ${p.droppedInRound ?: "–"}" else s?.let { "#${it.rank}" }
            ListRow(p.displayName, detail, onClick = rememberOpenProfile("event_players")(p.userId), avatar = { Avatar(p.displayName, p.userId) }) {
                if (s != null) {
                    Text(record(s.matchWins, s.matchLosses, s.matchDraws), color = T1.text, fontFamily = T1.mono, fontSize = 14.sp)
                    Label("${s.matchPoints} pts")
                }
            }
        }
        // Drafts with 2+ pods: each pod's players in final order (overall places), as their own blocks.
        val byPod = DraftPods.playerSections(ordered, pods, { it.podId }, { null })
        if (byPod != null) {
            byPod.forEach { sec ->
                item(key = "pod-${sec.key}") { PodHeader(sec.title, plural(sec.items.size, "player")) }
                items(sec.items, key = { it.id }) { finalRow(it) }
            }
        } else {
            item { Section("Players · ${ordered.size}") }
            items(ordered, key = { it.id }) { finalRow(it) }
        }
    }
}
