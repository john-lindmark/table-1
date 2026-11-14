// Dev server only: stand-in events for the TV display (contract/public-events-leagues-2026-11-13.md § 5), so
// /d/<demo id>?demo can be looked at without a server. Rounds are paired and ranked by the app's own rules
// (lib/pairings, lib/standings, lib/teams), so the lists look like a real event's. Production builds drop this file.
//
//   /d/demo?demo           64 players, Modern, round 2 of 6, 9 of 32 results in, clock running (12 minutes in)
//   /d/demo-small?demo     7-player draft, round 2 of 3, a bye, clock paused
//   /d/demo-team?demo      3v3 team draft, round 2 of 3
//   /d/demo-off?demo       16 players, "Round timer off"
//   /d/demo-welcome?demo   before round 1: name, start time, sign-up QR
//   /d/demo-final?demo     the 64-player event, finished
//   anything else          "This event isn't available"
//
// &elapsed=<seconds into the round> and &in=<results in> move the open round; &show= and the keys work as live.
import type { PublicEvent, PublicPairing, PublicStandings } from "./api";
import type { DisplayData } from "./display";
import { mulberry32, pairRound } from "./pairings";
import { computeStandings } from "./standings";
import { computeTeamStandings, pairTeamDraftRound, type Team } from "./teams";
import type { Match, Participant, RoundWithMatches } from "./types";

export interface DemoOptions {
  now?: number;
  /** Seconds into the open round. */
  elapsed?: number;
  /** Results in for the open round. */
  resultsIn?: number;
}

const FIRST = ["Ann", "Bo", "Cy", "Dee", "Eli", "Fen", "Gus", "Hal", "Ivy", "Jo", "Kai", "Lu", "Max", "Nia", "Oli", "Pat"];
const LAST = ["Ito", "Lindqvist", "Park", "Okafor", "Moreau", "Zhou", "Varga", "Brandt", "Novak", "Reyes", "Sato", "Bianchi"];
/** n different names: "Ann Ito", "Bo Lindqvist", …, every first name against a different last name each lap. */
const names = (n: number) => Array.from({ length: n }, (_, i) => `${FIRST[i % FIRST.length]} ${LAST[(i + Math.floor(i / FIRST.length) * 5) % LAST.length]}`);

function people(eventId: string, n: number): Participant[] {
  return names(n).map((displayName, i) => ({
    id: `p${i + 1}`, eventId, podId: null, displayName, seat: i + 1, status: "active", droppedInRound: null, userId: null,
  }));
}

/** One round from its proposed pairings: the first `played` matches have a result (the lower table wins 2–0 or 2–1). */
function roundOf(eventId: string, number: number, proposed: { tableNumber: number; side0ParticipantId: string; side1ParticipantId: string | null; isBye: boolean }[],
                 played: number, open: boolean, rng: () => number): RoundWithMatches {
  let done = 0;
  const matches: Match[] = proposed.map((m) => {
    const id = `m${number}-${m.tableNumber}`;
    const scored = m.isBye || done < played;
    if (!m.isBye && scored) done++;
    const roll = rng();
    const [a, b] = !scored || m.isBye ? [m.isBye ? 2 : 0, 0] : roll < 0.4 ? [2, 0] : roll < 0.6 ? [2, 1] : roll < 0.85 ? [0, 2] : [1, 2];
    return {
      id, eventId, roundId: `r${number}`, tableNumber: m.isBye ? null : m.tableNumber, isBye: m.isBye, gameDraws: 0, intentionalDraw: false,
      status: scored ? "confirmed" : "pending",
      sides: [
        { id: `${id}a`, matchId: id, participantId: m.side0ParticipantId, side: 0, gameWins: a },
        ...(m.side1ParticipantId ? [{ id: `${id}b`, matchId: id, participantId: m.side1ParticipantId, side: 1 as const, gameWins: b }] : []),
      ],
    };
  });
  return {
    id: `r${number}`, eventId, number, status: open ? "active" : "recorded", stage: "swiss", matches,
    timerDurationSeconds: 3000, timerRemainingAtChange: 3000, timerStatus: "paused", timerLastStartedAt: null, timerEndsAt: null,
  };
}

function publicPairings(round: RoundWithMatches, nameOf: Map<string, string>): PublicPairing[] {
  return round.matches.map((m) => ({
    matchId: m.id, tableNumber: m.tableNumber, isBye: m.isBye, status: m.status, gameDraws: m.gameDraws,
    sides: m.sides.map((s) => ({ side: s.side, participantId: s.participantId, displayName: nameOf.get(s.participantId ?? "") ?? "—", gameWins: s.gameWins })),
  }));
}

interface Spec {
  id: string;
  name: string;
  formatLabel: string;
  players: number;
  rounds: number;
  /** Rounds paired so far; the last one is open unless `finished`. */
  current: number;
  finished?: boolean;
  showClock?: boolean;
  paused?: boolean;
  team?: boolean;
  elapsed: number;
  resultsIn: number;
}

function build(spec: Spec, o: DemoOptions): DisplayData {
  const now = o.now ?? Date.now();
  const rng = mulberry32(20261113);
  const participants = people(spec.id, spec.players);
  const teams: Team[] = spec.team ? [{ id: "tA", name: "Team Ito", order: 0 }, { id: "tB", name: "Team Lindqvist", order: 1 }] : [];
  if (spec.team) participants.forEach((p, i) => Object.assign(p, { teamId: i % 2 === 0 ? "tA" : "tB", teamSlot: Math.floor(i / 2) + 1 }));
  const nameOf = new Map(participants.map((p) => [p.id, p.displayName]));
  const rounds: RoundWithMatches[] = [];
  for (let n = 1; n <= spec.current; n++) {
    const open = n === spec.current && !spec.finished;
    const proposed = spec.team
      ? pairTeamDraftRound(participants.filter((p) => p.teamId === "tA"), participants.filter((p) => p.teamId === "tB"), n)
      : pairRound({ participants, rounds, roundNumber: n, rng });
    const real = proposed.filter((m) => !m.isBye).length;
    rounds.push(roundOf(spec.id, n, proposed, open ? Math.min(real, o.resultsIn ?? spec.resultsIn) : real, open, rng));
  }
  const open = rounds.find((r) => r.status === "active") ?? null;
  if (open) {
    const elapsed = o.elapsed ?? spec.elapsed;
    if (spec.paused) Object.assign(open, { timerStatus: "paused", timerRemainingAtChange: open.timerDurationSeconds - elapsed });
    else Object.assign(open, { timerStatus: "running", timerRemainingAtChange: open.timerDurationSeconds, timerLastStartedAt: new Date(now - elapsed * 1000).toISOString() });
  }
  const tomorrow = new Date(now + 24 * 3600 * 1000);
  tomorrow.setHours(18, 30, 0, 0);
  const event: PublicEvent = {
    eventId: spec.id, name: spec.name, status: spec.finished ? "completed" : spec.current === 0 ? "setup" : "in_progress",
    currentRound: spec.current, numberOfRounds: spec.rounds, showClock: spec.showClock ?? true,
    round: open ? { ...open, matches: [] } : null,
    pairings: open ? publicPairings(open, nameOf) : [],
    rounds: [...rounds].reverse().map((r) => ({ number: r.number, stage: "swiss", status: r.status, matches: publicPairings(r, nameOf) })),
    access: "link", shortCode: "DEMO", formatLabel: spec.formatLabel, startsAt: spec.current === 0 ? tomorrow.toISOString() : null,
    venueName: "Denver Card Shop", organizerName: "Ann Ito", capacity: spec.current === 0 ? 16 : null, players: spec.players, waitlist: 0,
    topCut: 0, autoRounds: false, signUp: spec.current === 0 ? "open" : "closed", me: null, position: null, decklists: "off",
  };
  const standings: PublicStandings = {
    bracket: [], pods: [],
    rows: computeStandings(participants, rounds).map((s) => ({
      rank: s.rank, participantId: s.participantId, displayName: s.displayName, status: s.status, matchPoints: s.matchPoints,
      matchWins: s.matchWins, matchLosses: s.matchLosses, matchDraws: s.matchDraws, byes: s.byes, omw: s.opponentMatchWinPct, gw: s.gameWinPct,
    })),
    teams: spec.team
      ? computeTeamStandings(teams, participants, rounds).map((t) => ({
          rank: t.rank, teamId: t.teamId, name: t.name, points: t.points, wins: t.wins, losses: t.losses, draws: t.draws, matchWins: t.matchWins,
          members: t.members.map((m) => ({ participantId: m.participantId, displayName: m.displayName, matchWins: m.matchWins,
                                           matchLosses: m.matchLosses, matchDraws: m.matchDraws, status: m.status })),
        }))
      : null,
  };
  return { event, standings };
}

const SPECS: Spec[] = [
  { id: "demo", name: "Modern Open", formatLabel: "Modern", players: 64, rounds: 6, current: 2, elapsed: 720, resultsIn: 9 },
  { id: "demo-small", name: "Draft · Duskmourn · Fri 13 Nov", formatLabel: "Draft · Duskmourn", players: 7, rounds: 3, current: 2, paused: true, elapsed: 1276, resultsIn: 1 },
  { id: "demo-team", name: "Team draft · Duskmourn · Fri 13 Nov", formatLabel: "Team draft · Duskmourn", players: 6, rounds: 3, current: 2, team: true, elapsed: 900, resultsIn: 1 },
  { id: "demo-off", name: "Pauper League · Week 3", formatLabel: "Pauper", players: 16, rounds: 4, current: 3, showClock: false, elapsed: 1500, resultsIn: 5 },
  { id: "demo-welcome", name: "Modern Open", formatLabel: "Modern", players: 12, rounds: 4, current: 0, elapsed: 0, resultsIn: 0 },
  { id: "demo-final", name: "Modern Open", formatLabel: "Modern", players: 64, rounds: 6, current: 6, finished: true, elapsed: 0, resultsIn: 0 },
];

export const DEMO_DISPLAYS = SPECS.map((s) => s.id);

/** The stand-in event for a demo id, or null (the display then reads "This event isn't available"). */
export function demoDisplay(id: string, options: DemoOptions = {}): DisplayData | null {
  const spec = SPECS.find((s) => s.id === id);
  return spec ? build(spec, options) : null;
}
