package site.table1.events.ui.screens

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import site.table1.events.data.LeaguePage
import site.table1.events.data.LeaguePlayer
import site.table1.events.data.LeagueRow
import site.table1.events.data.Leagues
import site.table1.events.data.Repo
import site.table1.events.data.leaguePlayer
import site.table1.events.data.leagueStandings
import site.table1.events.data.leagueView
import site.table1.events.data.setLeagueFollow
import site.table1.events.insights.FilterCell
import site.table1.events.insights.FilterRow
import site.table1.events.library.ListGlyph
import site.table1.events.library.TuneGlyph
import site.table1.events.ui.components.Avatar
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Switch
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry
import site.table1.events.util.rethrowIfCancelled

/*
 * Leagues (contract/public-events-leagues-2026-11-13.md § 3 Clients): the league page (standings first, then its
 * events), a player's season, the whole table, details and Follow. The organizer's tools are in LeagueTools.kt.
 */

/** League pages already read this launch, by id and slug, so a pushed screen opens on what the page showed. */
object LeagueCache {
    private val pages = HashMap<String, LeaguePage>()
    fun of(league: String): LeaguePage? = pages[league.lowercase()]
    fun keep(p: LeaguePage) {
        pages[p.league.id.lowercase()] = p
        pages[p.league.slug.lowercase()] = p
    }
    fun forget(p: LeaguePage) {
        pages.remove(p.league.id.lowercase()); pages.remove(p.league.slug.lowercase())
    }
}

/** One standings row: rank · name · points, `Q` in accent for the qualified; your own row outlined in accent. */
@Composable
fun LeagueStandingRow(row: LeagueRow, mine: Boolean = false, onClick: (() -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().heightIn(min = 50.dp).background(T1.surface)
        .let { if (mine) it.border(1.dp, T1.accent) else it }
        .let { if (onClick != null) it.clickable(onClick = onClick) else it }
        .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("${row.rank}", Modifier.width(30.dp), color = T1.muted, fontFamily = T1.mono, fontSize = 13.sp, maxLines = 1)
        Text(row.name, Modifier.weight(1f), color = T1.text, fontFamily = T1.mono, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (row.qualified != null) Label("Q", Modifier.semantics { contentDescription = "Qualified" }, color = T1.accent)
        Text("${row.points}", Modifier.widthIn(min = 36.dp), color = T1.text, fontFamily = T1.mono, fontSize = 15.sp, textAlign = TextAlign.End)
    }
}

/** An attribute cell that only says something (the season's state beside its picker). */
@Composable
private fun Cell(text: String, modifier: Modifier = Modifier) {
    Box(modifier.height(50.dp).background(T1.surface).padding(horizontal = 6.dp), contentAlignment = Alignment.Center) {
        Text(text.uppercase(), color = T1.text, fontFamily = T1.mono, fontSize = 11.sp, letterSpacing = 1.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

private fun stateWord(state: String) = when (state) { "active" -> "Running"; "upcoming" -> "Upcoming"; else -> "Over" }

/** The league page. [league] is its id or slug. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun LeagueScreen(league: String, from: String, foregrounds: Int, onBack: () -> Unit, go: (String) -> Unit,
                 /** Opens on this season (a profile's achievement), else the league's current one. */
                 season: String? = null) {
    val scope = rememberCoroutineScope()
    // The page kept from before shows the league's current season: only when that's the one asked for.
    var page by remember { mutableStateOf(LeagueCache.of(league).takeIf { season == null || it?.season?.id == season }) }
    var seasonId by rememberSaveable { mutableStateOf(season) }
    var error by remember { mutableStateOf<String?>(null) }
    var missing by remember { mutableStateOf(false) }
    var retries by remember { mutableIntStateOf(0) }
    var followMenu by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { Telemetry.capture("league_opened", mapOf("from" to from)) }
    LaunchedEffect(league, seasonId, foregrounds, retries) {
        try {
            val p = Repo.leagueView(league, seasonId)
            page = p
            if (seasonId == null) LeagueCache.keep(p)
            error = null
        } catch (e: Throwable) {
            e.rethrowIfCancelled()
            if (Leagues.isMissing(e)) missing = true else error = userMessage(e)
        }
    }

    fun setFollow(on: Boolean, notify: Boolean?) {
        val p = page ?: return
        scope.launch {
            runCatching { Repo.setLeagueFollow(p.league.id, on, notify) }
                .onSuccess { me -> page = page?.let { it.copy(me = it.me.copy(following = me.following, notify = me.notify)) }?.also(LeagueCache::keep) }
                .onFailure { it.rethrowIfCancelled(); error = userMessage(it) }
        }
    }

    val p = page
    val id = p?.league?.id ?: league
    T1Screen {
        Bar(p?.league?.name ?: "League", onBack = onBack) {
            if (p != null) {
                if (p.me.role != null) {
                    BarGlyph("Organizer tools", { go("league/$id/tools") }) { TuneGlyph() }
                } else {
                    // A tap toggles; a long press has Notifications on or off (the details screen too).
                    Label(if (p.me.following) "Following" else "Follow",
                        Modifier.combinedClickable(onLongClickLabel = "Notifications", onLongClick = { if (p.me.following) followMenu = true else setFollow(true, null) },
                            onClick = { setFollow(!p.me.following, null) }).padding(vertical = 12.dp, horizontal = 4.dp),
                        color = if (p.me.following) T1.accent else T1.text)
                }
                BarGlyph("Details", { go("league/$id/details") }) { ListGlyph() }
            }
        }
        if (missing) Notice("Leagues aren't available yet.")
        error?.let { e -> RetryRow(e) { retries++ } }
        if (p == null) {
            if (error == null && !missing) Notice("Loading…")
            return@T1Screen
        }
        val season = p.season
        if (season != null) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                if (p.seasons.size > 1) {
                    Box(Modifier.weight(1f)) {
                        FilterRow(listOf(FilterCell("Season", season.name, p.seasons.map { Triple(it.id, it.name, Leagues.seasonLine(it.startsOn, it.endsOn, null)) },
                            current = season.id) { seasonId = it }), event = "league_season_picked")
                    }
                } else Cell(season.name, Modifier.weight(1f))
                Cell(stateWord(season.state), Modifier.weight(1f))
            }
        }
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (season == null) {
                item { ListRow("No season yet") }
                return@LazyColumn
            }
            fun open(r: LeagueRow) {
                Telemetry.capture("league_player_opened")
                go("league/player/${season.id}/${android.net.Uri.encode(r.key)}")
            }
            p.myRow?.let { mine -> item(key = "mine") { LeagueStandingRow(mine, mine = true) { open(mine) } } }
            if (p.standings.isEmpty()) item(key = "none") { ListRow("No results yet") }
            items(p.standings.take(10), key = { "row-${it.key}" }) { r -> LeagueStandingRow(r) { open(r) } }
            if (p.standingsCount > 10) item(key = "all") {
                ArrowRow("All ${p.standingsCount}") { go("league/standings/${season.id}?title=${android.net.Uri.encode("${p.league.name} · ${season.name}")}") }
            }
            if (p.events.isNotEmpty()) {
                item(key = "h-events") { Section("Events") }
                items(Leagues.ordered(p.events), key = { "event-${it.eventId}" }) { e ->
                    ListRow(e.name, Leagues.leagueEventLine(e), onClick = { go("eventpage/${e.eventId}?signup=false") }) {
                        Leagues.leagueEventMark(e.final, e.multiplier)?.let { Label(it, color = T1.text) }
                    }
                }
            }
        }
    }
    if (followMenu && p != null) {
        T1Menu(p.league.name, listOf(
            T1MenuItem(if (p.me.notify) "Turn notifications off" else "Turn notifications on") { setFollow(true, !p.me.notify) },
            T1MenuItem("Unfollow") { setFollow(false, null) },
        )) { followMenu = false }
    }
}

/** All N: the whole table, a hundred rows at a time. */
@Composable
fun LeagueStandingsScreen(seasonId: String, title: String?, onBack: () -> Unit, go: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    var rows by remember { mutableStateOf<List<LeagueRow>?>(null) }
    var done by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val me = Repo.userId

    fun load() {
        if (busy || done) return
        busy = true
        scope.launch {
            try {
                val next = Repo.leagueStandings(seasonId, after = rows?.size ?: 0)
                rows = rows.orEmpty() + next
                done = next.size < 100
                error = null
            } catch (e: Throwable) {
                e.rethrowIfCancelled()
                error = userMessage(e)
            } finally {
                busy = false
            }
        }
    }
    LaunchedEffect(seasonId) { load() }

    T1Screen {
        Bar(title ?: "Standings", onBack = onBack)
        error?.let { e -> RetryRow(e) { load() } }
        val list = rows
        if (list == null) {
            if (error == null) Notice("Loading…")
            return@T1Screen
        }
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (list.isEmpty()) item { ListRow("No results yet") }
            items(list, key = { it.key }) { r ->
                LeagueStandingRow(r, mine = me != null && r.userId == me) {
                    Telemetry.capture("league_player_opened")
                    go("league/player/$seasonId/${android.net.Uri.encode(r.key)}")
                }
            }
            if (!done && list.isNotEmpty()) item(key = "more") { ListRow(if (busy) "Loading…" else "Show more", onClick = { load() }) }
        }
    }
}

/** A player's season: their points large, then each event with place and points (`·` before a result outside best N). */
@Composable
fun LeaguePlayerScreen(seasonId: String, key: String, onBack: () -> Unit, go: (String) -> Unit) {
    var player by remember { mutableStateOf<LeaguePlayer?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var retries by remember { mutableIntStateOf(0) }
    LaunchedEffect(seasonId, key, retries) {
        try {
            player = Repo.leaguePlayer(seasonId, key)
            error = null
        } catch (e: Throwable) {
            e.rethrowIfCancelled()
            error = userMessage(e)
        }
    }
    val p = player
    T1Screen {
        Bar(p?.player?.name ?: "Player", onBack = onBack)
        error?.let { e -> RetryRow(e) { retries++ } }
        if (p == null) {
            if (error == null) Notice("Loading…")
            return@T1Screen
        }
        val row = p.player
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            item(key = "head") {
                Column(Modifier.fillMaxWidth().background(T1.surface).padding(vertical = 24.dp), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    // The avatar opens their profile when they have an account.
                    Avatar(row.name, row.userId, size = 60, opensFrom = "league")
                    Text("${row.points}", color = T1.accent, fontFamily = T1.mono, fontSize = 48.sp, letterSpacing = 4.sp)
                    Label(listOfNotNull("#${row.rank}", "${row.events} event${if (row.events == 1) "" else "s"}",
                        row.wins.takeIf { it > 0 }?.let { "$it win${if (it == 1) "" else "s"}" },
                        when (row.qualified) { "winner" -> "Qualified by winning"; "points" -> "Qualified on points"; else -> null }).joinToString(" · "))
                }
            }
            if (p.events.isEmpty()) item(key = "none") { ListRow("No results yet") }
            items(p.events, key = { it.eventId }) { e ->
                ListRow(e.name, Leagues.finishLine(e.place, e.players, e.formatLabel, Leagues.parseInstant(e.startsAt)?.let { Leagues.dateText(it) }),
                    onClick = { go("eventpage/${e.eventId}?signup=false") }) {
                    Text(if (e.counted) "${e.points}" else "· ${e.points}",
                        Modifier.semantics { contentDescription = if (e.counted) "${e.points} points" else "${e.points} points, not counted" },
                        color = if (e.counted) T1.text else T1.muted, fontFamily = T1.mono, fontSize = 15.sp)
                }
            }
        }
    }
}

/** A label on the left, its value on the right (lines kept). */
@Composable
internal fun InfoRow(label: String, value: String, onClick: (() -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().background(T1.surface).let { if (onClick != null) it.clickable(onClick = onClick) else it }
        .padding(horizontal = 16.dp, vertical = 14.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Label(label)
        Text(value, Modifier.weight(1f), color = T1.text, fontFamily = T1.mono, fontSize = 13.sp, lineHeight = 19.sp, textAlign = TextAlign.End)
    }
}

/** Behind the list icon: description, region, link, organizers, the points rule and qualification in words, and the
 *  follow's notifications. */
@Composable
fun LeagueDetailsScreen(league: String, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var page by remember { mutableStateOf(LeagueCache.of(league)) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(league) {
        runCatching { Repo.leagueView(league) }.onSuccess { page = it; LeagueCache.keep(it) }
            .onFailure { it.rethrowIfCancelled(); if (page == null) error = userMessage(it) }
    }
    fun setNotify(on: Boolean) {
        val p = page ?: return
        page = p.copy(me = p.me.copy(notify = on))
        scope.launch {
            runCatching { Repo.setLeagueFollow(p.league.id, true, on) }
                .onSuccess { me -> page = page?.let { it.copy(me = it.me.copy(following = me.following, notify = me.notify)) }?.also(LeagueCache::keep) }
                .onFailure { it.rethrowIfCancelled(); page = p; error = userMessage(it) }
        }
    }
    val p = page
    T1Screen {
        Bar(p?.league?.name ?: "League", onBack = onBack)
        error?.let { Notice(it, error = true) }
        if (p == null) {
            if (error == null) Notice("Loading…")
            return@T1Screen
        }
        val l = p.league
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            l.description?.takeIf { it.isNotBlank() }?.let { d -> item(key = "about") { LinkedText(d) } }
            l.region?.takeIf { it.isNotBlank() }?.let { r -> item(key = "region") { InfoRow("Region", r) } }
            l.link?.takeIf { it.startsWith("https://") }?.let { link ->
                item(key = "link") {
                    InfoRow("Link", link.removePrefix("https://")) {
                        runCatching { context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(link))) }
                    }
                }
            }
            if (l.organizers.isNotEmpty()) item(key = "organizers") { InfoRow(if (l.organizers.size == 1) "Organizer" else "Organizers", l.organizers.joinToString("\n")) }
            p.season?.let { s ->
                item(key = "season") { Section(s.name) }
                item(key = "dates") { InfoRow("Dates", "${Leagues.seasonDay(s.startsOn)} – ${Leagues.seasonDay(s.endsOn)}") }
                item(key = "points") { InfoRow("Points", Leagues.pointsWords(s.points).replace(" · ", "\n")) }
                s.bestN?.let { n -> item(key = "best") { InfoRow("Counts", "Best $n result${if (n == 1) "" else "s"}") } }
                Leagues.qualifyWords(s.qualify).takeIf { it.isNotEmpty() }?.let { q -> item(key = "qualify") { InfoRow("Qualify", q) } }
            }
            if (p.me.following) item(key = "notify") {
                ListRow("Notifications", onClick = { setNotify(!p.me.notify) }) { T1Switch(p.me.notify) { setNotify(it) } }
            }
        }
    }
}
