package site.table1.events.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.intOrNull

/*
 * Teams with captains, Team Trios, the top 4 cut, a season's final and alerts for new public events
 * (contract/teams-finals-alerts-2026-11-13.md): what the server answers and every wording, once. The rules pass
 * testdata/leagues/cases.json (cut_choices, seat_formats, seat_label, team_line, alert_line). Plain Kotlin.
 */

@Serializable
data class TeamMate(
    @SerialName("participant_id") val participantId: String,
    @SerialName("user_id") val userId: String? = null,
    val name: String = "",
    val slot: Int? = null,
)

/**
 * A team as team_mine sends it. Your own team (and every team, for organizers) comes in full: [members] is the list
 * and [joinCode] is set. Everyone else's is `{id, name, members (a count), complete}`.
 */
@Serializable
data class SignupTeam(
    val id: String,
    val name: String = "",
    @SerialName("captain_id") val captainId: String? = null,
    @SerialName("join_code") val joinCode: String? = null,
    val members: JsonElement = JsonNull,
    val complete: Boolean = false,
) {
    /** The members by seat, when the team came in full. */
    val mates: List<TeamMate>
        get() = (members as? JsonArray)?.let { a -> runCatching { TeamRules.json.decodeFromJsonElement<List<TeamMate>>(a) }.getOrNull() }
            .orEmpty().sortedBy { it.slot ?: 99 }

    val count: Int get() = (members as? JsonArray)?.size ?: (members as? JsonPrimitive)?.intOrNull ?: 0
}

@Serializable
data class TeamMine(
    @SerialName("team_signup") val teamSignup: Boolean = false,
    @SerialName("team_size") val teamSize: Int? = null,
    @SerialName("seat_formats") val seatFormats: List<String>? = null,
    val team: SignupTeam? = null,
    val captain: Boolean = false,
    @SerialName("can_create") val canCreate: Boolean = false,
    val teams: List<SignupTeam> = emptyList(),
)

@Serializable
data class TeamSignupSet(@SerialName("team_signup") val teamSignup: Boolean = false)

@Serializable
data class SeatFormatsSet(@SerialName("seat_formats") val seatFormats: List<String> = emptyList())

/** One row of league_final_status. [how]: winner | points | null; [state]: in | invited | declined | guest | none. */
@Serializable
data class FinalRow(
    val key: String = "",
    @SerialName("user_id") val userId: String? = null,
    val name: String = "",
    val rank: Int = 0,
    val points: Int = 0,
    val how: String? = null,
    val state: String = "none",
)

@Serializable
data class FinalStatus(
    @SerialName("season_id") val seasonId: String? = null,
    val qualified: List<FinalRow> = emptyList(),
    val next: List<FinalRow> = emptyList(),
) {
    val inCount: Int get() = qualified.count { it.state == "in" }
    /** `3 of 23 in`. */
    val line: String get() = "$inCount of ${qualified.size} in"
    /** Who Invite the qualified would reach: an account, not in, not invited yet. */
    val toInvite: Int get() = qualified.count { it.userId != null && it.state == "none" }
}

@Serializable
data class FinalInvited(val ok: Boolean = false, val invited: Int = 0)

/** event_alerts_get / _set: one alert setting per account. [lat]/[lng] are the rough area (0.1°), null with none. */
@Serializable
data class EventAlerts(
    val on: Boolean = false,
    val formats: List<String> = emptyList(),
    val km: Int? = null,
    val lat: Double? = null,
    val lng: Double? = null,
) {
    val hasArea: Boolean get() = lat != null && lng != null
}

/** One paired team match of the team playoffs (events-engine `team_bracket`). */
@Serializable
data class TeamBracketStage(val stage: String, val matches: List<Match> = emptyList()) {
    @Serializable
    data class Side(
        val seed: Int? = null,
        @SerialName("team_id") val teamId: String? = null,
        val name: String? = null,
        @SerialName("match_wins") val matchWins: Int = 0,
    )

    @Serializable
    data class Seat(
        @SerialName("match_id") val matchId: String,
        @SerialName("table_number") val tableNumber: Int? = null,
        @SerialName("is_bye") val isBye: Boolean = false,
        val status: String = "pending",
        val winner: String? = null,
        val sides: List<SeatSide> = emptyList(),
    )

    @Serializable
    data class SeatSide(
        @SerialName("participant_id") val participantId: String? = null,
        @SerialName("display_name") val displayName: String? = null,
        val slot: Int? = null,
        @SerialName("game_wins") val gameWins: Int = 0,
    )

    @Serializable
    data class Match(
        @SerialName("table_number") val tableNumber: Int? = null,
        val status: String = "pending",
        /** The winning team's id. */
        val winner: String? = null,
        val sides: List<Side> = emptyList(),
        val matches: List<Seat> = emptyList(),
    )

    val title: String get() = EventRules.roundName(stage, 0, 0)
}

object TeamRules {
    internal val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }

    /** The cuts a format can have: Swiss events of players 0 / 4 / 8; team sealed and Team Trios 0 / 4; never a team
     *  draft, a roto or round robin. */
    fun cutChoices(formatName: String?, pairing: String? = "swiss"): List<Int> = when {
        (pairing ?: "swiss") != "swiss" || formatName == "team_draft" || formatName == "roto" -> listOf(0)
        formatName == "team_sealed" || formatName == "team_trios" -> listOf(0, 4)
        else -> listOf(0, 4, 8)
    }

    fun cutLabel(cut: Int): String = if (cut == 0) "None" else "Top $cut"

    /** What a seat of a Team Trios event can play, in the pickers' order. */
    val seatFormats: List<Pair<String, String>> = Leagues.formatKeys.take(8) + listOf("duel_commander" to "Duel Commander", "other" to "Other")

    val defaultSeats = listOf("modern", "standard", "pioneer")

    fun seatFormatLabel(key: String): String = seatFormats.firstOrNull { it.first == key }?.second ?: "Other"

    /** `A · MODERN`; the letter alone outside Team Trios. */
    fun seatLabel(slot: Int, seatFormats: List<String>?): String {
        val letter = if (slot in 1..4) "ABCD"[slot - 1].toString() else "$slot"
        return if (!seatFormats.isNullOrEmpty() && slot in 1..seatFormats.size) "$letter · ${seatFormatLabel(seatFormats[slot - 1]).uppercase()}" else letter
    }

    /** `2/3`, or `COMPLETE`. */
    fun teamLine(members: Int, complete: Boolean, teamSize: Int): String = if (complete) "COMPLETE" else "$members/$teamSize"

    /** `OFF`, `MODERN, LIMITED · 50 KM`, `EVERY FORMAT · ANYWHERE`. */
    fun alertLine(a: EventAlerts): String {
        if (!a.on) return "OFF"
        val formats = a.formats.joinToString(", ") { Leagues.label(it).uppercase() }.ifEmpty { "EVERY FORMAT" }
        return if (a.km != null && a.km != 0) "$formats · ${a.km} KM" else "$formats · ANYWHERE"
    }

    /** Alerts' distances; null = anywhere. */
    val alertDistances: List<Int?> = listOf(null, 25, 50, 100, 250)

    /** The link a captain shares: the event page with the code filled in. */
    fun teamLink(eventId: String, code: String): String = "https://table-1.site/s/$eventId?team=$code"

    /** A typed or pasted team code: 8 letters and digits, also out of a pasted link. */
    fun parseCode(text: String?): String? {
        val t = text?.trim().orEmpty()
        Regex("""[?&]team=([A-Za-z0-9]{8})\b""").find(t)?.let { return it.groupValues[1].uppercase() }
        val plain = t.uppercase().filter { it in 'A'..'Z' || it in '0'..'9' }
        return plain.takeIf { it.length == 8 && t.length <= 12 }
    }

    /** The members' participant ids with one moved up (-1) or down (+1) a seat, seat A first: team_update's `order`. */
    fun moved(mates: List<TeamMate>, participantId: String, by: Int): List<String>? {
        val ids = mates.map { it.participantId }.toMutableList()
        val i = ids.indexOf(participantId)
        val j = i + by
        if (i < 0 || j !in ids.indices) return null
        ids[i] = ids[j].also { ids[j] = ids[i] }
        return ids
    }

    /** What leaving your team says first: the captain's says who takes over. */
    fun leaveText(team: SignupTeam, myUserId: String?): String {
        if (team.captainId == null || team.captainId != myUserId) return "You leave the event. Your seat on ${team.name} opens."
        val next = team.mates.firstOrNull { it.userId != myUserId }
        return if (next != null) "You leave the event. ${next.name} becomes captain of ${team.name}." else "You leave the event and ${team.name} closes."
    }

    /** Teams with at least one active member: what a team event's cut counts. */
    fun activeTeams(participants: List<ParticipantRow>): Int = participants.filter { it.status == "active" && it.teamId != null }.map { it.teamId }.distinct().size
}
