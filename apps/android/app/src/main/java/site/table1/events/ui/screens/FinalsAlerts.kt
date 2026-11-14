package site.table1.events.ui.screens

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import site.table1.events.data.EventAlerts
import site.table1.events.data.EventDemo
import site.table1.events.data.FinalRow
import site.table1.events.data.FinalStatus
import site.table1.events.data.Leagues
import site.table1.events.data.LeaguesDemo
import site.table1.events.data.Repo
import site.table1.events.data.TeamRules
import site.table1.events.data.eventAbout
import site.table1.events.data.eventAlerts
import site.table1.events.data.finalInvite
import site.table1.events.data.finalStatus
import site.table1.events.data.setEventAlerts
import site.table1.events.insights.FilterCell
import site.table1.events.insights.FilterRow
import site.table1.events.insights.LimitedCards
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Ghost
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Panel
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1Switch
import site.table1.events.ui.theme.T1
import site.table1.events.util.PermissionsStep
import site.table1.events.util.currentFix
import site.table1.events.util.rethrowIfCancelled

/*
 * A season's final and alerts for new public events (contract/teams-finals-alerts-2026-11-13.md §§ 3–4 Clients): the
 * Qualified row and list on a final you organize, and Find → Events' Alerts row with its screen.
 */

// ── § 3 a season's final ──

/**
 * Setup → Players on a final you organize: a Qualified row (`3 of 23 in`) opening the list. Nothing for any other
 * event (only a season's final asks), for someone who doesn't run its league, or while the server has no finals.
 */
@Composable
fun QualifiedRow(eventId: String, startOpen: Boolean = false, onChanged: suspend () -> Unit) {
    var status by remember(eventId) { mutableStateOf<FinalStatus?>(null) }
    var reloads by remember { mutableIntStateOf(0) }
    var open by remember { mutableStateOf(startOpen) }
    LaunchedEffect(eventId, reloads) {
        runCatching {
            // Only a season's final has the list; the event's own league row says whether it is one.
            if (status == null && Repo.eventAbout(eventId).league?.final != true) return@LaunchedEffect
            Repo.finalStatus(eventId)
        }.onSuccess { status = it }.onFailure { it.rethrowIfCancelled() }
    }
    val f = status ?: return
    ListRow("Qualified", onClick = { open = true }) {
        Label(f.line, color = T1.text)
        site.table1.events.library.IconGlyph(site.table1.events.library.T1Icon.Arrow)
    }
    if (open) QualifiedPanel(eventId, f, { open = false }) { reloads++; onChanged() }
}

/** Qualified (name, `WINNER` / `POINTS`, the state or Invite), Invite the qualified, then Next in line. */
@Composable
private fun QualifiedPanel(eventId: String, f: FinalStatus, onDismiss: () -> Unit, onInvited: suspend () -> Unit) {
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var said by remember { mutableStateOf<String?>(null) }

    fun invite(keys: List<String>?) {
        if (busy) return
        busy = true
        scope.launch {
            try {
                val n = Repo.finalInvite(eventId, keys)
                said = if (n == 0) "Nobody new to invite." else "Invited $n player${if (n == 1) "" else "s"}."
                error = null
                onInvited()
            } catch (e: Throwable) {
                e.rethrowIfCancelled()
                error = userMessage(e)
            } finally {
                busy = false
            }
        }
    }

    @Composable
    fun Line(r: FinalRow) {
        Row(Modifier.fillMaxWidth().background(T1.surface).padding(start = 16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("${r.rank}", Modifier.width(26.dp), color = T1.muted, fontFamily = T1.mono, fontSize = 13.sp, maxLines = 1)
            Column(Modifier.weight(1f).padding(vertical = 10.dp)) {
                Text(r.name, color = T1.text, fontFamily = T1.mono, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Label(listOfNotNull(r.how?.uppercase(), "${r.points} PTS").joinToString(" · "))
            }
            when (r.state) {
                "in" -> Label("In", Modifier.padding(end = 16.dp), color = T1.accent)
                "invited" -> Label("Invited", Modifier.padding(end = 16.dp))
                "declined" -> Label("Declined", Modifier.padding(end = 16.dp))
                "guest" -> Label("Guest", Modifier.padding(end = 16.dp))
                else -> Label("Invite", Modifier.clickable(enabled = !busy, onClickLabel = "Invite ${r.name}") { invite(listOf(r.key)) }
                    .padding(horizontal = 16.dp, vertical = 18.dp), color = T1.text)
            }
        }
    }

    T1Panel("Qualified · ${f.line}", onDismiss) {
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            error?.let { e -> item(key = "error") { Notice(e, error = true) } }
            said?.let { s -> item(key = "said") { Notice(s) } }
            if (f.qualified.isEmpty()) item(key = "none") { ListRow("Nobody has qualified yet") }
            items(f.qualified, key = { "q-${it.key}" }) { Line(it) }
            if (f.next.isNotEmpty()) {
                item(key = "h-next") { Section("Next in line") }
                items(f.next, key = { "n-${it.key}" }) { Line(it) }
            }
        }
        BigAction(if (f.toInvite == 0) "Everyone is invited" else "Invite the qualified", accent = true, busy = busy, enabled = f.toInvite > 0) { invite(null) }
    }
}

// ── § 4 alerts for new public events ──

/** Find → Events ends with Alerts (`OFF`, or `MODERN, LIMITED · 50 KM`). Nothing while the server has no alerts. */
@Composable
fun AlertsRow(reloads: Int, onOpen: () -> Unit) {
    var alerts by remember { mutableStateOf<EventAlerts?>(null) }
    LaunchedEffect(reloads) {
        if (Repo.userId == null && !LeaguesDemo.on) return@LaunchedEffect
        runCatching { Repo.eventAlerts() }.onSuccess { alerts = it }.onFailure { it.rethrowIfCancelled() }
    }
    val a = alerts ?: return
    ListRow("Alerts", onClick = onOpen) {
        Label(TeamRules.alertLine(a), color = if (a.on) T1.text else T1.muted)
        site.table1.events.library.IconGlyph(site.table1.events.library.T1Icon.Arrow)
    }
}

/**
 * Alerts for new public events: On, Formats (several; none = every format), Area (Use where I am now, asked only on
 * that tap; Forget area), Distance (Anywhere | 25 | 50 | 100 | 250 km; a distance without an area asks for the area
 * first), "Up to five a week."
 */
@Composable
fun AlertsScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var alerts by remember { mutableStateOf<EventAlerts?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var missing by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    // A distance picked before there was an area: set once the area is.
    var pendingKm by remember { mutableStateOf<Int?>(null) }

    LaunchedEffect(Unit) {
        try {
            alerts = Repo.eventAlerts()
        } catch (e: Throwable) {
            e.rethrowIfCancelled()
            if (Leagues.isMissing(e)) missing = true else error = userMessage(e)
        }
    }

    fun set(patch: JsonObject) {
        scope.launch {
            try {
                alerts = Repo.setEventAlerts(patch)
                error = null
            } catch (e: Throwable) {
                e.rethrowIfCancelled()
                error = userMessage(e)
            }
        }
    }

    /** Your rough area from where you are now (location is already allowed here), then any distance waiting on it. */
    fun useHere() {
        busy = true
        scope.launch {
            val fix = if (LeaguesDemo.on || EventDemo.shown) null else withTimeoutOrNull(8_000) { currentFix(context) }
            val km = pendingKm
            pendingKm = null
            busy = false
            if (fix == null && !LeaguesDemo.on) { error = "Couldn't find where you are. Try again outside or by a window."; return@launch }
            set(buildJsonObject {
                put("lat", Leagues.rough(fix?.lat ?: 39.7)); put("lng", Leagues.rough(fix?.lng ?: -105.0))
                km?.let { put("km", it) }
            })
        }
    }

    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted ->
        if (granted.values.any { it }) useHere()
        else { pendingKm = null; error = "Location is off, so alerts cover everywhere." }
    }
    fun area() {
        if (LeaguesDemo.on || PermissionsStep.locationAllowed(context)) useHere() else ask.launch(PermissionsStep.locationPermissions)
    }

    val a = alerts
    T1Screen {
        Bar("Alerts", onBack = onBack)
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (missing) Notice("Alerts aren't available yet.")
            error?.let { Notice(it, error = true) }
            if (a == null) {
                if (error == null && !missing) Notice("Loading…")
                return@Column
            }
            ListRow("New public events", TeamRules.alertLine(a), onClick = { set(buildJsonObject { put("on", !a.on) }) }) {
                T1Switch(a.on) { on -> set(buildJsonObject { put("on", on) }) }
            }
            Section("Formats")
            val any = LimitedCards.ANY
            FilterRow(listOf(FilterCell("Formats", when (a.formats.size) { 0 -> "Every format"; 1 -> Leagues.label(a.formats[0]); else -> "${a.formats.size} formats" },
                listOf(Triple(any, "Every format", null)) + Leagues.formatKeys.map { Triple(it.first, it.second, null) }, current = null, picked = a.formats) { v ->
                val now = alerts?.formats.orEmpty()
                val next = if (v == any) emptyList() else Leagues.formatKeys.map { it.first }.filter { k -> if (k == v) k !in now else k in now }
                // Shown at once, so a second pick in the open picker builds on the first.
                alerts = alerts?.copy(formats = next)
                set(buildJsonObject { putJsonArray("formats") { next.forEach { add(it) } } })
            }), event = "event_alerts_formats")
            Section("Area")
            if (a.hasArea) {
                ListRow("About ${a.lat}, ${a.lng}", "ROUGHLY 10 KM · NEVER YOUR EXACT PLACE")
                Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    Ghost(if (busy) "Finding…" else "Use where I am now", enabled = !busy) { area() }
                    Ghost("Forget area") { set(buildJsonObject { put("place", JsonNull); put("km", JsonNull) }) }
                }
            } else ListRow(if (busy) "Finding where you are…" else "Use where I am now", onClick = { if (!busy) area() }) { Label("None", color = T1.muted) }
            Section("Distance")
            val distances = TeamRules.alertDistances
            T1Segmented(distances.map { it?.let { km -> "$km km" } ?: "Anywhere" }, distances.indexOf(a.km).coerceAtLeast(0), scroll = true) { i ->
                val km = distances[i]
                when {
                    km == null -> set(buildJsonObject { put("km", JsonNull) })
                    a.hasArea -> set(buildJsonObject { put("km", km) })
                    // A distance needs an area: ask for it first, then set both.
                    else -> { pendingKm = km; area() }
                }
            }
            Notice("Up to five a week.")
        }
    }
}
