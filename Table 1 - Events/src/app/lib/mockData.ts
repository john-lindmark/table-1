import type { EventState, Pairing, Player } from "./types";

// Development seed data. This stands in for the Supabase-backed event until a
// backend is connected. Two teams, three formats, three players per team/format.

const TEAM_A = "team-a";
const TEAM_B = "team-b";

const FORMATS = [
  { id: "fmt-1", name: "Mystery Booster 2", displayOrder: 0 },
  { id: "fmt-2", name: "Final Fantasy", displayOrder: 1 },
  { id: "fmt-3", name: "Vintage cube", displayOrder: 2 },
];

const A_NAMES = [
  ["Alex", "Jordan", "Sam"],
  ["Riley", "Casey", "Morgan"],
  ["Taylor", "Quinn", "Avery"],
];
const B_NAMES = [
  ["Blake", "Drew", "Reese"],
  ["Skyler", "Parker", "Rowan"],
  ["Emerson", "Finley", "Hayden"],
];

function buildPlayers(): Player[] {
  const players: Player[] = [];
  FORMATS.forEach((fmt, fi) => {
    A_NAMES[fi].forEach((name, pi) => {
      players.push({
        id: `${TEAM_A}-${fmt.id}-${pi}`,
        teamId: TEAM_A,
        formatId: fmt.id,
        name,
        displayOrder: pi,
      });
    });
    B_NAMES[fi].forEach((name, pi) => {
      players.push({
        id: `${TEAM_B}-${fmt.id}-${pi}`,
        teamId: TEAM_B,
        formatId: fmt.id,
        name,
        displayOrder: pi,
      });
    });
  });
  return players;
}

const players = buildPlayers();

// Current-round pairings: pair each team-A player with a team-B player in the
// same format. Seed a few results so the dashboard shows a mid-match state.
function buildCurrentPairings(): Pairing[] {
  const pairings: Pairing[] = [];
  FORMATS.forEach((fmt) => {
    const as = players.filter((p) => p.teamId === TEAM_A && p.formatId === fmt.id);
    const bs = players.filter((p) => p.teamId === TEAM_B && p.formatId === fmt.id);
    as.forEach((a, i) => {
      pairings.push({
        id: `pair-${fmt.id}-${i}`,
        formatId: fmt.id,
        teamAPlayerId: a.id,
        teamBPlayerId: bs[i].id,
        teamAGameWins: 0,
        teamBGameWins: 0,
      });
    });
  });
  // Seed a couple of decisive game scores for a lively mid-match view.
  pairings[0].teamAGameWins = 2;
  pairings[0].teamBGameWins = 0;
  pairings[4].teamAGameWins = 1;
  pairings[4].teamBGameWins = 2;
  return pairings;
}

// One recorded historical round to populate cumulative wins.
function buildRecordedRounds() {
  const roundPairings: Pairing[] = [];
  FORMATS.forEach((fmt) => {
    const as = players.filter((p) => p.teamId === TEAM_A && p.formatId === fmt.id);
    const bs = players.filter((p) => p.teamId === TEAM_B && p.formatId === fmt.id);
    as.forEach((a, i) => {
      const aWins = (i + fmt.displayOrder) % 2 === 0;
      roundPairings.push({
        id: `r1-${fmt.id}-${i}`,
        formatId: fmt.id,
        teamAPlayerId: a.id,
        teamBPlayerId: bs[i].id,
        // Alternate decisive winners for a realistic spread.
        teamAGameWins: aWins ? 2 : 1,
        teamBGameWins: aWins ? 1 : 2,
      });
    });
  });
  return [
    {
      roundNumber: 1,
      pairings: roundPairings,
      recordedAt: new Date(Date.now() - 1000 * 60 * 45).toISOString(),
    },
  ];
}

export function createInitialEvent(): EventState {
  return {
    id: "evt-dev",
    name: "Denver Team League",
    status: "in_progress",
    matchupMethod: "round_robin",
    numberOfRounds: 5,
    currentRoundNumber: 2,
    drawsAllowed: false,
    teams: [
      { id: TEAM_A, name: "Denver Games", color: "#00ffd9", displayOrder: 0 },
      { id: TEAM_B, name: "Denver Drafters", color: "#7c7cff", displayOrder: 1 },
    ],
    formats: FORMATS,
    players,
    currentPairings: buildCurrentPairings(),
    recordedRounds: buildRecordedRounds(),
    timer: {
      durationSeconds: 3000,
      remainingSecondsAtChange: 3000,
      status: "paused",
      lastStartedAt: null,
    },
    role: "owner",
  };
}

export const TEAM_A_ID = TEAM_A;
export const TEAM_B_ID = TEAM_B;
