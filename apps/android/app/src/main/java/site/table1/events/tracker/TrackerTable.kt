package site.table1.events.tracker

/*
 * The table a local life tracker is set up for (contract/life-tracker-commander-2026-11-03.md): 2–5 players,
 * their starting life, where each sits around the phone, and commander damage. Same rules as iOS
 * TrackerTable.swift and web trackerTable.ts, checked against testdata/tracker-table/cases.json.
 */

/** Each seat faces its own edge: Bottom reads normally, Top is turned 180°, Left 90° clockwise, Right 90° back. */
enum class TrackerSeat(val degrees: Float) {
    Bottom(0f), Top(180f), Left(90f), Right(-90f);

    val sideways: Boolean get() = this == Left || this == Right

    /** A drag in screen pixels, measured toward the player (their "down") and across. */
    fun toward(dx: Float, dy: Float): Pair<Float, Float> = when (this) {
        Bottom -> dy to dx
        Top -> -dy to dx
        Left -> -dx to dy
        Right -> dx to dy
    }

    /**
     * A swipe toward the player opens their counter picker. No swipe closes it, only Done: swiping away is also
     * how the picker's rows scroll (commander damage made the list long).
     */
    fun opensPicker(dx: Float, dy: Float, minPx: Float): Boolean {
        val (down, across) = toward(dx, dy)
        return down >= minPx && down > kotlin.math.abs(across) * 1.5f
    }

    /** How far a point in a box (screen pixels, origin top-left) is from this player's far edge, their "top". */
    fun far(x: Float, y: Float, w: Float, h: Float): Float = when (this) {
        Bottom -> y
        Top -> h - y
        Left -> w - x
        Right -> x
    }
}

/**
 * The touch rule (contract/life-tracker-options-2026-10-20.md § Taps and the pull band, cases
 * testdata/tracker-touch/cases.json): a tap on a +1 / −1 zone always counts, however far it drifts; only a touch
 * that starts in the pull band along the player's far edge and travels toward them opens the counter picker.
 * Distances are dp; pass pixels with the same density to every call.
 */
object TrackerTouch {
    /** The pull band's depth from the player's far edge. */
    const val BAND_DP = 44f
    /** Travel toward the player that opens the picker. */
    const val SWIPE_DP = 24f
    /** Travel before the hold delay that makes a touch a rolled tap, not a hold (no repeat). */
    const val HOLD_SLOP_DP = 24f
    /** The old cancel distance: telemetry counts the taps that travelled past it (they used to be lost). */
    const val MOVED_DP = 10f

    fun inBand(seat: TrackerSeat, x: Float, y: Float, w: Float, h: Float, bandPx: Float): Boolean = seat.far(x, y, w, h) <= bandPx

    fun pulls(seat: TrackerSeat, x: Float, y: Float, w: Float, h: Float, dx: Float, dy: Float, bandPx: Float, swipePx: Float): Boolean =
        inBand(seat, x, y, w, h, bandPx) && seat.opensPicker(dx, dy, swipePx)

    fun holds(dx: Float, dy: Float, slopPx: Float): Boolean = kotlin.math.hypot(dx, dy) <= slopPx
}

/**
 * What the tracker's touches did while it was open, sent as `tracker_touches` when it closes or goes to the
 * background: taps, taps that travelled past the old 10 dp cancel (`moved`), pulls that opened the picker, holds.
 * Main thread only.
 */
object TrackerTouchStats {
    var taps = 0
    var moved = 0
    var pulls = 0
    var holds = 0
    var bandTaps = 0

    /** The event's properties, or null when nothing was touched; resets the counts. */
    fun take(players: Int, mode: String): Map<String, Any>? {
        val out = if (taps + pulls > 0) {
            mapOf("taps" to taps, "moved" to moved, "pulls" to pulls, "holds" to holds, "band_taps" to bandTaps,
                "players" to players, "mode" to mode)
        } else null
        taps = 0; moved = 0; pulls = 0; holds = 0; bandTaps = 0
        return out
    }
}

data class TrackerPlace(val side: Int, val seat: TrackerSeat)

/** A row of seats, or the info strip (null). */
typealias TrackerRow = List<TrackerPlace>?

object TrackerTable {
    val playerChoices = listOf(2, 3, 4, 5)
    val lifeChoices = listOf(20, 30, 40)
    /** Commander damage counts from this starting life (Commander 40, Pauper Commander 30; Oathbreaker is 20). */
    const val COMMANDER_FROM = 30
    /** Commander damage from one opponent that loses the game. */
    const val COMMANDER_LOSS = 21

    /** Rows top to bottom on screen; seats go clockwise from the bottom. */
    fun layout(players: Int): List<TrackerRow> = when (players) {
        3 -> listOf(listOf(TrackerPlace(1, TrackerSeat.Left), TrackerPlace(2, TrackerSeat.Right)), null,
            listOf(TrackerPlace(0, TrackerSeat.Bottom)))
        4 -> listOf(listOf(TrackerPlace(1, TrackerSeat.Left), TrackerPlace(2, TrackerSeat.Right)), null,
            listOf(TrackerPlace(0, TrackerSeat.Left), TrackerPlace(3, TrackerSeat.Right)))
        5 -> listOf(listOf(TrackerPlace(2, TrackerSeat.Left), TrackerPlace(3, TrackerSeat.Right)),
            listOf(TrackerPlace(1, TrackerSeat.Left), TrackerPlace(4, TrackerSeat.Right)), null,
            listOf(TrackerPlace(0, TrackerSeat.Bottom)))
        else -> listOf(listOf(TrackerPlace(1, TrackerSeat.Top)), null, listOf(TrackerPlace(0, TrackerSeat.Bottom)))
    }

    fun names(players: Int): List<String> = if (players <= 2) listOf("You", "Opponent") else (1..players).map { "P$it" }
}

/** `cmd:<side>` → the side whose commander dealt the damage, else null. */
fun commanderFrom(id: String): Int? =
    if (id.startsWith("cmd:")) id.removePrefix("cmd:").toIntOrNull()?.takeIf { it >= 0 } else null
