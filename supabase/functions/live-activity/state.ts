// Builds the per-player Live Activity state from one event's rows. Pure: no I/O.
// Field names match PlayerActivityAttributes.ContentState in the iOS app exactly (camelCase,
// dates as Unix seconds) because ActivityKit decodes push payloads with a default JSONDecoder.
import { computeStandings, recordLabel } from "./standings.ts";
import type { Match, MatchSide, Participant, RoundWithMatches } from "./types.ts";

export type Phase = "playing" | "bye" | "waiting" | "complete" | "cancelled" | "dropped";
export type MatchState = "pending" | "reported_me" | "reported_them" | "disputed" | "confirmed";

export interface ContentState {
  phase: Phase;
  round: number;
  rounds: number;
  roundSeconds: number;
  endsAt?: number;            // Unix seconds; present while the clock runs
  pausedRemaining?: number;   // seconds; present while the clock is paused
  table?: number;
  myName: string;
  myRank?: number;
  myRecord: string;
  players: number;
  oppName?: string;
  oppRank?: number;
  oppRecord?: string;
  matchId?: string;
  matchVersion?: number;
  mySide?: number;
  status?: MatchState;
  myWins?: number;
  theirWins?: number;
  draws?: number;
  canReport: boolean;
  updatedAt: number;
}

export interface Attributes { eventId: string; eventName: string; participantId: string }
export interface PlayerState { userId: string; participantId: string; attributes: Attributes; state: ContentState }

// deno-lint-ignore no-explicit-any
export const toParticipant = (r: any): Participant => ({
  id: r.id, eventId: r.event_id, podId: r.pod_id, displayName: r.display_name,
  seat: r.seat, status: r.status, droppedInRound: r.dropped_in_round, userId: r.user_id,
});
// deno-lint-ignore no-explicit-any
const toSide = (r: any): MatchSide => ({
  id: r.id, matchId: r.match_id, participantId: r.participant_id, side: r.side, gameWins: r.game_wins,
});
// deno-lint-ignore no-explicit-any
const toMatch = (r: any): Match => ({
  id: r.id, eventId: r.event_id, roundId: r.round_id, tableNumber: r.table_number, isBye: r.is_bye,
  gameDraws: r.game_draws, intentionalDraw: r.intentional_draw, status: r.status,
  version: r.version, disputed: r.disputed, reportedByUser: r.reported_by_user,
  sides: (r.match_sides ?? []).map(toSide).sort((a: MatchSide, b: MatchSide) => a.side - b.side),
});
// deno-lint-ignore no-explicit-any
export const toRound = (r: any): RoundWithMatches => ({
  id: r.id, eventId: r.event_id, number: r.number, status: r.status,
  timerDurationSeconds: r.timer_duration_seconds, timerRemainingAtChange: r.timer_remaining_at_change,
  timerStatus: r.timer_status, timerLastStartedAt: r.timer_last_started_at,
  matches: (r.matches ?? []).map(toMatch),
});

// deno-lint-ignore no-explicit-any
export function buildStates(event: any, participants: Participant[], rounds: RoundWithMatches[], only?: Set<string>): PlayerState[] {
  const standings = computeStandings(participants, rounds);
  const byId = new Map(standings.map((s) => [s.participantId, s]));
  const current = [...rounds].reverse().find((r) => r.status === "active") ?? null;
  const cancelled = event.status === "cancelled";
  const finished = cancelled || ["completed", "archived"].includes(event.status);
  const now = Date.now() / 1000;
  const active = participants.filter((p) => p.status === "active").length;

  const clock: Partial<ContentState> = {};
  if (current && !finished) {
    if (current.timerStatus === "running" && current.timerLastStartedAt) {
      clock.endsAt = Math.round(Date.parse(current.timerLastStartedAt) / 1000 + current.timerRemainingAtChange);
    } else {
      clock.pausedRemaining = Math.max(0, current.timerRemainingAtChange);
    }
  }

  const out: PlayerState[] = [];
  for (const p of participants) {
    if (!p.userId || (only && !only.has(p.id))) continue;
    const me = byId.get(p.id);
    const state: ContentState = {
      phase: "waiting",
      round: current?.number ?? event.current_round ?? 0,
      rounds: event.number_of_rounds,
      roundSeconds: current?.timerDurationSeconds ?? event.round_length_seconds,
      myName: p.displayName,
      myRank: me?.rank,
      myRecord: me ? recordLabel(me) : "0-0",
      players: active,
      canReport: !!event.allow_player_reporting,
      updatedAt: Math.round(now),
      ...clock,
    };
    if (finished) state.phase = cancelled ? "cancelled" : "complete";
    else if (p.status === "dropped") state.phase = "dropped";
    else if (current) {
      const m = current.matches.find((x) => x.sides.some((s) => s.participantId === p.id));
      if (m?.isBye) {
        state.phase = "bye";
        state.table = m.tableNumber ?? undefined;
      } else if (m) {
        const mine = m.sides.find((s) => s.participantId === p.id)!;
        const theirs = m.sides.find((s) => s.participantId !== p.id);
        const opp = theirs?.participantId ? byId.get(theirs.participantId) : undefined;
        state.phase = "playing";
        state.table = m.tableNumber ?? undefined;
        state.matchId = m.id;
        state.matchVersion = m.version;
        state.mySide = mine.side;
        state.oppName = opp?.displayName ?? "Opponent";
        state.oppRank = opp?.rank;
        state.oppRecord = opp ? recordLabel(opp) : undefined;
        state.myWins = mine.gameWins;
        state.theirWins = theirs?.gameWins ?? 0;
        state.draws = m.gameDraws;
        state.status = m.status === "confirmed" ? "confirmed"
          : m.status === "pending" ? "pending"
          : m.disputed ? "disputed"
          : m.reportedByUser && m.reportedByUser === p.userId ? "reported_me" : "reported_them";
      }
    }
    if (state.phase !== "playing") { delete state.endsAt; delete state.pausedRemaining; }
    out.push({
      userId: p.userId,
      participantId: p.id,
      attributes: { eventId: event.id, eventName: event.name, participantId: p.id },
      state,
    });
  }
  return out;
}
