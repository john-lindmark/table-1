// Final standings for the results post, from the event's rows with the engine's own rules (events-engine
// standings.ts + playoffs.ts, the same files the web ships), so Discord, the apps and /s agree to the decimal.
// Deploying through the MCP needs these cross-folder imports copied in next to index.ts (as insight-brief does).
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { playoffStandings, type PlayoffStanding, type StagedRound } from "../events-engine/playoffs.ts";
import { computeTeamStandings, type Team, type TeamStanding } from "../events-engine/teams.ts";
import type { Match, MatchSide, Participant } from "../events-engine/types.ts";

// deno-lint-ignore no-explicit-any
const toParticipant = (r: any): Participant => ({
  id: r.id, eventId: r.event_id, podId: r.pod_id, displayName: r.display_name,
  seat: r.seat, status: r.status, droppedInRound: r.dropped_in_round, userId: r.user_id,
  teamId: r.team_id ?? null, teamSlot: r.team_slot ?? null,
});
// deno-lint-ignore no-explicit-any
const toSide = (r: any): MatchSide => ({
  id: r.id, matchId: r.match_id, participantId: r.participant_id, side: r.side, gameWins: r.game_wins,
});
// deno-lint-ignore no-explicit-any
const toMatch = (r: any): Match => ({
  id: r.id, eventId: r.event_id, roundId: r.round_id, tableNumber: r.table_number, isBye: r.is_bye,
  gameDraws: r.game_draws, intentionalDraw: r.intentional_draw, status: r.status,
  sides: (r.match_sides ?? []).map(toSide).sort((a: MatchSide, b: MatchSide) => a.side - b.side),
});
// deno-lint-ignore no-explicit-any
const toRound = (r: any): StagedRound => ({
  id: r.id, eventId: r.event_id, number: r.number, status: r.status, stage: r.stage ?? "swiss",
  timerDurationSeconds: r.timer_duration_seconds, timerRemainingAtChange: r.timer_remaining_at_change,
  timerStatus: r.timer_status, timerLastStartedAt: r.timer_last_started_at,
  matches: (r.matches ?? []).map(toMatch),
});

export interface ResultRow {
  rank: number;
  name: string;
  wins: number;
  losses: number;
  draws: number;
  points: number;
  dropped: boolean;
}

export function toRows(standings: PlayoffStanding[]): ResultRow[] {
  return standings.map((s) => ({
    rank: s.rank, name: s.displayName, wins: s.matchWins + s.byes, losses: s.matchLosses, draws: s.matchDraws,
    points: s.matchPoints, dropped: s.status === "dropped",
  }));
}

/** A team event's teams in order, each with its members best first (events-engine teams.ts). */
export interface TeamResultRow {
  rank: number;
  name: string;
  wins: number;
  losses: number;
  draws: number;
  points: number;
  matchWins: number;
  members: { name: string; wins: number; losses: number; draws: number; dropped: boolean }[];
}

export function toTeamRows(teams: TeamStanding[]): TeamResultRow[] {
  return teams.map((t) => ({
    rank: t.rank, name: t.name, wins: t.wins, losses: t.losses, draws: t.draws, points: t.points,
    matchWins: t.matchWins,
    members: t.members.map((m) => ({
      name: m.displayName, wins: m.matchWins, losses: m.matchLosses, draws: m.matchDraws, dropped: m.status === "dropped",
    })),
  }));
}

export const isTeamFormat = (format: string | null | undefined) => format === "team_draft" || format === "team_sealed";

/** The players' standings, and for a team event (team draft, team sealed) the teams' too; null otherwise. */
export async function loadStandings(
  admin: SupabaseClient,
  eventId: string,
  teamEvent = false,
): Promise<{ rows: ResultRow[]; teams: TeamResultRow[] | null }> {
  const [parts, rounds, teams] = await Promise.all([
    admin.from("participants").select("*").eq("event_id", eventId).order("seat"),
    admin.from("rounds").select("*, matches(*, match_sides(*))").eq("event_id", eventId).order("number"),
    teamEvent
      ? admin.from("event_teams").select("*").eq("event_id", eventId).eq("active", true).order("display_order")
      : Promise.resolve({ data: [], error: null }),
  ]);
  if (parts.error) throw parts.error;
  if (rounds.error) throw rounds.error;
  if (teams.error) throw teams.error;
  const participants = (parts.data ?? []).map(toParticipant);
  const staged = (rounds.data ?? []).map(toRound);
  // deno-lint-ignore no-explicit-any
  const teamList = (teams.data ?? []).map((t: any): Team => ({ id: t.id, name: t.name, order: t.display_order }));
  return {
    rows: toRows(playoffStandings(participants, staged)),
    teams: teamEvent && teamList.length ? toTeamRows(computeTeamStandings(teamList, participants, staged)) : null,
  };
}
