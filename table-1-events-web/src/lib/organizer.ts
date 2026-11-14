// Pure helpers for the organizer's event screen (Setup / Live / Results).
// Spec: contract/organizer-phases-2026-10-14.md. Nothing here touches the network or the DOM.

import type { EventDetailsInput } from "./api";
import { isDraftFormat, isTeamFormat, isTriosFormat, typeOfFormat } from "./formats";
import { cutChoices } from "./leagues";
import { nextStep } from "./playoffs";
import type { TeamClinch } from "./teams";
import type { DraftableSet, EventStatus, FormatName, Match, Participant, RoundWithMatches, Table1Event, TopCut } from "./types";

/* ── phase ──────────────────────────────────────────────────────────────── */

export type Phase = "setup" | "live" | "results";

/**
 * Derived, never stored.
 *   Results: completed / archived / cancelled.
 *   Setup:   setup or seated, and no rounds exist.
 *   Live:    in_progress, or any round exists (and the event isn't over).
 */
export function derivePhase(status: EventStatus, roundCount: number): Phase {
  if (status === "completed" || status === "archived" || status === "cancelled") return "results";
  if ((status === "setup" || status === "seated") && roundCount === 0) return "setup";
  return "live";
}

export type OrganizerTab = "players" | "seating" | "teams" | "details" | "round" | "schedule" | "standings" | "rounds" | "prizes";

export const TAB_LABELS: Record<OrganizerTab, string> = {
  players: "Players",
  seating: "Seating",
  teams: "Teams",
  details: "Details",
  round: "Round",
  schedule: "Schedule",
  standings: "Standings",
  rounds: "Rounds",
  prizes: "Prizes",
};

/** The tabs of each phase, first tab first (it's where a phase change lands). */
export function phaseTabs(
  phase: Phase,
  opts: { isTeam: boolean; isDraft: boolean; isRoto?: boolean; roundRobin?: boolean; earlier?: boolean; prizes?: boolean },
): OrganizerTab[] {
  if (phase === "setup") {
    // Roto: Seating is the pick order list.
    const seating = opts.isDraft || opts.isRoto;
    return ["players", ...(seating ? (["seating"] as const) : []), ...(opts.isTeam ? (["teams"] as const) : []), "details"];
  }
  if (phase === "live") {
    // Earlier: the rounds before the current one, to correct a result (and re-pair; contract/repair-round-2026-11-09.md).
    return ["round", ...(opts.earlier ? (["rounds"] as const) : []), ...(opts.roundRobin ? (["schedule"] as const) : []),
            "standings", "players", ...(opts.isTeam ? (["teams"] as const) : [])];
  }
  // Prizes: a finished event with a fee or added prize money (contract/entry-fees-2026-11-13.md § 4).
  return ["standings", "rounds", "players", ...(opts.prizes ? (["prizes"] as const) : [])];
}

/**
 * The tab to show: the remembered one if it belongs to the current phase and still exists,
 * otherwise the phase's first tab (so a phase change resets the tab).
 */
export function resolveTab(
  selected: { phase: Phase; tab: OrganizerTab } | null,
  phase: Phase,
  tabs: OrganizerTab[],
): OrganizerTab {
  if (selected && selected.phase === phase && tabs.includes(selected.tab)) return selected.tab;
  return tabs[0];
}

/* ── matches ────────────────────────────────────────────────────────────── */

export type MatchGroupName = "disputed" | "waiting" | "results";

/** Disputed: players reported different scores. Waiting: no result yet. Results in: reported/confirmed, and byes. */
export function matchGroupOf(m: Match): MatchGroupName {
  if (m.isBye) return "results";
  if (m.disputed && m.status !== "confirmed") return "disputed";
  if (m.status === "pending") return "waiting";
  return "results";
}

const byTable = (a: Match, b: Match) => (a.tableNumber ?? 0) - (b.tableNumber ?? 0);

export interface MatchGroups {
  disputed: Match[];
  waiting: Match[];
  /** Results in, by table; byes last. */
  results: Match[];
}

/** Groups a round's matches in display order: Disputed, Waiting, Results in (byes listed last). */
export function groupMatches(matches: Match[]): MatchGroups {
  const groups: MatchGroups = { disputed: [], waiting: [], results: [] };
  for (const m of matches) groups[matchGroupOf(m)].push(m);
  groups.disputed.sort(byTable);
  groups.waiting.sort(byTable);
  groups.results.sort((a, b) => Number(a.isBye) - Number(b.isBye) || byTable(a, b));
  return groups;
}

/** Matches the organizer still has to see through: waiting + disputed. */
export function openMatchCount(round: RoundWithMatches | null | undefined): number {
  if (!round) return 0;
  return round.matches.filter((m) => matchGroupOf(m) !== "results").length;
}

const wins = (m: Match, side: 0 | 1) => m.sides.find((s) => s.side === side)?.gameWins ?? 0;

/** "2–1", "1–1–1" with game draws. */
export function scoreText(m: Match): string {
  const base = `${wins(m, 0)}–${wins(m, 1)}`;
  return m.gameDraws > 0 ? `${base}–${m.gameDraws}` : base;
}

export type NameOf = (participantId: string | null | undefined) => string;

export function nameLookup(participants: Participant[]): NameOf {
  const byId = new Map(participants.map((p) => [p.id, p.displayName]));
  return (id) => (id && byId.get(id)) || "—";
}

/** "T3 · Alex v Brit"; byes "Alex · Bye". */
export function matchTitle(m: Match, nameOf: NameOf): string {
  const a = nameOf(m.sides.find((s) => s.side === 0)?.participantId);
  if (m.isBye) return `${a} · Bye`;
  const b = nameOf(m.sides.find((s) => s.side === 1)?.participantId);
  return `T${m.tableNumber ?? "–"} · ${a} v ${b}`;
}

/**
 * The detail line on the Live round list.
 * `otherReport` is the second (conflicting) score when it's known, e.g. "1–2".
 */
export function matchDetail(m: Match, nameOf: NameOf, otherReport?: string | null): string {
  if (m.isBye) return "";
  switch (matchGroupOf(m)) {
    case "disputed":
      return otherReport ? `Reported ${scoreText(m)} and ${otherReport} · tap to set` : "Reported differently · tap to set";
    case "waiting":
      return "No result yet";
    default:
      if (m.resultSource === "organizer") return "Set by organizer";
      if (m.status === "confirmed") return "Confirmed";
      return `Reported by ${m.reportedByParticipant ? nameOf(m.reportedByParticipant) : "a player"}`;
  }
}

/** Value on the right: the score once a result is in, otherwise "Set". Byes: "Bye". */
export function matchValue(m: Match): string {
  if (m.isBye) return "Bye";
  return matchGroupOf(m) === "results" ? scoreText(m) : "Set";
}

/* ── clock ──────────────────────────────────────────────────────────────── */

/**
 * Seconds left on a round, never below 0.
 * Running: ends = timer_last_started_at + timer_remaining_at_change (or timer_ends_at).
 * Paused: timer_remaining_at_change.
 */
export function remainingSeconds(round: RoundWithMatches | null | undefined, now: number): number {
  if (!round) return 0;
  if (round.timerStatus === "running") {
    let end: number | null = null;
    if (round.timerLastStartedAt) end = new Date(round.timerLastStartedAt).getTime() + round.timerRemainingAtChange * 1000;
    else if (round.timerEndsAt) end = new Date(round.timerEndsAt).getTime();
    if (end != null && !Number.isNaN(end)) return Math.max(0, Math.ceil((end - now) / 1000));
  }
  return Math.max(0, round.timerRemainingAtChange);
}

/** "50:00", "4:05", "0:00". */
export function formatMmSs(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

/** Optimistic copy of what set_round_clock does, so the clock responds before the server answers. */
export function applyClock(
  round: RoundWithMatches,
  action: "pause" | "resume" | "add",
  seconds: number,
  now: number,
): RoundWithMatches {
  const left = remainingSeconds(round, now);
  const iso = new Date(now).toISOString();
  if (action === "add") {
    const next = Math.max(0, left + seconds);
    const running = round.timerStatus === "running";
    return {
      ...round,
      timerDurationSeconds: Math.max(60, round.timerDurationSeconds + seconds),
      timerRemainingAtChange: next,
      timerLastStartedAt: running ? iso : null,
      timerEndsAt: running ? new Date(now + next * 1000).toISOString() : null,
    };
  }
  if (action === "pause" && round.timerStatus === "running") {
    return { ...round, timerStatus: "paused", timerRemainingAtChange: left, timerLastStartedAt: null, timerEndsAt: null };
  }
  if (action === "resume" && round.timerStatus === "paused") {
    return {
      ...round,
      timerStatus: "running",
      timerRemainingAtChange: left,
      timerLastStartedAt: iso,
      timerEndsAt: new Date(now + left * 1000).toISOString(),
    };
  }
  return round;
}

/* ── bar subtitles, captions ────────────────────────────────────────────── */

export const activeRoundOf = (rounds: RoundWithMatches[]) => rounds.find((r) => r.status === "active") ?? null;
export const lastRoundNumber = (rounds: RoundWithMatches[]) => rounds.reduce((n, r) => Math.max(n, r.number), 0);
const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

/** "K7Q2 · Setup · 8 players · Draft" */
export function setupSubtitle(event: Table1Event, players: number): string {
  return `${event.shortCode} · Setup · ${plural(players, "player")} · ${event.formatLabel}`;
}

/** "Round 2 of 4 · 12:34 left · Draft" (or "paused", or "time"). Between rounds: "Round 1 of 4 · Draft". */
export function liveSubtitle(event: Table1Event, rounds: RoundWithMatches[], now: number): string {
  const active = activeRoundOf(rounds);
  const r = active?.number ?? lastRoundNumber(rounds);
  // A playoff round reads as its stage ("Semifinals"), never "Round 4 of 3".
  const stage = active?.stage ?? rounds.find((x) => x.number === r)?.stage ?? "swiss";
  const head = stage === "quarterfinal" ? "Quarterfinals" : stage === "semifinal" ? "Semifinals" : stage === "final" ? "Final" : `Round ${r} of ${event.numberOfRounds}`;
  if (!active || !event.showClock) return `${head} · ${event.formatLabel}`;
  const left = remainingSeconds(active, now);
  const clock = active.timerStatus === "paused" ? "paused" : left <= 0 ? "time" : `${formatMmSs(left)} left`;
  return `${head} · ${clock} · ${event.formatLabel}`;
}

/** "Round 2 of 4 · 5 of 8 results in · 1 disputed"; paused: "Paused · Round 2 of 4". */
export function roundCaption(event: Table1Event, round: RoundWithMatches): string {
  const head = `Round ${round.number} of ${event.numberOfRounds}`;
  if (round.timerStatus === "paused") return `Paused · ${head}`;
  const real = round.matches.filter((m) => !m.isBye);
  const groups = groupMatches(real);
  const disputed = groups.disputed.length;
  return `${head} · ${groups.results.length} of ${real.length} results in${disputed ? ` · ${disputed} disputed` : ""}`;
}

export function shortDate(iso: string | null | undefined): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

/** "Final · Oct 12 · 8 players · Draft"; cancelled: "Cancelled · Oct 12 · after round 2 of 4". */
export function resultsSubtitle(
  event: Table1Event,
  rounds: RoundWithMatches[],
  players: number,
  formatDate: (iso: string | null | undefined) => string = shortDate,
): string {
  const cancelled = event.status === "cancelled";
  const date = formatDate(cancelled ? event.cancelledAt ?? event.updatedAt : event.updatedAt);
  const parts = cancelled
    ? ["Cancelled", date, `after round ${lastRoundNumber(rounds)} of ${event.numberOfRounds}`]
    : ["Final", date, plural(players, "player"), event.formatLabel];
  return parts.filter(Boolean).join(" · ");
}

/* ── big actions and their dialogs ──────────────────────────────────────── */

/** Why "Start event · pair round 1" is disabled, or null when it can go. */
export function startBlocker(activePlayers: number, teamIssue: string | null): string | null {
  if (activePlayers < 2) return "Add at least 2 players";
  return teamIssue || null;
}

export function startDialog(event: Table1Event): { title: string; message: string } {
  const minutes = Math.round(event.roundLengthSeconds / 60);
  const how = isDraftFormat(event.formatName) ? "Pairs round 1 across the table and starts" : "Pairs round 1 and starts";
  const clock = event.showClock ? `the ${minutes}-minute clock` : "the round (clocks hidden)";
  return {
    title: `Start ${event.name}?`,
    message: `${how} ${clock}. Format, rounds and teams lock.`,
  };
}

export type LiveAction =
  | { kind: "waiting"; open: number; label: string }
  | { kind: "pair"; round: number; label: string }
  | { kind: "finish"; label: string; clinch?: TeamClinch; pairRound?: number }
  | { kind: "cut"; label: string }
  | { kind: "playoff"; stage: "semifinal" | "final"; label: string };

/**
 * Live big action: "Waiting on N results" (disabled) while the open round has open matches,
 * then "Pair round R+1", or "Finish event" on the last round.
 */
export function liveAction(event: Table1Event, rounds: RoundWithMatches[], clinch: TeamClinch | null = null,
                           activePlayers = 0, activeTeams: number | null = null): LiveAction {
  const active = activeRoundOf(rounds);
  const open = openMatchCount(active);
  const current = active?.number ?? lastRoundNumber(rounds);
  // A team that can't be caught: finish now (open matches don't count), unless a dispute is still open (the server
  // refuses to finish over one). Pairing on stays possible when the round is in.
  if (clinch && !active?.matches.some((m) => matchGroupOf(m) === "disputed")) {
    return open === 0 && current < event.numberOfRounds
      ? { kind: "finish", label: "Finish event", clinch, pairRound: current + 1 }
      : { kind: "finish", label: "Finish event", clinch };
  }
  if (open > 0) return { kind: "waiting", open, label: `Waiting on ${plural(open, "result")}` };
  // Swiss, then the top 8 or top 4 (contract/scheduled-events-2026-10-27.md §6, contract/teams-finals-alerts-2026-11-13.md
  // § 1): the shared next step decides. Team sealed and Team Trios cut between teams, so they count active teams.
  const stages = rounds.map((r) => r.stage ?? "swiss");
  const cut = event.topCut > 0 && cutChoices(event.formatName, event.pairing).includes(event.topCut);
  if (stages.some((st) => st !== "swiss") || cut) {
    const step = nextStep({ stages, waiting: false, numberOfRounds: event.numberOfRounds, topCut: event.topCut, activePlayers,
                            activeTeams: isTeamFormat(event.formatName) ? activeTeams ?? 0 : null });
    if (step === "cut") return { kind: "cut", label: "Cut to top 8" };
    if (step === "cut4") return { kind: "cut", label: "Cut to top 4" };
    if (step === "semifinals") return { kind: "playoff", stage: "semifinal", label: "Pair semifinals" };
    if (step === "final") return { kind: "playoff", stage: "final", label: "Pair the final" };
    if (step === "finish") return { kind: "finish", label: "Finish event" };
  }
  if (current >= event.numberOfRounds) return { kind: "finish", label: "Finish event" };
  return { kind: "pair", round: current + 1, label: `Pair round ${current + 1}` };
}

/** "Alpha has clinched it: 5–2 in match wins with 2 left to play." */
export function clinchText(c: TeamClinch): string {
  const team = /^team\b/i.test(c.name) ? c.name : `Team ${c.name}`;
  return `${team} has clinched it: ${c.matchWins}–${c.opponentMatchWins} in match wins with ${plural(c.remaining, "match", "matches")} left to play.`;
}

/* ── records ────────────────────────────────────────────────────────────── */

/** Games won and lost across scored, non-bye matches. */
export function gameRecord(participantId: string, rounds: RoundWithMatches[]): { won: number; lost: number } {
  let won = 0;
  let lost = 0;
  for (const r of rounds) {
    for (const m of r.matches) {
      if (m.isBye || m.status === "pending") continue;
      const mine = m.sides.find((s) => s.participantId === participantId);
      if (!mine) continue;
      const theirs = m.sides.find((s) => s.side !== mine.side);
      won += mine.gameWins;
      lost += theirs?.gameWins ?? 0;
    }
  }
  return { won, lost };
}

/* ── Setup → Details ────────────────────────────────────────────────────── */

export interface DetailsState {
  name: string;
  formatName: FormatName;
  formatOther: string;
  product: "set" | "cube";
  set: DraftableSet | null;
  setNameText: string;
  cubeName: string;
  cubeUrl: string;
  teamSize: 3 | 4;
  rounds: number;
  showClock: boolean;
  /** Named by the server while `name` is empty (contract/scheduled-events-2026-10-27.md §1). */
  autoName: boolean;
  /** Roto only. */
  pairing: "swiss" | "round_robin";
  topCut: TopCut;
  autoRounds: boolean;
  decklists: "off" | "optional" | "required";
}

/** The cut a format keeps when the organizer changes format: the pick if the format can have it, else none. */
export const cutFor = (formatName: FormatName, pairing: string | null | undefined, topCut: number): TopCut =>
  (cutChoices(formatName, pairing).includes(topCut) ? topCut : 0) as TopCut;

export function detailsFromEvent(e: Table1Event): DetailsState {
  return {
    name: e.autoName ? "" : e.name,
    formatName: e.formatName,
    formatOther: e.formatOther ?? "",
    product: e.cubeName ? "cube" : "set",
    set: e.setCode
      ? { code: e.setCode, name: e.setName ?? e.setCode.toUpperCase(), set_type: "", released_at: null, icon_svg_uri: null }
      : null,
    setNameText: e.setCode ? "" : e.setName ?? "",
    cubeName: e.cubeName ?? "",
    cubeUrl: e.cubeUrl ?? "",
    teamSize: e.teamSize === 4 ? 4 : 3,
    rounds: Math.min(15, Math.max(1, e.numberOfRounds)),
    showClock: e.showClock,
    autoName: e.autoName,
    pairing: e.formatName === "roto" ? e.pairing : "round_robin",
    topCut: e.topCut,
    autoRounds: e.autoRounds,
    decklists: e.decklists,
  };
}

/** The full state update_event_details takes; only what applies to the format is sent. */
export function detailsToInput(s: DetailsState): EventDetailsInput {
  const limited = typeOfFormat(s.formatName) === "limited";
  const roto = s.formatName === "roto";
  const cube = limited && (s.product === "cube" || roto) ? s.cubeName.trim().slice(0, 80) || null : null;
  const set = limited && s.product === "set" && !roto;
  const swiss = !isTeamFormat(s.formatName) && !(roto && s.pairing === "round_robin");
  const name = s.name.trim().replace(/\s+/g, " ").slice(0, 80);
  return {
    name: name || null,
    autoName: !name,
    topCut: cutFor(s.formatName, roto ? s.pairing : "swiss", s.topCut),
    autoRounds: swiss && s.autoRounds,
    decklists: limited ? "off" : s.decklists,
    formatName: s.formatName,
    rounds: s.rounds,
    showClock: s.showClock,
    setCode: set ? s.set?.code ?? null : null,
    setName: set ? s.set?.name ?? (s.setNameText.trim() || null) : null,
    cubeName: cube,
    cubeUrl: cube && s.cubeUrl.trim() ? s.cubeUrl.trim() : null,
    teamSize: isTriosFormat(s.formatName) ? 3 : isTeamFormat(s.formatName) ? s.teamSize : null,
    formatOther: s.formatName === "other_constructed" ? s.formatOther.trim().slice(0, 40) || null : null,
    pairing: roto ? s.pairing : undefined,
  };
}
