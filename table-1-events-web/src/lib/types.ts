// Domain types. These mirror the Postgres schema in the Table 1 Supabase
// project. A pod is first-class even when there is exactly one, and a match
// holds *sides* rather than playerA/playerB, so team events later are a change
// of cardinality rather than a change of model.

export type EventStatus = "setup" | "seated" | "in_progress" | "completed" | "archived" | "cancelled";
export type EventFormat = "draft" | "sealed" | "constructed" | "cube";
export type EventType = "constructed" | "limited";
export type FormatName =
  | "standard" | "pioneer" | "modern" | "legacy" | "vintage" | "pauper" | "premodern" | "canadian_highlander"
  | "other_constructed" | "draft" | "team_draft" | "sealed" | "team_sealed" | "roto" | "team_trios";
/** No cut, top 4 or top 8 (contract/teams-finals-alerts-2026-11-13.md § 1; which a format can have: leagues.ts cutChoices). */
export type TopCut = 0 | 4 | 8;
export type MatchStatus = "pending" | "reported" | "confirmed";
export type ParticipantStatus = "active" | "dropped";
export type TimerStatus = "paused" | "running";
export type SyncStatus = "saved" | "saving" | "offline" | "error";
export type Role = "owner" | "organizer" | "player" | "viewer";

export interface Table1Event {
  id: string;
  shortCode: string;
  name: string;
  format: EventFormat;
  status: EventStatus;
  numberOfRounds: number;
  currentRound: number;
  roundLengthSeconds: number;
  allowPlayerReporting: boolean;
  createdBy: string | null;
  cancelReason: string | null;
  formatName: FormatName;
  formatLabel: string;
  eventType: EventType;
  teamSize: number | null;
  setName: string | null;
  cubeName: string | null;
  cubeUrl: string | null;
  /** Scryfall set code for limited events (lowercase), when one was picked. */
  setCode: string | null;
  /** The typed name when the format is "Other" constructed. */
  formatOther: string | null;
  cancelledAt: string | null;
  updatedAt: string | null;
  /** "Round timer" on: clocks are shown. Rounds always run 50 minutes either way. */
  showClock: boolean;
  /** Named from its settings ("Draft · Duskmourn · Fri 17 Oct"); older events keep their typed names. */
  autoName: boolean;
  /** swiss | round_robin (roto only). */
  pairing: "swiss" | "round_robin";
  /** contract/scheduled-events-2026-10-27.md */
  topCut: TopCut;
  autoRounds: boolean;
  /** Team Trios: the format each seat plays, A first; null for every other format. */
  seatFormats: string[] | null;
  /** Team events: teams sign themselves up (captains and codes) instead of the organizer building them. */
  teamSignup: boolean;
  /** Who can find it: public / friends (listed in the Events tab, contract/public-events-leagues-2026-11-13.md § 1),
   *  link_only (Private: QR, code, link or invitation), and the two older choices nearby (150 m and alerts) and
   *  private (invitation only; contract/privacy-lockdown-2026-10-18.md). */
  visibility: "public" | "friends" | "nearby" | "link_only" | "private";
  /** Draft seating: players at both ends of the table too (contract/event-night-2026-10-16.md § 3). Drawing only. */
  seatEnds: boolean;
  capacity: number | null;
  startsAt: string | null;
  venueName: string | null;
  decklists: "off" | "optional" | "required";
  /** Drafts: the organizer's number of pods (null = automatic, pods of up to 8) and how rounds 2+ pair
   *  (contract/draft-pods-2026-11-09.md). */
  pods: number | null;
  podPairing: "pod" | "cross";
}

export interface Participant {
  id: string;
  eventId: string;
  podId: string | null;
  displayName: string;
  seat: number | null;
  status: ParticipantStatus;
  droppedInRound: number | null;
  /** Set when the seat belongs to a signed-in account (records and head-to-head follow it). */
  userId?: string | null;
  /** Team events: the participant's team and seat letter on it (1 = A). */
  teamId?: string | null;
  teamSlot?: number | null;
}

export interface Round {
  id: string;
  eventId: string;
  number: number;
  status: "pending" | "active" | "recorded";
  timerDurationSeconds: number;
  timerRemainingAtChange: number;
  timerStatus: TimerStatus;
  timerLastStartedAt: string | null;
  /** Set while running; the server keeps it equal to last_started_at + remaining_at_change. */
  timerEndsAt?: string | null;
  /** swiss | quarterfinal | semifinal | final (top 8). */
  stage?: "swiss" | "quarterfinal" | "semifinal" | "final";
  /** When the pairings went out (re-pair notice, lib/repairRound.ts). */
  pairingsPublishedAt?: string | null;
}

export interface MatchSide {
  id: string;
  matchId: string;
  participantId: string | null;
  side: 0 | 1;
  gameWins: number;
}

export interface Match {
  id: string;
  eventId: string;
  roundId: string;
  tableNumber: number | null;
  isBye: boolean;
  gameDraws: number;
  intentionalDraw: boolean;
  status: MatchStatus;
  sides: MatchSide[];
  /** Bumped by the server on every change; sent back as expected_version when reporting. */
  version?: number;
  disputed?: boolean;
  reportedByUser?: string | null;
  reportedByParticipant?: string | null;
  /** Who entered the result: a player report or the organizer (set_match_result). */
  resultSource?: "player" | "organizer" | null;
  /** Last change on the server (re-pair notice, lib/repairRound.ts). */
  updatedAt?: string | null;
  /** Extra time this table was given, in seconds (contract/room-tools-2026-11-13.md § 2). */
  extraSeconds?: number;
}

export interface RoundWithMatches extends Round {
  matches: Match[];
}

/* ── Events tab (events_home) ─────────────────────────────────────────── */

export interface HomeRound {
  number: number;
  timer_status: TimerStatus;
  duration_seconds: number;
  ends_at: string | null;
  remaining_seconds: number | null;
  results_in: number;
  matches: number;
  disputed: number;
  stage?: string | null;
}

export interface HomeEvent {
  id: string;
  name: string;
  short_code: string;
  format: EventFormat;
  format_name?: FormatName | null;
  format_label?: string | null;
  event_type?: EventType | null;
  team_size?: number | null;
  /** False when the organizer hid clocks for the event; the round's ends_at / remaining_seconds are then null. */
  show_clock?: boolean | null;
  status: EventStatus;
  /** live | upcoming | past */
  bucket: "live" | "upcoming" | "past";
  organizing: boolean;
  playing: boolean;
  venue_name: string | null;
  starts_at: string | null;
  number_of_rounds: number;
  current_round: number;
  cancel_reason: string | null;
  players: number;
  my_status: ParticipantStatus | null;
  round: HomeRound | null;
  capacity?: number | null;
  top_cut?: number | null;
  waitlist?: number | null;
  decklists?: "off" | "optional" | "required" | null;
  my_decklist?: boolean | null;
}

export interface HomeInvite {
  event_id: string;
  name: string;
  format: EventFormat;
  format_label?: string | null;
  source: "nearby_alert" | "owner_invite";
  venue_name: string | null;
  starts_at: string | null;
  invited_by: string | null;
  players: number;
}

export interface HomeWaitlist {
  event_id: string;
  name: string;
  format_label: string | null;
  starts_at: string | null;
  venue_name: string | null;
  position: number | null;
  players: number;
  capacity: number | null;
}

export interface HomeData {
  events: HomeEvent[];
  invites: HomeInvite[];
  /** Events you're waiting for (2026-10-27). */
  waitlist?: HomeWaitlist[];
}

/** One live seat from the live-activity function (the same state as the iOS Live Activity). */
export interface LiveSnapshot {
  eventId: string;
  participantId: string;
  state: {
    phase: string;
    round: number;
    rounds: number;
    endsAt?: number;
    pausedRemaining?: number;
    table?: number;
    myRank?: number;
    myRecord: string;
    oppName?: string;
    oppRank?: number;
    matchId?: string;
    matchVersion?: number;
    mySide?: number;
    status?: "pending" | "reported_me" | "reported_them" | "disputed" | "confirmed";
    myWins?: number;
    theirWins?: number;
    canReport: boolean;
  };
}

/* ── Account tab (account_overview) ───────────────────────────────────── */

export interface AccountOverview {
  profile: { id: string; display_name: string; handle: string | null } | null;
  record: {
    match_wins: number;
    match_losses: number;
    match_draws: number;
    byes: number;
    game_wins: number;
    game_losses: number;
    game_draws: number;
    events_played: number;
  };
  head_to_head: {
    opponent_id: string;
    name: string;
    match_wins: number;
    match_losses: number;
    match_draws: number;
    game_wins: number;
    game_losses: number;
    played: number;
  }[];
}

/* ── Add players ──────────────────────────────────────────────────────── */

export interface SuggestedPlayer {
  user_id: string;
  display_name: string;
  handle: string | null;
  shared_events: number;
  invited: boolean;
  /** A friend (contract/friends-sharing-2026-10-18.md): listed first. */
  friend?: boolean;
}

/* ── Formats, teams, seating ──────────────────────────────────────────── */

/** draftable_sets row (Scryfall sets for limited events). */
export interface DraftableSet {
  code: string;
  name: string;
  set_type: string;
  released_at: string | null;
  icon_svg_uri: string | null;
}

/** get_event_teams / set_teams / randomize_teams row. Slot 1 = seat A. */
export interface EventTeam {
  id: string;
  name: string;
  order: number;
  members: {
    participant_id: string;
    display_name: string;
    slot: number;
    user_id: string | null;
    status: ParticipantStatus;
  }[];
}

/** events-engine seat_players / standings.seating pod. */
export interface SeatingPod {
  pod_id: string;
  name: string;
  seats: { seat: number; participant_id: string; display_name: string; team: string | null }[];
}

/* ── Life tracker ─────────────────────────────────────────────────────── */

export type TrackerMode = "elsewhere" | "tracker";
