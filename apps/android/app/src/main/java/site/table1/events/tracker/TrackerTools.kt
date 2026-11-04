package site.table1.events.tracker

import kotlin.random.Random

/** Roll dice from the tracker's Options (iOS TrackerTools.swift). Pure, so tests can pass a seeded Random. */
object Dice {
    val sides = listOf(4, 6, 8, 10, 12, 20)
    const val MAX_COUNT = 10

    /** [count] dice of [sides] faces, each 1…sides. Count is clamped to 1…MAX_COUNT. */
    fun roll(sides: Int, count: Int, random: Random = Random.Default): List<Int> {
        val faces = sides.coerceAtLeast(2)
        return List(count.coerceIn(1, MAX_COUNT)) { random.nextInt(1, faces + 1) }
    }

    /** "3 + 5 + 1"; nothing for a single die (the total says it). */
    fun breakdown(rolls: List<Int>): String? = if (rolls.size > 1) rolls.joinToString(" + ") else null
}

/**
 * The chooser: everyone puts a finger on the screen; once the fingers on it have stayed the same for
 * [SETTLE_MS] (two or more of them), one is picked at random. It stays picked until every finger lifts;
 * fingers that land after the pick are ignored until then.
 */
data class Chooser(
    val fingers: List<Finger> = emptyList(),
    /** When the set of fingers last changed (landed or lifted); moving one doesn't count. */
    val changedAt: Long? = null,
    val winner: Long? = null,
    /** After the pick every circle stays drawn until the last finger lifts; these are the ones still down. */
    val pressed: Set<Long> = emptySet(),
) {
    data class Finger(val id: Long, val x: Float, val y: Float)

    val picked: Boolean get() = winner != null

    fun down(id: Long, x: Float, y: Float, now: Long): Chooser =
        if (picked || fingers.any { it.id == id }) this
        else copy(fingers = fingers + Finger(id, x, y), pressed = pressed + id, changedAt = now)

    fun move(id: Long, x: Float, y: Float): Chooser =
        if (fingers.none { it.id == id }) this
        else copy(fingers = fingers.map { if (it.id == id) Finger(id, x, y) else it })

    fun up(id: Long, now: Long): Chooser {
        if (id !in pressed) return this
        val stillDown = pressed - id
        if (picked) return if (stillDown.isEmpty()) Chooser() else copy(pressed = stillDown)
        val left = fingers.filter { it.id != id }
        return copy(fingers = left, pressed = stillDown, changedAt = if (left.isEmpty()) null else now)
    }

    /** Share of the settle time gone (0…1) while waiting to pick; null when there aren't enough fingers. */
    fun progress(now: Long): Float? {
        if (picked || fingers.size < MIN_FINGERS || changedAt == null) return null
        return ((now - changedAt).toFloat() / SETTLE_MS).coerceIn(0f, 1f)
    }

    /** Picks once the fingers have settled; the same state back when it's not time yet. */
    fun tick(now: Long, random: Random = Random.Default): Chooser {
        val p = progress(now) ?: return this
        if (p < 1f) return this
        return copy(winner = fingers.random(random).id)
    }

    companion object {
        const val SETTLE_MS = 2_000L
        const val MIN_FINGERS = 2
        /** After the pick the tracker comes back on its own this much later. */
        const val RETURN_MS = 1_500L
    }
}
