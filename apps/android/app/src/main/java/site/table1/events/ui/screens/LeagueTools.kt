package site.table1.events.ui.screens

import android.app.DatePickerDialog
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.JsonNull
import site.table1.events.data.LeagueMember
import site.table1.events.data.LeaguePage
import site.table1.events.data.Leagues
import site.table1.events.data.PointsRule
import site.table1.events.data.QualifyRule
import site.table1.events.data.Repo
import site.table1.events.data.createLeague
import site.table1.events.data.leagueView
import site.table1.events.data.setLeagueMember
import site.table1.events.data.setLeagueSeason
import site.table1.events.data.updateLeague
import site.table1.events.library.FriendsStore
import site.table1.events.ui.components.Avatar
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1AlertDialog
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1Stepper
import site.table1.events.ui.components.T1Switch
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1
import site.table1.events.util.rethrowIfCancelled
import java.time.LocalDate

/*
 * A league's organizer tools (contract/public-events-leagues-2026-11-13.md § 3 Clients "Organizers"): make a league,
 * edit it, its seasons (the Places and Match wins presets or custom brackets, best N, who qualifies, Close season) and
 * who runs it. An event joins a season from its own Setup → Details (EventListing.kt).
 */

/** Name, region, description and link, for a new league or an edit. */
@Composable
private fun LeagueFields(name: String, onName: (String) -> Unit, region: String, onRegion: (String) -> Unit,
                         description: String, onDescription: (String) -> Unit, link: String, onLink: (String) -> Unit) {
    FormBlock("Name") { T1TextField(name, { onName(it.take(60)) }, placeholder = "The league's name") }
    FormBlock("Region") { T1TextField(region, { onRegion(it.take(80)) }, placeholder = "City or area (optional)") }
    DescriptionRow(description, onDescription)
    FormBlock("Link") {
        T1TextField(link, { onLink(it.take(300)) }, placeholder = "https:// (optional)",
            error = if (link.isBlank() || link.trim().startsWith("https://")) null else "The link starts with https://")
    }
}

/** The `+` on Find → Leagues. */
@Composable
fun LeagueNewScreen(onBack: () -> Unit, onCreated: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf("") }
    var region by remember { mutableStateOf("") }
    var description by remember { mutableStateOf("") }
    var link by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    T1Screen {
        Bar("New league", onBack = onBack)
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            LeagueFields(name, { name = it }, region, { region = it }, description, { description = it }, link, { link = it })
            error?.let { Notice(it, error = true) }
        }
        BigAction("Create league", accent = true, busy = busy,
            enabled = name.trim().length >= 2 && (link.isBlank() || link.trim().startsWith("https://"))) {
            busy = true
            scope.launch {
                try {
                    val l = Repo.createLeague(name, description, region, link)
                    onCreated(l.id)
                } catch (e: Throwable) {
                    e.rethrowIfCancelled()
                    error = userMessage(e)
                } finally {
                    busy = false
                }
            }
        }
    }
}

/** Loads the league for a tools screen, keeping what the page showed while it reads again. */
@Composable
private fun rememberLeague(league: String, reloads: Int, onError: (String) -> Unit): LeaguePage? {
    var page by remember { mutableStateOf(LeagueCache.of(league)) }
    LaunchedEffect(league, reloads) {
        runCatching { Repo.leagueView(league) }.onSuccess { page = it; LeagueCache.keep(it) }
            .onFailure { it.rethrowIfCancelled(); if (page == null) onError(userMessage(it)) }
    }
    return page
}

/** Behind the tune icon on a league you run: Edit league, Seasons, Organizers. */
@Composable
fun LeagueToolsScreen(league: String, foregrounds: Int, onBack: () -> Unit, go: (String) -> Unit) {
    var error by remember { mutableStateOf<String?>(null) }
    val p = rememberLeague(league, foregrounds) { error = it }
    T1Screen {
        Bar(p?.league?.name ?: "League", onBack = onBack)
        error?.let { Notice(it, error = true) }
        if (p == null) {
            if (error == null) Notice("Loading…")
            return@T1Screen
        }
        val id = p.league.id
        val dues = rememberLeagueMoney(p.season?.id, foregrounds)
        val payments = rememberPaymentsOn()
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            item(key = "edit") { ArrowRow("Edit league", p.league.region?.uppercase()) { go("league/$id/edit") } }
            item(key = "h-seasons") { Section("Seasons") }
            items(p.seasons, key = { it.id }) { s -> ArrowRow(s.name, Leagues.seasonLine(s.startsOn, s.endsOn, s.state)) { go("league/$id/season/${s.id}") } }
            item(key = "add") { ListRow("Add a season", onClick = { go("league/$id/season/new") }) { site.table1.events.library.IconGlyph(site.table1.events.library.T1Icon.Plus) } }
            // What hosts owe the league from each paid entry (contract/entry-fees-2026-11-13.md § 5).
            if (payments && dues != null && (dues.entryCutCents > 0 || !dues.events.isNullOrEmpty())) item(key = "dues") {
                ArrowRow("Dues", "${site.table1.events.data.Fees.money(dues.poolCents)} OWED · ${site.table1.events.data.Fees.money(dues.receivedCents ?: 0)} RECEIVED") { go("league/$id/dues") }
            }
            item(key = "h-organizers") { Section("Organizers") }
            item(key = "organizers") { ArrowRow(p.league.organizers.joinToString(", ").ifEmpty { "Organizers" }) { go("league/$id/organizers") } }
        }
    }
}

@Composable
fun LeagueEditScreen(league: String, onBack: () -> Unit, onArchived: () -> Unit) {
    val scope = rememberCoroutineScope()
    var error by remember { mutableStateOf<String?>(null) }
    val p = rememberLeague(league, 0) { error = it }
    var loaded by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    var region by remember { mutableStateOf("") }
    var description by remember { mutableStateOf("") }
    var link by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var confirmArchive by remember { mutableStateOf(false) }
    LaunchedEffect(p?.league?.id) {
        val l = p?.league ?: return@LaunchedEffect
        if (!loaded) { name = l.name; region = l.region.orEmpty(); description = l.description.orEmpty(); link = l.link.orEmpty(); loaded = true }
    }
    fun run(done: () -> Unit, block: suspend (String) -> Unit) {
        val id = p?.league?.id ?: return
        busy = true
        scope.launch {
            try {
                block(id)
                p.let(LeagueCache::forget)
                done()
            } catch (e: Throwable) {
                e.rethrowIfCancelled()
                error = userMessage(e)
            } finally {
                busy = false
            }
        }
    }
    T1Screen {
        Bar("Edit league", onBack = onBack)
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (!loaded) { if (error == null) Notice("Loading…") }
            else {
                LeagueFields(name, { name = it }, region, { region = it }, description, { description = it }, link, { link = it })
                if (p?.me?.role == "owner") ListRow("Archive league", onClick = { confirmArchive = true }) { Label("Archive", color = T1.danger) }
            }
            error?.let { Notice(it, error = true) }
        }
        BigAction("Save", busy = busy, enabled = loaded && name.trim().length >= 2 && (link.isBlank() || link.trim().startsWith("https://"))) {
            run(onBack) { id ->
                Repo.updateLeague(id, buildJsonObject { put("name", name.trim()); put("region", region.trim()); put("description", description.trim()); put("link", link.trim()) })
            }
        }
    }
    if (confirmArchive) T1AlertDialog("Archive ${p?.league?.name ?: "the league"}?", { confirmArchive = false },
        confirm = { BarAction("Archive") { confirmArchive = false; run(onArchived) { id -> Repo.updateLeague(id, buildJsonObject { put("archived", true) }) } } },
        dismiss = { BarAction("Keep") { confirmArchive = false } },
        body = { Text("Its page closes for everyone. Results stay on players' records.", color = T1.text, fontFamily = T1.mono, fontSize = 13.sp) })
}

private val presets = listOf("places" to "Places", "match_wins" to "Match wins", "custom" to "Custom")

/** A season: name, dates, the points rule (Places | Match wins | Custom brackets), best N, who qualifies, Close season.
 *  [seasonId] null = a new one. */
@Composable
fun LeagueSeasonScreen(league: String, seasonId: String?, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var error by remember { mutableStateOf<String?>(null) }
    var page by remember { mutableStateOf<LeaguePage?>(null) }
    var loaded by remember { mutableStateOf(seasonId == null) }
    val year = remember { LocalDate.now().year }
    var name by remember { mutableStateOf(if (seasonId == null) "$year" else "") }
    var startsOn by remember { mutableStateOf(LocalDate.of(year, 1, 1)) }
    var endsOn by remember { mutableStateOf(LocalDate.of(year, 12, 31)) }
    var preset by remember { mutableStateOf("places") }
    var rule by remember { mutableStateOf(Leagues.places) }
    var bestN by remember { mutableStateOf<Int?>(null) }
    var qualify by remember { mutableStateOf(QualifyRule(winners = true, passDown = true, top = 10)) }
    var closed by remember { mutableStateOf(false) }
    /** What each paid entry owes the league, as typed (blank = none). */
    var cut by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var confirmClose by remember { mutableStateOf(false) }

    LaunchedEffect(league, seasonId) {
        // The season as the league page gives it (its rule comes with the season it shows).
        runCatching { Repo.leagueView(league, seasonId) }.onSuccess { p ->
            page = p
            val s = p.season?.takeIf { it.id == seasonId } ?: return@onSuccess
            name = s.name
            runCatching { startsOn = LocalDate.parse(s.startsOn.take(10)); endsOn = LocalDate.parse(s.endsOn.take(10)) }
            rule = s.points; preset = Leagues.preset(s.points); bestN = s.bestN; qualify = s.qualify; closed = s.closed
            cut = site.table1.events.data.Fees.field(s.entryCutCents)
            loaded = true
        }.onFailure { it.rethrowIfCancelled(); error = userMessage(it) }
    }

    fun pick(current: LocalDate, set: (LocalDate) -> Unit) {
        // The system date picker (the one platform control Android keeps besides alerts).
        DatePickerDialog(context, { _, y, m, d -> set(LocalDate.of(y, m + 1, d)) }, current.year, current.monthValue - 1, current.dayOfMonth).show()
    }

    fun save(close: Boolean = false) {
        val id = page?.league?.id ?: return
        busy = true
        scope.launch {
            try {
                Repo.setLeagueSeason(id, seasonId, buildJsonObject {
                    put("name", name.trim()); put("starts_on", startsOn.toString()); put("ends_on", endsOn.toString())
                    put("points", Leagues.pointsJson(rule))
                    if (bestN == null) put("best_n", JsonNull) else put("best_n", bestN)
                    put("qualify", Leagues.qualifyJson(qualify))
                    put("entry_cut_cents", if (cut.isBlank()) 0 else site.table1.events.data.Fees.cents(cut) ?: 0)
                    if (close) put("closed", true)
                }, preset = Leagues.preset(rule))
                page?.let(LeagueCache::forget)
                onBack()
            } catch (e: Throwable) {
                e.rethrowIfCancelled()
                error = userMessage(e)
            } finally {
                busy = false
            }
        }
    }

    T1Screen {
        Bar(if (seasonId == null) "New season" else name.ifEmpty { "Season" }, onBack = onBack)
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            error?.let { Notice(it, error = true) }
            if (!loaded) {
                if (error == null) Notice("Loading…")
                return@Column
            }
            FormBlock("Name") { T1TextField(name, { name = it.take(40) }, placeholder = "2026, Spring, Season 3") }
            ListRow("Starts", Leagues.seasonDay(startsOn.toString()), onClick = { pick(startsOn) { startsOn = it; if (endsOn < it) endsOn = it } })
            ListRow("Ends", Leagues.seasonDay(endsOn.toString()), onClick = { pick(endsOn) { endsOn = it; if (startsOn > it) startsOn = it } })
            FormBlock("Points") {
                T1Segmented(presets.map { it.second }, presets.indexOfFirst { it.first == preset }) { i ->
                    preset = presets[i].first
                    when (preset) { "places" -> rule = Leagues.places; "match_wins" -> rule = Leagues.matchWins }
                }
            }
            InfoRow("Earns", Leagues.pointsWords(rule).replace(" · ", "\n").ifEmpty { "No points yet" })
            if (preset == "custom") {
                rule.places.forEachIndexed { i, b ->
                    val floor = (rule.places.getOrNull(i - 1)?.through ?: 0) + 1
                    val ceiling = (rule.places.getOrNull(i + 1)?.through ?: 513) - 1
                    FormBlock(if (b.through == floor) Leagues.ordinal(b.through) else "Through ${Leagues.ordinal(b.through)}") {
                        T1Stepper("Through place", b.through, floor..ceiling, Modifier.fillMaxWidth()) { v ->
                            rule = rule.copy(places = rule.places.toMutableList().also { it[i] = b.copy(through = v) })
                        }
                        T1Stepper("Points", b.points, 0..1000, Modifier.fillMaxWidth()) { v ->
                            rule = rule.copy(places = rule.places.toMutableList().also { it[i] = b.copy(points = v) })
                        }
                    }
                }
                if (rule.places.size < 16) ListRow("Add a bracket", onClick = {
                    val last = rule.places.lastOrNull()
                    rule = rule.copy(places = rule.places + PointsRule.Bracket(if (last == null) 1 else (last.through * 2).coerceAtMost(512), last?.points?.div(2) ?: 10))
                }) { site.table1.events.library.IconGlyph(site.table1.events.library.T1Icon.Plus) }
                if (rule.places.isNotEmpty()) ListRow("Remove the last bracket", onClick = { rule = rule.copy(places = rule.places.dropLast(1)) })
                FormBlock("To play") { T1Stepper("Points", rule.participation, 0..100, Modifier.fillMaxWidth()) { rule = rule.copy(participation = it) } }
                FormBlock("A match win") { T1Stepper("Points", rule.matchWin, 0..20, Modifier.fillMaxWidth()) { rule = rule.copy(matchWin = it) } }
            }
            ListRow("Best results only", bestN?.let { "Best $it" } ?: "Every result", onClick = { bestN = if (bestN == null) 6 else null }) {
                T1Switch(bestN != null) { bestN = if (it) bestN ?: 6 else null }
            }
            bestN?.let { n -> FormBlock("Best") { T1Stepper("Results", n, 1..50, Modifier.fillMaxWidth()) { bestN = it } } }
            Section("Qualify")
            ListRow("Event winners", onClick = { qualify = qualify.copy(winners = !qualify.winners) }) { T1Switch(qualify.winners) { qualify = qualify.copy(winners = it) } }
            FormBlock("Top on points") { T1Stepper("Players", qualify.top, 0..64, Modifier.fillMaxWidth()) { qualify = qualify.copy(top = it) } }
            CutPerEntryField(cut) { cut = it }
            if (seasonId != null && !closed) ListRow("Close season", onClick = { confirmClose = true }) { Label("Close", color = T1.danger) }
            if (closed) ListRow("Closed")
        }
        BigAction("Save", busy = busy, enabled = loaded && name.isNotBlank() && endsOn >= startsOn && Leagues.pointsWords(rule).isNotEmpty() &&
            (cut.isBlank() || (site.table1.events.data.Fees.cents(cut) ?: -1) in 0..100000)) { save() }
    }
    if (confirmClose) T1AlertDialog("Close $name?", { confirmClose = false },
        confirm = { BarAction("Close season") { confirmClose = false; save(close = true) } },
        dismiss = { BarAction("Keep open") { confirmClose = false } },
        body = { Text("Standings are final, everyone who qualified on points is told, and no more events can join it.", color = T1.text, fontFamily = T1.mono, fontSize = 13.sp) })
}

/**
 * Who runs the league. Its own organizers get the members with their roles; the owner's rows open a menu (Make owner
 * or Make organizer, Remove) and the owner can add a friend. Other organizers read the list.
 */
@Composable
fun LeagueOrganizersScreen(league: String, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    var error by remember { mutableStateOf<String?>(null) }
    var reloads by remember { mutableIntStateOf(0) }
    val p = rememberLeague(league, reloads) { error = it }
    val friends by FriendsStore.state.collectAsState()
    var busy by remember { mutableStateOf(false) }
    var menuFor by remember { mutableStateOf<LeagueMember?>(null) }
    LaunchedEffect(Unit) { runCatching { FriendsStore.load() }.onFailure { it.rethrowIfCancelled() } }

    /** One change, then the league read again; a refusal ("A league keeps an owner…") shows as the error text. */
    fun set(userId: String, role: String?) {
        val id = p?.league?.id ?: return
        if (busy) return
        busy = true
        scope.launch {
            runCatching { Repo.setLeagueMember(id, userId, role) }
                .onSuccess { error = null; reloads++ }
                .onFailure { it.rethrowIfCancelled(); error = userMessage(it) }
            busy = false
        }
    }

    T1Screen {
        Bar("Organizers", onBack = onBack)
        error?.let { Notice(it, error = true) }
        if (p == null) {
            if (error == null) Notice("Loading…")
            return@T1Screen
        }
        val owner = p.me.role == "owner"
        val members = p.members
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (members == null) {
                // A server before `members` (or a reader who doesn't run the league): the names alone.
                items(p.league.organizers.withIndex().toList(), key = { "o-${it.index}" }) { (_, n) -> ListRow(n) }
            } else {
                items(members, key = { "m-${it.userId}" }) { m ->
                    ListRow(m.name, avatar = { Avatar(m.name, m.userId) },
                        onClick = if (Leagues.memberActions(p.me.role, m).isNotEmpty()) ({ menuFor = m }) else null) {
                        Label(if (m.role == "owner") "Owner" else "Organizer", color = if (m.role == "owner") T1.text else T1.muted)
                    }
                }
            }
            if (owner) {
                val taken = members?.map { it.userId }?.toSet().orEmpty()
                val candidates = friends.list?.friends.orEmpty().filter { it.userId !in taken && (members != null || it.displayName !in p.league.organizers) }
                item(key = "h-add") { Section("Add from friends") }
                if (candidates.isEmpty()) item(key = "none") { ListRow("No friends to add") }
                items(candidates, key = { "f-${it.userId}" }) { f ->
                    ListRow(f.displayName, avatar = { Avatar(f.displayName, f.userId) }, onClick = { set(f.userId, "organizer") }) { Label("Add", color = T1.text) }
                }
            }
        }
    }
    menuFor?.let { m ->
        T1Menu(m.name, Leagues.memberActions(p?.me?.role, m).map { (label, role) ->
            T1MenuItem(label, danger = role == null) { set(m.userId, role) }
        }) { menuFor = null }
    }
}
