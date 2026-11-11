package site.table1.events.tracker

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * tracker_next: the player's match in the event's newest later round (contract/life-tracker-options-2026-10-20.md
 * § Next round). Null when there is nothing newer, or when this phone isn't one of the match's players.
 */
@Serializable
data class TrackerNextAnswer(
    val round: Int,
    @SerialName("match_id") val matchId: String? = null,
    val bye: Boolean = false,
)

/**
 * What a synced tracker does with tracker_next's answer: a tracker opened on one match kept showing it after the
 * next round was paired (2026-11-11), since it only ever listened to that match. Cases `testdata/tracker-next/`.
 */
sealed interface TrackerNext {
    /** Keep this match. */
    data object Stay : TrackerNext
    /** The round is paired but its matches are still being written (events-engine inserts the round first). */
    data object Soon : TrackerNext
    /** Open the newer match. */
    data class Move(val matchId: String) : TrackerNext
    /** Show this and keep the match (a bye next). */
    data class Notice(val text: String) : TrackerNext

    companion object {
        /** How often an open tracker asks; also on returning to the app. */
        const val EVERY_MS = 15_000L
        const val SOON_MS = 2_000L

        fun decide(current: String?, answer: TrackerNextAnswer?): TrackerNext {
            if (current == null || answer == null) return Stay
            answer.matchId?.let { return if (it == current) Stay else Move(it) }
            if (answer.bye) return Notice("Round ${answer.round} paired | you have a bye")
            return Soon
        }
    }
}
