package site.table1.events.ui.screens

import site.table1.events.library.JoinNotice
import site.table1.events.util.rethrowIfCancelled
import site.table1.events.util.Offline
import site.table1.events.util.Telemetry

import site.table1.events.data.EventRules

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import site.table1.events.data.HomeData
import site.table1.events.data.HomeEvent
import site.table1.events.data.HomeInvite
import site.table1.events.data.JoinLink
import site.table1.events.data.LiveSnapshot
import site.table1.events.data.Repo
import site.table1.events.tracker.TrackerSettings
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Countdown
import site.table1.events.ui.components.Ghost
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.Stat
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.parseInstant
import site.table1.events.ui.components.shortWhen
import site.table1.events.ui.theme.T1
import site.table1.events.util.PermissionsStep
import site.table1.events.util.currentFix
import site.table1.events.util.QrScan
import site.table1.events.util.scanQr

/**
 * The Events tab. What's happening now comes first and biggest; getting into events (scan, nearby,
 * create) is secondary until there's nothing to show.
 */
@Composable
fun EventsHomeScreen(
    foregrounds: Int,
    autoOpenArmed: Boolean,
    onAutoOpened: () -> Unit,
    onOpenEvent: (String) -> Unit,
    onCreate: () -> Unit,
    /** An event you're on the waitlist for: its sign-up page. */
    onOpenPage: (String) -> Unit = {},
    onNearby: () -> Unit,
    onJoinLink: (JoinLink) -> Unit,
    onLife: () -> Unit,
    onOpenTracker: (String) -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var data by remember { mutableStateOf<HomeData?>(null) }
    var snaps by remember { mutableStateOf<Map<String, LiveSnapshot>>(emptyMap()) }
    var showPast by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    // When `data` was fetched (this launch's, or the device's saved copy), and the notice when a refresh fails
    // (contract/offline-2026-10-31.md § 1).
    var savedAt by remember { mutableStateOf<Long?>(null) }
    var stale by remember { mutableStateOf<String?>(null) }
    /** Events you follow but aren't in (contract/event-follows-2026-11-09.md). */
    var followed by remember { mutableStateOf<List<site.table1.events.data.FollowedEvent>>(emptyList()) }

    suspend fun load() {
        // What this account last saw shows at once; the server's answer replaces it.
        if (data == null) Repo.savedHome()?.let { (h, at) -> data = h; savedAt = at }
        runCatching { Repo.eventsHome() }
            .onSuccess { data = it; error = null; stale = null; savedAt = System.currentTimeMillis(); site.table1.events.widgets.Widgets.saveNext(context, it) }
        // A server without event follows (or a failed read) just shows no Following section.
        runCatching { Repo.eventsFollowed() }.onSuccess { followed = it }.onFailure { it.rethrowIfCancelled() }
            .onFailure { e ->
                e.rethrowIfCancelled()
                val age = Offline.age(savedAt)
                val n = Offline.notice(true, age, e.message)
                if (n != null && !n.second) {
                    stale = n.first
                    Telemetry.capture("offline_shown", mapOf("screen" to "home", "age_s" to (age ?: 0L)))
                } else if (data == null) { error = n?.first; data = HomeData() }
            }
        snaps = Repo.liveSnapshots().associateBy { it.eventId }
        TrackerSettings.refresh()
    }

    val live = data?.events?.filter { it.bucket == "live" }.orEmpty()
    val upcoming = data?.events?.filter { it.bucket == "upcoming" }.orEmpty()
    val past = data?.events?.filter { it.bucket == "past" }.orEmpty()
    val invites = data?.invites.orEmpty()

    LaunchedEffect(foregrounds) {
        load()
        // While a round you're playing is running, open straight into it (once per launch/return):
        // the life tracker for that match when tracker mode is on, otherwise the event.
        if (autoOpenArmed) {
            data?.events?.firstOrNull { it.bucket == "live" && it.playingNow }?.let { e ->
                onAutoOpened()
                val matchId = snaps[e.id]?.state?.takeIf { it.isPlaying }?.matchId
                if (TrackerSettings.useTracker && matchId != null) onOpenTracker(matchId) else onOpenEvent(e.id)
            }
        }
    }
    // While something is live, keep the cards fresh; the clocks themselves tick locally.
    LaunchedEffect(live.map { it.id }) {
        if (live.isEmpty()) return@LaunchedEffect
        while (true) {
            delay(45_000)
            load()
        }
    }

    // Keep this account's area cell fresh for nearby alerts while the app is open (opt-in on the Nearby screen). Never
    // asks: the permissions step after sign-in does, or Nearby / Create when they need a fix.
    LaunchedEffect(Unit) {
        if (PermissionsStep.locationAllowed(context)) currentFix(context)?.let { runCatching { Repo.updatePresence(it.lat, it.lng) } }
    }

    fun scan() = scope.launch {
        val raw = when (val scan = scanQr(context)) {
            is QrScan.Read -> scan.text
            QrScan.Cancelled -> return@launch
            QrScan.Unavailable -> {
                Telemetry.capture("qr_scanner_unavailable", mapOf("screen" to "home"))
                error = "This phone can't open Google's QR scanner yet. Update Google Play services and try again, " +
                    "or open the organizer's link."
                return@launch
            }
        }
        val link = JoinLink.parse(raw)
        if (link != null) onJoinLink(link) else error = "That QR code isn't a Table 1 event."
    }

    fun answer(invite: HomeInvite, accept: Boolean) = scope.launch {
        runCatching { Repo.respondToInvite(invite.eventId, accept) }
            .onSuccess { if (accept) onOpenEvent(invite.eventId) else load() }
            .onFailure { error = it.message }
    }

    T1Screen {
        Bar("Events", if (live.isEmpty()) null else "${live.size} live") {
            BarAction("Life", onLife)
            BarAction("+ New", onCreate)
        }
        error?.let { Notice(it, error = true) }
        stale?.let { Notice(it) }
        val d = data
        if (d == null) {
            Notice("Loading…")
            return@T1Screen
        }
        if (d.events.isEmpty() && invites.isEmpty() && d.waitlist.isEmpty() && followed.isEmpty()) {
            if (error != null) BigAction("Try again") { scope.launch { load() } }
            EmptyEvents(onScan = { scan() }, onNearby = onNearby, onCreate = onCreate, onJoined = onOpenEvent)
            return@T1Screen
        }
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            items(live, key = { "live-" + it.id }) { e ->
                if (e.playing && !e.organizing) {
                    PlayerHero(e, snaps[e.id], onOpen = { onOpenEvent(e.id) }, onOpenTracker = onOpenTracker,
                        onChanged = { scope.launch { load() } })
                } else {
                    OrganizerHero(e, onOpen = { onOpenEvent(e.id) })
                }
            }
            if (invites.isNotEmpty()) {
                item { Section("Invitations") }
                item { Notice(JoinNotice.TEXT) }
                items(invites, key = { "inv-" + it.eventId }) { invite ->
                    val detail = buildList {
                        add(if (invite.source == "nearby_alert") "Starting near you" else "From ${invite.invitedBy ?: "an organizer"}")
                        invite.formatLabel?.let { add(it) }
                        shortWhen(invite.startsAt)?.let { add(it) }
                        invite.venueName?.let { add(it) }
                    }.joinToString(" · ")
                    ListRow(invite.name, detail) {
                        BarAction("Decline") { answer(invite, false) }
                        BarAction("Join") { answer(invite, true) }
                    }
                }
            }
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    Ghost("Scan QR") { scan() }
                    Ghost("Nearby", onClick = onNearby)
                }
            }
            item { JoinCodeRow(onJoined = onOpenEvent) }
            if (upcoming.isNotEmpty()) {
                item { Section("Upcoming") }
                items(upcoming, key = { it.id }) { e -> EventLine(e) { onOpenEvent(e.id) } }
            }
            if (d.waitlist.isNotEmpty()) {
                item { Section("Waitlist") }
                items(d.waitlist, key = { "w-${it.eventId}" }) { w ->
                    ListRow(w.name, listOfNotNull("Number ${w.position ?: 1} on the waitlist", EventRules.whenText(w.startsAt), w.venueName).joinToString(" · "),
                        onClick = { onOpenPage(w.eventId) })
                }
            }
            if (followed.isNotEmpty()) {
                item { Section("Following") }
                items(followed, key = { "f-${it.eventId}" }) { f -> ListRow(f.name, f.detail, onClick = { onOpenPage(f.eventId) }) }
            }
            if (past.isNotEmpty()) {
                item {
                    Row(Modifier.fillMaxWidth().clickable { showPast = !showPast }) {
                        Section(if (showPast) "Past · hide" else "Past · ${past.size}")
                    }
                }
                if (showPast) items(past, key = { it.id }) { e -> EventLine(e) { onOpenEvent(e.id) } }
            }
        }
    }
}

/** A round you're playing: clock, table, opponent and ranks, and one-tap reporting. */
@Composable
private fun PlayerHero(e: HomeEvent, snap: LiveSnapshot?, onOpen: () -> Unit, onOpenTracker: (String) -> Unit, onChanged: () -> Unit) {
    val scope = rememberCoroutineScope()
    var sending by remember { mutableStateOf(false) }
    val s = snap?.state
    Column(Modifier.fillMaxWidth().clickable(onClick = onOpen), verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Row(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 10.dp)) {
            Label("Playing · Round ${e.round?.number ?: e.currentRound} of ${e.numberOfRounds}", Modifier.weight(1f), color = T1.accent)
            Label("Open ›", color = T1.text)
        }
        Column(Modifier.fillMaxWidth().background(T1.bg).padding(vertical = 16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(e.name, color = T1.text, fontFamily = T1.mono, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (e.showClock) {
                Countdown(
                    endMillis = s?.endsAt?.let { (it * 1000).toLong() } ?: parseInstant(e.round?.endsAt),
                    pausedSeconds = s?.pausedRemaining ?: e.round?.remainingSeconds,
                )
            } else {
                Label("Round ${e.round?.number ?: e.currentRound} of ${e.numberOfRounds}", color = T1.text)
            }
        }
        if (s != null && s.isPlaying) {
            Row(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Stat("Table", s.table?.toString() ?: "–", accent = true)
                Stat("You", "${s.myRank?.let { "#$it" } ?: "#–"} · ${s.myRecord}")
                Stat(s.oppRank?.let { "#$it" } ?: "#–", s.oppName ?: "Opponent", end = true)
            }
            Notice(s.statusLine)
            // Tracker mode leads with the life tracker; otherwise it's a secondary action under the results.
            val trackerMatch = s.matchId
            val trackerFirst = TrackerSettings.useTracker && trackerMatch != null
            if (trackerFirst) {
                Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    Ghost("Open life tracker", accent = true) { onOpenTracker(trackerMatch) }
                }
            }
            if (s.canReportNow) {
                Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    listOf(2 to 0, 2 to 1, 1 to 1, 1 to 2, 0 to 2).forEach { (my, their) ->
                        Ghost("$my-$their", enabled = !sending) {
                            val matchId = s.matchId ?: return@Ghost
                            val side = s.mySide ?: return@Ghost
                            sending = true
                            scope.launch {
                                runCatching { Repo.reportFromHome(matchId, side, my, their, s.matchVersion) }
                                sending = false
                                onChanged()
                            }
                        }
                    }
                }
            } else if (s.needsMyAnswer) {
                Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    Ghost("Dispute") { scope.launch { runCatching { Repo.respondToResult(s.matchId ?: "", false) }; onChanged() } }
                    Ghost("Confirm", accent = true) { scope.launch { runCatching { Repo.respondToResult(s.matchId ?: "", true) }; onChanged() } }
                }
            }
            if (!trackerFirst && trackerMatch != null) {
                Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    Ghost("Open life tracker") { onOpenTracker(trackerMatch) }
                }
            }
        } else {
            Notice(s?.statusLine ?: "Open the event for your table and opponent.")
        }
    }
}

/** A round you're running: clock and how many results are in. */
@Composable
private fun OrganizerHero(e: HomeEvent, onOpen: () -> Unit) {
    val r = e.round
    Column(Modifier.fillMaxWidth().clickable(onClick = onOpen), verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Row(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 10.dp)) {
            Label(if (r != null) "Organizing · Round ${r.number} of ${e.numberOfRounds}" else "Organizing · Seating",
                Modifier.weight(1f), color = T1.accent)
            Label("Open ›", color = T1.text)
        }
        Column(Modifier.fillMaxWidth().background(T1.bg).padding(vertical = 14.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(e.name, color = T1.text, fontFamily = T1.mono, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (r != null && e.showClock) Countdown(parseInstant(r.endsAt), r.remainingSeconds, size = 44)
            else Text("${e.players} players", color = T1.text, fontFamily = T1.mono, fontSize = 28.sp)
        }
        if (r != null) {
            Row(Modifier.fillMaxWidth().background(if (r.disputed > 0) T1.danger.copy(alpha = 0.15f) else T1.surface)
                .padding(horizontal = 16.dp, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Stat("Results in", "${r.resultsIn} of ${r.matches}", accent = r.resultsIn == r.matches)
                Stat("Disputed", "${r.disputed}")
                Stat("Players", "${e.players}", end = true)
            }
        } else {
            Notice("Pair round 1 when everyone is seated.")
        }
    }
}

@Composable
private fun EventLine(e: HomeEvent, onClick: () -> Unit) {
    val detail = buildList {
        add(if (e.organizing) "Organizing" else "Playing")
        add(e.label)
        when {
            e.bucket == "upcoming" -> {
                EventRules.whenText(e.startsAt)?.let { add(it) }
                add(e.capacity?.let { "${e.players}/$it signed up" } ?: "${e.players} signed up")
                if (e.owesDecklist) add("Add your decklist")
            }
            e.isCancelled -> e.cancelReason?.let { add(it) }
            else -> add("${e.numberOfRounds} rounds · ${e.players} players")
        }
    }.joinToString(" · ")
    ListRow(e.name, detail, onClick = onClick) {
        if (e.isCancelled) Label("Cancelled", color = T1.danger)
    }
}

/** No events and no invitations: the ways in become the screen. */
@Composable
private fun EmptyEvents(onScan: () -> Unit, onNearby: () -> Unit, onCreate: () -> Unit, onJoined: (String) -> Unit) {
    Column(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 24.dp, vertical = 40.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("No events yet", color = T1.text, fontFamily = T1.mono, fontSize = 20.sp)
        Text("Scan an organizer's QR code, enter their event code, find an event happening near you, or run your own.",
            color = T1.muted, fontFamily = T1.mono, fontSize = 12.sp, textAlign = TextAlign.Center)
    }
    BigAction("Scan QR", accent = true, onClick = onScan)
    BigAction("Find nearby", onClick = onNearby)
    JoinCodeRow(onJoined = onJoined)
    Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) { Ghost("Create an event", onClick = onCreate) }
}
