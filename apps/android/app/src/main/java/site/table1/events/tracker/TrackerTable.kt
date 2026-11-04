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
