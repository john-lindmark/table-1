package site.table1.events.ui.screens

import android.content.Context
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withLink
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import site.table1.events.data.BoardCard
import site.table1.events.data.FindFilters
import site.table1.events.data.FormatBoards
import site.table1.events.data.FoundEvent
import site.table1.events.data.Leaderboard
import site.table1.events.data.LeagueCard
import site.table1.events.data.Leagues
import site.table1.events.data.LeaguesDemo
import site.table1.events.data.LeaguesHome
import site.table1.events.data.Repo
import site.table1.events.data.findEvents
import site.table1.events.data.formatBoards
import site.table1.events.data.formatLeaderboard
import site.table1.events.data.leaguesHome
import site.table1.events.data.setLeaderboardsListed
import site.table1.events.insights.FilterCell
import site.table1.events.insights.FilterRow
import site.table1.events.insights.LimitedCards
import site.table1.events.library.IconGlyph
import site.table1.events.library.T1Icon
import site.table1.events.ui.components.Avatar
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.components.rememberOpenProfile
import site.table1.events.ui.theme.T1
import site.table1.events.util.PermissionsStep
import site.table1.events.util.Telemetry
import site.table1.events.util.currentFix
import site.table1.events.util.rethrowIfCancelled
import site.table1.events.widgets.UpcomingPlace

/*
 * Finding events (contract/public-events-leagues-2026-11-13.md § 1 Clients) and the format boards (§ 4): the Events
 * home's Find events section, and Find (route `find`) with its tabs Events | Leagues | Boards. League pages are in
 * LeagueScreens.kt. The server part may not be live: a missing function hides its section.
 */

/** An icon in a bar: a 50 dp wide tap target around the 18 dp glyph, kept to the bar's text height. */
@Composable
internal fun BarIcon(icon: T1Icon, label: String, onClick: () -> Unit) {
    Box(Modifier.size(width = 50.dp, height = 40.dp).clickable(onClickLabel = label, onClick = onClick).semantics { contentDescription = label },
        contentAlignment = Alignment.Center) { IconGlyph(icon) }
}

/** A glyph that isn't in T1Icon (the card page's list and tune) in the same bar slot. */
@Composable
internal fun BarGlyph(label: String, onClick: () -> Unit, glyph: @Composable () -> Unit) {
    Box(Modifier.size(width = 50.dp, height = 40.dp).clickable(onClickLabel = label, onClick = onClick).semantics { contentDescription = label },
        contentAlignment = Alignment.Center) { glyph() }
}

/** A row that opens a list: the title and the arrow. */
@Composable
internal fun ArrowRow(title: String, detail: String? = null, onClick: () -> Unit) {
    ListRow(title, detail, onClick = onClick) { IconGlyph(T1Icon.Arrow) }
}

/** An error with its way out. */
@Composable
internal fun RetryRow(error: String, onRetry: () -> Unit) {
    ListRow(error, onClick = onRetry) { Label("Try again", color = T1.text) }
}

/** The Find events picks on this device (`find.formats`, `find.km`, `find.when`, `find.more`) and where they're measured from. */
object FindStore {
    private const val PREFS = "t1.find"
    var filters by mutableStateOf(FindFilters())
        private set
    /** Said once after a distance was picked and location was refused. */
    var notice by mutableStateOf<String?>(null)
    private var read = false
    private var here: Pair<Double, Double>? = null
    private var hereAt = 0L

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun load(context: Context) {
        if (read) return
        read = true
        val p = prefs(context)
        filters = Leagues.picks(p.getStringSet("find.formats", null).orEmpty(), p.getInt("find.km", 0), p.getString("find.when", null),
            p.getStringSet("find.more", null).orEmpty())
    }

    fun set(context: Context, next: FindFilters) {
        filters = next
        prefs(context).edit().putStringSet("find.formats", next.formats.toSet()).putInt("find.km", next.km ?: 0)
            .putString("find.when", next.at).putStringSet("find.more", next.more.toSet()).apply()
    }

    /**
     * Where you are, only when location is already allowed (this never asks): so rows can say how far, and a picked
     * distance can cut. Kept five minutes; the rough place (0.1°) goes to the Upcoming events widget's Near me.
     */
    suspend fun place(context: Context): Pair<Double, Double>? {
        if (LeaguesDemo.on || !PermissionsStep.locationAllowed(context)) return null
        val now = System.currentTimeMillis()
        here?.takeIf { now - hereAt < 5 * 60_000 }?.let { return it }
        val fix = withTimeoutOrNull(6_000) { currentFix(context) } ?: return here
        here = fix.lat to fix.lng
        hereAt = now
        UpcomingPlace.save(context, fix.lat, fix.lng)
        return here
    }
}

/** What a list of found events shows: the rows, or why not. */
class FoundState {
    var events by mutableStateOf<List<FoundEvent>?>(null)
    /** The server has no find_events yet: the section hides. */
    var missing by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)
    var retries by mutableIntStateOf(0)
}

/** The events the picks find, read again whenever the picks, the words or [refresh] change. */
@Composable
fun rememberFound(q: String = "", limit: Int = 50, refresh: Int = 0): FoundState {
    val context = LocalContext.current
    val state = remember { FoundState() }
    remember { FindStore.load(context); true }
    val filters = FindStore.filters
    LaunchedEffect(filters, q, limit, refresh, state.retries) {
        if (q.isNotEmpty()) delay(250)
        try {
            state.events = Repo.findEvents(filters, q, FindStore.place(context), limit)
            state.error = null
            state.missing = false
        } catch (e: Throwable) {
            e.rethrowIfCancelled()
            if (Leagues.isMissing(e)) { state.missing = true; state.events = null } else state.error = userMessage(e)
        }
    }
    return state
}

/** Format · Where · When · More as attribute cells, each opening its picker. A distance asks for location only when
 *  picked, and falls back to Everywhere when refused. */
@Composable
fun FindFilterRow() {
    val context = LocalContext.current
    val f = FindStore.filters
    val labels = Leagues.filterLabels(f)
    var pendingKm by remember { mutableStateOf<Int?>(null) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted ->
        val km = pendingKm
        pendingKm = null
        if (granted.values.any { it }) {
            FindStore.notice = null
            FindStore.set(context, FindStore.filters.copy(km = km))
        } else {
            FindStore.notice = "Location is off, so this shows events everywhere."
            FindStore.set(context, FindStore.filters.copy(km = null))
        }
    }
    val any = LimitedCards.ANY
    FilterRow(listOf(
        FilterCell("Format", labels.format, listOf(Triple(any, "Any format", null)) + Leagues.formatKeys.map { Triple(it.first, it.second, null) },
            current = null, picked = f.formats) { v ->
            FindStore.set(context, if (v == any) FindStore.filters.copy(formats = emptyList()) else FindStore.filters.toggle(v))
        },
        FilterCell("Where", labels.where, listOf(Triple("0", "Everywhere", null)) + Leagues.distances.map { Triple("$it", "$it km", null) },
            current = "${f.km ?: 0}") { v ->
            val km = v.toIntOrNull()?.takeIf { it > 0 }
            if (km != null && !LeaguesDemo.on && !PermissionsStep.locationAllowed(context)) {
                pendingKm = km
                ask.launch(PermissionsStep.locationPermissions)
            } else {
                FindStore.notice = null
                FindStore.set(context, FindStore.filters.copy(km = km))
            }
        },
        FilterCell("When", labels.at, Leagues.whens.map { Triple(it.first, it.second, null) }, current = f.at) { v ->
            FindStore.set(context, FindStore.filters.copy(at = v))
        },
        FilterCell("More", labels.more, listOf(Triple(any, "All", null), Triple("public", "Listed: Public", null), Triple("friends", "Listed: Friends", null),
            Triple("team", "Team events", null), Triple("league", "League events", null), Triple("open", "Seats left", null)),
            current = null, picked = f.more) { v -> FindStore.set(context, FindStore.filters.toggleMore(v)) },
    ), event = "find_filtered")
}

/** A found event: the league (or FRIENDS) small above the name, the name, one line of data, IN when you're in it. */
@Composable
fun FoundEventRow(e: FoundEvent, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().background(T1.surface).clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            e.label?.let {
                Text(it, color = T1.muted, fontFamily = T1.mono, fontSize = 9.sp, letterSpacing = 1.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Text(e.name, color = T1.text, fontFamily = T1.mono, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            // The whole line of data, on a second row when a narrow phone needs it (the distance comes last).
            Text(e.line(), color = T1.muted, fontFamily = T1.mono, fontSize = 11.sp, letterSpacing = 1.5.sp, lineHeight = 15.sp, maxLines = 2,
                overflow = TextOverflow.Ellipsis)
        }
        if (e.me != null) Label("In", Modifier.semantics { contentDescription = "You're in" }, color = T1.accent)
    }
}

/** Where a tapped found event goes: the event itself when you run or play it, else its page. */
fun foundEventRoute(e: FoundEvent): String {
    Telemetry.capture("found_event_opened", mapOf("format_key" to e.formatKey, "visibility" to e.visibility, "km" to (e.km ?: -1)))
    return if (e.me == "organizer" || e.me == "player") "event/${e.eventId}" else "eventpage/${e.eventId}?signup=false"
}

/** What an empty list says: nothing matches the picks (Clear filters), or nothing is listed at all (Create an event). */
@Composable
private fun NoEvents(filtered: Boolean, onCreate: (() -> Unit)?) {
    val context = LocalContext.current
    if (filtered) ListRow("No events match", onClick = { FindStore.set(context, FindFilters()) }) { Label("Clear filters", color = T1.text) }
    else if (onCreate != null) ListRow("No public events yet", onClick = onCreate) { Label("Create an event", color = T1.text) }
    else ListRow("No public events yet")
}

/**
 * The Events home's Find events: the filter row, the first five results and All N. Nothing at all when the server
 * has no find_events yet.
 */
fun LazyListScope.findEventsSection(found: FoundState, onOpen: (FoundEvent) -> Unit, onAll: () -> Unit, onCreate: () -> Unit) {
    if (found.missing) return
    item(key = "find-head") { Section("Find events") }
    item(key = "find-filters") { FindFilterRow() }
    FindStore.notice?.let { n -> item(key = "find-notice") { Notice(n) } }
    found.error?.let { e -> item(key = "find-error") { RetryRow(e) { found.retries++ } } }
    val events = found.events
    when {
        events == null -> if (found.error == null) item(key = "find-loading") { Notice("Loading…") }
        events.isEmpty() -> item(key = "find-none") { NoEvents(!FindStore.filters.isDefault, onCreate) }
        else -> {
            items(events.take(5), key = { "find-${it.eventId}" }) { e -> FoundEventRow(e) { onOpen(e) } }
            if (events.size > 5) item(key = "find-all") { ArrowRow("All ${events.size}", onClick = onAll) }
        }
    }
}

private val findTabs = listOf("events" to "Events", "leagues" to "Leagues", "boards" to "Boards")

/** Find: Events (the whole list, with a search box) | Leagues | Boards. */
@Composable
fun FindScreen(startTab: String?, foregrounds: Int, onBack: () -> Unit, go: (String) -> Unit) {
    var tab by rememberSaveable { mutableStateOf(startTab?.takeIf { t -> findTabs.any { it.first == t } } ?: "events") }
    // No `+` while the server has no leagues (or on stand-in data, where nothing can be made).
    var canMake by remember { mutableStateOf(false) }
    LaunchedEffect(tab) { Telemetry.capture("find_opened", mapOf("tab" to tab)) }
    T1Screen {
        Bar("Find", onBack = onBack) {
            if (tab == "leagues" && canMake && !LeaguesDemo.on) BarIcon(T1Icon.Plus, "New league") { go("leagues/new") }
        }
        T1Segmented(findTabs.map { it.second }, findTabs.indexOfFirst { it.first == tab }) { tab = findTabs[it].first }
        when (tab) {
            "leagues" -> FindLeagues(foregrounds, onLoaded = { canMake = true }) { go(leagueRoute(it, "find")) }
            "boards" -> FindBoards(foregrounds) { go("board/$it") }
            else -> FindEvents(foregrounds, onOpen = { go(foundEventRoute(it)) }, onCreate = { go("create") })
        }
    }
}

@Composable
private fun ColumnScope.FindEvents(foregrounds: Int, onOpen: (FoundEvent) -> Unit, onCreate: () -> Unit) {
    var q by rememberSaveable { mutableStateOf("") }
    val found = rememberFound(q.trim(), limit = 100, refresh = foregrounds)
    Box(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp)) {
        T1TextField(q, { q = it.take(60) }, placeholder = "Search events")
    }
    if (found.missing) {
        Notice("Finding events isn't available yet.")
        return
    }
    FindFilterRow()
    FindStore.notice?.let { Notice(it) }
    found.error?.let { e -> RetryRow(e) { found.retries++ } }
    val events = found.events
    LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
        when {
            events == null -> if (found.error == null) item { Notice("Loading…") }
            events.isEmpty() -> item { NoEvents(!FindStore.filters.isDefault || q.trim().length >= 2, if (q.isBlank()) onCreate else null) }
            else -> items(events, key = { it.eventId }) { e -> FoundEventRow(e) { onOpen(e) } }
        }
    }
}

/** A league's route by slug (or id), with where it was opened from for telemetry. */
fun leagueRoute(league: String, from: String, season: String? = null) =
    "league/${android.net.Uri.encode(league)}?from=$from" + (season?.let { "&season=$it" } ?: "")

@Composable
private fun LeagueCardRow(c: LeagueCard, onLeague: (String) -> Unit) {
    ListRow(c.name, c.line.ifEmpty { null }, onClick = { onLeague(c.slug.ifEmpty { c.id }) })
}

/** Find → Leagues: Yours, Following, then a search box (name or region). */
@Composable
private fun ColumnScope.FindLeagues(foregrounds: Int, onLoaded: () -> Unit, onLeague: (String) -> Unit) {
    var home by remember { mutableStateOf<LeaguesHome?>(null) }
    var query by rememberSaveable { mutableStateOf("") }
    var missing by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var retries by remember { mutableIntStateOf(0) }
    LaunchedEffect(query.trim(), foregrounds, retries) {
        if (query.isNotEmpty()) delay(250)
        try {
            home = Repo.leaguesHome(query.trim())
            error = null
            onLoaded()
        } catch (e: Throwable) {
            e.rethrowIfCancelled()
            if (Leagues.isMissing(e)) missing = true else error = userMessage(e)
        }
    }
    if (missing) {
        Notice("Leagues aren't available yet.")
        return
    }
    error?.let { e -> RetryRow(e) { retries++ } }
    val h = home
    LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
        if (h == null) {
            if (error == null) item { Notice("Loading…") }
            return@LazyColumn
        }
        if (h.mine.isNotEmpty()) {
            item(key = "h-mine") { Section("Yours") }
            items(h.mine, key = { "mine-${it.id}" }) { LeagueCardRow(it, onLeague) }
        }
        if (h.following.isNotEmpty()) {
            item(key = "h-following") { Section("Following") }
            items(h.following, key = { "following-${it.id}" }) { LeagueCardRow(it, onLeague) }
        }
        item(key = "search") {
            Box(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp)) {
                T1TextField(query, { query = it.take(60) }, placeholder = "Search leagues")
            }
        }
        items(h.found, key = { "found-${it.id}" }) { LeagueCardRow(it, onLeague) }
        if (query.trim().length >= 2 && h.found.isEmpty()) item(key = "none") { ListRow("No leagues match") }
    }
}

/** Find → Boards: every board with how many it lists and where you stand. */
@Composable
private fun ColumnScope.FindBoards(foregrounds: Int, onBoard: (String) -> Unit) {
    var boards by remember { mutableStateOf<FormatBoards?>(null) }
    var missing by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var retries by remember { mutableIntStateOf(0) }
    LaunchedEffect(foregrounds, retries) {
        try {
            boards = Repo.formatBoards()
            error = null
        } catch (e: Throwable) {
            e.rethrowIfCancelled()
            if (Leagues.isMissing(e)) missing = true else error = userMessage(e)
        }
    }
    if (missing) {
        Notice("Boards aren't available yet.")
        return
    }
    error?.let { e -> RetryRow(e) { retries++ } }
    val b = boards
    LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
        if (b == null) {
            if (error == null) item { Notice("Loading…") }
            return@LazyColumn
        }
        items(b.boards, key = { it.board }) { c: BoardCard ->
            ListRow(c.label.uppercase(), c.line, onClick = { onBoard(c.board) })
        }
    }
}

/** One board: your rating large with rank and record when you have one, then `rank · name · rating` with the record. */
@Composable
fun BoardScreen(board: String, foregrounds: Int, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    val openProfile = rememberOpenProfile("board")
    var page by remember { mutableStateOf<Leaderboard?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var missing by remember { mutableStateOf(false) }
    var retries by remember { mutableIntStateOf(0) }
    var more by remember { mutableStateOf(false) }
    val me = Repo.userId
    LaunchedEffect(board, foregrounds, retries) {
        try {
            page = Repo.formatLeaderboard(board)
            error = null
            Telemetry.capture("board_opened", mapOf("board" to board))
        } catch (e: Throwable) {
            e.rethrowIfCancelled()
            if (Leagues.isMissing(e)) missing = true else error = userMessage(e)
        }
    }
    fun loadMore() {
        val p = page ?: return
        if (more) return
        more = true
        scope.launch {
            runCatching { Repo.formatLeaderboard(board, after = p.rows.size) }
                .onSuccess { next -> page = p.copy(rows = p.rows + next.rows) }
                .onFailure { it.rethrowIfCancelled(); error = userMessage(it) }
            more = false
        }
    }
    val p = page
    T1Screen {
        Bar(p?.label ?: Leagues.label(board), onBack = onBack)
        if (missing) Notice("Boards aren't available yet.")
        error?.let { e -> RetryRow(e) { retries++ } }
        if (p == null) {
            if (error == null && !missing) Notice("Loading…")
            return@T1Screen
        }
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            p.me?.let { m ->
                item(key = "me") {
                    Column(Modifier.fillMaxWidth().background(T1.surface).padding(vertical = 24.dp), horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text("${m.rating}", color = T1.accent, fontFamily = T1.mono, fontSize = 48.sp, letterSpacing = 4.sp, textAlign = TextAlign.Center)
                        Label(listOf(m.rank?.let { "#$it" } ?: if (m.toGo > 0) "${m.toGo} to go" else "Not listed",
                            Leagues.recordText(m.wins, m.losses, m.draws), "${m.events} event${if (m.events == 1) "" else "s"}").joinToString(" · "))
                    }
                }
            }
            if (p.rows.isEmpty()) item(key = "none") { ListRow("Nobody listed yet") }
            items(p.rows, key = { "${it.rank}-${it.userId ?: it.name}" }) { r ->
                val mine = me != null && r.userId == me
                Row(Modifier.fillMaxWidth().heightIn(min = 50.dp).background(T1.surface)
                    .let { if (mine) it.border(1.dp, T1.accent) else it }
                    .let { m -> openProfile(r.userId)?.let { m.clickable(onClickLabel = "Profile", onClick = it) } ?: m }
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("${r.rank}", Modifier.width(30.dp), color = T1.muted, fontFamily = T1.mono, fontSize = 13.sp, maxLines = 1)
                    Avatar(r.name, r.userId)
                    Column(Modifier.weight(1f)) {
                        Text(r.name, color = T1.text, fontFamily = T1.mono, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Label(Leagues.recordText(r.wins, r.losses, r.draws))
                    }
                    Text("${r.rating}", Modifier.widthIn(min = 44.dp), color = T1.text, fontFamily = T1.mono, fontSize = 15.sp, textAlign = TextAlign.End)
                }
            }
            if (p.rows.size < p.count && p.rows.isNotEmpty() && p.rows.size % 100 == 0) {
                item(key = "more") { ListRow(if (more) "Loading…" else "Show more", onClick = { loadMore() }) }
            }
        }
    }
}

/**
 * Account → Sharing → Leaderboards: Listed | Hidden on every format board. Nothing until the server has boards.
 */
@Composable
fun LeaderboardsControl() {
    val scope = rememberCoroutineScope()
    var listed by remember { mutableStateOf<Boolean?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { runCatching { Repo.formatBoards().listed }.onSuccess { listed = it }.onFailure { it.rethrowIfCancelled() } }
    val on = listed ?: return
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        ListRow("Leaderboards", "Your rating on the format boards") { Label(if (on) "Listed" else "Hidden", color = if (on) T1.accent else T1.muted) }
        T1Segmented(listOf("Listed", "Hidden"), if (on) 0 else 1) { i ->
            val next = i == 0
            listed = next
            scope.launch {
                runCatching { Repo.setLeaderboardsListed(next) }.onSuccess { listed = it; error = null }
                    .onFailure { it.rethrowIfCancelled(); listed = !next; error = userMessage(it) }
            }
        }
        Notice("Your results in public events count either way.")
        error?.let { Notice(it, error = true) }
    }
}

/** Plain text with its `https://` links tappable (a description, a league's blurb); line breaks kept. */
@Composable
fun LinkedText(text: String, modifier: Modifier = Modifier) {
    val link = remember { Regex("https://[^\\s<>\"']+") }
    val styled = remember(text) {
        buildAnnotatedString {
            var at = 0
            for (m in link.findAll(text)) {
                // A sentence's own full stop or bracket isn't part of the address.
                val url = m.value.trimEnd('.', ',', ')', ';', ':', '!', '?')
                append(text.substring(at, m.range.first))
                withLink(LinkAnnotation.Url(url, TextLinkStyles(SpanStyle(color = T1.text, textDecoration = TextDecoration.Underline)))) { append(url) }
                at = m.range.first + url.length
            }
            append(text.substring(at))
        }
    }
    Text(styled, modifier.fillMaxWidth().background(T1.surface).padding(16.dp), color = T1.text, fontFamily = T1.mono, fontSize = 15.sp, lineHeight = 22.sp)
}
