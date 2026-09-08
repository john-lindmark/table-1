// Domain types. These mirror the Postgres schema in the Table 1 Supabase
// project. A pod is first-class even when there is exactly one, and a match
// holds *sides* rather than playerA/playerB, so team events later are a change
// of cardinality rather than a change of model.

export type EventStatus = "setup" | "seated" | "in_progress" | "completed" | "archived";
export type EventFormat = "draft" | "sealed" | "constructed" | "cube";
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
}

export interface Participant {
  id: string;
  eventId: string;
  podId: string | null;
  displayName: string;
  seat: number | null;
  status: ParticipantStatus;
  droppedInRound: number | null;
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
}

export interface RoundWithMatches extends Round {
  matches: Match[];
}
