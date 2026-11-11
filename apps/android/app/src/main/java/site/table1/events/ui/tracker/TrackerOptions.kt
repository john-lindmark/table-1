package site.table1.events.ui.tracker

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameMillis
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import site.table1.events.tracker.Chooser
import site.table1.events.tracker.Dice
import site.table1.events.tracker.TrackerTable
import site.table1.events.ui.components.Bar
import site.table1.events.ui.components.BigAction
import site.table1.events.ui.components.T1FullScreenDialog
import site.table1.events.ui.components.Ghost
import site.table1.events.ui.components.Label
import site.table1.events.ui.components.T1Overlay
import site.table1.events.ui.components.sheetInsets
import site.table1.events.ui.components.T1Screen
import site.table1.events.ui.components.T1Segmented
import site.table1.events.ui.components.T1Stepper
import site.table1.events.ui.theme.T1
import site.table1.events.util.Telemetry
import kotlin.math.roundToInt

/** Swallows taps so they don't fall through to the scrim. */
@Composable
private fun Modifier.absorbTaps(): Modifier =
    clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}

/** Options (Figma 231:9191), rising from the bottom: Chooser, Roll dice, History, Leave tracker. Each row closes it first. */
@Composable
internal fun TrackerOptionsPanel(
    onDismiss: () -> Unit,
    onChooser: () -> Unit,
    onDice: () -> Unit,
    onHistory: () -> Unit,
    onNewMatch: (() -> Unit)? = null,
    onLeave: () -> Unit,
) {
    T1Overlay(onDismiss) {
        Column(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().absorbTaps().background(T1.bg)
                .sheetInsets().padding(start = 16.dp, top = 16.dp, end = 16.dp, bottom = 30.dp),
        ) {
            listOfNotNull("Chooser" to onChooser, "Roll dice" to onDice, "History" to onHistory,
                onNewMatch?.let { "New match" to it }, "Leave tracker" to onLeave)
                .forEach { (title, run) ->
                    Box(
                        Modifier.fillMaxWidth().clickable { onDismiss(); run() }.padding(horizontal = 8.dp, vertical = 16.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(title.uppercase(), color = T1.disabled, fontFamily = T1.mono, fontSize = 12.sp,
                            letterSpacing = 1.5.sp, lineHeight = 18.sp, textAlign = TextAlign.Center)
                    }
                }
        }
    }
}

/**
 * Pick a die and how many, then Roll: the total in accent (the result), each die under it. Tapping the total
 * rolls again. The choice of die is remembered on this device.
 */
@Composable
internal fun TrackerDicePanel(onDismiss: () -> Unit) {
    val prefs = LocalContext.current.getSharedPreferences("tracker", 0)
    var sides by remember { mutableIntStateOf(prefs.getInt("dice.sides", 20).takeIf { it in Dice.sides } ?: 20) }
    var count by remember { mutableIntStateOf(prefs.getInt("dice.count", 1).coerceIn(1, Dice.MAX_COUNT)) }
    var rolls by remember { mutableStateOf<List<Int>>(emptyList()) }
    var rolledAs by remember { mutableStateOf<Pair<Int, Int>?>(null) }
    val haptics = LocalHapticFeedback.current

    fun roll() {
        rolls = Dice.roll(sides, count)
        rolledAs = sides to rolls.size
        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
        Telemetry.capture("tracker_dice_rolled", mapOf("sides" to sides, "count" to rolls.size))
    }

    val caption = rolledAs?.let { (s, n) ->
        listOfNotNull((if (n > 1) "$n" else "") + "D$s", Dice.breakdown(rolls)).joinToString(" · ")
    } ?: "Tap roll"

    T1Overlay(onDismiss) {
        Column(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().absorbTaps().background(T1.surface).sheetInsets(),
            verticalArrangement = Arrangement.spacedBy(1.dp),
        ) {
            Row(Modifier.fillMaxWidth().background(T1.bg), verticalAlignment = Alignment.CenterVertically) {
                Label("Roll dice", Modifier.weight(1f).padding(start = 16.dp), color = T1.disabled)
                StripButton("Done", onClick = onDismiss)
            }
            Column(
                Modifier.fillMaxWidth().height(180.dp).background(T1.bg).clickable { roll() },
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically),
            ) {
                Text(
                    if (rolls.isEmpty()) "–" else "${rolls.sum()}",
                    color = if (rolls.isEmpty()) T1.disabled else T1.accent,
                    fontFamily = T1.mono, fontWeight = FontWeight.SemiBold, fontSize = 96.sp, letterSpacing = (-2.4).sp,
                    lineHeight = 96.sp,
                )
                Label(caption, color = T1.disabled)
            }
            T1Segmented(Dice.sides.map { "D$it" }, Dice.sides.indexOf(sides)) {
                sides = Dice.sides[it]
                prefs.edit().putInt("dice.sides", sides).apply()
            }
            T1Stepper("Dice", count, 1..Dice.MAX_COUNT, Modifier.fillMaxWidth()) {
                count = it
                prefs.edit().putInt("dice.count", it).apply()
            }
            BigAction("Roll") { roll() }
        }
    }
}

/**
 * Covers the screen. Everyone puts a finger down; when the fingers have stayed put for two seconds one is
 * picked at random and turns accent, and the tracker comes back [Chooser.RETURN_MS] later (Done leaves sooner).
 * A full-screen dialog drawn edge to edge like the app's other full-screen screens, with Done padded for the
 * system bars. In a popup John saw no Done and left only with the back gesture (cause not found).
 */
@Composable
internal fun TrackerChooser(onDismiss: () -> Unit) {
    var chooser by remember { mutableStateOf(Chooser()) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    val haptics = LocalHapticFeedback.current
    val waiting = !chooser.picked && chooser.fingers.size >= Chooser.MIN_FINGERS

    LaunchedEffect(Unit) { Telemetry.capture("tracker_chooser_opened") }
    LaunchedEffect(waiting) {
        while (waiting) {
            withFrameMillis { }
            now = System.currentTimeMillis()
            chooser = chooser.tick(now)
            if (chooser.picked) break
        }
    }
    LaunchedEffect(chooser.picked) {
        if (!chooser.picked) return@LaunchedEffect
        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
        Telemetry.capture("tracker_chooser_picked", mapOf("fingers" to chooser.fingers.size))
        delay(Chooser.RETURN_MS)
        onDismiss()
    }

    T1FullScreenDialog(onDismissRequest = onDismiss) {
        Box(
            Modifier.fillMaxSize().background(T1.bg).pointerInput(Unit) {
                awaitPointerEventScope {
                    while (true) {
                        val event = awaitPointerEvent()
                        val t = System.currentTimeMillis()
                        for (c in event.changes) {
                            val id = c.id.value
                            chooser = when {
                                c.pressed && !c.previousPressed -> chooser.down(id, c.position.x, c.position.y, t)
                                !c.pressed && c.previousPressed -> chooser.up(id, t)
                                c.pressed -> chooser.move(id, c.position.x, c.position.y)
                                else -> chooser
                            }
                            c.consume()
                        }
                    }
                }
            },
        ) {
            val progress = chooser.progress(now) ?: 0f
            chooser.fingers.forEach { f ->
                val state = when (chooser.winner) {
                    null -> 0
                    f.id -> 1
                    else -> 2
                }
                FingerMark(f.x, f.y, state, progress)
            }
            if (!chooser.picked && chooser.fingers.size < Chooser.MIN_FINGERS) {
                Label(
                    if (chooser.fingers.isEmpty()) "Everyone put a finger down" else "One more finger",
                    Modifier.align(Alignment.Center), color = T1.disabled,
                )
            }
            Box(Modifier.align(Alignment.BottomCenter).navigationBarsPadding()) { StripButton("Done", onClick = onDismiss) }
        }
    }
}

/** A ring around a waiting finger closing over the two seconds; the pick filled in accent, the others grey. */
@Composable
private fun FingerMark(x: Float, y: Float, state: Int, progress: Float) {
    val size by animateDpAsState(if (state == 1) 132.dp else 96.dp, tween(200), label = "finger")
    val half = with(LocalDensity.current) { size.toPx() / 2 }
    Canvas(Modifier.offset { IntOffset((x - half).roundToInt(), (y - half).roundToInt()) }.size(size)) {
        val stroke = Stroke(width = 2.dp.toPx())
        val inset = Offset(stroke.width / 2, stroke.width / 2)
        val ring = androidx.compose.ui.geometry.Size(this.size.width - stroke.width, this.size.height - stroke.width)
        when (state) {
            1 -> drawCircle(T1.accent)
            2 -> drawArc(T1.disabled, 0f, 360f, false, inset, ring, style = stroke)
            else -> {
                drawArc(T1.surface, 0f, 360f, false, inset, ring, style = stroke)
                drawArc(T1.text, -90f, 360f * progress, false, inset, ring, style = stroke)
            }
        }
    }
}

/**
 * A local tracker's first screen (contract/life-tracker-commander-2026-11-03.md): how many players and their
 * starting life, then Start (the chooser opens next). Continue reopens the saved table as it was.
 */
@Composable
internal fun TrackerSetup(
    initial: Pair<Int, Int>,
    canContinue: Boolean,
    onStart: (players: Int, life: Int) -> Unit,
    onContinue: () -> Unit,
    onClose: () -> Unit,
) {
    var players by remember { mutableIntStateOf(initial.first) }
    var life by remember { mutableIntStateOf(initial.second) }
    T1Screen {
        Bar("Life tracker", onBack = onClose)
        Column(Modifier.fillMaxWidth().background(T1.bg).padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Label("Players", color = T1.disabled)
            T1Segmented(TrackerTable.playerChoices.map { "$it" }, TrackerTable.playerChoices.indexOf(players)) {
                players = TrackerTable.playerChoices[it]
            }
        }
        Column(Modifier.fillMaxWidth().background(T1.bg).padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Label("Starting life", color = T1.disabled)
            T1Segmented(TrackerTable.lifeChoices.map { "$it" }, TrackerTable.lifeChoices.indexOf(life)) {
                life = TrackerTable.lifeChoices[it]
            }
        }
        Spacer(Modifier.weight(1f))
        if (canContinue) Row { Ghost("Continue", onClick = onContinue) }
        BigAction("Start") { onStart(players, life) }
    }
}
