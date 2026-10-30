package site.table1.events.library

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import kotlinx.coroutines.launch
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.Ghost
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1AlertDialog
import site.table1.events.ui.components.T1Panel
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1TextField
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry

/* Moderation screens (contract/moderation-2026-10-18.md): Account → From Table 1 (what changed on your content, why,
   and one appeal per change) and, for moderators, Account → Review (held content, appeals, flagged accounts). Same as
   iOS ModerationViews. */

/** Account rows: a restriction notice, From Table 1 when there are notices, Review for moderators. */
fun LazyListScope.moderationAccountRows(s: ModerationState, onNotices: () -> Unit, onReview: () -> Unit) {
    ModerationWords.date(s.me?.restrictedUntil)?.let { d ->
        item { Notice("You can't send friend requests until $d. Your profile is hidden until then. Events aren't affected.", error = true) }
    }
    if (!s.notices.isNullOrEmpty()) item {
        val unseen = s.me?.unseen ?: 0
        ListRow("From Table 1", if (unseen > 0) "$unseen new · changes to your content" else "Changes to your content", onClick = onNotices) {
            if (unseen > 0) Label("$unseen new", color = T1.accent)
        }
    }
    if (s.me?.moderator == true) item {
        ListRow("Review", s.queue?.let { "${it.waiting} waiting · ${if (it.mode == "shadow") "shadow mode" else "enforcing"}" } ?: "Moderation queue",
            onClick = onReview)
    }
}

/** Loads what the Account rows need (call from the Account screen). */
suspend fun loadModerationRows() {
    ModerationStore.loadMe()
    ModerationStore.loadNotices()
    if (ModerationStore.state.value.me?.moderator == true) ModerationStore.loadQueue()
}

@Composable
fun NoticesScreen(onBack: () -> Unit) {
    val s by ModerationStore.state.collectAsState()
    var appealing by remember { mutableStateOf<ModerationNotice?>(null) }
    LaunchedEffect(Unit) {
        Telemetry.screen("moderation_notices")
        ModerationStore.loadNotices()
        Telemetry.capture("moderation_notice_opened")
        ModerationStore.markSeen()
    }
    T1Screen {
        Bar("From Table 1", "Changes to your content", onBack = onBack)
        Hairlines(Modifier.weight(1f)) {
            s.error?.let { item { Notice(it, error = true) } }
            item {
                Notice("Content other players see is checked automatically. When something breaks the rules, Table 1 makes the smallest " +
                    "change it can and tells you here. You can appeal each change once; a person reviews it.")
            }
            val n = s.notices
            when {
                n == null -> item { Notice("Loading…") }
                n.isEmpty() -> item { Notice("Nothing here.") }
                else -> items(n, key = { it.id }) { x ->
                    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                        ListRow(x.label, listOfNotNull(x.whatChanged, ModerationWords.date(x.at)).joinToString(" · ")) {
                            Label(x.status, color = if (x.appeal == "reverted") T1.accent else T1.muted)
                        }
                        Notice(x.reasonText + if (x.action == "unshare" && x.appeal != "reverted") " Rename it to share it again." else "")
                        if (x.canAppeal) Row { Ghost("Appeal") { appealing = x } }
                    }
                }
            }
        }
    }
    appealing?.let { x -> AppealPanel(x) { appealing = null } }
}

/** One appeal: an optional note, sent once. */
@Composable
private fun AppealPanel(notice: ModerationNotice, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    var note by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    T1Panel("Appeal", onClose) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Section(notice.label)
            error?.let { Notice(it, error = true) }
            Notice("Say why this should come back (optional). A person reads it. You can appeal once.")
            Box(Modifier.fillMaxWidth().background(T1.surface).padding(16.dp)) {
                T1TextField(note, { note = it.take(500) }, placeholder = "E.g. it's a card name")
            }
        }
        BigAction("Send appeal", busy = busy, accent = true) {
            busy = true
            scope.launch {
                runCatching { ModerationStore.appeal(notice.id, note) }.onSuccess { onClose() }.onFailure { error = it.message }
                busy = false
            }
        }
    }
}

/** Moderators: held content, appeals and flagged accounts. */
@Composable
fun ReviewScreen(onBack: () -> Unit) {
    val s by ModerationStore.state.collectAsState()
    val scope = rememberCoroutineScope()
    var photos by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var revealed by remember { mutableStateOf<Set<String>>(emptySet()) }
    var ask by remember { mutableStateOf<Pair<String, () -> Unit>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        Telemetry.screen("moderation_review")
        ModerationStore.loadQueue()
        val q = ModerationStore.state.value.queue ?: return@LaunchedEffect
        photos = ModerationStore.photoUrls(
            q.checks.mapNotNull { c -> c.bucket?.let { b -> c.path?.let { b to it } } } + q.appeals.mapNotNull { a -> a.bucket?.let { b -> a.path?.let { b to it } } })
    }
    fun run(work: suspend () -> Unit) = scope.launch { runCatching { work() }.onFailure { error = it.message } }
    @Composable
    fun Content(text: String?, path: String?, childSafety: Boolean) {
        when {
            text != null -> Text(text, Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp),
                color = T1.text, fontFamily = T1.mono, fontSize = 15.sp)
            path == null -> {}
            childSafety -> Notice("Photo hidden and quarantined (child safety). US law requires a report to the NCMEC CyberTipline " +
                "(report.cybertip.org). Don't download or share it.", error = true)
            photos[path] != null -> Box(Modifier.fillMaxWidth().heightIn(max = 220.dp).background(T1.surface).clickable { revealed = revealed + path },
                contentAlignment = Alignment.Center) {
                // Blurred until tapped.
                AsyncImage(photos[path], null, Modifier.fillMaxWidth().heightIn(max = 220.dp).let { if (path in revealed) it else it.blur(24.dp) },
                    contentScale = ContentScale.Fit)
                if (path !in revealed) Label("Tap to show", color = T1.text)
            }
            else -> Notice("Photo: $path")
        }
    }
    val q = s.queue
    T1Screen {
        Bar("Review", q?.let { "${it.waiting} waiting" }, onBack = onBack)
        Hairlines(Modifier.weight(1f)) {
            (error ?: s.error)?.let { item { Notice(it, error = true) } }
            if (q == null) { item { Notice("Loading…") }; return@Hairlines }
            item {
                T1Segmented(listOf("Shadow", "Enforce"), if (q.mode == "enforce") 1 else 0) { i ->
                    val m = if (i == 1) "enforce" else "shadow"
                    if (m == q.mode) return@T1Segmented
                    if (m == "enforce") ask = "Start enforcing? Blocks will change players' content at once and tell them. Check a week of shadow verdicts first." to
                        { run { ModerationStore.setMode(m) } }
                    else run { ModerationStore.setMode(m) }
                }
            }
            item {
                Notice(if (q.mode == "shadow") "Shadow mode: verdicts are recorded and held here; nothing changes for players except child-safety takedowns. Block applies your decision."
                       else "Enforcing: blocks change content at once and the owner is told. Allow undoes it.")
            }
            item { Section("Held content · ${q.checks.size}") }
            if (q.checks.isEmpty()) item { Notice("Nothing held.") }
            items(q.checks, key = { "c${it.id}" }) { c ->
                Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    ListRow(ModerationWords.subject(c.subjectKind) + " · " + ModerationWords.category(c.category),
                        listOfNotNull(c.owner?.displayName, if (c.strikes > 0) "${c.strikes} strike${if (c.strikes == 1) "" else "s"}" else null,
                            if (c.reports > 0) "${c.reports} report${if (c.reports == 1) "" else "s"}" else null,
                            if (c.source == "report") "reported" else null, if (c.enforced) "already applied" else null).joinToString(" · ")) {
                        Label(if (c.status == "block") "Block" else "Review", color = if (c.status == "block") T1.danger else T1.muted)
                    }
                    Content(c.text, c.path, c.category == "child_safety")
                    c.reason?.takeIf { it.isNotEmpty() }?.let { Notice("Why: $it") }
                    Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                        Ghost(if (c.enforced) "Allow · undo" else "Allow") { run { ModerationStore.resolve(c, "allow") } }
                        Ghost("Block", accent = true) { run { ModerationStore.resolve(c, "block") } }
                    }
                }
            }
            item { Section("Appeals · ${q.appeals.size}") }
            if (q.appeals.isEmpty()) item { Notice("No appeals.") }
            items(q.appeals, key = { "a${it.id}" }) { a ->
                Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    ListRow(a.label, listOfNotNull(a.owner?.displayName, ModerationWords.category(a.category)).joinToString(" · "))
                    Content(a.text, a.path, a.category == "child_safety")
                    a.note?.takeIf { it.isNotEmpty() }?.let { Notice("They say: $it") }
                    Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                        Ghost("Uphold") { run { ModerationStore.resolveAppeal(a, "uphold") } }
                        Ghost("Revert", accent = true) { run { ModerationStore.resolveAppeal(a, "revert") } }
                    }
                }
            }
            item { Section("Flagged accounts · ${q.flagged.size}") }
            if (q.flagged.isEmpty()) item { Notice("No accounts with 3+ strikes or reporters.") }
            items(q.flagged, key = { "f${it.userId}" }) { f ->
                Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    ListRow(f.displayName, "${f.strikes} strikes in 90 days · ${f.reporters} reporters in 14 days" +
                        (ModerationWords.date(f.restrictedUntil)?.let { " · restricted until $it" } ?: ""))
                    Row {
                        if (f.restrictedUntil != null) Ghost("Lift restriction") { run { ModerationStore.restrict(f.userId, 0, "") } }
                        else Ghost("Restrict 7 days", accent = true) {
                            ask = "Restrict ${f.displayName} for 7 days? They can't send friend requests and their profile is hidden. Events aren't affected. They're told." to
                                { run { ModerationStore.restrict(f.userId, 7, "Repeated violations or reports") } }
                        }
                    }
                }
            }
        }
    }
    ask?.let { (text, go) ->
        T1AlertDialog(text.substringBefore("? ") + "?", onDismiss = { ask = null },
            confirm = { TextButton(onClick = { ask = null; go() }) { Label("Confirm", color = T1.danger) } },
            dismiss = { TextButton(onClick = { ask = null }) { Label("Cancel", color = T1.text) } },
            body = { Text(text.substringAfter("? "), color = T1.muted, fontFamily = T1.mono, fontSize = 13.sp) })
    }
}
