// Subset of events-engine/types.ts used by the live-activity function.
export interface Participant {
  id: string; eventId: string; podId: string | null; displayName: string; seat: number | null;
  status: "active" | "dropped"; droppedInRound: number | null; userId?: string | null;
}
export interface MatchSide { id: string; matchId: string; participantId: string | null; side: 0 | 1; gameWins: number }
export interface Match {
  id: string; eventId: string; roundId: string; tableNumber: number | null; isBye: boolean; gameDraws: number;
  intentionalDraw: boolean; status: "pending" | "reported" | "confirmed"; sides: MatchSide[];
  version?: number; disputed?: boolean; reportedByUser?: string | null;
}
export interface RoundWithMatches {
  id: string; eventId: string; number: number; status: "pending" | "active" | "recorded";
  timerDurationSeconds: number; timerRemainingAtChange: number; timerStatus: "paused" | "running";
  timerLastStartedAt: string | null; matches: Match[];
}
