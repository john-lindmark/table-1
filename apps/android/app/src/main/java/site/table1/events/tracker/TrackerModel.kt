package site.table1.events.tracker

import kotlinx.serialization.Serializable
import site.table1.events.data.TrackerClock
import site.table1.events.data.TrackerGame
import site.table1.events.data.TrackerOp
import java.time.Instant
import java.time.OffsetDateTime
import java.util.UUID

/*
 * Life tracker rules (contract §5). Everything is derived from an append-only list of ops:
 * totals = starting value + sum of deltas for the game; history groups are computed for display only.
 */

data class CounterKind(val id: String, val label: String, val min: Int?, val max: Int?) {
    /** Column label; "Experience" doesn't fit a narrow column. */
    val shortLabel: String get() = if (id == "experience") "Exp" else label
}

val trackerCounters = listOf(
    CounterKind("poison", "Poison", 0, null),
    CounterKind("energy", "Energy", 0, null),
    CounterKind("experience", "Experience", 0, null),
    CounterKind("rad", "Rad", 0, null),
    CounterKind("speed", "Speed", 0, 4),
)

fun counterLabel(id: String): String = if (id == "life") "Life" else trackerCounters.firstOrNull { it.id == id }?.label ?: id

/** Counters shown as columns next to life, per side. */
const val MAX_COUNTERS = 3

/**
 * Which counters one side shows: turned on, or turned off (which hides a non-zero one). A per-device
 * display choice, saved with the session.
 */
@Serializable
data class CounterPrefs(val on: List<String> = emptyList(), val off: List<String> = emptyList())

/* ── round clock ──────────────────────────────────────────────────────────────── */

enum class ClockTone { Normal, Warning, Overtime }

/** The tracker turns the clock amber for the last 10 minutes (the organizer screen keeps its own threshold). */
const val TRACKER_WARN_SECONDS = 600

fun TrackerClock.remaining(nowMillis: Long): Int {
    val base = timerRemainingAtChange ?: timerDurationSeconds
    val started = timerLastStartedAt?.let { parseTapped(it) }?.takeIf { it > 0 }
    return if (timerStatus == "running" && started != null) base - Math.floorDiv(nowMillis - started, 1000L).toInt() else base
}

fun clockTone(remaining: Int): ClockTone = when {
    remaining < 0 -> ClockTone.Overtime
    remaining <= TRACKER_WARN_SECONDS -> ClockTone.Warning
    else -> ClockTone.Normal
}

/** "42:52", "6:12", "+0:42" in overtime. */
fun formatTrackerClock(remaining: Int): String {
    val a = kotlin.math.abs(remaining)
    val text = "${a / 60}:${(a % 60).toString().padStart(2, '0')}"
    return if (remaining < 0) "+$text" else text
}

/** Share of the bar to fill: time left over the round length; full in overtime. */
fun TrackerClock.progress(remaining: Int): Float = when {
    remaining < 0 -> 1f
    timerDurationSeconds > 0 -> (remaining.toFloat() / timerDurationSeconds).coerceAtMost(1f)
    else -> 0f
}

/** Consecutive taps on the same side + counter, each < 2 s after the previous one. */
const val GROUP_WINDOW_MS = 2_000L

/** One history entry. */
data class ChangeGroup(
    val gameNo: Int,
    val side: Int,
    val counter: String,
    val delta: Int,
    /** The counter's value after this group. */
    val after: Int,
    val startMillis: Long,
    val endMillis: Long,
    /** tapped_at of the group's latest tap, verbatim (an undo's inverse op reuses it). */
    val lastTappedAt: String,
    val opIds: List<String>,
    val mine: Boolean,
)

/** Persisted tracker session: local ("local") or synced to a match ("match:<id>"). */
@Serializable
data class TrackerDoc(
    val key: String,
    val synced: Boolean = false,
    val sessionId: String? = null,
    val matchId: String? = null,
    val eventId: String? = null,
    val eventName: String? = null,
    val round: Int? = null,
    val table: Int? = null,
    val clock: TrackerClock? = null,
    /**
     * 0 or 1; null = organizer watching (read-only, side 0 at the bottom). Local sessions: 0.
     * Defaults to null because the app's Json drops nulls on save (explicitNulls = false).
     */
    val mySide: Int? = null,
    val names: List<String> = listOf("You", "Opponent"),
    val startingLife: Int = 20,
    val games: List<TrackerGame> = emptyList(),
    val ops: List<TrackerOp> = emptyList(),
    /** client_op_ids the server hasn't accepted yet (synced only). */
    val pending: List<String> = emptyList(),
    /** Number of recorded games when the "report / match result" prompt was last answered. */
    val promptedAt: Int = 0,
    /** Counter columns per side (index = side). */
    val counterPrefs: List<CounterPrefs> = listOf(CounterPrefs(), CounterPrefs()),
) {
    val readOnly: Boolean get() = synced && mySide == null
    val bottomSide: Int get() = mySide ?: 0
    val topSide: Int get() = 1 - bottomSide
    val currentGame: Int get() = games.size + 1

    fun name(side: Int): String = names.getOrNull(side)?.takeIf { it.isNotBlank() } ?: if (side == bottomSide) "You" else "Opponent"

    fun wins(side: Int): Int = games.count { !it.isDraw && it.winnerSide == side }
    val draws: Int get() = games.count { it.isDraw }

    /** Someone has 2 game wins, or 3 games have been played. */
    val decided: Boolean get() = wins(0) >= 2 || wins(1) >= 2 || games.size >= 3

    /** One game's ops in tap order: sorted by tapped_at, ties kept in insertion order (stable sort). */
    fun opsFor(game: Int): List<TrackerOp> = ops.filter { it.gameNo == game }.sortedBy { opMillis(it) }

    fun total(game: Int, side: Int, counter: String): Int {
        val base = if (counter == "life") startingLife else 0
        return base + ops.sumOf { if (it.gameNo == game && it.side == side && it.counter == counter) it.delta else 0 }
    }

    /**
     * Every change group of one game, oldest first, including groups an undo cancelled (net 0).
     * An undo's inverse op carries the group's last tap time, so it sorts right after the group and joins it.
     */
    fun allGroups(game: Int): List<ChangeGroup> {
        val running = HashMap<Pair<Int, String>, Int>()
        val out = ArrayList<ChangeGroup>()
        opsFor(game).forEach { o ->
            val key = o.side to o.counter
            val value = (running[key] ?: if (o.counter == "life") startingLife else 0) + o.delta
            running[key] = value
            val t = opMillis(o)
            val last = out.lastOrNull()
            if (last != null && last.side == o.side && last.counter == o.counter && t - last.endMillis < GROUP_WINDOW_MS) {
                // An inverse op stamped with the group's last tap keeps that tap as the group's end.
                val newer = t >= last.endMillis
                out[out.size - 1] = last.copy(
                    delta = last.delta + o.delta, after = value,
                    endMillis = if (newer) t else last.endMillis,
                    lastTappedAt = if (newer) o.tappedAt else last.lastTappedAt,
                    opIds = last.opIds + o.clientOpId, mine = last.mine && o.mine,
                )
            } else {
                out += ChangeGroup(game, o.side, o.counter, o.delta, value, t, t, o.tappedAt, listOf(o.clientOpId), o.mine)
            }
        }
        return out
    }

    /** History for one game, oldest first: groups whose net change is 0 (undone) are hidden. */
    fun groups(game: Int): List<ChangeGroup> = allGroups(game).filter { it.delta != 0 }

    /** The group still collecting taps (last tap < 2 s ago), if any. */
    fun openGroup(nowMillis: Long): ChangeGroup? =
        groups(currentGame).lastOrNull()?.takeIf { nowMillis - it.endMillis < GROUP_WINDOW_MS }

    /** Undo last: inverse op(s) for the newest non-zero group of the current game, stamped with its last tap time. */
    fun undoLastOps(): List<TrackerOp> {
        val group = groups(currentGame).lastOrNull() ?: return emptyList()
        return inverse(group)
    }

    /** Synced "Reset game": one inverse per non-zero group of the current game, each at that group's last tap time. */
    fun resetOps(): List<TrackerOp> = groups(currentGame).flatMap { inverse(it) }

    /** Fresh random ids; the server allows |delta| ≤ 999 per op, so very large nets are split. */
    private fun inverse(group: ChangeGroup): List<TrackerOp> {
        val out = ArrayList<TrackerOp>()
        var remaining = -group.delta
        while (remaining != 0) {
            val chunk = remaining.coerceIn(-999, 999)
            out += TrackerOp(UUID.randomUUID().toString(), group.gameNo, group.side, group.counter, chunk, group.lastTappedAt, mine = true)
            remaining -= chunk
        }
        return out
    }

    /**
     * Columns next to life: counters turned on, plus any that aren't zero (so poison you dealt shows on the
     * other phone) unless turned off. Three at most.
     */
    fun shownCounters(side: Int): List<CounterKind> {
        val p = counterPrefs.getOrNull(side) ?: CounterPrefs()
        return trackerCounters.filter {
            it.id in p.on || (total(currentGame, side, it.id) != 0 && it.id !in p.off)
        }.take(MAX_COUNTERS)
    }

    fun withCounterToggled(side: Int, id: String): TrackerDoc {
        val prefs = counterPrefs.toMutableList().also { while (it.size < 2) it += CounterPrefs() }
        val p = prefs[side]
        val shown = shownCounters(side).map { it.id }
        prefs[side] = when {
            id in shown -> CounterPrefs(on = p.on - id, off = p.off - id + id)
            shown.size >= MAX_COUNTERS -> return this
            else -> CounterPrefs(on = p.on - id + id, off = p.off - id)
        }
        return copy(counterPrefs = prefs)
    }

    /** "Marcus is at 0 — record game 2?" for the first side that has lost, with the winner side. */
    fun loseCondition(): Pair<String, Int>? {
        val g = currentGame
        for (side in listOf(topSide, bottomSide)) {
            val life = total(g, side, "life")
            val poison = total(g, side, "poison")
            if (life <= 0) return "${name(side)} is at $life — record game $g?" to (1 - side)
            if (poison >= 10) return "${name(side)} has $poison poison — record game $g?" to (1 - side)
        }
        return null
    }

    companion object {
        fun newOp(game: Int, side: Int, counter: String, delta: Int): TrackerOp =
            TrackerOp(UUID.randomUUID().toString(), game, side, counter, delta, Instant.now().toString(), mine = true)
    }
}

/** Server timestamps ("2026-10-12T01:47:38.449639+00:00") and local ones ("…Z") → epoch millis. */
fun opMillis(op: TrackerOp): Long = parseTapped(op.tappedAt)

fun parseTapped(s: String): Long =
    runCatching { OffsetDateTime.parse(s).toInstant().toEpochMilli() }.getOrNull()
        ?: runCatching { Instant.parse(s).toEpochMilli() }.getOrNull()
        ?: runCatching {
            // Postgres text form: "2026-10-12 01:47:38.449639+00"
            val iso = s.replace(' ', 'T').let { if (Regex("[+-]\\d\\d$").containsMatchIn(it)) "$it:00" else it }
            OffsetDateTime.parse(iso).toInstant().toEpochMilli()
        }.getOrNull()
        ?: 0L

fun signed(n: Int): String = if (n > 0) "+$n" else if (n < 0) "−${-n}" else "0"
