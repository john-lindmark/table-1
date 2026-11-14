package site.table1.events.ui.screens

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
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
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import site.table1.events.data.EventAbout
import site.table1.events.data.EventLeague
import site.table1.events.data.EventRow
import site.table1.events.data.LeagueCard
import site.table1.events.data.LeaguePage
import site.table1.events.data.Leagues
import site.table1.events.data.LeaguesDemo
import site.table1.events.data.Repo
import site.table1.events.data.eventAbout
import site.table1.events.data.findEvents
import site.table1.events.data.leagueView
import site.table1.events.data.leaguesHome
import site.table1.events.data.setEventListing
import site.table1.events.data.setLeagueEvent
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Panel
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1Switch
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1
import site.table1.events.util.PermissionsStep
import site.table1.events.util.currentFix
import site.table1.events.util.rethrowIfCancelled
import kotlinx.coroutines.withTimeoutOrNull

/*
 * An event's listing (contract/public-events-leagues-2026-11-13.md § 1 Clients): who can find it, its description and
 * address in Create and Setup → Details, the event's League row there (§ 3), and the About and league rows the event
 * page shows everyone who can open it.
 */

/** Whether the server lists events yet (asked once a launch; a "no" is asked again). Before it does, Create and Setup
 *  keep the choices they had. */
object ListingLive {
    private var live: Boolean? = null

    suspend fun check(): Boolean {
        if (LeaguesDemo.on || live == true) return true
        val now = try {
            Repo.findEvents(site.table1.events.data.FindFilters(), limit = 1)
            true
        } catch (e: Throwable) {
            e.rethrowIfCancelled()
            // Only "no such function" says it isn't there; a refusal or no network leaves the new choices up.
            !Leagues.isMissing(e)
        }
        live = now
        return now
    }
}

/** Once per device: sign-up for a public or league event says its results are public. */
object PublicResultsNotice {
    private fun prefs(context: Context) = context.getSharedPreferences("onboarding", Context.MODE_PRIVATE)
    fun seen(context: Context) = prefs(context).getBoolean("publicResults.seen", false)
    fun markSeen(context: Context) = prefs(context).edit().putBoolean("publicResults.seen", true).apply()
}

/** Public | Friends | Private. [older]: Setup's two older choices under a hairline (Nearby + QR, Invitation only). */
@Composable
fun WhoCanFind(find: String, enabled: Boolean = true, older: Boolean = false, onPick: (String) -> Unit) {
    FormBlock("Who can find it") {
        T1Segmented(Leagues.finds.map { it.second }, Leagues.finds.indexOfFirst { it.first == find }, enabled = enabled) { onPick(Leagues.finds[it].first) }
        if (older) {
            Box(Modifier.fillMaxWidth().height(1.dp).background(T1.bg))
            val olds = listOf("nearby" to "Nearby + QR", "invite" to "Invitation only")
            T1Segmented(olds.map { it.second }, olds.indexOfFirst { it.first == find }, enabled = enabled) { onPick(olds[it].first) }
        }
    }
}

/** A long text in its own panel, with its counter (`1,240 / 2,000`) and Save. */
@Composable
fun TextPanel(title: String, start: String, max: Int, placeholder: String, onDismiss: () -> Unit, onSave: (String) -> Unit) {
    var text by remember { mutableStateOf(start) }
    T1Panel(title, onDismiss, action = { BarAction("Save") { onSave(text.trim()) } }) {
        Label(Leagues.counter(text.length, max), Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 8.dp))
        BasicTextField(text, { text = it.take(max) }, Modifier.fillMaxWidth().weight(1f),
            textStyle = TextStyle(color = T1.text, fontFamily = T1.mono, fontSize = 15.sp, lineHeight = 22.sp), cursorBrush = SolidColor(T1.accent),
            decorationBox = { inner ->
                Box(Modifier.fillMaxWidth().background(T1.surface).padding(16.dp)) {
                    if (text.isEmpty()) Text(placeholder, color = T1.muted, fontFamily = T1.mono, fontSize = 15.sp)
                    inner()
                }
            })
    }
}

/** The description's row: its first line as data, opening the text panel. */
@Composable
fun DescriptionRow(description: String, onChange: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    ArrowRow("Description", description.lineSequence().firstOrNull { it.isNotBlank() }?.trim()) { open = true }
    if (open) TextPanel("Description", description, Leagues.DESCRIPTION_MAX, "What players should know", { open = false }) {
        open = false
        onChange(it)
    }
}

/** A place for a listing's distance: the organizer's fix when location is already allowed (never asks). */
internal suspend fun venuePin(context: Context): Pair<Double, Double>? {
    if (!PermissionsStep.locationAllowed(context)) return null
    return withTimeoutOrNull(6_000) { currentFix(context) }?.let { it.lat to it.lng }
}

/**
 * Setup → Details once the server lists events: Who can find it (Public | Friends | Private, then the older Nearby +
 * QR and Invitation only), Description, Address and League. [setOlder] is the screen's existing way to set the two
 * older choices (it needs the organizer's place).
 */
@Composable
fun EventListingBlock(event: EventRow, onChanged: suspend () -> Unit, onError: (String?) -> Unit, pending: Boolean, setOlder: (String) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var about by remember(event.id) { mutableStateOf<EventAbout?>(null) }
    var address by remember(event.id) { mutableStateOf("") }
    var addressEdits by remember { mutableIntStateOf(0) }
    var busy by remember { mutableStateOf(false) }
    var reloads by remember { mutableIntStateOf(0) }

    LaunchedEffect(event.id, reloads) {
        runCatching { Repo.eventAbout(event.id) }.onSuccess { a ->
            about = a
            if (addressEdits == 0) address = a.venueAddress.orEmpty()
        }.onFailure { it.rethrowIfCancelled() }
    }

    fun save(block: suspend () -> Unit) {
        busy = true
        scope.launch {
            try {
                block()
                onError(null)
                reloads++
                onChanged()
            } catch (e: Throwable) {
                e.rethrowIfCancelled()
                onError(userMessage(e))
            } finally {
                busy = false
            }
        }
    }

    val listed = event.visibility == "public" || event.visibility == "friends"
    WhoCanFind(Leagues.findOf(event.visibility), enabled = !busy && !pending, older = true) { pick ->
        when (pick) {
            // A listing takes the event's place for distance when the organizer is at it: an event starting now, with
            // location already allowed. A scheduled event is usually set up away from the venue.
            "public", "friends" -> save { Repo.setEventListing(event.id, find = pick, place = if (event.startsAt == null) venuePin(context) else null) }
            "private" -> save { Repo.setEventListing(event.id, find = "private") }
            // The older choices are set as before, after unlisting a listed event.
            else -> if (listed) save { Repo.setEventListing(event.id, find = "private"); setOlder(if (pick == "invite") "private" else "nearby") }
                    else setOlder(if (pick == "invite") "private" else "nearby")
        }
    }
    DescriptionRow(about?.description.orEmpty()) { text -> save { Repo.setEventListing(event.id, description = text) } }
    FormBlock("Address") {
        T1TextField(address, { address = it.take(Leagues.ADDRESS_MAX); addressEdits++ }, placeholder = "Street and city (optional)")
    }
    LaunchedEffect(addressEdits) {
        if (addressEdits > 0) {
            delay(600)
            save { Repo.setEventListing(event.id, address = address) }
        }
    }
    EventLeagueRow(event.id, about?.league, private = event.visibility == "private", onError = onError) { reloads++; scope.launch { onChanged() } }
}

/** The event's League row for organizers who run a league: league and season, multiplier, This is the final; Remove. */
@Composable
fun EventLeagueRow(eventId: String, current: EventLeague?, private: Boolean, onError: (String?) -> Unit, onSaved: () -> Unit) {
    val scope = rememberCoroutineScope()
    var mine by remember { mutableStateOf<List<LeagueCard>>(emptyList()) }
    var open by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { runCatching { Repo.leaguesHome().mine }.onSuccess { mine = it }.onFailure { it.rethrowIfCancelled() } }
    if (mine.isEmpty() && current == null) return
    ArrowRow("League", current?.let { l -> listOfNotNull(l.name, l.season, Leagues.leagueEventMark(l.final, l.multiplier)).joinToString(" · ") } ?: "None") { open = true }
    if (!open) return

    var leagueId by remember { mutableStateOf(current?.id ?: mine.firstOrNull()?.id) }
    var page by remember { mutableStateOf<LeaguePage?>(null) }
    var seasonId by remember { mutableStateOf(current?.seasonId) }
    var multiplier by remember { mutableStateOf(current?.multiplier ?: 1.0) }
    var final by remember { mutableStateOf(current?.final ?: false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(leagueId) {
        val id = leagueId ?: return@LaunchedEffect
        page = null
        runCatching { Repo.leagueView(id) }.onSuccess { p ->
            page = p
            val open = p.seasons.filter { it.state != "over" }
            if (open.none { it.id == seasonId }) seasonId = open.firstOrNull()?.id
        }.onFailure { it.rethrowIfCancelled(); error = userMessage(it) }
    }
    fun run(block: suspend () -> Unit) {
        busy = true
        scope.launch {
            try {
                block()
                open = false
                onError(null)
                onSaved()
            } catch (e: Throwable) {
                e.rethrowIfCancelled()
                error = userMessage(e)
            } finally {
                busy = false
            }
        }
    }
    T1Panel("League", { open = false }, action = {
        if (seasonId != null && !busy && !private) BarAction("Save") { run { Repo.setLeagueEvent(eventId, seasonId, multiplier, final) } }
    }) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            error?.let { Notice(it, error = true) }
            if (private) Notice("An invitation-only event can't be in a league.")
            if (mine.size > 1 || mine.none { it.id == leagueId }) {
                Section("League")
                mine.forEach { l -> ListRow(l.name, l.line.ifEmpty { null }, onClick = { leagueId = l.id }) { if (l.id == leagueId) Label("Picked", color = T1.accent) } }
            } else mine.firstOrNull()?.let { ListRow(it.name, it.line.ifEmpty { null }) }
            Section("Season")
            val seasons = page?.seasons?.filter { it.state != "over" }
            when {
                seasons == null -> if (error == null) Notice("Loading…")
                seasons.isEmpty() -> ListRow("No open season", "Add one from the league's tools")
                else -> seasons.forEach { s ->
                    ListRow(s.name, Leagues.seasonLine(s.startsOn, s.endsOn, null), onClick = { seasonId = s.id }) { if (s.id == seasonId) Label("Picked", color = T1.accent) }
                }
            }
            FormBlock("Multiplier") {
                T1Segmented(Leagues.multipliers.map(Leagues::multiplierText), Leagues.multipliers.indexOf(multiplier), enabled = !final) { multiplier = Leagues.multipliers[it] }
            }
            ListRow("This is the final", onClick = { final = !final }) { T1Switch(final) { final = it } }
            if (current != null) ListRow("Remove from league", onClick = { if (!busy) run { Repo.setLeagueEvent(eventId, null) } }) { Label("Remove", color = T1.danger) }
        }
    }
}

/**
 * What the event page adds for anyone who can open the event: an About row when there is a description or an address
 * (second line: the address) opening the text, and the league's row opening the league. Nothing while the server has
 * no event_about, or for an event with neither.
 */
@Composable
fun EventAboutRows(eventId: String, go: (String) -> Unit, loaded: (EventAbout) -> Unit = {}) {
    var about by remember(eventId) { mutableStateOf<EventAbout?>(null) }
    var open by remember { mutableStateOf(false) }
    LaunchedEffect(eventId) {
        runCatching { Repo.eventAbout(eventId) }.onSuccess { about = it; loaded(it) }.onFailure { it.rethrowIfCancelled() }
    }
    val a = about ?: return
    if (a.hasAbout) ArrowRow("About", a.venueAddress?.takeIf { it.isNotBlank() }) { open = true }
    a.league?.let { l ->
        ArrowRow(l.name, listOfNotNull(l.season, Leagues.leagueEventMark(l.final, l.multiplier)).joinToString(" · ").ifEmpty { null }) {
            go(leagueRoute(l.slug.ifEmpty { l.id }, "event"))
        }
    }
    if (open) T1Panel("About", { open = false }) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            a.description?.takeIf { it.isNotBlank() }?.let { LinkedText(it) }
            a.venueAddress?.takeIf { it.isNotBlank() }?.let { InfoRow("Address", it) }
        }
    }
}
