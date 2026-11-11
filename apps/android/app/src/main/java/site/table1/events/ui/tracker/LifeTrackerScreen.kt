package site.table1.events.ui.tracker

import site.table1.events.ui.components.FoldMode
import site.table1.events.ui.components.FoldSplit
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
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.layout
import androidx.compose.ui.unit.Constraints
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
import site.table1.events.tracker.TrackerNext
import site.table1.events.tracker.TrackerPlace
import site.table1.events.tracker.TrackerRow
import site.table1.events.tracker.TrackerSeat
import site.table1.events.tracker.TrackerTable
import site.table1.events.tracker.TrackerTouch
import site.table1.events.tracker.TrackerTouchStats
import site.table1.events.tracker.clockTone
import site.table1.events.tracker.commanderFrom
import site.table1.events.tracker.formatTrackerClock
import site.table1.events.tracker.progress
import site.table1.events.tracker.remaining
import site.table1.events.tracker.signed
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
import site.table1.events.util.Telemetry
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** Winner choice in the Record game flow: a side, or a draw. */
private data class Winner(val side: Int?, val draw: Boolean)

/**
 * Two-player life tracker (Figma "Life tracker — On its own", 73:5420). [matchId] null = local session on
 * this device only; otherwise the shared session for that match. Two halves (the opponent's rotated to face
 * them) around the info strip: round clock, Record, Options (chooser, dice, history, leave; 231:9191), Reset.
 * Swipe down on a half, in that player's
 * orientation, to choose its counter columns. Full screen, screen kept on.
 *
 * A local tracker opens on Setup (2–5 players, 20/30/40 life), then the chooser; three to five players sit
 * around the phone ([TrackerTable.layout]), and 30+ life tracks commander damage
 * (contract/life-tracker-commander-2026-11-03.md).
 */
/** Sends what the touches did since the last flush (`tracker_touches`). */
private fun flushTouches(controller: TrackerController) {
    val d = controller.doc ?: return
    TrackerTouchStats.take(d.players, if (d.synced) "match" else "local")
        ?.let { Telemetry.capture("tracker_touches", it) }
}

@Composable
fun LifeTrackerScreen(matchId: String?, onClose: () -> Unit, onNext: (String) -> Unit = {}) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val controller = remember(matchId) { TrackerController(context.applicationContext, matchId) }
    DisposableEffect(controller) {
        controller.start()
        onDispose {
            flushTouches(controller)
            controller.close()
        }
    }

    // The next round is paired: open that match instead (contract/life-tracker-options-2026-10-20.md § Next round).
    val nextMatch = controller.nextMatchId
    LaunchedEffect(nextMatch) { nextMatch?.let(onNext) }
    // While it's up and in front, ask every 15 s.
    LifecycleResumeEffect(controller) {
        val poll = if (controller.synced) scope.launch {
            while (isActive) {
                delay(TrackerNext.EVERY_MS)
                controller.checkNext("poll")
            }
        } else null
        onPauseOrDispose { poll?.cancel() }
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
                Lifecycle.Event.ON_STOP -> {
                    flushTouches(controller)
                    controller.flushSoon()
                }
                Lifecycle.Event.ON_START -> {
                    controller.refetch()
                    controller.checkNext("foreground")
                }
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
    var panel by remember { mutableStateOf<String?>(null) }
    var resetting by remember { mutableStateOf(false) }
    var picking by remember { mutableStateOf(false) }
    var confirming by remember { mutableStateOf<Winner?>(null) }
    var forceReport by remember { mutableStateOf(false) }
    var reportNotice by remember { mutableStateOf<String?>(null) }
    var picker by remember { mutableStateOf<Int?>(null) }
    // Local trackers open on Setup.
    var setup by remember { mutableStateOf(!controller.synced) }
    val commanderTapped = remember { mutableSetOf<Int>() }

    val me = d.bottomSide
    val them = d.topSide
    val game = d.currentGame

    fun tap(side: Int, counter: String, delta: Int) {
        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
        controller.tap(side, counter, delta)
        if (commanderFrom(counter) != null && commanderTapped.add(game)) {
            Telemetry.capture("tracker_commander_damage", mapOf("players" to d.players))
        }
    }

    fun newTable() {
        picker = null
        setup = true
    }

    if (setup) {
        TrackerSetup(
            initial = controller.lastSetup,
            canContinue = d.games.isNotEmpty() || d.groups(d.currentGame).isNotEmpty(),
            onStart = { players, life ->
                controller.configure(players, life)
                commanderTapped.clear()
                picker = null
                setup = false
                panel = "chooser"
                Telemetry.capture("tracker_setup_started", mapOf("players" to players, "life" to life))
            },
            onContinue = {
                setup = false
                Telemetry.capture("tracker_setup_continued", mapOf("players" to d.players))
            },
            onClose = onClose,
        )
        return
    }

    // Two players: mine at the bottom (the organizer watching sees side 0 there), the opponent's facing them.
    val rows: List<TrackerRow> = if (d.players == 2) {
        listOf(listOf(TrackerPlace(them, TrackerSeat.Top)), null, listOf(TrackerPlace(me, TrackerSeat.Bottom)))
    } else {
        TrackerTable.layout(d.players)
    }

    val stripContext = reportNotice ?: controller.error ?: controller.nextNotice?.takeIf { d.pending.isEmpty() } ?: contextLine(d)
    val stripColor = when {
        reportNotice != null -> T1.accent
        controller.error != null -> T1.danger
        else -> T1.disabled
    }
    val onRecord: () -> Unit = {
        val winner = d.settledWinner()
        if (d.canRecord) {
            if (winner != null) confirming = Winner(winner, false) else picking = true
        }
    }

    // Foldables (contract/foldables-2026-11-10.md § The screens): tabletop stands every seat upright on the top half
    // with the controls on the flat half; book puts the seats on the left page and the controls on the right.
    FoldSplit("tracker", allow = setOf(FoldMode.Tabletop, FoldMode.Book), single = {
    // Edge to edge: the halves' tap zones and column hairlines reach the very top and bottom of the screen.
    // Hairlines between seats at a bigger table.
    Column(
        Modifier.fillMaxSize().background(if (d.players > 2) T1.surface else T1.bg),
        verticalArrangement = Arrangement.spacedBy(1.dp),
    ) {
      rows.forEach { row ->
        if (row != null) {
            Row(Modifier.weight(1f).fillMaxWidth().background(T1.surface), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                row.forEach { place ->
                    TrackerHalf(
                        d, side = place.side, pickerOpen = picker == place.side,
                        onPicker = { picker = if (it) place.side else null },
                        onTap = ::tap, onToggle = { controller.toggleCounter(place.side, it) },
                        modifier = Modifier.weight(1f).fillMaxHeight().seat(place.seat),
                    )
                }
            }
            return@forEach
        }
        InfoStrip(
            d,
            context = stripContext,
            contextColor = stripColor,
            recordAccent = d.canRecord && d.settledWinner() != null,
            busy = controller.busy,
            onOptions = { panel = "options" },
            onReset = { resetting = true },
            onRecord = onRecord,
        )
      }
    }
    }, first = { layout ->
        // Every seat facing whoever holds the phone: the opponent first, you last; at a bigger table P1 to P5.
        val book = layout.mode == FoldMode.Book
        val order = if (d.players == 2) listOf(them, me) else d.sides.toList()
        @Composable
        fun Upright(side: Int, modifier: Modifier) {
            Box(modifier) {
                TrackerHalf(
                    d, side = side, pickerOpen = picker == side,
                    onPicker = { picker = if (it) side else null },
                    onTap = ::tap, onToggle = { controller.toggleCounter(side, it) },
                    modifier = Modifier.fillMaxSize(),
                )
                // Side by side and all facing one way, the seats say whose they are.
                Label(d.name(side), Modifier.align(Alignment.BottomCenter).padding(bottom = 12.dp), color = T1.muted)
            }
        }
        if (book) {
            Column(Modifier.fillMaxSize().background(T1.surface), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                order.forEach { Upright(it, Modifier.weight(1f).fillMaxWidth()) }
            }
        } else {
            Row(Modifier.fillMaxSize().background(T1.surface), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                order.forEach { Upright(it, Modifier.weight(1f).fillMaxHeight()) }
            }
        }
    }, second = { layout ->
        FoldControls(
            d, book = layout.mode == FoldMode.Book, context = stripContext, contextColor = stripColor,
            recordAccent = d.canRecord && d.settledWinner() != null, busy = controller.busy,
            onRecord = onRecord, onOptions = { panel = "options" }, onReset = { resetting = true },
        )
    })

    when (panel) {
        "options" -> TrackerOptionsPanel(
            onDismiss = { panel = null },
            onChooser = { panel = "chooser" },
            onDice = { panel = "dice" },
            onHistory = { showHistory = true },
            onNewMatch = if (!controller.synced) ::newTable else null,
            onLeave = onClose,
        )
        "dice" -> TrackerDicePanel(onDismiss = { panel = null })
        "chooser" -> TrackerChooser(onDismiss = { panel = null })
    }

    if (resetting) {
        // Only this device's own games can be cleared, never an event's recorded ones.
        val canResetMatch = !controller.synced && d.games.isNotEmpty()
        val score = d.scoreText
        val life = "Life goes back to ${d.startingLife} and counters to 0."
        fun reset(match: Boolean) {
            resetting = false
            if (match) controller.resetMatch() else controller.resetGame()
            Telemetry.capture("tracker_reset", mapOf("scope" to if (match) "match" else "game",
                "mode" to if (controller.synced) "match" else "local"))
        }
        T1AlertDialog(
            title = if (canResetMatch) "Reset?" else "Reset game $game?",
            onDismiss = { resetting = false },
            body = {
                Text(
                    when {
                        canResetMatch -> "$life Reset match also clears the games ($score)."
                        controller.synced && d.games.isNotEmpty() -> "$life Recorded games stay ($score)."
                        else -> life
                    },
                    fontFamily = T1.mono, color = T1.muted, fontSize = 13.sp,
                )
            },
            confirm = {
                Row {
                    if (canResetMatch) T1TextAction("Reset game") { reset(false) }
                    T1TextAction(if (canResetMatch) "Reset match" else "Reset", color = T1.danger) { reset(canResetMatch) }
                }
            },
            dismiss = { BarAction("Cancel") { resetting = false } },
        )
    }

    if (showHistory) {
        HistoryPanel(
            d,
            onUndo = { controller.undoLast() },
            onReset = { controller.resetGame(); showHistory = false },
            onNewMatch = if (!controller.synced) ({ showHistory = false; newTable() }) else null,
            onReport = if (controller.synced && !d.readOnly) ({ showHistory = false; forceReport = true }) else null,
            onDismiss = { showHistory = false },
        )
    }

    if (picking) {
        T1Menu(
            title = "Who won game $game?",
            items = (if (d.players == 2) {
                listOf(T1MenuItem("Me") { confirming = Winner(me, false) }, T1MenuItem(d.name(them)) { confirming = Winner(them, false) })
            } else {
                d.sides.map { side -> T1MenuItem(d.name(side)) { confirming = Winner(side, false) } }
            }) + T1MenuItem("Draw") { confirming = Winner(null, true) },
            onDismiss = { picking = false },
        )
    }

    confirming?.let { w ->
        val myWins = d.wins(me) + if (!w.draw && w.side == me) 1 else 0
        val theirWins = d.wins(them) + if (!w.draw && w.side == them) 1 else 0
        val draws = d.draws + if (w.draw) 1 else 0
        val who = when {
            w.draw -> "draw"
            d.players > 2 -> "${d.name(w.side ?: 0)} won"
            w.side == me -> "you won"
            else -> "${d.name(them)} won"
        }
        T1AlertDialog(
            title = "Record game $game: $who?",
            onDismiss = { confirming = null },
            body = {
                Text(
                    if (d.players > 2) "Game ${game + 1} starts at ${d.startingLife}."
                    else "Match is $myWins–$theirWins${if (draws > 0) "–$draws" else ""}.",
                    fontFamily = T1.mono, color = T1.muted, fontSize = 13.sp,
                )
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
    if (!d.synced) return if (d.players > 2) "Local game | ${d.players} players" else "Local game"
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

/** Lifetracker Info (73:5617): clock + context, the progress bar, then Record / Options / Reset. */
@Composable
private fun InfoStrip(
    d: TrackerDoc,
    context: String,
    contextColor: Color,
    recordAccent: Boolean,
    busy: Boolean,
    onRecord: () -> Unit,
    onOptions: () -> Unit,
    onReset: () -> Unit,
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
            Box(Modifier.weight(1f)) {
                if (!d.readOnly) StripButton(recordText(d, busy), accent = recordAccent, disabled = !d.canRecord, onClick = { if (!busy) onRecord() })
            }
            StripButton("Options", onClick = onOptions)
            Box(Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
                if (!d.readOnly) StripButton("Reset", onClick = onReset)
            }
        }
    }
}

/** The strip grown to fill the flat half (tabletop) or the right page (book): the round clock large, the match
 *  line, then Record · Options · Reset as full-size targets (contract/foldables-2026-11-10.md). */
@Composable
private fun FoldControls(
    d: TrackerDoc,
    book: Boolean,
    context: String,
    contextColor: Color,
    recordAccent: Boolean,
    busy: Boolean,
    onRecord: () -> Unit,
    onOptions: () -> Unit,
    onReset: () -> Unit,
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
    Column(Modifier.fillMaxSize().background(T1.surface), verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Column(
            Modifier.weight(1f).fillMaxWidth().background(T1.bg).padding(horizontal = 16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
        ) {
            if (remaining != null && tone != null) {
                Text(formatTrackerClock(remaining), color = toneColor(tone), fontFamily = T1.mono, fontSize = 56.sp,
                    fontWeight = FontWeight.SemiBold, maxLines = 1)
            }
            Label(context, color = contextColor)
            Label("Game ${d.currentGame} · ${d.scoreText}", color = T1.muted)
        }
        @Composable
        fun Action(text: String, accent: Boolean, modifier: Modifier, onClick: () -> Unit, disabled: Boolean = false) {
            val interaction = remember { MutableInteractionSource() }
            val pressed by interaction.collectIsPressedAsState()
            Box(
                modifier.background(if (pressed) T1.surface else T1.bg)
                    .clickable(enabled = !disabled, interactionSource = interaction, indication = null, onClick = onClick),
                contentAlignment = Alignment.Center,
            ) { Label(text, color = if (disabled) T1.disabled else if (accent) T1.accent else T1.text) }
        }
        if (book) {
            Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                if (!d.readOnly) Action(recordText(d, busy), recordAccent, Modifier.fillMaxWidth().height(72.dp), { if (!busy) onRecord() }, disabled = !d.canRecord)
                Action("Options", false, Modifier.fillMaxWidth().height(72.dp), onOptions)
                if (!d.readOnly) Action("Reset", false, Modifier.fillMaxWidth().height(72.dp), onReset)
            }
        } else {
            Row(Modifier.fillMaxWidth().height(72.dp), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                if (!d.readOnly) Action(recordText(d, busy), recordAccent, Modifier.weight(1f).fillMaxHeight(), { if (!busy) onRecord() }, disabled = !d.canRecord)
                Action("Options", false, Modifier.weight(1f).fillMaxHeight(), onOptions)
                if (!d.readOnly) Action("Reset", false, Modifier.weight(1f).fillMaxHeight(), onReset)
            }
        }
    }
}

/** "Result in" once the match's result has been submitted: games can't be added after it. */
private fun recordText(d: TrackerDoc, busy: Boolean): String = when {
    busy -> "Saving…"
    d.canRecord -> "Record"
    else -> "Result in"
}

/** Strip Button: a label with a surface fill while pressed. Accent means "the result" (a game was lost). */
@Composable
internal fun StripButton(text: String, accent: Boolean = false, disabled: Boolean = false, onClick: () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val fill by animateColorAsState(if (pressed) T1.surface else T1.bg, tween(150), label = "strip")
    Box(
        Modifier.height(48.dp).background(fill)
            .clickable(enabled = !disabled, interactionSource = interaction, indication = null, onClick = onClick)
            .padding(horizontal = 16.dp),
        contentAlignment = Alignment.Center,
    ) {
        Label(text, color = if (disabled) T1.disabled else if (accent) T1.accent else T1.text)
    }
}

/**
 * Lays a seat out in its player's own frame (width and height swapped for side seats) and turns it to face
 * their edge. Compose turns the touches with the drawing, so the half inside works as if it were upright.
 */
private fun Modifier.seat(seat: TrackerSeat): Modifier = when (seat) {
    TrackerSeat.Bottom -> this
    TrackerSeat.Top -> rotate(180f)
    TrackerSeat.Left, TrackerSeat.Right -> layout { measurable, constraints ->
        val w = constraints.maxWidth
        val h = constraints.maxHeight
        val p = measurable.measure(Constraints.fixed(h, w))
        layout(w, h) { p.placeWithLayer((w - h) / 2, (h - w) / 2) { rotationZ = seat.degrees } }
    }
}

/**
 * One player's half or seat (Figma "Me", Counters=0…3): life, plus up to three counter columns, each with its
 * own top +1 / bottom −1 zones. Swipe down (in this half's own orientation — the rotation carries the touch
 * coordinates with it) opens the counter picker; only Done closes it (swiping up scrolls its rows).
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
    // Seats at a bigger table are a third to a half the size of a two-player half.
    val scale = if (d.players > 2) 0.6f else 1f
    val open by rememberUpdatedState(pickerOpen)
    val setOpen by rememberUpdatedState(onPicker)
    // A pull from the band along the player's far edge (the +1 zones' top strip) opens the picker.
    val pull = { if (!open) setOpen(true) }

    Box(modifier.fillMaxWidth().background(T1.surface)) {
        Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            CounterColumn(
                value = life, label = null, target = (if (counters.isEmpty()) 162f else 120f) * scale, lost = life <= 0,
                enabled = enabled, name = "${d.name(side)} life", modifier = Modifier.weight(1f), onPull = pull,
            ) { onTap(side, "life", it) }
            if (counters.isNotEmpty()) {
                Row(Modifier.weight(1f).fillMaxHeight(), horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    counters.forEach { c ->
                        val value = d.total(game, side, c.id)
                        CounterColumn(
                            value = value, label = c.shortLabel,
                            target = when (counters.size) { 1 -> 80f; 2 -> 64f; else -> 44f } * scale,
                            lost = if (c.id == "poison") value >= 10 else commanderFrom(c.id) != null && value >= TrackerTable.COMMANDER_LOSS,
                            enabled = enabled,
                            name = "${d.name(side)} ${c.label}", modifier = Modifier.weight(1f), onPull = pull,
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
            CounterPicker(d.pickerCounters(side), d.shownCounters(side), onToggle = onToggle, onDone = { onPicker(false) })
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
    onPull: () -> Unit,
    onDelta: (Int) -> Unit,
) {
    BoxWithConstraints(modifier.fillMaxHeight().background(T1.bg)) {
        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            // The seat is turned as a whole, so +1 always runs along the player's far edge, by the pull band.
            TapZone(enabled, "$name +1", Modifier.weight(1f), onPull = onPull) { onDelta(1) }
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
 * Increment Button. A tap fires on release and always counts, however far the finger drifts (a drift past 10 dp
 * used to cancel it, which lost real taps). Only a touch that starts in the pull band along the player's far edge
 * (the +1 zone, `onPull`) and travels toward them opens the counter picker instead. Holding fires after 0.5 s,
 * then every 0.15 s, unless the finger rolled more than 24 dp first. A second finger on the zone is its own tap.
 * The seat is already turned, so positions are in its player's own frame (TrackerSeat.Bottom).
 */
@Composable
private fun TapZone(enabled: Boolean, label: String, modifier: Modifier, onPull: (() -> Unit)? = null, onStep: () -> Unit) {
    val step by rememberUpdatedState(onStep)
    val pull by rememberUpdatedState(onPull)
    var pressed by remember { mutableStateOf(false) }
    val fill by animateColorAsState(if (pressed) T1.surface else T1.bg, tween(150), label = "zone")
    val density = LocalDensity.current
    val bandPx = with(density) { TrackerTouch.BAND_DP.dp.toPx() }
    val swipePx = with(density) { TrackerTouch.SWIPE_DP.dp.toPx() }
    val holdSlopPx = with(density) { TrackerTouch.HOLD_SLOP_DP.dp.toPx() }
    val movedPx = with(density) { TrackerTouch.MOVED_DP.dp.toPx() }
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
                            val seat = TrackerSeat.Bottom
                            val band = pull != null && TrackerTouch.inBand(seat, down.position.x, down.position.y,
                                size.width.toFloat(), size.height.toFloat(), bandPx)
                            var held = false
                            var rolled = false
                            var moved = false
                            var pulled = false
                            var lifted = false
                            val repeat = launch {
                                delay(500)
                                held = true
                                TrackerTouchStats.holds++
                                while (isActive) {
                                    step()
                                    delay(150)
                                }
                            }
                            while (true) {
                                val event = awaitPointerEvent()
                                // Another finger that landed here and lifts is a tap of its own.
                                event.changes.forEach { c ->
                                    if (c.id != down.id && c.previousPressed && !c.pressed) {
                                        TrackerTouchStats.taps++
                                        step()
                                    }
                                }
                                if (!lifted) {
                                    val change = event.changes.firstOrNull { it.id == down.id }
                                    if (change == null || !change.pressed) {
                                        lifted = true
                                        repeat.cancel()
                                        pressed = false
                                        if (change != null && !held && !pulled) {
                                            TrackerTouchStats.taps++
                                            if (moved) TrackerTouchStats.moved++
                                            if (band) TrackerTouchStats.bandTaps++
                                            step()
                                        }
                                    } else if (!held && !pulled) {
                                        val dx = change.position.x - down.position.x
                                        val dy = change.position.y - down.position.y
                                        if (!moved && kotlin.math.hypot(dx, dy) > movedPx) moved = true
                                        if (!rolled && !TrackerTouch.holds(dx, dy, holdSlopPx)) {
                                            rolled = true
                                            repeat.cancel()
                                        }
                                        if (band && seat.opensPicker(dx, dy, swipePx)) {
                                            pulled = true
                                            repeat.cancel()
                                            pressed = false
                                            TrackerTouchStats.pulls++
                                            pull?.invoke()
                                        }
                                    }
                                }
                                if (event.changes.none { it.pressed }) break
                            }
                            repeat.cancel()
                            pressed = false
                        }
                    }
                }
            },
    )
}

/** Counter Picker: which counters this side shows, three at most; commander damage from each opponent first. */
@Composable
private fun CounterPicker(all: List<CounterKind>, shown: List<CounterKind>, onToggle: (String) -> Unit, onDone: () -> Unit) {
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
                all.forEach { c ->
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
                    Section(if (d.players > 2) "Games · ${d.scoreText}" else "Match ${d.scoreText}")
                    if (!d.readOnly) ListRow("Reset game", onClick = onReset)
                    onNewMatch?.let { ListRow("New match", detail = "${d.players} · ${d.startingLife}", onClick = it) }
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
            "${d.name(g.side)} · ${d.label(g.counter)} ${signed(g.delta)} → ${g.after}",
            Modifier.weight(1f), color = T1.text, fontFamily = T1.mono, fontSize = 13.sp,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
        Label(listOfNotNull(time, by).joinToString(" · "))
    }
}
