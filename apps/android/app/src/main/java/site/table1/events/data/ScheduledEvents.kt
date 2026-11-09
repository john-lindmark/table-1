package site.table1.events.data

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// Scheduled events, the sign-up link, the waitlist, top 8, automatic rounds and decklists
// (contract/scheduled-events-2026-10-27.md). Checked against testdata/scheduled-events/cases.json (ScheduledEventsTest);
// iOS and the web carry the same rules.

object EventRules {
    private val bands = listOf(2 to 1, 4 to 2, 8 to 3, 16 to 4, 32 to 5, 64 to 6, 128 to 7, 226 to 8, 409 to 9)

    /** Swiss rounds for a number of players (t1_private.swiss_rounds; above 128 the MTR Appendix E bands). */
    fun swissRounds(players: Int): Int = bands.firstOrNull { players <= it.first }?.second ?: 10

    /** start | waiting | pair | cut | semifinals | final | finish. */
    fun nextStep(stages: List<String>, waiting: Boolean, numberOfRounds: Int, topCut: Int, activePlayers: Int): String {
        val last = stages.lastOrNull() ?: return "start"
        if (waiting) return "waiting"
        return when (last) {
            "quarterfinal" -> "semifinals"
            "semifinal" -> "final"
            "final" -> "finish"
            else -> when {
                stages.count { it == "swiss" } < numberOfRounds -> "pair"
                topCut == 8 && activePlayers > 8 -> "cut"
                else -> "finish"
            }
        }
    }

    /** "Round 2 of 5", "Quarterfinals", "Semifinals", "Final". */
    fun roundName(stage: String?, number: Int, of: Int): String = when (stage) {
        "quarterfinal" -> "Quarterfinals"
        "semifinal" -> "Semifinals"
        "final" -> "Final"
        else -> "Round $number of $of"
    }

    private fun players(n: Int) = if (n == 1) "1 player" else "$n players"

    /** "12 players signed up", "12/16 players", "16/16 players · 3 on the waitlist". */
    fun signUpLine(players: Int, capacity: Int?, waitlist: Int): String =
        if (capacity == null) "${players(players)} signed up"
        else "$players/$capacity players" + if (waitlist > 0) " · $waitlist on the waitlist" else ""

    fun autoLabel(players: Int): String {
        if (players < 2) return "Auto · set when round 1 is paired"
        val n = swissRounds(players)
        return "Auto · $n round${if (n == 1) "" else "s"} for $players players"
    }

    fun roundsLine(auto: Boolean, rounds: Int, topCut: Int, open: Boolean): String =
        (if (auto && open) "Auto rounds" else "$rounds round${if (rounds == 1) "" else "s"}") + if (topCut == 8) " · Top 8" else ""

    /** organizer | in | waitlisted | closed | sign_in | waitlist | sign_up. */
    fun button(signedIn: Boolean, signUp: String?, me: String?): String = when {
        me == "organizer" -> "organizer"
        me == "player" -> "in"
        me == "waitlisted" -> "waitlisted"
        signUp == "closed" -> "closed"
        !signedIn -> "sign_in"
        signUp == "full" -> "waitlist"
        else -> "sign_up"
    }

    data class Counts(val main: Int = 0, val side: Int = 0)

    private val mainHeads = setOf("deck", "main", "mainboard", "main deck", "commander")
    private val sideHeads = setOf("sideboard", "side", "side board")
    private val skipHeads = setOf("considering", "maybeboard", "maybe", "tokens", "about", "companion")
    private val lineRe = Regex("""^(sb:\s*)?(\d{1,3})\s*x?\s+\S""", RegexOption.IGNORE_CASE)
    private val headTail = Regex("""[:\s]*(\(\d+\))?[:\s]*$""")

    /** Card counts in a pasted list (t1_private.decklist_counts). */
    fun decklistCounts(body: String): Counts {
        var main = 0; var side = 0; var section = "main"; var headers = false; var seen = false
        for (raw in body.replace("\r", "").split("\n")) {
            val line = raw.trim()
            if (line.isEmpty()) {
                if (!headers && seen && section == "main") section = "side"
                continue
            }
            val head = line.replace(headTail, "").lowercase()
            when (head) {
                in mainHeads -> { section = "main"; headers = true; continue }
                in sideHeads -> { section = "side"; headers = true; continue }
                in skipHeads -> { section = "skip"; headers = true; continue }
            }
            val m = lineRe.find(line) ?: continue
            val n = m.groupValues[2].toInt()
            when {
                m.groupValues[1].isNotEmpty() -> side += n
                section == "main" -> { main += n; seen = true }
                section == "side" -> side += n
            }
        }
        return Counts(main, side)
    }

    /** The deck format that fits an event's format; null = any deck (Other constructed). */
    fun deckFormat(eventFormat: String?): String? = when (eventFormat) {
        null, "other_constructed" -> null
        "canadian_highlander" -> "canlander"
        else -> eventFormat
    }

    fun decklistsLine(sent: Int, players: Int) = "$sent/$players decklists in"

    fun countsText(main: Int, side: Int) = if (side > 0) "$main main · $side sideboard" else "$main main"

    /** "Sat 8 Nov · 18:30" in the device's time zone. */
    fun whenText(iso: String?): String? {
        val instant = runCatching { Instant.parse(iso?.replace(Regex("""\+00:00$"""), "Z") ?: return null) }
            .recoverCatching { java.time.OffsetDateTime.parse(iso).toInstant() }.getOrNull() ?: return null
        val t = instant.atZone(ZoneId.systemDefault())
        return DateTimeFormatter.ofPattern("EEE d MMM", Locale.getDefault()).format(t) + " · " +
            DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).format(t)
    }

    val constructedFormats = setOf("standard", "pioneer", "modern", "legacy", "vintage", "pauper", "premodern",
        "canadian_highlander", "other_constructed")
}

/** event_preview / event_public: what the event page shows (contract §4). */
@Serializable
data class EventPage(
    @SerialName("event_id") val eventId: String? = null,
    val access: String? = null,
    @SerialName("short_code") val shortCode: String? = null,
    val name: String? = null,
    @SerialName("format_label") val formatLabel: String? = null,
    val status: String? = null,
    @SerialName("starts_at") val startsAt: String? = null,
    @SerialName("venue_name") val venueName: String? = null,
    val capacity: Int? = null,
    val players: Int = 0,
    @SerialName("organizer_name") val organizerName: String? = null,
    @SerialName("top_cut") val topCut: Int = 0,
    @SerialName("auto_rounds") val autoRounds: Boolean = false,
    @SerialName("number_of_rounds") val numberOfRounds: Int = 3,
    val waitlist: Int = 0,
    @SerialName("sign_up") val signUp: String? = null,
    val me: String? = null,
    val position: Int? = null,
    val decklists: String = "off",
    /** After round 1 (contract/event-links-2026-11-09.md): the round being played and every round's matchups. */
    @SerialName("current_round") val currentRound: Int = 0,
    val round: Head? = null,
    val rounds: List<PublicRound>? = null,
    /** The current round's matchups, from servers before `rounds`. */
    val pairings: List<PublicMatch>? = null,
) {
    @Serializable data class Head(val number: Int, val stage: String? = null)

    /** Standings and matchups rather than sign-up: sign-ups closed, except someone still waiting before round 1. */
    val showsResults: Boolean get() = signUp == "closed" && !(me == "waitlisted" && currentRound == 0)

    /** Under the bar after round 1: "Final standings", "Round 2 of 4", "Quarterfinals". */
    val resultsTitle: String
        get() = when {
            status == "completed" -> "Final standings"
            round != null -> EventRules.roundName(round.stage, round.number, numberOfRounds)
            else -> "Round $currentRound of $numberOfRounds"
        }

    /** Matchups, newest first; an older server's current pairings stand in for its round. */
    val matchupRounds: List<PublicRound>
        get() = rounds?.takeIf { it.isNotEmpty() }
            ?: round?.let { r -> pairings?.takeIf { it.isNotEmpty() }?.let { listOf(PublicRound(r.number, r.stage, "active", it)) } }
            ?: emptyList()

    val available: Boolean get() = eventId != null && access != "none"
    val signUpLine: String get() = EventRules.signUpLine(players, capacity, waitlist)
    val roundsLine: String get() = EventRules.roundsLine(autoRounds, numberOfRounds, topCut, signUp != "closed")
    val facts: String
        get() = listOfNotNull(EventRules.whenText(startsAt), venueName, formatLabel, organizerName?.let { "Run by $it" })
            .filter { it.isNotBlank() }.joinToString(" · ")
}

/** One round on the public page: "Round 2 · now", then its matches by name. */
@Serializable
data class PublicRound(val number: Int, val stage: String? = null, val status: String? = null, val matches: List<PublicMatch> = emptyList()) {
    val title: String
        get() = (if ((stage ?: "swiss") == "swiss") "Round $number" else EventRules.roundName(stage, number, 0)) +
            if (status == "active") " · now" else ""
}

/** A match on the public page: names only, no account ids. */
@Serializable
data class PublicMatch(
    @SerialName("match_id") val matchId: String,
    @SerialName("table_number") val tableNumber: Int? = null,
    @SerialName("is_bye") val isBye: Boolean = false,
    val status: String? = null,
    @SerialName("game_draws") val gameDraws: Int = 0,
    val sides: List<Side> = emptyList(),
) {
    @Serializable data class Side(val side: Int, @SerialName("display_name") val displayName: String? = null, @SerialName("game_wins") val gameWins: Int = 0)

    fun name(side: Int) = sides.firstOrNull { it.side == side }?.displayName ?: "—"
    val tableLabel: String get() = if (isBye) "Bye" else "T${tableNumber ?: "–"}"
    val score: String
        get() {
            if (status == "pending") return "vs"
            val a = sides.firstOrNull { it.side == 0 }?.gameWins ?: 0
            val b = sides.firstOrNull { it.side == 1 }?.gameWins ?: 0
            return "$a–$b" + if (gameDraws > 0) "–$gameDraws" else ""
        }
}

/** Following an event you're not in (contract/event-follows-2026-11-09.md). */
@Serializable
data class EventFollow(val following: Boolean = false, val notify: Boolean = false, @SerialName("can_follow") val canFollow: Boolean? = null)

/** An event you follow, for the Events home's Following section. */
@Serializable
data class FollowedEvent(
    @SerialName("event_id") val eventId: String,
    val name: String,
    @SerialName("format_label") val formatLabel: String? = null,
    val status: String? = null,
    @SerialName("current_round") val currentRound: Int = 0,
    @SerialName("number_of_rounds") val numberOfRounds: Int = 0,
    @SerialName("top_cut") val topCut: Int = 0,
    @SerialName("starts_at") val startsAt: String? = null,
    @SerialName("venue_name") val venueName: String? = null,
    val notify: Boolean = true,
    val stage: String? = null,
) {
    /** "Round 2 of 4 · Modern", "Final standings · Modern", "Sat 8 Nov · 18:30 · The Shop · Modern". */
    val detail: String
        get() {
            val state = when {
                status == "completed" -> "Final standings"
                currentRound > 0 -> EventRules.roundName(stage, currentRound, numberOfRounds)
                else -> listOfNotNull(EventRules.whenText(startsAt), venueName).joinToString(" · ").ifEmpty { null }
            }
            return listOfNotNull(state, formatLabel).joinToString(" · ")
        }
}

@Serializable
data class SignUpResult(
    @SerialName("event_id") val eventId: String,
    val status: String,
    @SerialName("participant_id") val participantId: String? = null,
    val position: Int? = null,
)

@Serializable
data class WaitlistEntry(
    @SerialName("user_id") val userId: String,
    @SerialName("display_name") val displayName: String,
    val position: Int = 1,
)

@Serializable
data class DecklistInfo(
    @SerialName("participant_id") val participantId: String,
    @SerialName("main_count") val mainCount: Int = 0,
    @SerialName("side_count") val sideCount: Int = 0,
    @SerialName("list_name") val listName: String? = null,
    val source: String? = null,
)

@Serializable
data class Decklist(
    @SerialName("participant_id") val participantId: String,
    @SerialName("display_name") val displayName: String? = null,
    val body: String = "",
    @SerialName("main_count") val mainCount: Int = 0,
    @SerialName("side_count") val sideCount: Int = 0,
    @SerialName("list_id") val listId: String? = null,
    @SerialName("list_name") val listName: String? = null,
)

/** events-engine standings `bracket`. */
@Serializable
data class BracketStage(val stage: String, val matches: List<Match> = emptyList()) {
    @Serializable
    data class Side(
        val seed: Int? = null,
        @SerialName("participant_id") val participantId: String? = null,
        @SerialName("display_name") val displayName: String? = null,
        @SerialName("game_wins") val gameWins: Int = 0,
    )
    @Serializable
    data class Match(
        @SerialName("match_id") val matchId: String,
        @SerialName("table_number") val tableNumber: Int? = null,
        val status: String = "pending",
        val winner: String? = null,
        val sides: List<Side> = emptyList(),
    )
    val title: String get() = EventRules.roundName(stage, 0, 0)
}

@Serializable
data class HomeWaitlist(
    @SerialName("event_id") val eventId: String,
    val name: String,
    @SerialName("format_label") val formatLabel: String? = null,
    @SerialName("starts_at") val startsAt: String? = null,
    @SerialName("venue_name") val venueName: String? = null,
    val position: Int? = null,
    val players: Int = 0,
    val capacity: Int? = null,
)
