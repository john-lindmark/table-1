package site.table1.events.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/*
 * Organizer tools for the room (contract/room-tools-2026-11-13.md): the display remote, extra time for a table, judge
 * calls, the rules level and the decklist deadline. The wording passes testdata/leagues/cases.json (extension_text,
 * judge_line, rules_line). Plain Kotlin.
 */

/** What displays show: auto | clock | pairings | standings, and the announcement along the bottom. */
@Serializable
data class RoomDisplay(val show: String = "auto", val message: String? = null)

@Serializable
data class RoomExtension(
    @SerialName("match_id") val matchId: String,
    @SerialName("table_number") val tableNumber: Int? = null,
    @SerialName("extra_seconds") val extraSeconds: Int = 0,
)

/** An open judge call, as organizers get it. */
@Serializable
data class JudgeCall(
    @SerialName("call_id") val callId: String,
    @SerialName("match_id") val matchId: String? = null,
    @SerialName("table_number") val tableNumber: Int? = null,
    @SerialName("called_at") val calledAt: String? = null,
    val by: String? = null,
)

/** A player's own table in the newest round. */
@Serializable
data class RoomMyMatch(
    @SerialName("match_id") val matchId: String,
    @SerialName("table_number") val tableNumber: Int? = null,
    @SerialName("extra_seconds") val extraSeconds: Int = 0,
    @SerialName("call_open") val callOpen: Boolean = false,
)

/** event_room. [calls] is null for anyone who doesn't run the event. */
@Serializable
data class EventRoom(
    val display: RoomDisplay = RoomDisplay(),
    val extensions: List<RoomExtension> = emptyList(),
    val calls: List<JudgeCall>? = null,
    @SerialName("my_match") val myMatch: RoomMyMatch? = null,
) {
    fun extra(matchId: String): Int = extensions.firstOrNull { it.matchId == matchId }?.extraSeconds ?: 0
}

@Serializable
data class JudgeCalled(@SerialName("call_id") val callId: String? = null, @SerialName("match_id") val matchId: String? = null)

object RoomRules {
    /** `+5:00`; nothing for no extra time. */
    fun extensionText(seconds: Int): String = if (seconds > 0) "+%d:%02d".format(Locale.US, seconds / 60, seconds % 60) else ""

    /** `JUDGE · TABLE 7 · BEA · 2 MIN`; `NOW` in the first minute. */
    fun judgeLine(tableNumber: Int?, by: String?, calledAt: String?, now: Instant = Instant.now()): String {
        val at = Leagues.parseInstant(calledAt)
        val mins = if (at == null) 0 else maxOf(0L, Math.floorDiv(java.time.Duration.between(at, now).seconds, 60L))
        return listOfNotNull("JUDGE", "TABLE ${tableNumber ?: "–"}", by?.uppercase()?.takeIf { it.isNotEmpty() }, if (mins == 0L) "NOW" else "$mins MIN")
            .joinToString(" · ")
    }

    val rels = listOf(null to "Not said", "casual" to "Casual", "competitive" to "Competitive")

    /** `COMPETITIVE · DECKLISTS DUE SAT 14 NOV 09:30`. [due] is the deadline already in the device's zone. */
    fun rulesLine(rel: String?, due: String?): String =
        listOfNotNull(rel?.takeIf { it.isNotEmpty() }?.uppercase(), due?.takeIf { it.isNotEmpty() }?.let { "DECKLISTS DUE $it" }).joinToString(" · ")

    /** `SAT 14 NOV 09:30` in the zone. */
    fun dueText(iso: String?, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): String? =
        Leagues.parseInstant(iso)?.let { DateTimeFormatter.ofPattern("EEE d MMM HH:mm", locale).format(it.atZone(zone)).uppercase(locale).replace(".", "") }

    val shows = listOf("auto" to "Auto", "clock" to "Clock", "pairings" to "Pairings", "standings" to "Standings")

    const val MESSAGE_MAX = 140

    /** `24 / 140`. */
    fun counter(text: String): String = "${text.length} / $MESSAGE_MAX"

    /** The web display's address for the event (contract/public-events-leagues-2026-11-13.md § 5). */
    fun displayUrl(eventId: String): String = "https://table-1.site/d/$eventId"

    /** Extra time's choices in seconds; 0 takes it back. */
    val extras = listOf(180 to "+3 min", 300 to "+5 min", 600 to "+10 min", 0 to "Take it back")

    /** What match_time_extend is sent for a pick: the table's total after it stays 0–3600; Take it back sends minus
     *  what the table has. */
    fun extendBy(pick: Int, current: Int): Int = if (pick == 0) -current else minOf(pick, 3600 - current)
}
