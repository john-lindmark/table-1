// Builds the organizer's Live Activity state from one event's rows. Pure: no I/O.
// Field names match OrganizerActivityAttributes.ContentState in the iOS app exactly (camelCase, Unix seconds).
// Contract: contract/widgets-2026-10-22.md.
import type { Match, Participant, RoundWithMatches } from "./types.ts";

export type OrgPhase = "live" | "between" | "complete" | "cancelled";

export interface OrgContentState {
  phase: OrgPhase;
  round: number;
  rounds: number;
  roundSeconds: number;
  endsAt?: number;
  pausedRemaining?: number;
  matches: number;
  done: number;
  waiting: number;
  disputes: number;
  guestWaiting: number;
  players: number;
  updatedAt: number;
}

export interface OrgAttributes { eventId: string; eventName: string }
export interface OrgState { attributes: OrgAttributes; state: OrgContentState }

/** Still needs the organizer: pending, or disputed and not decided (the organizer screen's `outstanding`). */
export const isWaiting = (m: Match) => m.status === "pending" || (!!m.disputed && m.status !== "confirmed");

// deno-lint-ignore no-explicit-any
export function buildOrganizerState(event: any, participants: Participant[], rounds: RoundWithMatches[]): OrgState {
  const current = [...rounds].reverse().find((r) => r.status === "active") ?? null;
  const last = current ?? [...rounds].sort((a, b) => b.number - a.number)[0] ?? null;
  const cancelled = event.status === "cancelled";
  const finished = cancelled || ["completed", "archived"].includes(event.status);
  const accounts = new Map(participants.map((p) => [p.id, p.userId ?? null]));

  const games = (current?.matches ?? []).filter((m) => !m.isBye);
  const waiting = games.filter(isWaiting);
  const state: OrgContentState = {
    phase: finished ? (cancelled ? "cancelled" : "complete") : current ? "live" : "between",
    round: last?.number ?? event.current_round ?? 0,
    rounds: event.number_of_rounds,
    roundSeconds: current?.timerDurationSeconds ?? event.round_length_seconds,
    matches: games.length,
    done: games.length - waiting.length,
    waiting: waiting.length,
    disputes: waiting.filter((m) => m.disputed).length,
    // Nobody with an account can report these: the organizer keeps score.
    guestWaiting: waiting.filter((m) => m.status === "pending" && !m.disputed &&
      m.sides.every((s) => !s.participantId || !accounts.get(s.participantId))).length,
    players: participants.filter((p) => p.status === "active").length,
    updatedAt: Math.round(Date.now() / 1000),
  };
  if (current && !finished && event.show_clock !== false) {
    if (current.timerStatus === "running" && current.timerLastStartedAt) {
      state.endsAt = Math.round(Date.parse(current.timerLastStartedAt) / 1000 + current.timerRemainingAtChange);
    } else {
      state.pausedRemaining = Math.max(0, current.timerRemainingAtChange);
    }
  }
  return { attributes: { eventId: event.id, eventName: event.name }, state };
}

/** The organizer's alert for a `match` dispatch, if any: a new dispute, or the round's last result settling. */
export function organizerAlert(o: OrgState, flags: { disputed?: boolean; settled?: boolean },
  disputedTable?: number | null): { title: string; body: string } | undefined {
  const s = o.state;
  if (s.phase !== "live") return undefined;
  if (flags.disputed) {
    return { title: `Dispute${disputedTable ? ` at table ${disputedTable}` : ""}`, body: `${o.attributes.eventName} · Decide it from the Live tab.` };
  }
  if (flags.settled && s.waiting === 0 && s.matches > 0) {
    const next = s.round < s.rounds ? `Pair round ${s.round + 1}` : "Finish event";
    return { title: `All results in · ${next}`, body: o.attributes.eventName };
  }
  return undefined;
}
