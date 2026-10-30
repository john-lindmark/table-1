package site.table1.events.library

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.selection.SelectionContainer
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
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import site.table1.events.T1App
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BarAction
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
import site.table1.events.util.rethrowIfCancelled
import java.util.UUID

/* Bugs (contract/bug-pipeline-2026-10-18.md § Inbox): for the bug watchers only (John). A bug push opens the bug, a
   build push opens what's waiting to ship. The register lives on the server; this shows it and sends the watcher's
   changes back (severity, status, notes the fix runner reads, a platform shipped). Everyone else is refused by the
   server and never sees the Account row. Same as iOS Bugs.swift / BugsViews.swift. */

@Serializable
data class BugsMe(val watcher: Boolean = false, @SerialName("needs_you") val needsYou: Int? = null, val open: Int? = null,
                  @SerialName("to_ship") val toShip: Int? = null)

@Serializable
data class BugRow(
    val id: Long, val severity: String? = null, val status: String, val platform: String, val title: String, val events: Int = 0,
    val users: Int = 0, val regressed: Boolean = false, @SerialName("last_seen") val lastSeen: String? = null,
    @SerialName("fixed_at") val fixedAt: String? = null, @SerialName("fix_platforms") val fixPlatforms: List<String> = emptyList(),
    val shipped: List<String> = emptyList(), @SerialName("last_note") val lastNote: String? = null, @SerialName("my_notes") val myNotes: Int = 0,
) {
    val waitingToShip get() = if (status == "fixed") fixPlatforms.filter { it !in shipped } else emptyList()
}

@Serializable
data class BugPending(val platform: String, val fixes: Int = 0, val worst: String = "S4", val oldest: String? = null,
                      val ids: List<Long> = emptyList(), val due: Boolean = false)

@Serializable
data class BugsInbox(val bugs: List<BugRow> = emptyList(), val pending: List<BugPending> = emptyList()) {
    val needsYou get() = bugs.filter { it.status == "needs_john" }
    val open get() = bugs.filter { it.status in setOf("new", "open", "fixing") }
    val closed get() = bugs.filter { it.status in setOf("wontfix", "duplicate") || (it.status == "fixed" && it.waitingToShip.isEmpty()) }
    fun toShip(platform: String) = pending.firstOrNull { it.platform == platform }?.ids.orEmpty().mapNotNull { id -> bugs.firstOrNull { it.id == id } }
}

@Serializable
data class BugLogEntry(val kind: String, val body: String, val at: String)

@Serializable
data class BugSample(
    val kind: String? = null, val exception: List<Exception>? = null, val breadcrumbs: List<Crumb>? = null, val tags: Map<String, String>? = null,
    val issue: Issue? = null, val link: String? = null, val job: String? = null, val message: String? = null, val status: Int? = null,
    @SerialName("timed_out") val timedOut: Boolean? = null,
) {
    @Serializable data class Frame(val file: String? = null, val fn: String? = null, val module: String? = null, val line: Int? = null)
    @Serializable data class Exception(val type: String? = null, val value: String? = null, val frames: List<Frame>? = null)
    @Serializable data class Crumb(val category: String? = null, val message: String? = null, val url: String? = null, val status: Int? = null)
    @Serializable data class Issue(val type: String? = null, val value: String? = null, val filename: String? = null, val function: String? = null)
}

@Serializable
data class BugDetail(
    val id: Long, val severity: String? = null, @SerialName("severity_reason") val severityReason: String? = null,
    @SerialName("severity_by") val severityBy: String? = null, val status: String, val platform: String, val title: String,
    val culprit: String? = null, val link: String? = null, val releases: List<String> = emptyList(), val events: Int = 0, val users: Int = 0,
    val spikes: Int = 0, @SerialName("first_seen") val firstSeen: String? = null, @SerialName("last_seen") val lastSeen: String? = null,
    val regressed: Boolean = false, val attempts: Int = 0, @SerialName("claimed_at") val claimedAt: String? = null, val notes: String? = null,
    @SerialName("fix_commit") val fixCommit: String? = null, @SerialName("fix_summary") val fixSummary: String? = null,
    @SerialName("fix_test") val fixTest: String? = null, @SerialName("fix_platforms") val fixPlatforms: List<String> = emptyList(),
    @SerialName("fixed_at") val fixedAt: String? = null, val shipped: List<String> = emptyList(),
    @SerialName("duplicate_of") val duplicateOf: Long? = null, @SerialName("duplicate_title") val duplicateTitle: String? = null,
    val detail: BugSample? = null, val log: List<BugLogEntry> = emptyList(),
) {
    val sentryUrl get() = link ?: detail?.link
}

object BugWords {
    fun platform(p: String) = mapOf("ios" to "iOS", "android" to "Android", "web" to "Web", "server" to "Server")[p] ?: "App"

    fun status(s: String) = when (s) {
        "new" -> "Waiting for a severity"; "open" -> "Waiting for the fix runner"; "fixing" -> "Fix runner on it"; "fixed" -> "Fixed"
        "needs_john" -> "Needs you"; "wontfix" -> "Won't fix"; "duplicate" -> "Duplicate"; else -> s
    }

    /** "Oct 22, 14:05". */
    fun `when`(iso: String?): String? = iso?.let {
        runCatching { java.time.OffsetDateTime.parse(it).atZoneSameInstant(java.time.ZoneId.systemDefault()) }.getOrNull()
            ?.format(java.time.format.DateTimeFormatter.ofPattern("MMM d, HH:mm"))
    }

    /** One line under a bug's title: severity, platform, reach, and what it's waiting on. */
    fun line(b: BugRow) = buildList {
        add(b.severity ?: "Untriaged"); add(platform(b.platform))
        if (b.users > 0) add("${b.users} ${if (b.users == 1) "person" else "people"}")
        add("${b.events}×")
        if (b.regressed) add("came back")
        if (b.status == "fixing") add("fixing")
        if (b.waitingToShip.isNotEmpty()) add("ship " + b.waitingToShip.joinToString(" + ") { platform(it) })
    }.joinToString(" · ")

    /** The server's refusals in plain words. */
    fun words(e: Throwable): String {
        val t = e.message ?: e.toString()
        return when {
            "42501" in t || "Bug watchers only" in t -> "Bugs are only for the people who get bug alerts."
            "PT409" in t -> "The fix runner is working on this one. Try again when it's done."
            "Pick a severity" in t -> "Pick a severity first."
            else -> t
        }
    }
}

data class BugsState(val me: BugsMe? = null, val inbox: BugsInbox? = null, val details: Map<Long, BugDetail> = emptyMap(),
                     val showClosed: Boolean = false, val error: String? = null)

object BugsStore {
    private val _state = MutableStateFlow(BugsState())
    val state: StateFlow<BugsState> = _state.asStateFlow()
    private val rpc get() = T1App.supabase.postgrest

    fun stop() { _state.value = BugsState() }
    fun setError(e: String?) = _state.update { it.copy(error = e) }

    suspend fun loadMe() {
        runCatching { rpc.rpc("bugs_me").decodeAs<BugsMe>() }.onSuccess { m -> _state.update { it.copy(me = m) } }.onFailure { it.rethrowIfCancelled() }
    }

    suspend fun loadInbox() {
        runCatching { rpc.rpc("bugs_inbox", buildJsonObject { put("p_closed", _state.value.showClosed) }).decodeAs<BugsInbox>() }
            .onSuccess { i -> _state.update { it.copy(inbox = i, error = null) } }
            .onFailure { e -> e.rethrowIfCancelled(); _state.update { it.copy(error = BugWords.words(e)) } }
    }

    suspend fun setShowClosed(on: Boolean) { _state.update { it.copy(showClosed = on) }; loadInbox() }

    suspend fun loadDetail(id: Long) {
        runCatching { rpc.rpc("bugs_detail", buildJsonObject { put("p_id", id) }).decodeAs<BugDetail>() }
            .onSuccess { d -> _state.update { it.copy(details = it.details + (id to d), error = null) } }
            .onFailure { e -> e.rethrowIfCancelled(); _state.update { it.copy(error = BugWords.words(e)) } }
    }

    /** Severity, status and/or a note in one call; [key] makes a retried send land once. */
    suspend fun update(id: Long, severity: String? = null, status: String? = null, note: String? = null, key: String = UUID.randomUUID().toString()) {
        val trimmed = note?.trim()?.take(2000).orEmpty()
        val d = rpc.rpc("bugs_update", buildJsonObject {
            put("p_id", id)
            put("p", buildJsonObject {
                put("key", key)
                severity?.let { put("severity", it) }
                status?.let { put("status", it) }
                if (trimmed.isNotEmpty()) put("note", trimmed)
            })
        }).decodeAs<BugDetail>()
        _state.update { it.copy(details = it.details + (id to d)) }
        Telemetry.capture("bug_updated", mapOf("severity" to (severity != null), "status" to (status ?: ""), "note" to trimmed.isNotEmpty()))
        loadInbox(); loadMe()
    }

    @Serializable private data class Shipped(val shipped: List<Long> = emptyList())

    /** A build or deploy went out: every pending fix on that platform counts as shipped. */
    suspend fun ship(platform: String): Int {
        val r = rpc.rpc("bugs_ship", buildJsonObject { put("p_platform", platform) }).decodeAs<Shipped>()
        Telemetry.capture("bugs_shipped", mapOf("platform" to platform, "fixes" to r.shipped.size))
        _state.update { it.copy(details = emptyMap()) }
        loadInbox(); loadMe()
        return r.shipped.size
    }
}

/** Account row, watchers only. */
fun LazyListScope.bugsAccountRow(s: BugsState, onOpen: () -> Unit) {
    val me = s.me ?: return
    if (!me.watcher) return
    item {
        ListRow("Bugs", listOfNotNull("${me.open ?: 0} open", if ((me.toShip ?: 0) > 0) "build due" else null).joinToString(" · "), onClick = onOpen) {
            if ((me.needsYou ?: 0) > 0) Label("${me.needsYou} need you", color = T1.accent)
        }
    }
}

@Composable
fun BugsScreen(onBack: () -> Unit, onBug: (Long) -> Unit) {
    val s by BugsStore.state.collectAsState()
    val scope = rememberCoroutineScope()
    var shipping by remember { mutableStateOf<BugPending?>(null) }
    LaunchedEffect(Unit) { Telemetry.screen("bugs"); BugsStore.loadInbox() }
    val inbox = s.inbox
    T1Screen {
        Bar("Bugs", inbox?.let { "${it.needsYou.size} need you · ${it.open.size} open" }, onBack = onBack)
        Hairlines(Modifier.weight(1f)) {
            s.error?.let { item { Notice(it, error = true) } }
            if (inbox == null) { item { Notice("Loading…") }; return@Hairlines }
            fun rows(list: List<BugRow>, detail: (BugRow) -> String = BugWords::line) = items(list, key = { "b${it.id}${list.hashCode()}" }) { b ->
                ListRow(b.title, detail(b), onClick = { onBug(b.id) }) { Label(b.severity ?: "–", color = if (b.severity == "S1") T1.danger else T1.text) }
            }
            if (inbox.pending.isNotEmpty()) {
                item { Section("To ship") }
                for (p in inbox.pending) {
                    val name = BugWords.platform(p.platform)
                    item(key = "p${p.platform}") {
                        ListRow(if (p.platform == "server") "Server deploy" else "$name build",
                            "${p.fixes} fix${if (p.fixes == 1) "" else "es"} · worst ${p.worst}" + if (p.due) " · due now" else " · can wait") {
                            if (p.due) Label("Due", color = T1.accent)
                        }
                    }
                    rows(inbox.toShip(p.platform)) { b -> "${b.severity ?: "–"} · fixed ${BugWords.`when`(b.fixedAt) ?: ""}" }
                    item(key = "ship${p.platform}") { Row { Ghost(if (p.platform == "server") "Mark deployed" else "Mark $name shipped") { shipping = p } } }
                }
            }
            item { Section("Needs you · ${inbox.needsYou.size}") }
            if (inbox.needsYou.isEmpty()) item { Notice("The fix runner has no questions.") }
            rows(inbox.needsYou) { b -> b.lastNote ?: BugWords.line(b) }
            item { Section("Open · ${inbox.open.size}") }
            if (inbox.open.isEmpty()) item { Notice("Nothing open.") }
            rows(inbox.open)
            if (s.showClosed) {
                item { Section("Closed in the last 30 days · ${inbox.closed.size}") }
                if (inbox.closed.isEmpty()) item { Notice("Nothing closed lately.") }
                rows(inbox.closed)
            }
            item { Row { Ghost(if (s.showClosed) "Hide closed" else "Show closed") { scope.launch { BugsStore.setShowClosed(!s.showClosed) } } } }
        }
    }
    shipping?.let { p ->
        val name = BugWords.platform(p.platform)
        val what = if (p.platform == "server") "the server deploy" else "the $name build"
        T1AlertDialog(if (p.platform == "server") "Mark ${p.fixes} server fix${if (p.fixes == 1) "" else "es"} deployed?" else "Mark ${p.fixes} $name fix${if (p.fixes == 1) "" else "es"} shipped?",
            onDismiss = { shipping = null },
            confirm = { TextButton(onClick = {
                shipping = null
                scope.launch { runCatching { BugsStore.ship(p.platform) }.onFailure { BugsStore.setError(BugWords.words(it)) } }
            }) { Label(if (p.platform == "server") "Mark deployed" else "Mark shipped", color = T1.accent) } },
            dismiss = { TextButton(onClick = { shipping = null }) { Label("Cancel", color = T1.text) } },
            body = { Text("Do this once $what with these fixes is out. A fix that comes back after this reopens as more urgent. All ${p.fixes} count, so if the build was cut before the newest fix, use bugs.py shipped --commit instead.",
                color = T1.muted, fontFamily = T1.mono, fontSize = 13.sp) })
    }
}

@Composable
fun BugScreen(id: Long, onBack: () -> Unit) {
    val s by BugsStore.state.collectAsState()
    val scope = rememberCoroutineScope()
    val uri = LocalUriHandler.current
    var crumbs by remember { mutableStateOf(false) }
    var noting by remember { mutableStateOf<Boolean?>(null) } // true = answer (sends it back)
    LaunchedEffect(id) { Telemetry.screen("bug"); BugsStore.setError(null); BugsStore.loadDetail(id) }
    val b = s.details[id]
    fun run(work: suspend () -> Unit) = scope.launch { runCatching { work() }.onSuccess { BugsStore.setError(null) }.onFailure { BugsStore.setError(BugWords.words(it)) } }
    fun change(status: String) {
        val d = b ?: return
        if (status == "open" && d.severity == null) { BugsStore.setError("Pick a severity first."); return }
        run { BugsStore.update(d.id, status = status) }
    }
    @Composable
    fun Code(text: String, muted: Boolean = false) = SelectionContainer {
        Text(text, Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp),
            color = if (muted) T1.muted else T1.text, fontFamily = T1.mono, fontSize = 12.sp)
    }
    T1Screen {
        Bar("Bug #$id" + (b?.severity?.let { " · $it" } ?: ""), b?.let { BugWords.status(it.status) }, onBack = onBack) {
            b?.sentryUrl?.let { url -> BarAction("Sentry") { runCatching { uri.openUri(url) } } }
        }
        Hairlines(Modifier.weight(1f)) {
            s.error?.let { item { Notice(it, error = true) } }
            if (b == null) { item { Notice("Loading…") }; return@Hairlines }
            item { Text(b.title, Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 14.dp), color = T1.text, fontFamily = T1.mono, fontSize = 15.sp) }
            item {
                Notice(buildList {
                    add(BugWords.platform(b.platform)); add("${b.events} time${if (b.events == 1) "" else "s"}")
                    if (b.users > 0) add("${b.users} ${if (b.users == 1) "person" else "people"}")
                    if (b.spikes > 0) add("${b.spikes} spike${if (b.spikes == 1) "" else "s"}")
                    if (b.regressed) add("came back after a fix")
                    BugWords.`when`(b.firstSeen)?.let { add("first $it") }; BugWords.`when`(b.lastSeen)?.let { add("last $it") }
                    b.releases.lastOrNull()?.let { add(it.replace("site.table1.events@", "")) }
                }.joinToString(" · "))
            }
            if (b.status == "needs_john") {
                item { Section("The fix runner asks") }
                item { Notice(b.notes ?: "It handed this to you without a note.") }
                item { Row { Ghost("Answer", accent = true) { noting = true }; Ghost("Won't fix") { change("wontfix") } } }
            }
            item { Section("Severity") }
            item {
                val sev = listOf("S1", "S2", "S3", "S4")
                T1Segmented(sev, sev.indexOf(b.severity)) { i -> if (sev[i] != b.severity) run { BugsStore.update(b.id, severity = sev[i]) } }
            }
            item {
                val who = if (b.severityBy == "john") "Set by you." else (b.severityReason ?: "").trim().let { if (it.isNotEmpty() && it.last() !in ".?!") "$it." else it }
                Notice(listOf(who, "S1: the fix runner starts within 5 minutes. Others wait for the 08:00 and 18:00 runs.").filter { it.isNotEmpty() }.joinToString(" "))
            }
            item { Section("Status") }
            item {
                when (b.status) {
                    "fixing" -> Notice("The fix runner took it ${BugWords.`when`(b.claimedAt) ?: "recently"} (try ${b.attempts}). You can change the severity or add a note; the status waits until it's done.")
                    "new", "open" -> Row { Ghost("Keep for me") { change("needs_john") }; Ghost("Won't fix") { change("wontfix") } }
                    "needs_john" -> Row { Ghost("Send to the fix runner", accent = true) { change("open") } }
                    "fixed" -> Row { Ghost("Reopen: the fix didn't work") { change("open") } }
                    else -> Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                        b.duplicateOf?.let { Notice("Same as #$it" + (b.duplicateTitle?.let { t -> ": $t" } ?: "")) }
                        Row { Ghost("Reopen") { change("open") } }
                    }
                }
            }
            if (b.status == "fixed" || b.fixCommit != null) {
                item { Section("Fix") }
                b.fixSummary?.let { item { Notice(it) } }
                item { Notice(listOfNotNull(b.fixCommit?.let { "Commit ${it.take(9)}" }, b.fixTest?.let { "Test $it" }, BugWords.`when`(b.fixedAt)?.let { "merged $it" }).joinToString(" · ")) }
                items(b.fixPlatforms, key = { "fp$it" }) { p ->
                    ListRow(BugWords.platform(p), if (p == "server") "Deploy" else "Build") {
                        Label(if (p in b.shipped) "Shipped" else "Waiting", color = if (p in b.shipped) T1.accent else T1.muted)
                    }
                }
            }
            item { Section("Notes") }
            item { Notice("Your notes go to the fix runner with this bug, the next time it takes it.") }
            items(b.log.size) { i ->
                val e = b.log[i]
                Column(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Label((if (e.kind == "note") "You" else "Changed") + (BugWords.`when`(e.at)?.let { " · $it" } ?: ""))
                    Text(e.body, color = if (e.kind == "note") T1.text else T1.muted, fontFamily = T1.mono, fontSize = 13.sp)
                }
            }
            item { Row { Ghost("Add a note") { noting = false } } }
            if (b.status != "needs_john" && !b.notes.isNullOrEmpty()) {
                item { Section("Fix runner notes") }
                item { Notice(b.notes) }
            }
            b.detail?.let { d ->
                item { Section("Latest occurrence") }
                b.culprit?.takeIf { it.isNotEmpty() && it != "?" }?.let { item { Notice("Where: $it") } }
                d.exception.orEmpty().forEachIndexed { i, x ->
                    item(key = "x$i") {
                        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                            Code(listOfNotNull(x.type, x.value).joinToString(": "))
                            val frames = x.frames.orEmpty().reversed().map { f ->
                                val place = listOfNotNull(f.file, f.line?.toString()).joinToString(":")
                                listOfNotNull(f.fn, place.ifEmpty { f.module?.substringAfterLast('/') }).joinToString("  ")
                            }
                            if (frames.isNotEmpty()) Code(frames.joinToString("\n"), muted = true)
                        }
                    }
                }
                d.issue?.let { i -> item { Code(listOfNotNull(i.type, i.value, i.function, i.filename).joinToString("\n")) } }
                d.job?.let { item { Code("Cron job $it") } }
                d.status?.let { st -> item { Code("HTTP $st" + if (d.timedOut == true) " · timed out" else "") } }
                d.message?.let { item { Code(it, muted = true) } }
                d.tags?.takeIf { it.isNotEmpty() }?.let { t -> item { Code(t.keys.sorted().filter { it != "app.device" }.joinToString("\n") { "$it: ${t[it]}" }, muted = true) } }
                d.breadcrumbs?.takeIf { it.isNotEmpty() }?.let { c ->
                    item { Row { Ghost(if (crumbs) "Hide breadcrumbs" else "Breadcrumbs · ${c.size}") { crumbs = !crumbs } } }
                    if (crumbs) item { Code(c.joinToString("\n") { listOfNotNull(it.category, it.message, it.url, it.status?.toString()).joinToString(" ") }, muted = true) }
                }
            }
        }
    }
    noting?.let { sendBack -> b?.let { BugNotePanel(it, sendBack) { noting = null } } }
}

@Composable
private fun BugNotePanel(bug: BugDetail, sendBack: Boolean, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    var text by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val key = remember { UUID.randomUUID().toString() }
    T1Panel(if (sendBack) "Answer" else "Note", onClose) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Section("Bug #${bug.id}")
            error?.let { Notice(it, error = true) }
            if (sendBack) bug.notes?.lines()?.lastOrNull()?.let { Notice(it) }
            Notice(if (sendBack) "Your answer goes to the fix runner, and the bug goes back in its queue." else "The fix runner reads this the next time it takes the bug.")
            Box(Modifier.fillMaxWidth().background(T1.surface).padding(16.dp)) {
                T1TextField(text, { text = it.take(2000) }, placeholder = if (sendBack) "E.g. yes, add the upload step" else "What you saw, what to try")
            }
        }
        BigAction(if (sendBack) "Send to the fix runner" else "Save note", enabled = text.isNotBlank(), busy = busy, accent = true) {
            busy = true
            scope.launch {
                runCatching { BugsStore.update(bug.id, status = if (sendBack && bug.severity != null) "open" else null, note = text, key = key) }
                    .onSuccess { onClose() }.onFailure { error = BugWords.words(it) }
                busy = false
            }
        }
    }
}
