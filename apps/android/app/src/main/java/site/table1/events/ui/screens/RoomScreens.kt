package site.table1.events.ui.screens

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Presentation
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.ContextWrapper
import android.hardware.display.DisplayManager
import android.os.Bundle
import android.view.Display
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import site.table1.events.data.EventAbout
import site.table1.events.data.EventRoom
import site.table1.events.data.JudgeCall
import site.table1.events.data.MatchRow
import site.table1.events.data.Repo
import site.table1.events.data.RoomRules
import site.table1.events.data.eventRoom
import site.table1.events.data.extendMatch
import site.table1.events.data.judgeCall
import site.table1.events.data.judgeCancel
import site.table1.events.data.judgeResolve
import site.table1.events.data.setDisplay
import site.table1.events.data.setEventRules
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.Ghost
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1AlertDialog
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Panel
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1Switch
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry
import site.table1.events.util.qrBitmap
import site.table1.events.util.rethrowIfCancelled
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

/*
 * Organizer tools for the room (contract/room-tools-2026-11-13.md Clients): the Display panel (address, QR, Copy,
 * Showing, Announcement, a second screen from the phone), Extra time for a table, judge calls for players and
 * organizers, and the rules level and decklist deadline in Details.
 */

// ── § 1 the display remote ──

/**
 * A second screen from the phone: with a presentation display present (a wireless display, a cable), the event's
 * display page fills that screen in a web view the app owns while the phone keeps the organizer screen. One at a time;
 * it ends on Stop showing, when the display goes away, or when the organizer leaves the event.
 */
object SecondScreen {
    private var showing: Presentation? = null
    var eventId by mutableStateOf<String?>(null)
        private set

    private class Page(context: Context, display: Display, private val url: String) : Presentation(context, display) {
        @SuppressLint("SetJavaScriptEnabled")
        override fun onCreate(savedInstanceState: Bundle?) {
            super.onCreate(savedInstanceState)
            val web = WebView(context)
            web.settings.javaScriptEnabled = true
            web.settings.domStorageEnabled = true
            web.webViewClient = WebViewClient()
            web.setBackgroundColor(0xFF171725.toInt())
            setContentView(web)
            web.loadUrl(url)
        }
    }

    private fun activity(context: Context): Activity? = generateSequence(context) { (it as? ContextWrapper)?.baseContext }.filterIsInstance<Activity>().firstOrNull()

    /** The external displays a presentation can go on (none on a phone by itself). */
    fun displays(context: Context): List<Display> =
        (context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager).getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION).toList()

    fun show(context: Context, display: Display, event: String): Boolean {
        stop(report = false)
        val host = activity(context) ?: return false
        return runCatching {
            val p = Page(host, display, RoomRules.displayUrl(event))
            p.setOnDismissListener { if (showing === p) { showing = null; eventId = null } }
            p.show()
            showing = p
            eventId = event
            Telemetry.capture("display_second_screen", mapOf("on" to true))
        }.isSuccess
    }

    fun stop(report: Boolean = true) {
        val p = showing ?: return
        showing = null
        eventId = null
        runCatching { p.dismiss() }
        if (report) Telemetry.capture("display_second_screen", mapOf("on" to false))
    }
}

/** The external displays, kept current as one is plugged in or goes away. */
@Composable
private fun rememberPresentationDisplays(): List<Display> {
    val context = LocalContext.current
    var displays by remember { mutableStateOf(SecondScreen.displays(context)) }
    DisposableEffect(context) {
        val manager = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        val listener = object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(id: Int) { displays = SecondScreen.displays(context) }
            override fun onDisplayRemoved(id: Int) { displays = SecondScreen.displays(context) }
            override fun onDisplayChanged(id: Int) { displays = SecondScreen.displays(context) }
        }
        manager.registerDisplayListener(listener, null)
        onDispose { manager.unregisterDisplayListener(listener) }
    }
    return displays
}

/** Live → More → Display: the address, its QR code, Copy link, Showing, Announcement, and a second screen. */
@Composable
fun DisplayPanel(eventId: String, room: EventRoom?, onDismiss: () -> Unit, onChanged: suspend () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val url = RoomRules.displayUrl(eventId)
    var show by remember(room?.display?.show) { mutableStateOf(room?.display?.show ?: "auto") }
    var shown by remember(room?.display?.message) { mutableStateOf(room?.display?.message.orEmpty()) }
    var message by remember { mutableStateOf(room?.display?.message.orEmpty()) }
    var error by remember { mutableStateOf<String?>(null) }
    var copied by remember { mutableStateOf(false) }
    val displays = rememberPresentationDisplays()

    fun set(newShow: String? = null, newMessage: String? = null) {
        scope.launch {
            try {
                val d = Repo.setDisplay(eventId, newShow, newMessage)
                show = d.show
                shown = d.message.orEmpty()
                error = null
                onChanged()
            } catch (e: Throwable) {
                e.rethrowIfCancelled()
                error = userMessage(e)
            }
        }
    }

    T1Panel("Display", onDismiss) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Column(Modifier.fillMaxWidth().background(T1.surface).padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                val qr = remember(url) { qrBitmap(url) }
                Image(qr, contentDescription = "The display's address as a QR code", modifier = Modifier.size(168.dp).background(T1.text).padding(6.dp))
                // The whole address on one line (an event's id is long): small, never wrapped.
                Text(url.removePrefix("https://"), color = T1.text, fontFamily = T1.mono, fontSize = 10.sp, maxLines = 1, softWrap = false,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                Ghost(if (copied) "Copied" else "Copy link") {
                    (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("Display", url))
                    copied = true
                }
            }
            // A second screen from the phone.
            val on = SecondScreen.eventId == eventId
            if (on) ListRow("Showing on a second screen", onClick = { SecondScreen.stop() }) { Label("Stop showing", color = T1.text) }
            else if (displays.isEmpty()) Notice("Mirror your screen, or open the address on the TV.")
            else displays.forEach { d ->
                ListRow("Show on ${d.name}", onClick = { if (!SecondScreen.show(context, d, eventId)) error = "Couldn't show on ${d.name}." }) { Label("Show", color = T1.accent) }
            }
            Section("Showing")
            T1Segmented(RoomRules.shows.map { it.second }, RoomRules.shows.indexOfFirst { it.first == show }.coerceAtLeast(0)) { i ->
                show = RoomRules.shows[i].first
                set(newShow = show)
            }
            Row(Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Label("Announcement", Modifier.weight(1f))
                Label(RoomRules.counter(message), color = if (message.length >= RoomRules.MESSAGE_MAX) T1.text else T1.muted)
            }
            BasicTextField(message, { message = it.replace("\n", " ").take(RoomRules.MESSAGE_MAX) }, Modifier.fillMaxWidth().semantics { contentDescription = "Announcement" },
                textStyle = TextStyle(color = T1.text, fontFamily = T1.mono, fontSize = 15.sp, lineHeight = 22.sp), cursorBrush = SolidColor(T1.accent),
                decorationBox = { inner ->
                    Box(Modifier.fillMaxWidth().heightIn(min = 76.dp).background(T1.surface).padding(16.dp)) {
                        if (message.isEmpty()) Text("A line along the bottom of every screen", color = T1.muted, fontFamily = T1.mono, fontSize = 15.sp)
                        inner()
                    }
                })
            Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                Ghost("Clear", enabled = shown.isNotEmpty() || message.isNotEmpty()) { message = ""; set(newMessage = "") }
                Ghost(if (shown.isNotEmpty() && shown == message.trim()) "Showing" else "Show", enabled = message.isNotBlank() && shown != message.trim(),
                    accent = message.isNotBlank() && shown != message.trim()) { set(newMessage = message.trim()) }
            }
            error?.let { Notice(it, error = true) }
        }
    }
}

// ── § 2 extra time ──

/** A match row's Extra time: +3 min, +5 min, +10 min, Take it back. */
@Composable
fun ExtraTimeMenu(m: MatchRow, room: EventRoom?, onDismiss: () -> Unit, onDone: suspend () -> Unit, onError: (String?) -> Unit) {
    val scope = rememberCoroutineScope()
    val now = room?.extra(m.id) ?: 0
    T1Menu("Table ${m.tableNumber ?: "–"} · extra time ${RoomRules.extensionText(now)}".trim(), RoomRules.extras.map { (pick, label) ->
        val by = RoomRules.extendBy(pick, now)
        T1MenuItem(label, enabled = by != 0, danger = pick == 0) {
            scope.launch {
                runCatching { Repo.extendMatch(m.id, by) }.onSuccess { onError(null) }.onFailure { it.rethrowIfCancelled(); onError(userMessage(it)) }
                onDone()
            }
        }
    }, onDismiss)
}

// ── § 3 judge calls ──

/** The current time, ticking every [everyMs], for lines that say how long ago. */
@Composable
private fun rememberNow(everyMs: Long = 20_000): Instant {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(everyMs)
            now = System.currentTimeMillis()
        }
    }
    return Instant.ofEpochMilli(now)
}

/** Organizer, Live → Round: open calls lead the tab, each `JUDGE · TABLE 7 · BEA · 2 MIN` with Done. */
fun LazyListScope.judgeCallItems(calls: List<JudgeCall>?, onChanged: suspend () -> Unit, onError: (String?) -> Unit) {
    val open = calls?.takeIf { it.isNotEmpty() } ?: return
    items(open, key = { "judge-${it.callId}" }) { c ->
        val scope = rememberCoroutineScope()
        val now = rememberNow()
        var busy by remember { mutableStateOf(false) }
        Row(Modifier.fillMaxWidth().background(T1.surface).padding(start = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Label(RoomRules.judgeLine(c.tableNumber, c.by, c.calledAt, now), Modifier.weight(1f).padding(vertical = 16.dp), color = T1.accent)
            Label(if (busy) "…" else "Done", Modifier.clickable(enabled = !busy, onClickLabel = "Done") {
                busy = true
                scope.launch {
                    runCatching { Repo.judgeResolve(c.callId) }.onSuccess { onError(null) }.onFailure { it.rethrowIfCancelled(); onError(userMessage(it)) }
                    onChanged()
                    busy = false
                }
            }.padding(horizontal = 16.dp, vertical = 16.dp), color = T1.text)
        }
    }
}

/**
 * A player's table in the room, wherever their match shows (the event screen, the life tracker): its extra time and
 * the judge call. [load] reads event_room again (every 15 s while it's up, and after a call or a cancel).
 */
class TableRoom {
    var extra by mutableIntStateOf(0)
    /** null: this isn't your table in the newest round (or the server has no room tools), so no Call a judge. */
    var callOpen by mutableStateOf<Boolean?>(null)
    var error by mutableStateOf<String?>(null)

    fun take(room: EventRoom?, matchId: String?) {
        val mine = room?.myMatch?.takeIf { it.matchId == matchId }
        extra = mine?.extraSeconds ?: matchId?.let { room?.extra(it) } ?: 0
        callOpen = mine?.callOpen
    }

    suspend fun call(matchId: String, on: Boolean, reload: suspend () -> Unit) {
        try {
            if (on) Repo.judgeCall(matchId) else Repo.judgeCancel(matchId)
            callOpen = on
            error = null
        } catch (e: Throwable) {
            e.rethrowIfCancelled()
            error = userMessage(e)
        }
        reload()
    }
}

/** A table's room for a screen that doesn't read the event itself (the life tracker): event_room every 15 s. */
@Composable
fun rememberTableRoom(eventId: String?, matchId: String?): Pair<TableRoom, suspend () -> Unit> {
    val state = remember(matchId) { TableRoom() }
    val reload: suspend () -> Unit = {
        if (eventId != null && matchId != null) {
            runCatching { Repo.eventRoom(eventId) }.onSuccess { state.take(it, matchId) }.onFailure { it.rethrowIfCancelled() }
        }
    }
    LaunchedEffect(eventId, matchId) {
        if (eventId == null || matchId == null) return@LaunchedEffect
        while (true) {
            reload()
            delay(15_000)
        }
    }
    return state to reload
}

/** The player's match on the event screen: Call a judge (a confirm); while a call is open, `JUDGE CALLED` in accent
 *  with Cancel. Nothing when this isn't your table in the round being played. */
@Composable
fun JudgeCallRow(matchId: String, table: Int?, room: EventRoom?, onChanged: suspend () -> Unit) {
    val mine = room?.myMatch?.takeIf { it.matchId == matchId } ?: return
    val scope = rememberCoroutineScope()
    val state = remember(matchId) { TableRoom() }
    state.take(room, matchId)
    var confirm by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        if (mine.callOpen) {
            Row(Modifier.fillMaxWidth().background(T1.surface).padding(start = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Label("Judge called", Modifier.weight(1f).padding(vertical = 14.dp), color = T1.accent)
                Label("Cancel", Modifier.clickable(onClickLabel = "Cancel the judge call") { scope.launch { state.call(matchId, false, onChanged) } }
                    .padding(horizontal = 16.dp, vertical = 14.dp), color = T1.text)
            }
        } else Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) { Ghost("Call a judge") { confirm = true } }
        state.error?.let { Notice(it, error = true) }
    }
    if (confirm) JudgeConfirm(table, { confirm = false }) { scope.launch { state.call(matchId, true, onChanged) } }
}

/** "Call a judge to table 7?" */
@Composable
fun JudgeConfirm(table: Int?, onDismiss: () -> Unit, onCall: () -> Unit) {
    T1AlertDialog("Call a judge to table ${table ?: "–"}?", onDismiss,
        body = { Text("The organizers are told now.", color = T1.text, fontFamily = T1.mono, fontSize = 13.sp) },
        confirm = { BarAction("Call a judge") { onDismiss(); onCall() } },
        dismiss = { BarAction("Not now", onDismiss) })
}

// ── § 4 the rules level and the decklist deadline ──

/** Setup → Details: Rules (Not said | Casual | Competitive) and, when decklists are on, Decklists due (a day and a
 *  time, in 15-minute steps like the event's own start). */
@Composable
fun EventRulesRows(eventId: String, about: EventAbout?, decklistsOn: Boolean, startsAt: String?, enabled: Boolean, onSaved: () -> Unit, onError: (String?) -> Unit) {
    val a = about ?: return
    val scope = rememberCoroutineScope()
    val zone = ZoneId.systemDefault()
    var rel by remember(a.rel) { mutableStateOf(a.rel) }
    var due by remember(a.decklistDueAt) {
        mutableStateOf(site.table1.events.data.Leagues.parseInstant(a.decklistDueAt)?.atZone(zone)?.toLocalDateTime())
    }
    var edits by remember { mutableIntStateOf(0) }

    fun save(block: suspend () -> Unit) {
        scope.launch {
            try {
                block()
                onError(null)
                onSaved()
            } catch (e: Throwable) {
                e.rethrowIfCancelled()
                onError(userMessage(e))
            }
        }
    }
    // The steppers save once they rest.
    LaunchedEffect(edits) {
        if (edits == 0) return@LaunchedEffect
        delay(600)
        val at = due
        save { Repo.setEventRules(eventId, dueAt = at?.atZone(zone)?.toInstant()?.toString(), setDue = true) }
    }

    FormBlock("Rules") {
        T1Segmented(RoomRules.rels.map { it.second }, RoomRules.rels.indexOfFirst { it.first == rel }.coerceAtLeast(0), enabled = enabled) { i ->
            rel = RoomRules.rels[i].first
            val picked = rel
            save { Repo.setEventRules(eventId, rel = picked, setRel = true) }
        }
    }
    if (!decklistsOn) return
    val start = site.table1.events.data.Leagues.parseInstant(startsAt)?.atZone(zone)?.toLocalDateTime()
    ListRow("Decklists due", due?.let { RoomRules.dueText(it.atZone(zone).toInstant().toString()) } ?: "No deadline", onClick = {
        due = if (due == null) (start?.minusMinutes(30) ?: LocalDateTime.now().plusDays(1).withHour(18).withMinute(0)).withSecond(0).withNano(0) else null
        edits++
    }) { T1Switch(due != null, enabled = enabled) { on ->
        due = if (on) (start?.minusMinutes(30) ?: LocalDateTime.now().plusDays(1).withHour(18).withMinute(0)).withSecond(0).withNano(0) else null
        edits++
    } }
    due?.let { d ->
        StepRow("Due day", DateTimeFormatter.ofPattern("EEE d MMM yyyy", Locale.getDefault()).format(d),
            onMinus = { due = d.minusDays(1); edits++ }, onPlus = { due = d.plusDays(1); edits++ })
        StepRow("Due time", DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).format(d),
            onMinus = { due = d.minusMinutes(15); edits++ }, onPlus = { due = d.plusMinutes(15); edits++ })
    }
}
