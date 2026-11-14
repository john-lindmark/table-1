// Final places, kept once an event is over (public.event_placements; contract/public-events-leagues-2026-11-13.md
// § Final places). A copy of what the standings say, for leagues and profiles to read: never an input to standings.
//
// Individual events: the final order (playoffs.ts: the top 8 or top 4 by how far they went, everyone else by Swiss
// standing). Team events: every member takes their team's place and playoff stage (teams.ts: after a top 4 the
// winning team's members are all 1st and `winner`), so league points and qualification go to the whole team; each
// row keeps the player's own Swiss record.
import { playoffStandings, type StagedRound } from "./playoffs.ts";
import { computeTeamStandings, type Team } from "./teams.ts";
import type { Participant } from "./types.ts";

export interface PlacementRow {
  participant_id: string;
  place: number;
  match_points: number;
  match_wins: number;
  match_losses: number;
  match_draws: number;
  playoff: string | null;
  team_id: string | null;
}

export function placementRows(
  participants: Participant[], rounds: StagedRound[], teams: Team[], teamEvent: boolean,
): PlacementRow[] {
  const teamOf = new Map<string, { teamId: string; rank: number; playoff: string | null }>();
  let teamCount = 0;
  if (teamEvent) {
    const standings = computeTeamStandings(teams, participants, rounds);
    teamCount = standings.length;
    for (const t of standings) {
      for (const m of t.members) teamOf.set(m.participantId, { teamId: t.teamId, rank: t.rank, playoff: t.playoff });
    }
  }
  return playoffStandings(participants, rounds).map((s) => {
    const team = teamOf.get(s.participantId);
    return {
      participant_id: s.participantId,
      // A player on no team in a team event sits behind every team.
      place: teamEvent ? team?.rank ?? teamCount + 1 : s.rank,
      match_points: s.matchPoints,
      match_wins: s.matchWins,
      match_losses: s.matchLosses,
      match_draws: s.matchDraws,
      playoff: teamEvent ? team?.playoff ?? null : s.playoff,
      team_id: team?.teamId ?? null,
    };
  });
}
