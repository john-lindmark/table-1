package site.table1.events.data

import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.temporal.ChronoUnit
import java.util.Locale
import kotlin.math.ceil
import kotlin.math.roundToLong

/* What the surfaces outside the app show (contract/widgets-2026-10-22.md): the organizer's live status, the Next event
   widget's pick and time text, and the Collection value widget's history. iOS draws these in Live Activities and
   WidgetKit; Android in an ongoing notification and Glance widgets (util/LiveUpdates.kt, widgets/). Same rules as iOS
   Shared/OrganizerModels.swift, NextEvent.swift and ValueHistory.swift; pure, so unit tests run without Android. */

/** The organizer's live state, as live-activity's organizer.ts builds it (camelCase, Unix seconds). */
@Serializable
data class OrgState(
    /** live | between | complete | cancelled */
    val phase: String = "live",
    val round: Int = 0,
    val rounds: Int = 0,
    val roundSeconds: Int = 0,
    val endsAt: Double? = null,
    val pausedRemaining: Int? = null,
    /** Non-bye matches this round. */
    val matches: Int = 0,
    /** Settled. */
    val done: Int = 0,
    /** Pending, or disputed and not decided. */
    val waiting: Int = 0,
    val disputes: Int = 0,
    /** Pending with no account on either side: the organizer enters these. */
    val guestWaiting: Int = 0,
    val players: Int = 0,
    val updatedAt: Double = 0.0,
) {
    val isLive get() = phase == "live"
    /** Every result is in and nothing is disputed: the organizer can move on. */
    val isReady get() = isLive && matches > 0 && waiting == 0
    val roundText get() = "R${maxOf(round, 1)}/$rounds"
    val resultsText get() = "$done/$matches in"
    val nextAction get() = if (round < rounds) "Pair round ${round + 1}" else "Finish event"
    val ended get() = phase == "complete" || phase == "cancelled"
    /** A paused clock: `20:00`. */
    val pausedText get() = pausedRemaining?.let { "%02d:%02d".format(it / 60, it % 60) }

    /** The one line that says what's next, for every surface. */
    val nextStep: String get() = when (phase) {
        "complete" -> "Event complete"
        "cancelled" -> "Event cancelled"
        "between" -> if (round == 0) "Pair round 1" else "Round $round recorded · $nextAction"
        else -> when {
            isReady -> "Ready: $nextAction"
            matches == 0 -> "No matches this round"
            else -> "Waiting on $waiting result${if (waiting == 1) "" else "s"}"
        }
    }

    /** Under the next step: disputes first (they block pairing), then results only the organizer can enter. */
    val flags: List<String> get() = if (!isLive) emptyList() else listOfNotNull(
        if (disputes > 0) "$disputes dispute${if (disputes == 1) "" else "s"} to decide" else null,
        if (guestWaiting > 0) "$guestWaiting to enter yourself" else null,
    )
}

/** One event this account runs, as live-activity's `state` returns it. */
@Serializable
data class OrganizerSnapshot(val eventId: String, val eventName: String = "", val state: OrgState)

/** What the Next event widget keeps of `events_home`. */
@Serializable
data class NextEventItem(
    val id: String, val name: String, val status: String, val bucket: String, val organizing: Boolean, val playing: Boolean,
    val venueName: String? = null, val startsAt: String? = null, val numberOfRounds: Int = 0, val currentRound: Int = 0,
    val players: Int = 0, val formatLabel: String? = null, val format: String = "",
) {
    val label get() = formatLabel ?: format.replaceFirstChar { it.uppercase() }
    val isLive get() = bucket == "live"
    val start: Instant? get() = startsAt?.let { s -> runCatching { OffsetDateTime.parse(s).toInstant() }.getOrNull() ?: runCatching { Instant.parse(s) }.getOrNull() }

    companion object {
        fun of(e: HomeEvent) = NextEventItem(e.id, e.name, e.status, e.bucket, e.organizing, e.playing, e.venueName, e.startsAt,
            e.numberOfRounds, e.currentRound, e.players, e.formatLabel, e.format)
    }
}

@Serializable
data class NextEventData(val events: List<NextEventItem> = emptyList(), val invites: Int = 0, val fetchedAt: Long = 0)

object NextEvent {
    /** Best first: a live event, then the soonest upcoming with a start time, then upcoming ones with none (server order).
     *  Cancelled and past never show. */
    fun pick(events: List<NextEventItem>): List<NextEventItem> {
        val shown = events.filter { it.status != "cancelled" && it.bucket != "past" }
        val upcoming = shown.filter { !it.isLive }
        return shown.filter { it.isLive } + upcoming.filter { it.start != null }.sortedBy { it.start } + upcoming.filter { it.start == null }
    }

    /** `Live · R2/4`, `Starting now`, `In 2h 10m` (within 12 h), else `Fri 6:30 PM` / `Oct 30, 6:30 PM`, or `Not scheduled`. */
    fun timeText(e: NextEventItem, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): String {
        if (e.isLive) return "Live · R${maxOf(e.currentRound, 1)}/${e.numberOfRounds}"
        val start = e.start ?: return "Not scheduled"
        val seconds = ChronoUnit.SECONDS.between(now, start)
        if (seconds <= 60) return "Starting now"
        if (seconds < 12 * 3600) {
            val minutes = ceil(seconds / 60.0).toInt()
            return if (minutes < 60) "In ${minutes}m" else "In ${minutes / 60}h ${minutes % 60}m"
        }
        val at = start.atZone(zone)
        val time = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(locale).format(at)
        return if (seconds < 6 * 86400) DateTimeFormatter.ofPattern("EEE", locale).format(at) + " " + time
        else DateTimeFormatter.ofPattern("MMM d", locale).format(at) + ", " + time
    }

    /** Redraw 1 min after the next start time passes, every 30 min while one is within 12 h (or live), else every 3 h. */
    fun nextReload(shown: List<NextEventItem>, now: Instant = Instant.now()): Instant {
        val soon = shown.mapNotNull { it.start }.filter { it > now }.minOrNull()
        if (soon != null && ChronoUnit.SECONDS.between(now, soon) < 12 * 3600) return minOf(soon.plusSeconds(60), now.plusSeconds(30 * 60))
        if (shown.any { it.isLive }) return now.plusSeconds(30 * 60)
        return now.plusSeconds(3 * 3600)
    }
}

@Serializable
data class ValuePoint(val day: String, val usd: Double)

/** The Collection value widget's history: one point per day (the last value seen that day), 30 days, per account. */
@Serializable
data class ValueRecord(val userId: String, val points: List<ValuePoint> = emptyList(), val cards: Int = 0, val copies: Int = 0, val fetchedAt: Long = 0) {
    val current get() = points.lastOrNull()?.usd

    /** From the latest point at least [days] old (or the oldest, when history is shorter) to today; null until two days. */
    fun change(days: Int = 7, today: LocalDate = LocalDate.now()): Pair<Double, Int>? {
        val last = points.lastOrNull() ?: return null
        if (points.size < 2) return null
        val cutoff = today.minusDays(days.toLong()).toString()
        val base = points.lastOrNull { it.day <= cutoff } ?: points.first()
        if (base.day == last.day) return null
        val span = ChronoUnit.DAYS.between(LocalDate.parse(base.day), LocalDate.parse(last.day)).toInt()
        return (last.usd - base.usd) to maxOf(1, span)
    }
}

object ValueHistory {
    const val KEEP_DAYS = 30L

    /** Adds or replaces today's point; a different account starts fresh. */
    fun record(rec: ValueRecord?, userId: String, usd: Double, cards: Int, copies: Int, today: LocalDate = LocalDate.now()): ValueRecord {
        val r = rec?.takeIf { it.userId == userId } ?: ValueRecord(userId)
        val day = today.toString()
        val rounded = (usd * 100).roundToLong() / 100.0
        val points = (if (r.points.lastOrNull()?.day == day) r.points.dropLast(1) else r.points) + ValuePoint(day, rounded)
        val oldest = today.minusDays(KEEP_DAYS - 1).toString()
        return r.copy(points = points.filter { it.day >= oldest }, cards = cards, copies = copies)
    }
}
