package site.table1.events.ui.tracker

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import site.table1.events.tracker.ChangeGroup
import site.table1.events.tracker.ClockTone
import site.table1.events.tracker.CounterKind
import site.table1.events.tracker.MAX_COUNTERS
import site.table1.events.tracker.TrackerController
import site.table1.events.tracker.TrackerDoc
import site.table1.events.tracker.clockTone
import site.table1.events.tracker.counterLabel
import site.table1.events.tracker.formatTrackerClock
import site.table1.events.tracker.progress
import site.table1.events.tracker.remaining
import site.table1.events.tracker.signed
import site.table1.events.tracker.trackerCounters
import site.table1.events.ui.components.BarAction
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.ListRow
import site.table1.events.ui.components.Notice
import site.table1.events.ui.components.Section
import site.table1.events.ui.components.T1AlertDialog
import site.table1.events.ui.components.T1Menu
import site.table1.events.ui.components.T1MenuItem
import site.table1.events.ui.components.T1Panel
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1TextAction
import site.table1.events.ui.components.Bar
import site.table1.events.ui.theme.T1
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** Winner choice in the Record game flow: a side, or a draw. */
private data class Winner(val side: Int?, val draw: Boolean)

/**
 * Two-player life tracker (Figma "Life tracker — On its own", 73:5420). [matchId] null = local session on
 * this device only; otherwise the shared session for that match. Two halves (the opponent's rotated to face
 * them) around the info strip: round clock, Close, Record, History. Swipe down on a half, in that player's
 * orientation, to choose its counter columns. Full screen, screen kept on.
 */
@Composable
fun LifeTrackerScreen(matchId: String?, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val controller = remember(matchId) { TrackerController(context.applicationContext, matchId) }
    DisposableEffect(controller) {
        controller.start()
        onDispose { controller.close() }
    }

    // Keep the screen on while the tracker is visible.
    val view = LocalView.current
    DisposableEffect(view) {
        view.keepScreenOn = true
        onDispose { view.keepScreenOn = false }
    }

    // Push queued taps on the way to the background; catch up when we come back.
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle, controller) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_STOP -> controller.flushSoon()
                Lifecycle.Event.ON_START -> controller.refetch()
                else -> {}
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }

    val d = controller.doc
    if (d == null) {
        T1Screen {
            Bar("Life") { BarAction("Close", onClose) }
            Notice(controller.error ?: "Opening the tracker…", error = controller.error != null)
        }
        return
    }

    val haptics = LocalHapticFeedback.current
    var showHistory by remember { mutableStateOf(false) }
    var picking by remember { mutableStateOf(false) }
    var confirming by remember { mutableStateOf<Winner?>(null) }
    var startingLife by remember { mutableStateOf(false) }
    var forceReport by remember { mutableStateOf(false) }
    var reportNotice by remember { mutableStateOf<String?>(null) }
    var picker by remember { mutableStateOf<Int?>(null) }

    val me = d.bottomSide
    val them = d.topSide
    val game = d.currentGame

    fun tap(side: Int, counter: String, delta: Int) {
        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
        controller.tap(side, counter, delta)
    }

    // Edge to edge: the halves' tap zones and column hairlines reach the very top and bottom of the screen.
    Column(Modifier.fillMaxSize().background(T1.bg), verticalArrangement = Arrangement.spacedBy(1.dp)) {
        TrackerHalf(
            d, side = them, pickerOpen = picker == them, onPicker = { picker = if (it) them else null },
            onTap = ::tap, onToggle = { controller.toggleCounter(them, it) },
            modifier = Modifier.weight(1f).rotate(180f),
        )
        InfoStrip(
            d,
            context = reportNotice ?: controller.error ?: contextLine(d),
            contextColor = when {
                reportNotice != null -> T1.accent
                controller.error != null -> T1.danger
                else -> T1.disabled
            },
            recordAccent = !d.readOnly && d.loseCondition() != null,
            busy = controller.busy,
            onClose = onClose,
            onRecord = {
                val lose = d.loseCondition()
                if (lose != null) confirming = Winner(lose.second, false) else picking = true
            },
            onHistory = { showHistory = true },
        )
        TrackerHalf(
            d, side = me, pickerOpen = picker == me, onPicker = { picker = if (it) me else null },
            onTap = ::tap, onToggle = { controller.toggleCounter(me, it) },
            modifier = Modifier.weight(1f),
        )
    }

    if (showHistory) {
        HistoryPanel(
            d,
            onUndo = { controller.undoLast() },
            onReset = { controller.resetGame(); showHistory = false },
            onStartingLife = if (!controller.synced) ({ showHistory = false; startingLife = true }) else null,
            onNewMatch = if (!controller.synced) ({ controller.newMatch(); showHistory = false }) else null,
            onReport = if (controller.synced && !d.readOnly) ({ showHistory = false; forceReport = true }) else null,
            onDismiss = { showHistory = false },
        )
    }

    if (startingLife) {
        T1Menu(
            title = "Starting life",
            items = listOf(20, 25, 30, 40).map { life ->
                T1MenuItem("$life", selected = d.startingLife == life) { controller.setStartingLife(life) }
            },
            onDismiss = { startingLife = false },
        )
    }

    if (picking) {
        T1Menu(
            title = "Who won game $game?",
            items = listOf(
                T1MenuItem("Me") { confirming = Winner(me, false) },
                T1MenuItem(d.name(them)) { confirming = Winner(them, false) },
                T1MenuItem("Draw") { confirming = Winner(null, true) },
            ),
            onDismiss = { picking = false },
        )
    }

    confirming?.let { w ->
        val myWins = d.wins(me) + if (!w.draw && w.side == me) 1 else 0
        val theirWins = d.wins(them) + if (!w.draw && w.side == them) 1 else 0
        val draws = d.draws + if (w.draw) 1 else 0
        val who = when {
            w.draw -> "draw"
            w.side == me -> "you won"
            else -> "${d.name(them)} won"
        }
        T1AlertDialog(
            title = "Record game $game: $who?",
            onDismiss = { confirming = null },
            body = {
                Text("Match is $myWins–$theirWins${if (draws > 0) "–$draws" else ""}.", fontFamily = T1.mono, color = T1.muted, fontSize = 13.sp)
            },
            confirm = {
                T1TextAction("Record", color = T1.accent) {
                    confirming = null
                    haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                    controller.recordGame(w.side, w.draw)
                }
            },
            dismiss = { BarAction("Cancel") { confirming = null } },
        )
    }

    // Match decided: players report it to the event (synced) or see the result (local).
    val promptDecided = !d.readOnly && confirming == null && !picking &&
        ((d.decided && d.games.size > d.promptedAt) || forceReport)
    if (promptDecided) {
        val my = d.wins(me)
        val their = d.wins(them)
        val score = "$my–$their${if (d.draws > 0) "–${d.draws}" else ""}"
        if (controller.synced) {
            T1AlertDialog(
                title = "Report $score to the event?",
                onDismiss = { forceReport = false; controller.markPrompted() },
                body = {
                    Text("${d.name(them)} confirms or disputes it, as with any report.", fontFamily = T1.mono, color = T1.muted, fontSize = 13.sp)
                },
                confirm = {
                    T1TextAction("Report", color = T1.accent) {
                        forceReport = false
                        scope.launch {
                            if (controller.report()) reportNotice = "Reported $score | waiting on ${d.name(them)}"
                        }
                        controller.markPrompted()
                    }
                },
                dismiss = { BarAction("Not now") { forceReport = false; controller.markPrompted() } },
            )
        } else {
            val result = when {
                my > their -> "${d.name(me)} won $score"
                their > my -> "${d.name(them)} won $their–$my${if (d.draws > 0) "–${d.draws}" else ""}"
                else -> "Match drawn $score"
            }
            T1AlertDialog(
                title = result,
                onDismiss = { forceReport = false; controller.markPrompted() },
                confirm = { T1TextAction("New match", color = T1.accent) { forceReport = false; controller.newMatch() } },
                dismiss = { BarAction("Keep") { forceReport = false; controller.markPrompted() } },
            )
        }
    }
}

/** "R2 | Table 13 | Kai Budde"; offline / sending takes the slot while it lasts. */
private fun contextLine(d: TrackerDoc): String {
    if (d.synced && d.pending.isNotEmpty()) return "Sending…"
    if (!d.synced) return "Local game"
    return listOfNotNull(
        if (d.readOnly) "Watching" else null,
        d.round?.let { "R$it" },
        d.table?.let { "Table $it" },
        if (d.readOnly) "${d.name(0)} vs ${d.name(1)}" else d.name(d.topSide),
    ).joinToString(" | ")
}

private fun toneColor(tone: ClockTone): Color = when (tone) {
    ClockTone.Normal -> T1.accent
    ClockTone.Warning -> T1.warning
    ClockTone.Overtime -> T1.error
}

/** Lifetracker Info (73:5617): clock + context, the progress bar, then Close / Record / History. */
@Composable
private fun InfoStrip(
    d: TrackerDoc,
    context: String,
    contextColor: Color,
    recordAccent: Boolean,
    busy: Boolean,
    onClose: () -> Unit,
    onRecord: () -> Unit,
    onHistory: () -> Unit,
) {
    val clock = d.clock
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(clock?.timerStatus, clock?.timerLastStartedAt) {
        while (isActive && clock?.timerStatus == "running") {
            now = System.currentTimeMillis()
            delay(1_000 - now % 1_000)
        }
        now = System.currentTimeMillis()
    }
    val remaining = clock?.remaining(now)
    val tone = remaining?.let { clockTone(it) }

    Column(Modifier.fillMaxWidth().background(T1.bg), verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Row(Modifier.fillMaxWidth().height(48.dp), verticalAlignment = Alignment.CenterVertically) {
            if (remaining != null && tone != null) {
                Label(formatTrackerClock(remaining), Modifier.padding(horizontal = 16.dp), color = toneColor(tone))
            }
            Box(Modifier.weight(1f).padding(horizontal = 16.dp), contentAlignment = Alignment.CenterEnd) {
                Label(context, color = contextColor)
            }
        }
        Box(Modifier.fillMaxWidth().height(4.dp).background(T1.surface)) {
            if (remaining != null && tone != null) {
                Box(Modifier.fillMaxHeight().fillMaxWidth(clock.progress(remaining)).background(toneColor(tone)))
            }
        }
        Row(Modifier.fillMaxWidth().height(48.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f)) { StripButton("Close", onClick = onClose) }
            if (!d.readOnly) StripButton(if (busy) "Saving…" else "Record", accent = recordAccent, onClick = { if (!busy) onRecord() })
            Box(Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) { StripButton("History", onClick = onHistory) }
        }
    }
}

/** Strip Button: a label with a surface fill while pressed. Accent means "the result" (a game was lost). */
@Composable
private fun StripButton(text: String, accent: Boolean = false, onClick: () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val fill by animateColorAsState(if (pressed) T1.surface else T1.bg, tween(150), label = "strip")
    Box(
        Modifier.height(48.dp).background(fill)
            .clickable(interactionSource = interaction, indication = null, onClick = onClick)
            .padding(horizontal = 16.dp),
        contentAlignment = Alignment.Center,
    ) {
        Label(text, color = if (accent) T1.accent else T1.text)
    }
}

/**
 * One player's half (Figma "Me", Counters=0…3): life, plus up to three counter columns, each with its own
 * top +1 / bottom −1 zones. Swipe down (in this half's own orientation — the rotation carries the touch
 * coordinates with it) opens the counter picker; swipe up or Done closes it.
 */
@Composable
private fun TrackerHalf(
    d: TrackerDoc,
    side: Int,
    pickerOpen: Boolean,
    onPicker: (Boolean) -> Unit,
    onTap: (Int, String, Int) -> Unit,
    onToggle: (String) -> Unit,
    modifier: Modifier,
) {
    val game = d.currentGame
    val enabled = !d.readOnly
    val counters = d.shownCounters(side)
    val life = d.total(game, side, "life")
    val swipePx = with(LocalDensity.current) { 24.dp.toPx() }
    val open by rememberUpdatedState(pickerOpen)
    val setOpen by rememberUpdatedState(onPicker)

    Box(
        modifier.fillMaxWidth().background(T1.surface).pointerInput(Unit) {
            awaitEachGesture {
                val down = awaitFirstDown(requireUnconsumed = false)
                while (true) {
                    val event = awaitPointerEvent()
                    val change = event.changes.firstOrNull { it.id == down.id } ?: break
                    if (!change.pressed) break
                    val dx = change.position.x - down.position.x
                    val dy = change.position.y - down.position.y
                    if (kotlin.math.abs(dy) >= swipePx && kotlin.math.abs(dy) > kotlin.math.abs(dx) * 1.5f) {
                        if (dy > 0 && !open) setOpen(true) else if (dy < 0 && open) setOpen(false)
                        break
                    }
                }
            }
        },
    ) {
        Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            CounterColumn(
                value = life, label = null, target = if (counters.isEmpty()) 162f else 120f, lost = life <= 0,
                enabled = enabled, name = "${d.name(side)} life", modifier = Modifier.weight(1f),
            ) { onTap(side, "life", it) }
            if (counters.isNotEmpty()) {
                Row(Modifier.weight(1f).fillMaxHeight(), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    counters.forEach { c ->
                        val value = d.total(game, side, c.id)
                        CounterColumn(
                            value = value, label = c.shortLabel,
                            target = when (counters.size) { 1 -> 80f; 2 -> 64f; else -> 44f },
                            lost = c.id == "poison" && value >= 10, enabled = enabled,
                            name = "${d.name(side)} ${c.label}", modifier = Modifier.weight(1f),
                        ) { onTap(side, c.id, it) }
                    }
                }
            }
        }
        if (counters.isEmpty()) {
            // The hairline mark, 8 dp from the strip.
            Box(Modifier.align(Alignment.TopCenter).padding(top = 8.dp).width(26.dp).height(1.dp).background(T1.surface))
        }
        AnimatedVisibility(
            visible = pickerOpen,
            enter = slideInVertically(tween(150)) { -it },
            exit = slideOutVertically(tween(150)) { -it },
        ) {
            CounterPicker(d.shownCounters(side), onToggle = onToggle, onDone = { onPicker(false) })
        }
    }
}

/** Counter Column: the total (and a label for counters) over its own +1 / −1 zones. */
@Composable
private fun CounterColumn(
    value: Int,
    label: String?,
    target: Float,
    lost: Boolean,
    enabled: Boolean,
    name: String,
    modifier: Modifier,
    onDelta: (Int) -> Unit,
) {
    BoxWithConstraints(modifier.fillMaxHeight().background(T1.bg)) {
        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            TapZone(enabled, "$name +1", Modifier.weight(1f)) { onDelta(1) }
            TapZone(enabled, "$name −1", Modifier.weight(1f)) { onDelta(-1) }
        }
        // Shrink to fit narrow columns and short halves (a monospace digit is about 0.6 em wide).
        val digits = value.toString().length.coerceAtLeast(2)
        val fontScale = LocalDensity.current.fontScale
        val size = minOf(target, (maxWidth.value - 8f) / (digits * 0.6f), maxHeight.value * 0.45f) / fontScale
        Column(
            Modifier.align(Alignment.Center).padding(bottom = 32.dp, start = 4.dp, end = 4.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                "$value", color = if (lost) T1.error else T1.text, fontFamily = T1.mono,
                fontWeight = FontWeight.SemiBold, fontSize = size.sp, letterSpacing = (-0.025).em,
                lineHeight = size.sp, maxLines = 1,
            )
            if (label != null) Label(label, color = T1.disabled)
        }
    }
}

/**
 * Increment Button. A tap fires on release so a swipe never changes a total; moving more than 10 dp cancels
 * it. Holding fires after 0.5 s, then every 0.15 s. Pressed = surface.
 */
@Composable
private fun TapZone(enabled: Boolean, label: String, modifier: Modifier, onStep: () -> Unit) {
    val step by rememberUpdatedState(onStep)
    var pressed by remember { mutableStateOf(false) }
    val fill by animateColorAsState(if (pressed) T1.surface else T1.bg, tween(150), label = "zone")
    val slop = with(LocalDensity.current) { 10.dp.toPx() }
    Box(
        modifier.fillMaxWidth().background(fill)
            .semantics {
                contentDescription = label
                role = Role.Button
                if (enabled) onClick { step(); true }
            }
            .let { m ->
                if (!enabled) m else m.pointerInput(Unit) {
                    coroutineScope {
                        awaitEachGesture {
                            val down = awaitFirstDown()
                            pressed = true
                            var held = false
                            var cancelled = false
                            val repeat = launch {
                                delay(500)
                                held = true
                                while (isActive) {
                                    step()
                                    delay(150)
                                }
                            }
                            while (true) {
                                val event = awaitPointerEvent()
                                val change = event.changes.firstOrNull { it.id == down.id }
                                if (change == null || !change.pressed) break
                                if (!held && !cancelled && (change.position - down.position).getDistance() > slop) {
                                    cancelled = true
                                    repeat.cancel()
                                    pressed = false
                                }
                            }
                            repeat.cancel()
                            pressed = false
                            if (!held && !cancelled) step()
                        }
                    }
                }
            },
    )
}

/** Counter Picker: which counters this side shows, three at most. */
@Composable
private fun CounterPicker(shown: List<CounterKind>, onToggle: (String) -> Unit, onDone: () -> Unit) {
    val full = shown.size >= MAX_COUNTERS
    Column(Modifier.fillMaxSize().background(T1.surface), verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Row(Modifier.fillMaxWidth().background(T1.bg), verticalAlignment = Alignment.CenterVertically) {
            Label("Counters · ${shown.size} of $MAX_COUNTERS", Modifier.weight(1f).padding(horizontal = 16.dp), color = T1.disabled)
            StripButton("Done", onClick = onDone)
        }
        Column(
            Modifier.weight(1f).fillMaxWidth().background(T1.bg).verticalScroll(rememberScrollState()),
        ) {
            Column(Modifier.background(T1.surface), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                trackerCounters.forEach { c ->
                    val on = shown.any { it.id == c.id }
                    val disabled = !on && full
                    val interaction = remember { MutableInteractionSource() }
                    val pressed by interaction.collectIsPressedAsState()
                    Row(
                        Modifier.fillMaxWidth().height(48.dp)
                            .background(if (disabled) T1.disabled else if (pressed) T1.surface else T1.bg)
                            .clickable(enabled = !disabled, interactionSource = interaction, indication = null) { onToggle(c.id) }
                            .padding(horizontal = 16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Label(c.label, Modifier.weight(1f), color = if (disabled) T1.bg else T1.text)
                        Label(
                            if (on) "On" else if (disabled) "Max 3" else "Off",
                            color = if (disabled) T1.bg else if (on) T1.text else T1.disabled,
                        )
                    }
                }
            }
        }
    }
}

private val timeFormat = DateTimeFormatter.ofPattern("h:mm:ss a")

/** History, newest first; the footer holds what used to be in the ⋯ menu. */
@Composable
private fun HistoryPanel(
    d: TrackerDoc,
    onUndo: () -> Unit,
    onReset: () -> Unit,
    onStartingLife: (() -> Unit)?,
    onNewMatch: (() -> Unit)?,
    onReport: (() -> Unit)?,
    onDismiss: () -> Unit,
) {
    T1Panel(
        title = "History",
        onDismiss = onDismiss,
        action = if (d.readOnly) null else ({
            T1TextAction("Undo last", enabled = d.groups(d.currentGame).isNotEmpty(), color = T1.accent, onClick = onUndo)
        }),
    ) {
        val games = (d.currentGame downTo 1).map { g -> g to d.groups(g).asReversed() }
        LazyColumn(Modifier.fillMaxWidth().weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            if (games.all { it.second.isEmpty() }) {
                item { Notice("No changes yet") }
            }
            games.forEach { (g, groups) ->
                if (groups.isEmpty() && g == d.currentGame && d.games.isEmpty()) return@forEach
                item(key = "game-$g") {
                    val recorded = d.games.firstOrNull { it.gameNo == g }
                    val result = when {
                        recorded == null -> "in progress"
                        recorded.isDraw -> "draw"
                        else -> "${d.name(recorded.winnerSide ?: 0)} won"
                    }
                    Box(Modifier.fillMaxWidth().background(T1.bg).padding(horizontal = 16.dp, vertical = 8.dp)) {
                        Label("Game $g · $result")
                    }
                }
                items(groups, key = { "g$g-" + it.opIds.first() }) { grp ->
                    HistoryRow(d, grp)
                }
            }
            item(key = "actions") {
                Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    Section("Match ${d.wins(d.bottomSide)}–${d.wins(d.topSide)}")
                    if (!d.readOnly) ListRow("Reset game", onClick = onReset)
                    onStartingLife?.let { ListRow("Starting life", detail = "${d.startingLife}", onClick = it) }
                    onNewMatch?.let { ListRow("New match", onClick = it) }
                    onReport?.let { ListRow("Report now", onClick = it) }
                }
            }
        }
    }
}

@Composable
private fun HistoryRow(d: TrackerDoc, g: ChangeGroup) {
    val by = when {
        !d.synced || d.readOnly -> null
        g.mine -> "by you"
        else -> "by ${d.name(d.topSide)}"
    }
    val time = timeFormat.format(Instant.ofEpochMilli(g.endMillis).atZone(ZoneId.systemDefault()))
    Row(
        Modifier.fillMaxWidth().background(T1.surface).padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            "${d.name(g.side)} · ${counterLabel(g.counter)} ${signed(g.delta)} → ${g.after}",
            Modifier.weight(1f), color = T1.text, fontFamily = T1.mono, fontSize = 13.sp,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
        Label(listOfNotNull(time, by).joinToString(" · "))
    }
}
