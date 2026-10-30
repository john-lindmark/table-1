package site.table1.events.roto

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

/* Roto (rotisserie) cube drafts (contract/roto-2026-10-16.md): wire shapes from roto_state and friends, and the pure
   turn maths the screens need. The server decides whose turn it is; the client only predicts it for display ("YOU PICK
   IN 3") with the same formula as t1_private.roto_seat_index. Same as iOS RotoModel.swift and web rotoMath.ts. */

data class RotoClockRange(val fromRound: Int, val seconds: Int)

/** `[pick_no, seat, slot, how, at]`. `seat` is 1-based pick order; `how` is player | auto | timeout | organizer. */
data class RotoPick(val pickNo: Int, val seat: Int, val slot: Int, val how: String = "player", val at: Double = 0.0) {
    /** Picked by the server from the player's list (their turn came, or their clock ran out). */
    val automatic get() = how == "auto" || how == "timeout"
}

/** `[slot, card_id, finish]`: one copy in the snapshot of the cube. */
data class RotoPoolCard(val slot: Int, val cardId: String, val finish: String = "nonfoil")

data class RotoDraftInfo(
    val picksPerPlayer: Int = 45, val pickOrder: String = "snake", val players: Int = 0, val poolCount: Int = 0, val picksMade: Int = 0,
    val totalPicks: Int? = null, val sourceListId: String? = null, val clock: List<RotoClockRange>? = null, val clockPaused: Boolean = false,
    val startedAt: Double? = null, val finishedAt: Double? = null,
) {
    val snake get() = pickOrder != "fixed"
    val total get() = totalPicks ?: (players * picksPerPlayer)
}

data class RotoOnClock(
    val participantId: String, val seat: Int = 0, val pickNo: Int = 0, val round: Int = 1, val turnStartedAt: Double? = null,
    val turnSeconds: Int? = null, val remainingSeconds: Int? = null, val deadline: Double? = null, val overdue: Boolean = false,
)

data class RotoSeat(val seat: Int?, val participantId: String, val displayName: String, val account: Boolean = true, val me: Boolean = false)

data class RotoMe(val participantId: String, val seat: Int?, val queue: List<Int> = emptyList(), val autoPick: Boolean = true, val deckListId: String? = null)

/** roto_state (and the state inside roto_pick / roto_undo / roto_set_clock / roto_start answers). */
data class RotoState(
    val eventId: String, val phase: String = "setup", val draft: RotoDraftInfo = RotoDraftInfo(), val onClock: RotoOnClock? = null,
    val seats: List<RotoSeat> = emptyList(), val picks: List<RotoPick> = emptyList(), val pool: List<RotoPoolCard>? = null, val me: RotoMe? = null,
)

data class RotoPickResult(val ok: Boolean, val conflict: Boolean, val state: RotoState)
data class RotoQueueResult(val queue: List<Int>, val autoPick: Boolean, val picksMade: Int)
data class RotoCubeResult(val eventId: String, val sourceListId: String?, val cubeName: String?, val poolCount: Int, val players: Int, val maxPicksPerPlayer: Int)

/** Wire → model, leniently: the server's snake_case objects and positional arrays. */
object RotoWire {
    private fun JsonElement?.prim() = (this as? JsonPrimitive)?.takeIf { this !is JsonNull }
    private fun JsonElement?.int(d: Int = 0) = prim()?.let { it.doubleOrNull?.toInt() ?: it.contentOrNull?.toDoubleOrNull()?.toInt() } ?: d
    private fun JsonElement?.intOrNull() = prim()?.let { it.doubleOrNull?.toInt() ?: it.contentOrNull?.toDoubleOrNull()?.toInt() }
    private fun JsonElement?.num() = prim()?.let { it.doubleOrNull ?: it.contentOrNull?.toDoubleOrNull() }
    private fun JsonElement?.str() = prim()?.takeIf { it.isString }?.contentOrNull
    private fun JsonElement?.bool(d: Boolean = false) = prim()?.booleanOrNull ?: d
    private fun JsonElement?.obj() = this as? JsonObject
    private fun JsonElement?.arr() = this as? JsonArray

    fun draft(d: JsonObject?) = RotoDraftInfo(
        picksPerPlayer = d?.get("picks_per_player").int(45), pickOrder = if (d?.get("pick_order").str() == "fixed") "fixed" else "snake",
        players = d?.get("players").int(), poolCount = d?.get("pool_count").int(), picksMade = d?.get("picks_made").int(),
        totalPicks = d?.get("total_picks").intOrNull(), sourceListId = d?.get("source_list_id").str(),
        clock = d?.get("clock").arr()?.mapNotNull { r -> r.obj()?.let { RotoClockRange(it["from_round"].int(1), it["seconds"].int()) } },
        clockPaused = d?.get("clock_paused").bool(), startedAt = d?.get("started_at").num(), finishedAt = d?.get("finished_at").num(),
    )

    fun pick(a: JsonElement): RotoPick? {
        val x = a.arr() ?: return null
        if (x.size < 3) return null
        val how = x.getOrNull(3).str()
        return RotoPick(x[0].int(), x[1].int(), x[2].int(), if (how in setOf("auto", "timeout", "organizer")) how!! else "player", x.getOrNull(4).num() ?: 0.0)
    }

    fun state(s: JsonObject): RotoState {
        val c = s["on_clock"].obj()
        val me = s["me"].obj()
        return RotoState(
            eventId = s["event_id"].str() ?: "",
            phase = s["phase"].str()?.takeIf { it == "drafting" || it == "done" } ?: "setup",
            draft = draft(s["draft"].obj()),
            onClock = c?.get("participant_id").str()?.let { id ->
                RotoOnClock(id, c!!["seat"].int(), c["pick_no"].int(), c["round"].int(1), c["turn_started_at"].num(), c["turn_seconds"].intOrNull(),
                    c["remaining_seconds"].intOrNull(), c["deadline"].num(), c["overdue"].bool())
            },
            seats = s["seats"].arr()?.mapNotNull { e ->
                e.obj()?.let { x -> x["participant_id"].str()?.let { RotoSeat(x["seat"].intOrNull(), it, x["display_name"].str() ?: "Player", x["account"].bool(true), x["me"].bool()) } }
            }.orEmpty(),
            picks = s["picks"].arr()?.mapNotNull(::pick).orEmpty(),
            pool = s["pool"].arr()?.mapNotNull { e -> e.arr()?.takeIf { it.size >= 2 }?.let { RotoPoolCard(it[0].int(), it[1].str() ?: it[1].toString(), it.getOrNull(2).str() ?: "nonfoil") } },
            me = me?.get("participant_id").str()?.let { id ->
                RotoMe(id, me!!["seat"].intOrNull(), me["queue"].arr()?.map { it.int() }.orEmpty(), me["auto_pick"].bool(true), me["deck_list_id"].str())
            },
        )
    }

    fun pickResult(o: JsonObject) = RotoPickResult(o["ok"].bool(), o["conflict"].bool(), state(o["state"]!!.jsonObject))
    fun queue(o: JsonObject) = RotoQueueResult(o["queue"].arr()?.map { it.int() }.orEmpty(), o["auto_pick"].bool(true), o["picks_made"].int())
    fun cube(o: JsonObject) = RotoCubeResult(o["event_id"].str() ?: "", o["source_list_id"].str(), o["cube_name"].str(), o["pool_count"].int(), o["players"].int(),
        o["max_picks_per_player"].int())
}

/** Turn maths (mirrors t1_private.roto_seat_index / roto_round). */
object RotoMath {
    /** 1-based seat on the clock for a pick. Snake reverses every other round. */
    fun seat(players: Int, pickNo: Int, snake: Boolean): Int {
        if (players <= 0 || pickNo <= 0) return 0
        val i = (pickNo - 1) % players
        val backwards = snake && ((pickNo - 1) / players) % 2 == 1
        return if (backwards) players - i else i + 1
    }

    fun round(players: Int, pickNo: Int): Int = if (players <= 0 || pickNo <= 0) 1 else (pickNo - 1) / players + 1

    /** The pick number at (seat, round): the cell of the classic roto sheet. */
    fun pickNo(seat: Int, round: Int, players: Int, snake: Boolean): Int {
        val backwards = snake && (round - 1) % 2 == 1
        val index = if (backwards) players - seat else seat - 1
        return (round - 1) * players + index + 1
    }

    /** Picks other people make before [seat] is next on the clock (0 = it's theirs); null when they have none left. */
    fun picksUntil(seat: Int, picksMade: Int, players: Int, total: Int, snake: Boolean): Int? {
        if (players <= 0 || seat <= 0) return null
        var n = picksMade + 1
        while (n <= total && n <= picksMade + 2 * players) {
            if (seat(players, n, snake) == seat) return n - picksMade - 1
            n++
        }
        return null
    }

    /** Seconds per pick in a round from the schedule (the last range starting at or before it); null = no clock. */
    fun clockSeconds(clock: List<RotoClockRange>?, round: Int) = clock?.filter { it.fromRound <= round }?.maxByOrNull { it.fromRound }?.seconds

    /** "4 h", "1 h 30 min", "45 min", "30 s". */
    fun durationText(seconds: Int): String {
        val h = seconds / 3600; val m = (seconds % 3600) / 60; val s = seconds % 60
        return when {
            h > 0 -> if (m > 0) "$h h $m min" else "$h h"
            m > 0 -> if (s > 0) "$m min $s s" else "$m min"
            else -> "$s s"
        }
    }

    /** "1:42:10", "4:05", "0:09". */
    fun countdownText(seconds: Int): String {
        val s = maxOf(0, seconds); val h = s / 3600; val m = (s % 3600) / 60; val r = s % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, r) else "%d:%02d".format(m, r)
    }

    /** Round robin: n − 1 rounds, or n with a bye each round when odd. */
    fun roundRobinRounds(players: Int) = if (players < 2) 1 else if (players % 2 == 0) players - 1 else players

    /** Round robin for 2–8 players, Swiss for 9 or more. */
    fun defaultPairing(players: Int) = if (players >= 9) "swiss" else "round_robin"

    /** Times the clock editor offers, 30 s to 24 h. */
    val CLOCK_DURATIONS = listOf(30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 14400, 28800, 43200, 86400)

    /** Add a range: splits what's left of the last one, at about half its time. */
    fun addClockRange(ranges: List<RotoClockRange>, rounds: Int): List<RotoClockRange> {
        val last = ranges.lastOrNull() ?: return listOf(RotoClockRange(1, 14400))
        val from = last.fromRound + maxOf(1, (rounds - last.fromRound + 1) / 2)
        val seconds = CLOCK_DURATIONS.reversed().firstOrNull { it <= maxOf(30, last.seconds / 2) } ?: 30
        return ranges + RotoClockRange(minOf(rounds, from), seconds)
    }
}

object RotoMerge {
    /**
     * Folds a `roto_state(p_after_pick = after)` answer into the picks held. Picks above the server's picksMade are
     * dropped (an undo); new ones replace any held at the same number. `needsFull` when the delta can't repair what's
     * held (the server is behind it, a card at two numbers, or a gap): fetch every pick again then.
     */
    fun apply(held: List<RotoPick>, delta: List<RotoPick>, picksMade: Int): Pair<List<RotoPick>, Boolean> {
        val byNo = sortedMapOf<Int, RotoPick>()
        for (p in held) if (p.pickNo <= picksMade) byNo[p.pickNo] = p
        for (p in delta) if (p.pickNo <= picksMade) byNo[p.pickNo] = p
        val picks = byNo.values.toList()
        val heldTop = held.maxOfOrNull { it.pickNo } ?: 0
        val duplicateSlot = picks.map { it.slot }.toSet().size != picks.size
        val gap = picks.size != (picks.lastOrNull()?.pickNo ?: 0)
        return picks to (picksMade < heldTop || duplicateSlot || gap)
    }
}

/** Round robin (contract/roto-2026-10-16.md, events-engine's circle method): the same pairs the engine makes. */
object RoundRobin {
    /** Pairs of roster ids for round r (1-based); null is the phantom seat of an odd roster. */
    fun pairs(ids: List<String>, round: Int): List<Pair<String?, String?>> {
        val seats: List<String?> = if (ids.size % 2 == 0) ids else ids + null
        val n = seats.size
        if (n < 2) return emptyList()
        val rot = listOf(seats[0]) + (0 until n - 1).map { g -> seats[1 + ((g + round - 1) % (n - 1))] }
        return (0 until n / 2).map { k -> rot[k] to rot[n - 1 - k] }
    }

    fun rounds(roster: Int) = if (roster < 2) 0 else if (roster % 2 == 0) roster - 1 else roster
}

/** What the Draft screens show of a card: from the local catalog only. */
data class RotoCard(val cardId: String, val name: String, val typeLine: String, val manaCost: String, val colors: List<String>, val manaValue: Int,
                    val group: String, val isLand: Boolean, val isCreature: Boolean) {
    companion object {
        val GROUPS = listOf("White", "Blue", "Black", "Red", "Green", "Multicolor", "Colorless", "Lands")

        /** "{2}{U}{U}" → 4; X counts 0, hybrid and Phyrexian count 1. Split cards use the front face. */
        fun manaValue(cost: String): Int {
            val front = cost.split(" // ").first()
            return Regex("\\{([^}]*)\\}").findAll(front).sumOf { m ->
                val sym = m.groupValues[1]
                sym.toIntOrNull() ?: if (sym == "X" || sym == "Y" || sym == "Z") 0 else 1
            }
        }

        fun of(cardId: String, name: String, typeLine: String, manaCost: String): RotoCard {
            val front = typeLine.split(" // ").first()
            val colors = listOf("W", "U", "B", "R", "G").filter { manaCost.contains("{$it") || manaCost.contains("/$it") }
            val isLand = front.contains("Land")
            val group = when {
                isLand -> "Lands"
                colors.size > 1 -> "Multicolor"
                else -> mapOf("W" to "White", "U" to "Blue", "B" to "Black", "R" to "Red", "G" to "Green")[colors.firstOrNull()] ?: "Colorless"
            }
            return RotoCard(cardId, name, typeLine, manaCost, colors, manaValue(manaCost), group, isLand, front.contains("Creature"))
        }

        fun unknown(cardId: String) = of(cardId, "Card", "", "")
    }
}
