package site.table1.events.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// Wire models. Field names match Postgres / RPC JSON exactly (see contract/rpc.schema.json).

@Serializable
data class EventRow(
    val id: String,
    @SerialName("short_code") val shortCode: String,
    val name: String,
    val format: String = "draft",
    val status: String = "setup",
    @SerialName("number_of_rounds") val numberOfRounds: Int = 3,
    @SerialName("current_round") val currentRound: Int = 0,
    @SerialName("round_length_seconds") val roundLengthSeconds: Int = 3000,
    @SerialName("allow_player_reporting") val allowPlayerReporting: Boolean = true,
    @SerialName("created_by") val createdBy: String? = null,
    @SerialName("venue_name") val venueName: String? = null,
    val visibility: String = "link_only",
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("cancel_reason") val cancelReason: String? = null,
    @SerialName("is_demo") val isDemo: Boolean = false,
    @SerialName("format_name") val formatName: String? = null,
    @SerialName("format_label") val formatLabel: String? = null,
    @SerialName("event_type") val eventType: String? = null,
    @SerialName("team_size") val teamSize: Int? = null,
    @SerialName("set_code") val setCode: String? = null,
    @SerialName("set_name") val setName: String? = null,
    @SerialName("cube_name") val cubeName: String? = null,
    @SerialName("cube_url") val cubeUrl: String? = null,
    @SerialName("format_other") val formatOther: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
    @SerialName("cancelled_at") val cancelledAt: String? = null,
    @SerialName("starts_at") val startsAt: String? = null,
    /** "Round timer" on: clocks are shown. Rounds always run 50 minutes either way. */
    @SerialName("show_clock") val showClock: Boolean = true,
    /** Named from its settings ("Draft · Duskmourn · Fri 17 Oct"); older events keep their typed names. */
    @SerialName("auto_name") val autoName: Boolean = false,
    /** swiss | round_robin. */
    val pairing: String = "swiss",
    /** 0 or 8 (contract/scheduled-events-2026-10-27.md). */
    @SerialName("top_cut") val topCut: Int = 0,
    /** Rounds follow the players until round 1 is paired. */
    @SerialName("auto_rounds") val autoRounds: Boolean = false,
    /** Self sign-ups past it join the waitlist. */
    val capacity: Int? = null,
    /** off | optional | required (constructed events). */
    val decklists: String = "off",
) {
    val isConstructed: Boolean get() = formatName in EventRules.constructedFormats
    val takesDecklists: Boolean get() = decklists != "off"
    val isCancelled: Boolean get() = status == "cancelled"
    val isFinished: Boolean get() = status in setOf("completed", "archived", "cancelled")
    /** "Modern", "Draft · Duskmourn", "Team draft · Vintage Cube" (older rows: the coarse format). */
    val label: String get() = formatLabel ?: format.replaceFirstChar { it.uppercase() }
    val isDraft: Boolean get() = formatName == "draft" || formatName == "team_draft"
    val isTeamEvent: Boolean get() = teamSize != null
    /** Seats and teams can change until round 1 is paired. */
    val beforeRoundOne: Boolean get() = (status == "setup" || status == "seated") && currentRound == 0
}

@Serializable
data class ParticipantRow(
    val id: String,
    @SerialName("event_id") val eventId: String,
    @SerialName("display_name") val displayName: String,
    val seat: Int? = null,
    val status: String = "active",
    @SerialName("user_id") val userId: String? = null,
    @SerialName("pod_id") val podId: String? = null,
    @SerialName("team_id") val teamId: String? = null,
    @SerialName("team_slot") val teamSlot: Int? = null,
    @SerialName("dropped_in_round") val droppedInRound: Int? = null,
)

/** public.event_teams (active rows). */
@Serializable
data class EventBundleWire(
    val event: EventRow,
    val participants: List<ParticipantRow> = emptyList(),
    val rounds: List<RoundRow> = emptyList(),
    val teams: List<BundleTeam> = emptyList(),
    @SerialName("is_organizer") val isOrganizer: Boolean = false,
    val waitlist: List<WaitlistEntry> = emptyList(),
    val decklists: List<DecklistInfo> = emptyList(),
)

/** A team as event_bundle sends it (get_event_teams' shape; members are read from participants). */
@Serializable
data class BundleTeam(val id: String, val name: String, val order: Int = 0)

@Serializable
data class EventTeamRow(
    val id: String,
    val name: String,
    @SerialName("display_order") val displayOrder: Int = 0,
)

@Serializable
data class SideRow(
    val id: String,
    @SerialName("match_id") val matchId: String,
    @SerialName("participant_id") val participantId: String? = null,
    val side: Int,
    @SerialName("game_wins") val gameWins: Int = 0,
)

@Serializable
data class MatchRow(
    val id: String,
    @SerialName("event_id") val eventId: String,
    @SerialName("round_id") val roundId: String,
    @SerialName("table_number") val tableNumber: Int? = null,
    @SerialName("is_bye") val isBye: Boolean = false,
    @SerialName("game_draws") val gameDraws: Int = 0,
    val status: String = "pending",
    val version: Int = 0,
    val disputed: Boolean = false,
    @SerialName("reported_by_user") val reportedByUser: String? = null,
    @SerialName("reported_by_participant") val reportedByParticipant: String? = null,
    /** 'player' | 'organizer' (null while pending). */
    @SerialName("result_source") val resultSource: String? = null,
    @SerialName("match_sides") val sides: List<SideRow> = emptyList(),
) {
    fun side(n: Int): SideRow? = sides.firstOrNull { it.side == n }
}

@Serializable
data class RoundRow(
    val id: String,
    @SerialName("event_id") val eventId: String,
    val number: Int,
    val status: String = "pending",
    @SerialName("timer_ends_at") val timerEndsAt: String? = null,
    /** 'running' | 'paused'. */
    @SerialName("timer_status") val timerStatus: String = "paused",
    @SerialName("timer_duration_seconds") val timerDurationSeconds: Int = 3000,
    @SerialName("timer_remaining_at_change") val timerRemainingAtChange: Int? = null,
    @SerialName("timer_last_started_at") val timerLastStartedAt: String? = null,
    @SerialName("recorded_at") val recordedAt: String? = null,
    val matches: List<MatchRow> = emptyList(),
    /** swiss | quarterfinal | semifinal | final. */
    val stage: String = "swiss",
) {
    val isPlayoff: Boolean get() = stage != "swiss"
    fun name(of: Int): String = EventRules.roundName(stage, number, of)
}

/** update_event_details result: the event's details after the save. */
@Serializable
data class EventDetails(
    @SerialName("event_id") val eventId: String,
    val name: String,
    @SerialName("format_name") val formatName: String? = null,
    @SerialName("format_label") val formatLabel: String? = null,
    @SerialName("number_of_rounds") val numberOfRounds: Int = 3,
    @SerialName("round_length_seconds") val roundLengthSeconds: Int = 3000,
    @SerialName("set_code") val setCode: String? = null,
    @SerialName("set_name") val setName: String? = null,
    @SerialName("cube_name") val cubeName: String? = null,
    @SerialName("cube_url") val cubeUrl: String? = null,
    @SerialName("team_size") val teamSize: Int? = null,
    @SerialName("format_other") val formatOther: String? = null,
)

/** set_round_clock result. */
@Serializable
data class RoundClockState(
    @SerialName("round_id") val roundId: String,
    @SerialName("timer_status") val timerStatus: String = "paused",
    @SerialName("remaining_seconds") val remainingSeconds: Int = 0,
    @SerialName("duration_seconds") val durationSeconds: Int = 0,
    @SerialName("ends_at") val endsAt: String? = null,
)

@Serializable
data class Standing(
    val rank: Int,
    @SerialName("participant_id") val participantId: String,
    @SerialName("display_name") val displayName: String,
    val status: String = "active",
    @SerialName("match_points") val matchPoints: Int = 0,
    @SerialName("match_wins") val matchWins: Int = 0,
    @SerialName("match_losses") val matchLosses: Int = 0,
    @SerialName("match_draws") val matchDraws: Int = 0,
    val byes: Int = 0,
    val omw: Double = 0.0,
    val gw: Double = 0.0,
    val ogw: Double = 0.0,
    /** Top 8: the Swiss place and the furthest stage reached. */
    @SerialName("swiss_rank") val swissRank: Int? = null,
    val playoff: String? = null,
)

@Serializable
data class StandingsResponse(
    val standings: List<Standing> = emptyList(),
    /** Team events only (team table first). */
    val teams: List<TeamStanding>? = null,
    /** Draft events only. */
    val seating: List<SeatingPod>? = null,
    /** Team events: the team the other can no longer catch, so the organizer may finish early. */
    val clinched: TeamClinch? = null,
    @SerialName("top_cut") val topCut: Int = 0,
    /** The playoff rounds paired so far (top 8). */
    val bracket: List<BracketStage> = emptyList(),
)

/** Two teams head to head: one's match wins beat the other's plus every match still to play (events-engine). */
@Serializable
data class TeamClinch(
    @SerialName("team_id") val teamId: String,
    val name: String,
    @SerialName("match_wins") val matchWins: Int,
    @SerialName("opponent_match_wins") val opponentMatchWins: Int,
    val remaining: Int,
) {
    /** "Team Alpha has clinched it: 5–2 in match wins with 2 matches left to play." */
    val text: String
        get() {
            val team = if (name.startsWith("team", ignoreCase = true)) name else "Team $name"
            return "$team has clinched it: $matchWins–$opponentMatchWins in match wins with $remaining ${if (remaining == 1) "match" else "matches"} left to play."
        }
}

@Serializable
data class TeamStanding(
    val rank: Int,
    @SerialName("team_id") val teamId: String,
    val name: String,
    val points: Int = 0,
    val wins: Int = 0,
    val losses: Int = 0,
    val draws: Int = 0,
    val byes: Int = 0,
    @SerialName("match_wins") val matchWins: Int = 0,
    val gw: Double = 0.0,
    val members: List<TeamStandingMember> = emptyList(),
)

@Serializable
data class TeamStandingMember(
    @SerialName("participant_id") val participantId: String,
    @SerialName("display_name") val displayName: String,
    val slot: Int? = null,
    @SerialName("match_wins") val matchWins: Int = 0,
    @SerialName("match_losses") val matchLosses: Int = 0,
    @SerialName("match_draws") val matchDraws: Int = 0,
    val status: String = "active",
)

/* ── draft seating (events-engine seat_players / standings.seating) ─────────── */

@Serializable
data class SeatingPod(
    @SerialName("pod_id") val podId: String,
    val name: String? = null,
    val seats: List<SeatingSeat> = emptyList(),
)

@Serializable
data class SeatingSeat(
    val seat: Int,
    @SerialName("participant_id") val participantId: String,
    @SerialName("display_name") val displayName: String,
    val team: String? = null,
)

@Serializable
data class SeatPlayersResponse(
    val pods: List<SeatingPod> = emptyList(),
    val error: String? = null,
)

/* ── teams (get_event_teams / set_teams / randomize_teams) ──────────────────── */

@Serializable
data class EventTeam(
    val id: String? = null,
    val name: String,
    val order: Int = 0,
    val members: List<TeamMember> = emptyList(),
)

@Serializable
data class TeamMember(
    @SerialName("participant_id") val participantId: String,
    @SerialName("display_name") val displayName: String,
    val slot: Int? = null,
    @SerialName("user_id") val userId: String? = null,
    val status: String = "active",
)

/** Seat letter for a team slot: 1 → A. */
fun slotLetter(slot: Int?): String = slot?.takeIf { it in 1..26 }?.let { ('A' + (it - 1)).toString() } ?: "–"

/* ── event create ───────────────────────────────────────────────────────────── */

@Serializable
data class DraftableSet(
    val code: String,
    val name: String,
    @SerialName("set_type") val setType: String? = null,
    @SerialName("released_at") val releasedAt: String? = null,
    @SerialName("icon_svg_uri") val iconSvgUri: String? = null,
)

/* ── life tracker (tracker_open / tracker_state / tracker_push / tracker_record_game) ── */

@Serializable
data class TrackerOp(
    @SerialName("client_op_id") val clientOpId: String,
    @SerialName("game_no") val gameNo: Int,
    val side: Int,
    val counter: String = "life",
    val delta: Int,
    @SerialName("tapped_at") val tappedAt: String,
    val mine: Boolean = true,
)

@Serializable
data class TrackerGame(
    @SerialName("game_no") val gameNo: Int,
    @SerialName("winner_side") val winnerSide: Int? = null,
    @SerialName("is_draw") val isDraw: Boolean = false,
    @SerialName("recorded_at") val recordedAt: String? = null,
)

@Serializable
data class TrackerState(
    @SerialName("session_id") val sessionId: String,
    @SerialName("match_id") val matchId: String? = null,
    @SerialName("event_id") val eventId: String? = null,
    @SerialName("starting_life") val startingLife: Int = 20,
    @SerialName("my_side") val mySide: Int? = null,
    val names: List<String>? = null,
    @SerialName("event_name") val eventName: String? = null,
    val round: Int? = null,
    val table: Int? = null,
    /** The match's round timer; null when there's no round. Kept live from rounds UPDATEs. */
    val clock: TrackerClock? = null,
    val games: List<TrackerGame> = emptyList(),
    val ops: List<TrackerOp> = emptyList(),
)

/**
 * The round clock as tracker_state returns it. Running: remaining = remaining_at_change − (now − last_started_at),
 * negative in overtime. Paused: remaining_at_change (null = the full duration).
 */
@Serializable
data class TrackerClock(
    @SerialName("round_id") val roundId: String,
    @SerialName("timer_status") val timerStatus: String = "paused",
    @SerialName("timer_last_started_at") val timerLastStartedAt: String? = null,
    @SerialName("timer_remaining_at_change") val timerRemainingAtChange: Int? = null,
    @SerialName("timer_duration_seconds") val timerDurationSeconds: Int = 0,
)

/** A rounds row from Realtime, reduced to the clock. */
@Serializable
data class RoundClockRow(
    val id: String,
    @SerialName("timer_status") val timerStatus: String = "paused",
    @SerialName("timer_last_started_at") val timerLastStartedAt: String? = null,
    @SerialName("timer_remaining_at_change") val timerRemainingAtChange: Int? = null,
    @SerialName("timer_duration_seconds") val timerDurationSeconds: Int? = null,
) {
    fun clock(previous: TrackerClock?) = TrackerClock(
        id, timerStatus, timerLastStartedAt, timerRemainingAtChange,
        timerDurationSeconds ?: previous?.timerDurationSeconds ?: 0,
    )
}

/** A tracker_ops row as Realtime delivers it (actor instead of the `mine` flag). */
@Serializable
data class TrackerOpRow(
    @SerialName("client_op_id") val clientOpId: String,
    @SerialName("game_no") val gameNo: Int,
    val side: Int,
    val counter: String = "life",
    val delta: Int,
    @SerialName("tapped_at") val tappedAt: String? = null,
    val actor: String? = null,
)

@Serializable
data class TrackerPushResult(val inserted: Int = 0, @SerialName("game_no") val gameNo: Int = 0)

@Serializable
data class UserSettings(
    @SerialName("user_id") val userId: String,
    @SerialName("tracker_mode") val trackerMode: String = "elsewhere",
)

@Serializable
data class PairRoundResponse(
    @SerialName("round_number") val roundNumber: Int = 0,
    @SerialName("timer_ends_at") val timerEndsAt: String? = null,
    val error: String? = null,
    val stage: String? = null,
)

/* ── Events tab (events_home) ──────────────────────────────────────────────── */

@Serializable
data class HomeData(
    val events: List<HomeEvent> = emptyList(),
    val invites: List<HomeInvite> = emptyList(),
    /** Events you're waiting for (2026-10-27). */
    val waitlist: List<HomeWaitlist> = emptyList(),
)

@Serializable
data class HomeEvent(
    val id: String,
    val name: String,
    @SerialName("short_code") val shortCode: String = "",
    val format: String = "draft",
    val status: String = "setup",
    /** live | upcoming | past */
    val bucket: String = "past",
    val organizing: Boolean = false,
    val playing: Boolean = false,
    @SerialName("venue_name") val venueName: String? = null,
    @SerialName("starts_at") val startsAt: String? = null,
    @SerialName("number_of_rounds") val numberOfRounds: Int = 3,
    @SerialName("current_round") val currentRound: Int = 0,
    @SerialName("is_demo") val isDemo: Boolean = false,
    @SerialName("cancel_reason") val cancelReason: String? = null,
    val players: Int = 0,
    @SerialName("my_status") val myStatus: String? = null,
    val round: HomeRound? = null,
    @SerialName("format_name") val formatName: String? = null,
    @SerialName("format_label") val formatLabel: String? = null,
    @SerialName("event_type") val eventType: String? = null,
    @SerialName("team_size") val teamSize: Int? = null,
    /** False when the organizer hid clocks; the round's ends_at / remaining_seconds are then null. */
    @SerialName("show_clock") val showClock: Boolean = true,
    val capacity: Int? = null,
    @SerialName("top_cut") val topCut: Int = 0,
    val decklists: String = "off",
    @SerialName("my_decklist") val myDecklist: Boolean = false,
) {
    /** A player who still owes a list for a constructed event before round 1. */
    val owesDecklist: Boolean get() = playing && decklists != "off" && !myDecklist && bucket == "upcoming"
    val label: String get() = formatLabel ?: format.replaceFirstChar { it.uppercase() }
    val isCancelled: Boolean get() = status == "cancelled"
    /** A seat in a round that is running right now. */
    val playingNow: Boolean get() = playing && myStatus == "active" && round?.timerStatus == "running"
}

@Serializable
data class HomeRound(
    val number: Int,
    @SerialName("timer_status") val timerStatus: String = "paused",
    @SerialName("duration_seconds") val durationSeconds: Int = 3000,
    @SerialName("ends_at") val endsAt: String? = null,
    @SerialName("remaining_seconds") val remainingSeconds: Int? = null,
    @SerialName("results_in") val resultsIn: Int = 0,
    val matches: Int = 0,
    val disputed: Int = 0,
    val stage: String = "swiss",
)

@Serializable
data class HomeInvite(
    @SerialName("event_id") val eventId: String,
    val name: String,
    val format: String = "draft",
    val source: String = "owner_invite",
    @SerialName("venue_name") val venueName: String? = null,
    @SerialName("starts_at") val startsAt: String? = null,
    @SerialName("invited_by") val invitedBy: String? = null,
    val players: Int = 0,
    @SerialName("format_label") val formatLabel: String? = null,
)

/** One live seat from the live-activity function (same data as the iOS Live Activity). */
@Serializable
data class LiveSnapshot(
    val eventId: String,
    val eventName: String = "",
    val participantId: String,
    val state: LiveState,
)

@Serializable
data class LiveState(
    val phase: String = "waiting",
    val round: Int = 0,
    val rounds: Int = 0,
    val endsAt: Double? = null,
    val pausedRemaining: Int? = null,
    val table: Int? = null,
    val myRank: Int? = null,
    val myRecord: String = "0-0",
    val players: Int = 0,
    val oppName: String? = null,
    val oppRank: Int? = null,
    val oppRecord: String? = null,
    val matchId: String? = null,
    val matchVersion: Int? = null,
    val mySide: Int? = null,
    val status: String? = null,
    val myWins: Int? = null,
    val theirWins: Int? = null,
    val canReport: Boolean = true,
) {
    val isPlaying: Boolean get() = phase == "playing"
    val tableText get() = table?.let { "T$it" } ?: "T–"
    val roundText get() = "R${maxOf(round, 1)}/$rounds"
    val myRankText get() = myRank?.let { "#$it" } ?: "#–"
    val oppRankText get() = oppRank?.let { "#$it" } ?: "#–"
    /** Over: the notification and the widget let go of it. */
    val ended get() = phase == "complete" || phase == "cancelled" || phase == "dropped"
    val canReportNow: Boolean get() = isPlaying && canReport && status == "pending"
    val needsMyAnswer: Boolean get() = isPlaying && status == "reported_them"
    val statusLine: String get() = when (phase) {
        "bye" -> "Bye this round"
        "waiting" -> "Waiting for round ${round + 1}"
        "complete" -> "Event complete"
        "cancelled" -> "Event cancelled"
        "dropped" -> "Dropped"
        else -> when (status) {
            "reported_me" -> "Reported ${myWins ?: 0}–${theirWins ?: 0} · waiting on ${oppName ?: "opponent"}"
            "reported_them" -> "${oppName ?: "Opponent"} reported ${myWins ?: 0}–${theirWins ?: 0}"
            "disputed" -> "Disputed · organizer deciding"
            "confirmed" -> "Confirmed ${myWins ?: 0}–${theirWins ?: 0}"
            else -> if (canReport) "Report when you're done" else "Organizer records results"
        }
    }
}

@Serializable
data class LiveStateResponse(val snapshots: List<LiveSnapshot> = emptyList(),
                             /** Events you organize (older servers send none). */ val organizer: List<OrganizerSnapshot> = emptyList())

/* ── Account tab (account_overview) ────────────────────────────────────────── */

@Serializable
data class AccountOverview(
    val profile: AccountProfile? = null,
    val record: AccountRecord = AccountRecord(),
    @SerialName("head_to_head") val headToHead: List<Rival> = emptyList(),
) {
    val label: String get() = profile?.let { it.handle?.takeIf { h -> h.isNotBlank() } ?: it.displayName } ?: "Account"
}

@Serializable
data class AccountProfile(val id: String, @SerialName("display_name") val displayName: String, val handle: String? = null)

@Serializable
data class AccountRecord(
    @SerialName("match_wins") val matchWins: Int = 0,
    @SerialName("match_losses") val matchLosses: Int = 0,
    @SerialName("match_draws") val matchDraws: Int = 0,
    val byes: Int = 0,
    @SerialName("game_wins") val gameWins: Int = 0,
    @SerialName("game_losses") val gameLosses: Int = 0,
    @SerialName("game_draws") val gameDraws: Int = 0,
    @SerialName("events_played") val eventsPlayed: Int = 0,
) {
    val matches: Int get() = matchWins + matchLosses + matchDraws
}

@Serializable
data class Rival(
    @SerialName("opponent_id") val opponentId: String,
    val name: String,
    @SerialName("match_wins") val matchWins: Int = 0,
    @SerialName("match_losses") val matchLosses: Int = 0,
    @SerialName("match_draws") val matchDraws: Int = 0,
    @SerialName("game_wins") val gameWins: Int = 0,
    @SerialName("game_losses") val gameLosses: Int = 0,
    val played: Int = 0,
)

/* ── Add players ───────────────────────────────────────────────────────────── */

@Serializable
data class SuggestedPlayer(
    @SerialName("user_id") val userId: String,
    @SerialName("display_name") val displayName: String,
    val handle: String? = null,
    @SerialName("shared_events") val sharedEvents: Int = 0,
    val invited: Boolean = false,
    /** A friend (contract/friends-sharing-2026-10-18.md): listed first. */
    val friend: Boolean = false,
) {
    val label: String get() = handle?.takeIf { it.isNotBlank() } ?: displayName
}

@Serializable
data class InviteResult(val invited: Int = 0)

@Serializable
data class NearbyEvent(
    @SerialName("event_id") val eventId: String,
    val name: String,
    @SerialName("venue_name") val venueName: String? = null,
    val format: String = "draft",
    val status: String = "setup",
    val players: Int = 0,
    val capacity: Int? = null,
    @SerialName("distance_m") val distanceM: Int = 0,
    /** Already an active player here, or its organizer: open the event instead of joining. */
    val joined: Boolean = false,
)

@Serializable
data class JoinQr(
    @SerialName("short_code") val shortCode: String,
    val secret: String,
    val url: String,
)

@Serializable
data class SeatResult(
    @SerialName("event_id") val eventId: String,
    @SerialName("participant_id") val participantId: String? = null,
    val seat: Int? = null,
    @SerialName("already_joined") val alreadyJoined: Boolean = false,
    val status: String? = null,
)

@Serializable
data class ReportOutcome(
    val ok: Boolean = false,
    val status: String = "pending",
    val version: Int = 0,
    val conflict: Boolean = false,
)

@Serializable
data class CreateEventResult(
    @SerialName("event_id") val eventId: String,
    @SerialName("short_code") val shortCode: String,
)

/** Everything one event screen needs, loaded in one go. */
data class EventBundle(
    val event: EventRow,
    val participants: List<ParticipantRow>,
    val rounds: List<RoundRow>,
    val isOrganizer: Boolean,
    val teams: List<EventTeamRow> = emptyList(),
    val waitlist: List<WaitlistEntry> = emptyList(),
    val decklists: List<DecklistInfo> = emptyList(),
) {
    val activeRound: RoundRow? get() = rounds.lastOrNull { it.status == "active" }
    fun decklist(participantId: String): DecklistInfo? = decklists.firstOrNull { it.participantId == participantId }
    val decklistsMissing: Int get() = participants.count { it.status == "active" && decklist(it.id) == null }

    /** What the organizer does next (contract §6). */
    val nextStep: String
        get() {
            val waiting = activeRound?.matches?.any { !it.isBye && (it.status == "pending" || (it.disputed && it.status != "confirmed")) } ?: false
            return EventRules.nextStep(rounds.map { it.stage }, waiting, event.numberOfRounds, event.topCut,
                participants.count { it.status == "active" })
        }
    fun name(participantId: String?): String =
        participants.firstOrNull { it.id == participantId }?.displayName ?: "—"
    fun teamName(teamId: String?): String? = teams.firstOrNull { it.id == teamId }?.name
    /** participant id → account id (guests have none), for avatars. */
    val userIds: Map<String, String> get() = participants.mapNotNull { p -> p.userId?.let { p.id to it } }.toMap()
}

/** One parsed QR join link: https://table-1.site/j/<code>?s=<secret> */
data class JoinLink(val code: String, val secret: String) {
    companion object {
        private val pattern = Regex("""^https?://[^/]+/j/([A-Za-z0-9]+)\?(?:.*&)?s=([0-9a-fA-F]+)""")
        fun parse(raw: String?): JoinLink? {
            val m = pattern.find(raw?.trim() ?: return null) ?: return null
            return JoinLink(m.groupValues[1], m.groupValues[2])
        }
    }
}

/**
 * The event behind a scanned QR, shown over sign-in (event_preview by the code; contract/qr-sign-up-2026-10-23.md).
 * [from] is null when there's nothing to show: private, cancelled or unknown codes fall back to the code itself.
 */
data class JoinPreview(val title: String, val facts: String) {
    @Serializable
    data class Wire(
        @SerialName("event_id") val eventId: String? = null,
        val access: String? = null,
        val name: String? = null,
        @SerialName("format_label") val formatLabel: String? = null,
        @SerialName("venue_name") val venueName: String? = null,
        val capacity: Int? = null,
        val players: Int? = null,
        @SerialName("organizer_name") val organizerName: String? = null,
    )

    companion object {
        fun from(w: Wire): JoinPreview? {
            fun text(s: String?) = s?.trim()?.takeIf { it.isNotEmpty() }
            val name = text(w.name)
            if (w.eventId == null || w.access == "none" || name == null) return null
            val players = w.players ?: 0
            val cap = w.capacity ?: 0
            val count = if (cap > 0) "$players/$cap players" else if (players == 1) "1 player" else "$players players"
            val facts = listOfNotNull(text(w.formatLabel), text(w.venueName), text(w.organizerName)?.let { "Run by $it" }, count)
            return JoinPreview(name, facts.joinToString(" · "))
        }
    }
}

/* ── create event and Setup (2026-10-14) ───────────────────────────────────── */

@Serializable
data class AddedPlayer(
    @SerialName("participant_id") val participantId: String,
    @SerialName("display_name") val displayName: String,
)

/** recent_cubes: cubes this account has run, newest first. */
@Serializable
data class RecentCube(
    @SerialName("cube_name") val cubeName: String,
    @SerialName("cube_url") val cubeUrl: String? = null,
    @SerialName("last_used_at") val lastUsedAt: String? = null,
)

/** cube-lookup: a Cube Cobra link → the cube's name (error set when the server refused). */
@Serializable
data class CubeLookup(
    @SerialName("cube_id") val cubeId: String? = null,
    val name: String? = null,
    @SerialName("card_count") val cardCount: Int? = null,
    val url: String? = null,
    val error: String? = null,
)

/** The name the server gives a new event: "<format label> · <Tue 14 Oct>". Shown as a preview on Create. */
object EventNaming {
    fun preview(formatLabel: String, product: String?, date: java.time.LocalDate = java.time.LocalDate.now()): String {
        val day = date.format(java.time.format.DateTimeFormatter.ofPattern("EEE d MMM", java.util.Locale.US))
        val p = product?.trim().orEmpty()
        return (if (p.isEmpty()) formatLabel else "$formatLabel · $p") + " · " + day
    }

    /** The device's date, sent as p_local_date so the name says the day it is here. */
    fun localDate(): String = java.time.LocalDate.now().toString()
}
