package site.table1.events.ui.screens

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import site.table1.events.data.EventBundle
import site.table1.events.data.EventTeam
import site.table1.events.data.JoinQr
import site.table1.events.data.MatchRow
import site.table1.events.data.Repo
import site.table1.events.data.SeatingPod
import site.table1.events.data.Standing
import site.table1.events.data.StandingsResponse
import site.table1.events.data.TeamMember
import site.table1.events.data.TeamStanding
import site.table1.events.data.slotLetter
import site.table1.events.tracker.TrackerSettings
import site.table1.events.ui.components.Avatar
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.Ghost
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.record
import site.table1.events.ui.components.T1AlertDialog
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Stepper
import site.table1.events.ui.components.T1Switch
import site.table1.events.ui.components.T1TextAction
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1
import site.table1.events.util.qrBitmap
import java.time.Instant

/** One event: the organizer's control room, or a player's match card — chosen by role. */
@Composable
fun EventScreen(eventId: String, onBack: () -> Unit, onAddPlayers: () -> Unit, onOpenTracker: (String) -> Unit, onOpenPhotos: () -> Unit) {
    var bundle by remember { mutableStateOf<EventBundle?>(null) }
    var standings by remember { mutableStateOf(StandingsResponse()) }
    var error by remember { mutableStateOf<String?>(null) }

    // The bundle and the engine's standings don't depend on each other: fetch both at once.
    suspend fun refresh(): Unit = coroutineScope {
        val latestStandings = async { runCatching { Repo.standingsFull(eventId) } }
        runCatching { Repo.loadEvent(eventId) }
            .onSuccess { bundle = it; error = null }
            .onFailure { if (bundle == null) error = it.message }
        latestStandings.await().onSuccess { standings = it }
    }

    LaunchedEffect(eventId) {
        refresh()
        // Realtime: any change in this event refetches, coalesced so a burst of reports is one reload.
        Repo.eventChanges(eventId).collectLatest {
            delay(250)
            refresh()
        }
    }

    val b = bundle
    if (b == null) {
        T1Screen {
            Bar("Event", onBack = onBack)
            Notice(error ?: "Loading…", error = error != null)
        }
        return
    }
    if (b.isOrganizer) OrganizerScreen(
        b, standings, onBack, onAddPlayers, onOpenTracker, onChanged = { refresh() },
        onSeated = { standings = standings.copy(seating = it) }, onOpenPhotos = onOpenPhotos,
    )
    else PlayerView(b, standings, onBack, onOpenTracker, onOpenPhotos, onChanged = { refresh() })
}

/** participant id → team name, for the team tag in the individual table and seating. */
internal fun teamTags(b: EventBundle, standings: StandingsResponse): Map<String, String> {
    val fromStandings = standings.teams.orEmpty().flatMap { t -> t.members.map { it.participantId to t.name } }.toMap()
    val fromBundle = b.participants.mapNotNull { p -> b.teamName(p.teamId)?.let { p.id to it } }.toMap()
    return fromBundle + fromStandings
}

/** The organizer's set-result panel. [onWatch] (live matches) opens the match's shared life tracker read-only. */
@Composable
internal fun EditResultDialog(
    m: MatchRow,
    b: EventBundle,
    onDismiss: () -> Unit,
    onWatch: (() -> Unit)? = null,
    onSave: (Int, Int, Int) -> Unit,
) {
    var s0 by remember { mutableIntStateOf(m.side(0)?.gameWins ?: 0) }
    var s1 by remember { mutableIntStateOf(m.side(1)?.gameWins ?: 0) }
    var draws by remember { mutableIntStateOf(m.gameDraws) }
    val valid = s0 in 0..2 && s1 in 0..2 && s0 + s1 + draws <= 3
    T1AlertDialog(
        title = "Table ${m.tableNumber ?: ""}",
        onDismiss = onDismiss,
        body = {
            Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                T1Stepper(b.name(m.side(0)?.participantId), s0, 0..2, Modifier.fillMaxWidth()) { s0 = it }
                T1Stepper(b.name(m.side(1)?.participantId), s1, 0..2, Modifier.fillMaxWidth()) { s1 = it }
                T1Stepper("Drawn games", draws, 0..3, Modifier.fillMaxWidth()) { draws = it }
                if (!valid) Notice("At most 3 games in a match.", error = true)
                if (onWatch != null) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                        Ghost("Watch life tracker", onClick = onWatch)
                    }
                }
            }
        },
        confirm = { T1TextAction("Save", enabled = valid) { onSave(s0, s1, draws) } },
        dismiss = { BarAction("Cancel", onDismiss) },
    )
}

@Composable
internal fun ShareQr(eventId: String) {
    val scope = rememberCoroutineScope()
    var qr by remember { mutableStateOf<JoinQr?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(eventId) { runCatching { Repo.joinQr(eventId) }.onSuccess { qr = it }.onFailure { error = it.message } }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Column(
            Modifier.fillMaxWidth().background(T1.surface).padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            qr?.let { q ->
                val bitmap = remember(q.url) { qrBitmap(q.url) }
                Image(bitmap, contentDescription = "Join QR code", modifier = Modifier.size(240.dp).background(T1.text).padding(8.dp))
                Text(q.shortCode, color = T1.text, fontFamily = T1.mono, fontSize = 36.sp, letterSpacing = 10.sp)
                Label("Scan with the phone camera or the Table 1 app")
            }
            error?.let { Notice(it, error = true) }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            Ghost("New code") { scope.launch { runCatching { Repo.joinQr(eventId, rotate = true) }.onSuccess { qr = it } } }
        }
    }
}

/* ── teams (organizer) ───────────────────────────────────────────────────────── */

/**
 * Teams of a team event: Randomize, move players between teams, rename, "+ Team", then save the whole
 * layout with set_teams. Read-only once round 1 is paired.
 */
@Composable
internal fun TeamsTab(b: EventBundle, onChanged: suspend () -> Unit) {
    val scope = rememberCoroutineScope()
    val event = b.event
    val teamSize = event.teamSize ?: 4
    val maxTeams = if (event.formatName == "team_draft") 2 else 64
    val editable = event.beforeRoundOne && b.rounds.isEmpty() && !event.isCancelled
    var teams by remember { mutableStateOf<List<EventTeam>?>(null) }
    var dirty by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var moving by remember { mutableStateOf<String?>(null) }
    var renaming by remember { mutableStateOf<Pair<Int, String>?>(null) }

    // Reload from the server whenever the event changes, unless there are unsaved edits.
    LaunchedEffect(b.participants, b.teams) {
        if (dirty && teams != null) return@LaunchedEffect
        runCatching { Repo.eventTeams(event.id) }.onSuccess { teams = it }.onFailure { error = it.message }
    }

    fun commit(block: suspend () -> List<EventTeam>) {
        busy = true
        error = null
        scope.launch {
            try {
                teams = block()
                dirty = false
                onChanged()
            } catch (e: Exception) {
                error = e.message
            } finally {
                busy = false
            }
        }
    }

    fun edit(next: List<EventTeam>) {
        teams = next
        dirty = true
    }

    /** Moves a player to team [to] (index), or out of every team when [to] is null. */
    fun move(member: TeamMember, to: Int?) {
        val current = teams ?: return
        val stripped = current.map { t -> t.copy(members = t.members.filterNot { it.participantId == member.participantId }) }
        edit(if (to == null) stripped else stripped.mapIndexed { i, t -> if (i == to) t.copy(members = t.members + member) else t })
    }

    val list = teams
    val assigned = list.orEmpty().flatMap { t -> t.members.map { it.participantId } }.toSet()
    val unassigned = b.participants.filter { it.status == "active" && it.id !in assigned }
        .map { TeamMember(it.id, it.displayName, null, it.userId, it.status) }

    LazyColumn(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        if (editable) {
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    Ghost("Randomize", enabled = !busy) { commit { Repo.randomizeTeams(event.id) } }
                    Ghost("+ Team", enabled = !busy && list != null && list.size < maxTeams) {
                        val cur = list.orEmpty()
                        edit(cur + EventTeam(id = null, name = "Team ${cur.size + 1}", order = cur.size + 1))
                    }
                    Ghost(if (busy) "Saving…" else "Save", accent = dirty, enabled = dirty && !busy) {
                        val cur = list.orEmpty()
                        commit { Repo.setTeams(event.id, cur) }
                    }
                }
            }
            item { Notice("Teams of $teamSize. ${if (maxTeams == 2) "A team draft has two teams. " else ""}Teams lock when round 1 is paired.") }
        } else {
            item { Notice("Teams lock when round 1 is paired.") }
        }
        error?.let { item { Notice(it, error = true) } }
        if (list == null) {
            item { Notice("Loading…") }
            return@LazyColumn
        }
        list.forEachIndexed { index, team ->
            item(key = "t-$index") {
                ListRow(team.name, "${team.members.size} of $teamSize") {
                    if (editable) {
                        BarAction("Rename") { renaming = index to team.name }
                        if (team.members.isEmpty()) BarAction("Remove") { edit(list.filterIndexed { i, _ -> i != index }) }
                    }
                }
            }
            items(team.members, key = { "t-$index-${it.participantId}" }) { m ->
                MemberRow(
                    member = m, letter = slotLetter(team.members.indexOf(m) + 1), teams = list, teamSize = teamSize,
                    editable = editable, menuOpen = moving == m.participantId,
                    onOpenMenu = { moving = m.participantId }, onDismissMenu = { moving = null },
                    onMove = { to -> moving = null; move(m, to) },
                )
            }
        }
        item(key = "unassigned") { Section("Unassigned · ${unassigned.size}") }
        items(unassigned, key = { "u-${it.participantId}" }) { m ->
            MemberRow(
                member = m, letter = "–", teams = list, teamSize = teamSize,
                editable = editable, menuOpen = moving == m.participantId,
                onOpenMenu = { moving = m.participantId }, onDismissMenu = { moving = null },
                onMove = { to -> moving = null; move(m, to) },
            )
        }
    }

    renaming?.let { (index, draft) ->
        T1AlertDialog(
            title = "Team name",
            onDismiss = { renaming = null },
            body = { T1TextField(draft, { renaming = index to it.take(40) }) },
            confirm = {
                BarAction("Save") {
                    val name = draft.trim()
                    renaming = null
                    val cur = teams ?: return@BarAction
                    if (name.isNotEmpty() && index in cur.indices) {
                        edit(cur.mapIndexed { i, t -> if (i == index) t.copy(name = name) else t })
                    }
                }
            },
            dismiss = { BarAction("Cancel") { renaming = null } },
        )
    }
}

@Composable
private fun MemberRow(
    member: TeamMember,
    letter: String,
    teams: List<EventTeam>,
    teamSize: Int,
    editable: Boolean,
    menuOpen: Boolean,
    onOpenMenu: () -> Unit,
    onDismissMenu: () -> Unit,
    onMove: (Int?) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().background(T1.surface).let { if (editable) it.clickable(onClick = onOpenMenu) else it }
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Label(letter, color = T1.text)
        Text(member.displayName, Modifier.weight(1f), color = if (member.status == "dropped") T1.muted else T1.text,
            fontFamily = T1.mono, fontSize = 14.sp, maxLines = 1)
        if (editable) Label("Move to…", color = T1.text)
    }
    if (editable && menuOpen) {
        val onTeam = teams.any { t -> t.members.any { it.participantId == member.participantId } }
        T1Menu(
            title = "Move ${member.displayName} to…",
            items = teams.mapIndexed { i, t ->
                val here = t.members.any { it.participantId == member.participantId }
                val full = t.members.size >= teamSize
                T1MenuItem(t.name + if (full && !here) " (full)" else "", enabled = !here && !full, selected = here) { onMove(i) }
            } + T1MenuItem("Unassigned", enabled = onTeam, selected = !onTeam) { onMove(null) },
            onDismiss = onDismissMenu,
        )
    }
}

/** "Use life tracker": the same user_settings.tracker_mode as Account → Settings. */
@Composable
private fun TrackerModeSwitch(onError: (String?) -> Unit) {
    val scope = rememberCoroutineScope()
    Row(
        Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text("Use life tracker", color = T1.text, fontFamily = T1.mono, fontSize = 14.sp)
            Label(if (TrackerSettings.useTracker) "Opens when your round starts" else "Report results here")
        }
        T1Switch(TrackerSettings.useTracker) { on ->
            scope.launch {
                runCatching { TrackerSettings.set(if (on) "tracker" else "elsewhere") }.onFailure { onError(it.message) }
            }
        }
    }
}

/* ── player ─────────────────────────────────────────────────────────────────── */

private val outcomes = listOf("Won 2–0" to (2 to 0), "Won 2–1" to (2 to 1), "Draw 1–1" to (1 to 1), "Lost 1–2" to (1 to 2), "Lost 0–2" to (0 to 2))

@Composable
private fun PlayerView(
    b: EventBundle, standings: StandingsResponse, onBack: () -> Unit, onOpenTracker: (String) -> Unit, onOpenPhotos: () -> Unit,
    onChanged: suspend () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val me = b.participants.firstOrNull { it.userId != null && it.userId == Repo.userId }
    val tags = teamTags(b, standings)
    val myTeam = me?.let { tags[it.id] }?.let { name ->
        val team = if (name.startsWith("Team", ignoreCase = true)) name else "Team $name"
        "$team · seat ${slotLetter(me?.teamSlot)}"
    }
    val seating = standings.seating.orEmpty()
    val active = b.activeRound
    val match = active?.matches?.firstOrNull { m -> m.sides.any { it.participantId == me?.id } }
    val mine = match?.sides?.firstOrNull { it.participantId == me?.id }
    val theirs = match?.sides?.firstOrNull { it.participantId != me?.id }
    // Optimistic: the tapped result shows instantly; the server confirms (or the error reverts it).
    var optimistic by remember(match?.id, match?.version) { mutableStateOf<Pair<Int, Int>?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    val opponentReported = match != null && match.status == "reported" && match.reportedByUser != null && match.reportedByUser != Repo.userId

    fun report(myWins: Int, theirWins: Int) {
        val m = match ?: return
        val side = mine?.side ?: return
        optimistic = myWins to theirWins
        error = null
        scope.launch {
            try {
                val (s0, s1) = if (side == 0) myWins to theirWins else theirWins to myWins
                val outcome = Repo.reportMatch(m, s0, s1)
                if (outcome.conflict) notice = "Your opponent reported a different score. The first result stands until the organizer decides."
                onChanged()
            } catch (e: Exception) {
                optimistic = null
                error = e.message
            }
        }
    }

    T1Screen {
        Bar(b.event.name, listOfNotNull(me?.displayName ?: "Spectating", myTeam, b.event.label,
            "Round ${active?.number ?: b.event.currentRound} of ${b.event.numberOfRounds}").joinToString(" · "), onBack = onBack)
        if (b.event.isCancelled) CancelledBanner(b.event.cancelReason)
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (active != null && b.event.showClock) item { RoundClock(active.timerEndsAt) }
            when {
                me == null -> item { Notice("You're viewing this event. Scan the organizer's QR to take a seat.") }
                match == null -> if (!b.event.isFinished) item { Notice(if (active == null) "Waiting for the next round to be paired." else "You're not paired this round.") }
                match.isBye -> item {
                    Box(Modifier.fillMaxWidth().background(T1.accent).padding(24.dp), contentAlignment = Alignment.Center) {
                        Label("You have the bye this round", color = T1.ink)
                    }
                }
                else -> {
                    item {
                        Column(Modifier.fillMaxWidth().background(T1.surface).padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                            Label("Table ${match.tableNumber ?: "–"} · playing")
                            Text(b.name(theirs?.participantId), color = T1.text, fontFamily = T1.mono, fontSize = 22.sp)
                        }
                    }
                    if (match.status != "confirmed") item {
                        Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                            Ghost("Open life tracker", accent = TrackerSettings.useTracker) { onOpenTracker(match.id) }
                        }
                    }
                    if (opponentReported) {
                        item { Notice("${b.name(theirs?.participantId)} reported ${mine?.gameWins}–${theirs?.gameWins} for you.${if (match.disputed) " Disputed — waiting on the organizer." else ""}") }
                        if (!match.disputed) item {
                            Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                                Ghost("Dispute") { scope.launch { runCatching { Repo.respondToResult(match.id, false) }; notice = "Disputed. The organizer has been notified."; onChanged() } }
                                Ghost("Confirm", accent = true) { scope.launch { runCatching { Repo.respondToResult(match.id, true) }; onChanged() } }
                            }
                        }
                    } else if (match.status == "confirmed") {
                        item { Notice("Result confirmed: ${mine?.gameWins}–${theirs?.gameWins}. The organizer can still correct it.") }
                    } else if (b.event.allowPlayerReporting) {
                        items(outcomes, key = { it.first }) { (label, score) ->
                            val selected = optimistic == score ||
                                (optimistic == null && match.status == "reported" && mine?.gameWins == score.first && theirs?.gameWins == score.second)
                            Box(
                                Modifier.fillMaxWidth().background(if (selected) T1.accent else T1.surface)
                                    .clickable { report(score.first, score.second) }.padding(vertical = 16.dp),
                                contentAlignment = Alignment.Center,
                            ) { Label(label, color = if (selected) T1.ink else T1.text) }
                        }
                        if (match.status == "reported") item { Notice("Reported. Tap a different result to correct it before the round ends.") }
                    } else {
                        item { Notice("The organizer is recording results for this event.") }
                    }
                }
            }
            notice?.let { item { Notice(it) } }
            error?.let { item { Notice(it, error = true) } }
            if (me != null) item {
                TrackerModeSwitch(onError = { error = it })
            }
            // Your deck during the event; everyone's once it's over (contract/event-night-2026-10-16.md § 7).
            if (me != null && !b.event.isCancelled) item {
                Row { Ghost(if (b.event.isFinished) "Deck photos" else "Deck photo") { onOpenPhotos() } }
            }
            if (b.event.isDraft && seating.isNotEmpty() && b.rounds.size <= 1) {
                item { Section("Seating") }
                seatingItems(seating, highlight = me?.id, teamDraft = b.event.formatName == "team_draft")
            }
            standings.teams?.takeIf { it.isNotEmpty() }?.let { teams ->
                teamStandingItems(teams, highlightMember = me?.id)
            }
            item { Section(if (standings.teams.isNullOrEmpty()) "Standings" else "Players") }
            items(standings.standings, key = { it.participantId }) { s -> StandingLine(s, highlight = s.participantId == me?.id, team = tags[s.participantId], userId = b.userIds[s.participantId]) }
        }
    }
}

/* ── shared ─────────────────────────────────────────────────────────────────── */

@Composable
private fun CancelledBanner(reason: String?) {
    Notice("Cancelled by the organizer${reason?.let { ": $it" } ?: ""}. Confirmed results still count.", error = true)
}

/** Standings (team table first for team events), with optional rows above and below. */
@Composable
internal fun StandingsList(
    standings: List<Standing>,
    teams: List<TeamStanding>?,
    tags: Map<String, String>,
    highlight: String?,
    /** participant id → account id, for avatars. */
    userIds: Map<String, String> = emptyMap(),
    header: LazyListScope.() -> Unit = {},
    footer: LazyListScope.() -> Unit = {},
) {
    LazyColumn(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        header()
        if (standings.isEmpty()) item { Notice("Standings appear after the first results.") }
        if (!teams.isNullOrEmpty()) {
            teamStandingItems(teams, highlightMember = highlight)
            if (standings.isNotEmpty()) item { Section("Players") }
        }
        items(standings, key = { it.participantId }) {
            StandingLine(it, it.participantId == highlight, tags[it.participantId], userIds[it.participantId])
        }
        footer()
    }
}

/** Team table: rank · name · points · W-L-D · match wins, members (slot letter + record) underneath, best first. */
internal fun LazyListScope.teamStandingItems(teams: List<TeamStanding>, highlightMember: String?) {
    item { Section("Teams") }
    teams.forEach { t ->
        item(key = "team-${t.teamId}") {
            Row(
                Modifier.fillMaxWidth().background(if (t.members.any { it.participantId == highlightMember }) T1.surfaceHover else T1.surface)
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Label("${t.rank}")
                Text(t.name, Modifier.weight(1f), color = T1.text, fontFamily = T1.mono, fontSize = 14.sp, maxLines = 1)
                Label("${t.points} pts", color = T1.accent)
                Text(record(t.wins, t.losses, t.draws), color = T1.text, fontFamily = T1.mono, fontSize = 14.sp)
                Label("${t.matchWins} match wins")
            }
        }
        // Best first by record, then game-win %, then OMW (the engine's order).
        items(t.members, key = { "team-${t.teamId}-${it.participantId}" }) { m ->
            Row(
                Modifier.fillMaxWidth().background(T1.bg).padding(start = 40.dp, end = 16.dp, top = 8.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Label(slotLetter(m.slot), color = T1.text)
                Text(m.displayName, Modifier.weight(1f), color = if (m.status == "dropped") T1.muted else T1.text,
                    fontFamily = T1.mono, fontSize = 13.sp, maxLines = 1)
                Label(record(m.matchWins, m.matchLosses, m.matchDraws))
            }
        }
    }
}

@Composable
internal fun StandingLine(s: Standing, highlight: Boolean, team: String? = null, userId: String? = null) {
    Row(
        Modifier.fillMaxWidth().background(if (highlight) T1.surfaceHover else T1.surface).padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Label("${s.rank}")
        Avatar(s.displayName, userId)
        Text(s.displayName, Modifier.weight(1f), color = if (s.status == "dropped") T1.muted else T1.text, fontFamily = T1.mono, fontSize = 14.sp)
        team?.let { Label(it) }
        Text(record(s.matchWins, s.matchLosses, s.matchDraws), color = T1.text, fontFamily = T1.mono, fontSize = 14.sp)
        Label("${s.matchPoints} pts")
        Label("%.0f%%".format(s.omw * 100))
    }
}

/** Counts down to the server's timer_ends_at, so every phone shows the same clock. */
@Composable
private fun RoundClock(endsAt: String?) {
    val end = remember(endsAt) { endsAt?.let { runCatching { Instant.parse(it).toEpochMilli() }.getOrNull() } } ?: return
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(end) {
        while (true) {
            now = System.currentTimeMillis()
            delay(1000)
        }
    }
    val left = ((end - now) / 1000).coerceAtLeast(0)
    Box(Modifier.fillMaxWidth().background(T1.bg).padding(vertical = 16.dp), contentAlignment = Alignment.Center) {
        Text(
            if (left == 0L) "TIME" else "%02d:%02d".format(left / 60, left % 60),
            color = if (left == 0L) T1.danger else T1.text, fontFamily = T1.mono, fontSize = 56.sp, letterSpacing = 4.sp,
        )
    }
}
