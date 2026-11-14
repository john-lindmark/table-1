package site.table1.events.ui.screens

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import site.table1.events.data.Repo
import site.table1.events.data.SignupTeam
import site.table1.events.data.TeamBracketStage
import site.table1.events.data.TeamMate
import site.table1.events.data.TeamMine
import site.table1.events.data.TeamRules
import site.table1.events.data.teamCreate
import site.table1.events.data.teamJoin
import site.table1.events.data.teamMine
import site.table1.events.data.teamUpdate
import site.table1.events.insights.FilterCell
import site.table1.events.insights.FilterRow
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1AlertDialog
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1
import site.table1.events.util.rethrowIfCancelled

/*
 * Team Trios and teams that sign themselves up (contract/teams-finals-alerts-2026-11-13.md §§ 1–2 Clients): the Seats
 * row of a Team Trios event, the event page's Sign up a team / Join a team, Your team with the captain's menu, the
 * Teams list everyone sees, and the team playoff bracket.
 */

/** Team Trios' Seats: three cells `A · MODERN` `B · STANDARD` `C · PIONEER`, each a format dropdown. */
@Composable
fun TrioSeatsRow(seats: List<String>, onChange: (List<String>) -> Unit) {
    val now = seats.takeIf { it.size == 3 } ?: TeamRules.defaultSeats
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Section("Seats")
        FilterRow((1..3).map { slot ->
            FilterCell("Seat ${"ABC"[slot - 1]}", TeamRules.seatLabel(slot, now), TeamRules.seatFormats.map { Triple(it.first, it.second, null) }, current = now[slot - 1]) { pick ->
                onChange(now.toMutableList().also { it[slot - 1] = pick })
            }
        }, event = "trio_seat_picked")
    }
}

/** The team playoffs paired so far (team sealed and Team Trios with a top 4): `(1) Stack Overflow 2–1 (4) Top Decks`,
 *  the winner in the accent, then each seat's match under it. */
fun LazyListScope.teamBracketItems(bracket: List<TeamBracketStage>, seatFormats: List<String>? = null) {
    if (bracket.isEmpty()) return
    item(key = "team-bracket") { Section("Top 4") }
    for (stage in bracket) {
        item(key = "team-stage-${stage.stage}") { Label(stage.title, Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) }
        stage.matches.forEachIndexed { n, m ->
            item(key = "team-match-${stage.stage}-$n") {
                Row(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    val a = m.sides.getOrNull(0)
                    val b = m.sides.getOrNull(1)
                    TeamSide("(${a?.seed ?: "–"}) ${a?.name ?: "—"}", a?.teamId != null && a.teamId == m.winner, TextAlign.Start, Modifier.weight(1f))
                    Text(if (m.status == "pending") "v" else "${a?.matchWins ?: 0}–${b?.matchWins ?: 0}", color = T1.muted, fontFamily = T1.mono, fontSize = 14.sp)
                    TeamSide("(${b?.seed ?: "–"}) ${b?.name ?: "—"}", b?.teamId != null && b.teamId == m.winner, TextAlign.End, Modifier.weight(1f))
                }
            }
            items(m.matches, key = { "team-seat-${it.matchId}" }) { s ->
                val x = s.sides.getOrNull(0)
                val y = s.sides.getOrNull(1)
                Row(Modifier.fillMaxWidth().background(T1.bg).padding(start = 40.dp, end = 16.dp, top = 8.dp, bottom = 8.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Label(x?.slot?.let { TeamRules.seatLabel(it, seatFormats) } ?: "–", Modifier.width(if (seatFormats == null) 20.dp else 110.dp), color = T1.text)
                    TeamSide(x?.displayName ?: "—", x?.participantId != null && x.participantId == s.winner, TextAlign.Start, Modifier.weight(1f), small = true)
                    Text(if (s.status == "pending") "v" else "${x?.gameWins ?: 0}–${y?.gameWins ?: 0}", color = T1.muted, fontFamily = T1.mono, fontSize = 13.sp)
                    TeamSide(y?.displayName ?: "—", y?.participantId != null && y.participantId == s.winner, TextAlign.End, Modifier.weight(1f), small = true)
                }
            }
        }
    }
}

@Composable
private fun TeamSide(text: String, won: Boolean, align: TextAlign, modifier: Modifier, small: Boolean = false) {
    Text(text, modifier, color = if (won) T1.accent else T1.text, fontFamily = T1.mono, fontSize = if (small) 13.sp else 14.sp,
        fontWeight = if (won) FontWeight.Bold else FontWeight.Normal, maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = align)
}

/** team_mine for an event, read again on [reloads]; null while the server has no team sign-up (or it refused). */
@Composable
fun rememberTeamMine(eventId: String, reloads: Int): TeamMine? {
    var mine by remember(eventId) { mutableStateOf<TeamMine?>(null) }
    LaunchedEffect(eventId, reloads) {
        runCatching { Repo.teamMine(eventId) }.onSuccess { mine = it }.onFailure { it.rethrowIfCancelled() }
    }
    return mine
}

private fun copy(context: Context, label: String, text: String) {
    (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText(label, text))
}

/** A team's code with Paste: eight letters and digits, also read out of a pasted link. */
@Composable
private fun TeamCodeRow(code: String, busy: Boolean, onCode: (String) -> Unit, onJoin: () -> Unit) {
    val context = LocalContext.current
    val clipboard = remember { context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager }
    var pasteError by remember { mutableStateOf<String?>(null) }
    fun typed(text: String) {
        pasteError = null
        // A long paste (a message, the link) is read for its code; typing keeps to 8 letters and digits.
        onCode(if (text.length > 8) TeamRules.parseCode(text) ?: text.uppercase().filter { it in 'A'..'Z' || it in '0'..'9' }.take(8)
               else text.uppercase().filter { it in 'A'..'Z' || it in '0'..'9' })
    }
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Row(Modifier.fillMaxWidth().background(T1.bg), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            Box(Modifier.weight(1f).height(50.dp).background(T1.surface).padding(horizontal = 16.dp), contentAlignment = Alignment.CenterStart) {
                if (code.isEmpty()) Text("TEAM CODE", color = T1.muted, fontFamily = T1.mono, fontSize = 16.sp, letterSpacing = 4.sp)
                BasicTextField(code, ::typed, Modifier.fillMaxWidth().semantics { contentDescription = "Team code" }, singleLine = true,
                    textStyle = TextStyle(color = T1.text, fontFamily = T1.mono, fontSize = 16.sp, letterSpacing = 4.sp), cursorBrush = SolidColor(T1.accent),
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters, imeAction = ImeAction.Go),
                    keyboardActions = KeyboardActions(onGo = { if (code.length == 8) onJoin() }))
            }
            Box(Modifier.height(50.dp).background(T1.surface).clickable(onClickLabel = "Paste") {
                val text = clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString()
                val found = TeamRules.parseCode(text)
                if (found == null) pasteError = "What you copied has no team code in it." else { pasteError = null; onCode(found) }
            }.padding(horizontal = 16.dp), contentAlignment = Alignment.Center) { Label("Paste", color = T1.text) }
            Box(Modifier.height(50.dp).background(if (code.length == 8 && !busy) T1.accent else T1.disabled).clickable(enabled = code.length == 8 && !busy, onClick = onJoin)
                .padding(horizontal = 20.dp), contentAlignment = Alignment.Center) { Label(if (busy) "Joining…" else "Join", color = T1.ink) }
        }
        pasteError?.let { Notice(it, error = true) }
    }
}

/**
 * The event page's team part for a team event with sign-up on. On no team: Sign up a team (asks its name) and Join a
 * team (a code field with Paste; [startCode] arrives from `/s/<event>?team=<CODE>`), or "The event is full". On a
 * team: Your team (the name, members by seat with seat labels, `2/3`, the code with Copy and Share; the captain's menu
 * on a member and Rename team; Leave team for everyone). Then Teams, which everyone sees. Nothing while the server has
 * no team sign-up or the organizer builds the teams.
 */
@Composable
fun TeamSignupBlock(eventId: String, eventName: String, startCode: String? = null, reloads: Int = 0, canSignUp: Boolean = true,
                    onChanged: suspend () -> Unit, onLeft: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var local by remember { mutableIntStateOf(0) }
    val read = rememberTeamMine(eventId, reloads + local)
    // A change's own answer shows at once; the next read replaces it.
    var answered by remember { mutableStateOf<TeamMine?>(null) }
    LaunchedEffect(read) { answered = null }
    val t = answered ?: read ?: return
    if (!t.teamSignup) return
    val size = t.teamSize ?: 3
    val me = Repo.userId
    var code by remember { mutableStateOf(startCode.orEmpty()) }
    var how by remember { mutableStateOf(if (startCode.isNullOrEmpty()) "code" else "link") }
    var naming by remember { mutableStateOf<String?>(null) }
    var renaming by remember { mutableStateOf<String?>(null) }
    var menuFor by remember { mutableStateOf<TeamMate?>(null) }
    var confirmLeave by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    fun run(block: suspend () -> TeamMine?) {
        if (busy) return
        busy = true
        error = null
        scope.launch {
            try {
                block()?.let { answered = it }
                local++
                onChanged()
            } catch (e: Throwable) {
                e.rethrowIfCancelled()
                error = userMessage(e)
            } finally {
                busy = false
            }
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        val team = t.team
        if (team == null) {
            if (canSignUp && me != null) {
                if (t.canCreate) ListRow("Sign up a team", onClick = { naming = "" }) {
                    site.table1.events.library.IconGlyph(site.table1.events.library.T1Icon.Plus)
                } else ListRow("The event is full")
                Section("Join a team")
                TeamCodeRow(code, busy, { code = it; if (it.isEmpty()) how = "code" }) { run { Repo.teamJoin(eventId, code, how) } }
            }
        } else {
            val mates = team.mates
            Section("Your team")
            ListRow(team.name, onClick = if (t.captain) ({ renaming = team.name }) else null) {
                if (t.captain) Label("Rename", color = T1.text)
                Label(TeamRules.teamLine(team.count, team.complete, size), color = if (team.complete) T1.accent else T1.text)
            }
            mates.forEach { m ->
                val captain = m.userId != null && m.userId == team.captainId
                Row(Modifier.fillMaxWidth().background(T1.surface).let { x -> if (t.captain && !busy) x.clickable(onClickLabel = "Team") { menuFor = m } else x }
                    .padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Label(TeamRules.seatLabel(m.slot ?: 0, t.seatFormats), Modifier.width(if (t.seatFormats == null) 20.dp else 120.dp), color = T1.text)
                    Text(if (m.userId == me) "You · ${m.name}" else m.name, Modifier.weight(1f), color = T1.text, fontFamily = T1.mono, fontSize = 14.sp, maxLines = 1,
                        overflow = TextOverflow.Ellipsis)
                    if (captain) Label("Captain")
                }
            }
            team.joinCode?.takeIf { it.isNotEmpty() && !team.complete }?.let { c ->
                Row(Modifier.fillMaxWidth().background(T1.surface).padding(start = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f).padding(vertical = 10.dp)) {
                        Label("Team code")
                        Text(c, color = T1.accent, fontFamily = T1.mono, fontSize = 20.sp, letterSpacing = 4.sp, maxLines = 1)
                    }
                    Label("Copy", Modifier.clickable { copy(context, "Team code", c) }.padding(horizontal = 14.dp, vertical = 20.dp), color = T1.text)
                    Label("Share", Modifier.clickable {
                        val text = "Join ${team.name} for $eventName: ${TeamRules.teamLink(eventId, c)}"
                        context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), null))
                    }.padding(start = 14.dp, end = 16.dp, top = 20.dp, bottom = 20.dp), color = T1.text)
                }
            }
            ListRow("Leave team", onClick = { confirmLeave = true }) { Label("Leave", color = T1.danger) }
        }
        error?.let { Notice(it, error = true) }
        if (t.teams.isNotEmpty()) {
            Section("Teams · ${t.teams.size}")
            t.teams.forEach { x ->
                ListRow(x.name) { Label(TeamRules.teamLine(x.count, x.complete, size), color = if (x.complete) T1.accent else T1.muted) }
            }
        }
    }

    naming?.let { name ->
        T1AlertDialog("Team name", { naming = null },
            body = { T1TextField(name, { naming = it.take(40) }, placeholder = "Your team's name") },
            confirm = { BarAction("Sign up") { val n = name.trim(); naming = null; if (n.isNotEmpty()) run { Repo.teamCreate(eventId, n) } } },
            dismiss = { BarAction("Cancel") { naming = null } })
    }
    val team = t.team
    renaming?.let { name ->
        T1AlertDialog("Rename team", { renaming = null },
            body = { T1TextField(name, { renaming = it.take(40) }) },
            confirm = {
                BarAction("Save") {
                    val n = name.trim(); renaming = null
                    if (n.isNotEmpty() && team != null) run { Repo.teamUpdate(team.id, buildJsonObject { put("name", n) }, "name") }
                }
            },
            dismiss = { BarAction("Cancel") { renaming = null } })
    }
    menuFor?.let { m ->
        if (team == null) return@let
        val mates = team.mates
        fun order(by: Int): (() -> Unit) = {
            TeamRules.moved(mates, m.participantId, by)?.let { ids ->
                run { Repo.teamUpdate(team.id, buildJsonObject { put("order", buildJsonArray { ids.forEach { add(JsonPrimitive(it)) } }) }, "order") }
            }
        }
        val mine = m.userId == me
        T1Menu("${TeamRules.seatLabel(m.slot ?: 0, t.seatFormats)} · ${m.name}", listOfNotNull(
            T1MenuItem("Move up", enabled = TeamRules.moved(mates, m.participantId, -1) != null, onClick = order(-1)),
            T1MenuItem("Move down", enabled = TeamRules.moved(mates, m.participantId, 1) != null, onClick = order(1)),
            if (!mine && m.userId != null) T1MenuItem("Make captain") { run { Repo.teamUpdate(team.id, buildJsonObject { put("captain", m.userId) }, "captain") } } else null,
            if (!mine) T1MenuItem("Remove", danger = true) { run { Repo.teamUpdate(team.id, buildJsonObject { put("remove", m.participantId) }, "remove") } } else null,
        )) { menuFor = null }
    }
    if (confirmLeave && team != null) {
        T1AlertDialog("Leave ${team.name}?", { confirmLeave = false },
            body = { Text(TeamRules.leaveText(team, me), color = T1.text, fontFamily = T1.mono, fontSize = 13.sp) },
            confirm = {
                BarAction("Leave") {
                    confirmLeave = false
                    busy = true
                    scope.launch {
                        try {
                            Repo.leaveEvent(eventId, waitlist = false)
                            onLeft()
                        } catch (e: Throwable) {
                            e.rethrowIfCancelled()
                            error = userMessage(e)
                        } finally {
                            busy = false
                        }
                    }
                }
            },
            dismiss = { BarAction("Stay") { confirmLeave = false } })
    }
}

/** A team's `CODE · 2/3` for the organizer's Teams tab, by team id (organizers get every team in full). */
fun teamCodes(mine: TeamMine?): Map<String, String> {
    val t = mine?.takeIf { it.teamSignup } ?: return emptyMap()
    return t.teams.associate { x -> x.id to listOfNotNull(x.joinCode?.takeIf { it.isNotEmpty() }, TeamRules.teamLine(x.count, x.complete, t.teamSize ?: 3)).joinToString(" · ") }
}

/** A Team Trios event's seats for the event page's data line: `MODERN · STANDARD · PIONEER`. */
fun seatsLine(seats: List<String>?): String? = seats?.takeIf { it.isNotEmpty() }?.joinToString(" · ") { TeamRules.seatFormatLabel(it).uppercase() }
