// Domain types for the MTG team-event dashboard.
// These mirror the intended Supabase schema so the frontend can swap from
// local state to the database with minimal changes.

export type EventStatus =
  | "draft"
  | "ready"
  | "in_progress"
  | "paused"
  | "completed"
  | "archived";

export type MatchupMethod = "round_robin" | "swiss";

export type PairingResult = "pending" | "team_a_win" | "team_b_win" | "draw";

export type TimerStatus = "paused" | "running" | "completed";

export type SyncStatus = "saved" | "saving" | "offline" | "error";

export type Role = "owner" | "organizer" | "viewer";

export interface Team {
  id: string;
  name: string;
  color: string;
  displayOrder: number;
}

export interface Format {
  id: string;
  name: string;
  displayOrder: number;
}

export interface Player {
  id: string;
  teamId: string;
  formatId: string;
  name: string;
  displayOrder: number;
}

export interface Pairing {
  id: string;
  formatId: string;
  teamAPlayerId: string;
  teamBPlayerId: string;
  // Per-player game wins (0, 1, or 2). Each button cycles 0 → 1 → 2 → 0
  // independently; neither is ever disabled because the other reached 2.
  teamAGameWins: number;
  teamBGameWins: number;
  // Legacy: previously stored an organizer tie award. Ties are now recorded as
  // draws (no winner), so this is retained only for backward compatibility and
  // no longer affects scoring.
  tieResolutionTeamId?: string | null;
  // Timer remaining seconds at the moment this pairing first became decisive.
  // (durationSeconds - completedAtSeconds) gives elapsed match time in seconds.
  completedAtSeconds?: number | null;
  // Legacy field retained for older callers; results are now derived from game wins.
  result?: PairingResult;
}

export interface RecordedRound {
  roundNumber: number;
  pairings: Pairing[];
  recordedAt: string;
}

export interface TimerState {
  durationSeconds: number;
  remainingSecondsAtChange: number;
  status: TimerStatus;
  lastStartedAt: number | null; // epoch ms
}

export interface EventState {
  id: string;
  name: string;
  status: EventStatus;
  matchupMethod: MatchupMethod;
  numberOfRounds: number;
  currentRoundNumber: number;
  drawsAllowed: boolean;
  teams: Team[];
  formats: Format[];
  players: Player[];
  currentPairings: Pairing[];
  recordedRounds: RecordedRound[];
  timer: TimerState;
  role: Role;
}
