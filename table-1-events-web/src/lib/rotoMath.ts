// Roto (rotisserie) cube drafts: wire shapes from roto_state and friends (contract/roto-2026-10-16.md), and the
// pure turn maths the screens need. The server decides whose turn it is; the client only predicts it for display
// ("YOU PICK IN 3") with the same formula as t1_private.roto_seat_index. Mirrors apps/ios/Table1/Roto/RotoModel.swift.

export type RotoPhase = "setup" | "drafting" | "done";
export type RotoHow = "player" | "auto" | "timeout" | "organizer";

/** One range of the pick clock: from this round on, each pick gets `seconds`. */
export interface RotoClockRange {
  fromRound: number;
  seconds: number;
}

/** `[pick_no, seat, slot, how, at]`. `seat` is 1-based pick order. */
export interface RotoPick {
  pickNo: number;
  seat: number;
  slot: number;
  how: RotoHow;
  at: number;
}

/** `[slot, card_id, finish]`: one copy in the snapshot of the cube. */
export interface RotoPoolCard {
  slot: number;
  cardId: string;
  finish: string;
}

export interface RotoDraftInfo {
  picksPerPlayer: number;
  /** snake | fixed */
  pickOrder: "snake" | "fixed";
  players: number;
  poolCount: number;
  picksMade: number;
  totalPicks: number | null;
  sourceListId: string | null;
  clock: RotoClockRange[] | null;
  clockPaused: boolean;
  startedAt: number | null;
  finishedAt: number | null;
}

export interface RotoOnClock {
  participantId: string;
  seat: number;
  pickNo: number;
  round: number;
  turnStartedAt: number | null;
  turnSeconds: number | null;
  remainingSeconds: number | null;
  deadline: number | null;
  overdue: boolean;
}

export interface RotoSeat {
  seat: number | null;
  participantId: string;
  displayName: string;
  account: boolean;
  me: boolean;
}

export interface RotoMe {
  participantId: string;
  seat: number | null;
  queue: number[];
  autoPick: boolean;
  deckListId: string | null;
}

export interface RotoState {
  eventId: string;
  phase: RotoPhase;
  draft: RotoDraftInfo;
  onClock: RotoOnClock | null;
  seats: RotoSeat[];
  picks: RotoPick[];
  pool: RotoPoolCard[] | null;
  me: RotoMe | null;
}

export interface RotoPickResult {
  ok: boolean;
  conflict: boolean;
  state: RotoState;
}

export interface RotoQueueResult {
  queue: number[];
  autoPick: boolean;
  picksMade: number;
}

export interface RotoCubeResult {
  eventId: string;
  sourceListId: string | null;
  cubeName: string | null;
  poolCount: number;
  players: number;
  maxPicksPerPlayer: number;
}

/* ── wire → model ───────────────────────────────────────────────────── */

/* eslint-disable @typescript-eslint/no-explicit-any */
const int = (v: any, d = 0): number => {
  const n = typeof v === "number" ? v : typeof v === "string" ? Number(v) : NaN;
  return Number.isFinite(n) ? Math.trunc(n) : d;
};
const intOrNull = (v: any): number | null => (v == null ? null : int(v));
const num = (v: any): number | null => (v == null ? null : Number.isFinite(Number(v)) ? Number(v) : null);

export function toDraft(d: any): RotoDraftInfo {
  d = d ?? {};
  return {
    picksPerPlayer: int(d.picks_per_player, 45),
    pickOrder: d.pick_order === "fixed" ? "fixed" : "snake",
    players: int(d.players),
    poolCount: int(d.pool_count),
    picksMade: int(d.picks_made),
    totalPicks: intOrNull(d.total_picks),
    sourceListId: d.source_list_id ?? null,
    clock: Array.isArray(d.clock) ? d.clock.map((r: any) => ({ fromRound: int(r.from_round, 1), seconds: int(r.seconds) })) : null,
    clockPaused: !!d.clock_paused,
    startedAt: num(d.started_at),
    finishedAt: num(d.finished_at),
  };
}

export function toPick(a: any[]): RotoPick | null {
  if (!Array.isArray(a) || a.length < 3) return null;
  const how = a[3];
  return {
    pickNo: int(a[0]),
    seat: int(a[1]),
    slot: int(a[2]),
    how: how === "auto" || how === "timeout" || how === "organizer" ? how : "player",
    at: num(a[4]) ?? 0,
  };
}

export function toState(s: any): RotoState {
  const c = s?.on_clock;
  return {
    eventId: s?.event_id ?? "",
    phase: s?.phase === "drafting" || s?.phase === "done" ? s.phase : "setup",
    draft: toDraft(s?.draft),
    onClock: c?.participant_id
      ? {
          participantId: c.participant_id,
          seat: int(c.seat),
          pickNo: int(c.pick_no),
          round: int(c.round, 1),
          turnStartedAt: num(c.turn_started_at),
          turnSeconds: intOrNull(c.turn_seconds),
          remainingSeconds: intOrNull(c.remaining_seconds),
          deadline: num(c.deadline),
          overdue: !!c.overdue,
        }
      : null,
    seats: (s?.seats ?? []).map((x: any) => ({
      seat: x.seat ?? null,
      participantId: x.participant_id,
      displayName: x.display_name ?? "Player",
      account: x.account ?? true,
      me: !!x.me,
    })),
    picks: (s?.picks ?? []).map(toPick).filter((p: RotoPick | null): p is RotoPick => !!p),
    pool: Array.isArray(s?.pool)
      ? s.pool
          .filter((a: any) => Array.isArray(a) && a.length >= 2)
          .map((a: any[]) => ({ slot: int(a[0]), cardId: String(a[1]), finish: a[2] ?? "nonfoil" }))
      : null,
    me: s?.me?.participant_id
      ? {
          participantId: s.me.participant_id,
          seat: s.me.seat ?? null,
          queue: (s.me.queue ?? []).map((n: any) => int(n)),
          autoPick: s.me.auto_pick ?? true,
          deckListId: s.me.deck_list_id ?? null,
        }
      : null,
  };
}
/* eslint-enable @typescript-eslint/no-explicit-any */

/* ── turn maths (mirrors t1_private.roto_seat_index / roto_round) ───── */

export const isAutomatic = (p: RotoPick) => p.how === "auto" || p.how === "timeout";
export const totalPicks = (d: RotoDraftInfo) => d.totalPicks ?? d.players * d.picksPerPlayer;

/** 1-based seat on the clock for a pick. Snake reverses every other round. */
export function seatFor(players: number, pickNo: number, snake: boolean): number {
  if (players <= 0 || pickNo <= 0) return 0;
  const i = (pickNo - 1) % players;
  const backwards = snake && Math.floor((pickNo - 1) / players) % 2 === 1;
  return backwards ? players - i : i + 1;
}

/** 1-based round of a pick. */
export function roundOf(players: number, pickNo: number): number {
  if (players <= 0 || pickNo <= 0) return 1;
  return Math.floor((pickNo - 1) / players) + 1;
}

/** The pick number at (seat, round): the cell of the classic roto sheet. */
export function pickNoAt(seat: number, round: number, players: number, snake: boolean): number {
  const backwards = snake && (round - 1) % 2 === 1;
  const index = backwards ? players - seat : seat - 1;
  return (round - 1) * players + index + 1;
}

/** Picks other people make before `seat` is next on the clock (0 = it's theirs); null when they have none left. */
export function picksUntil(seat: number, picksMade: number, players: number, total: number, snake: boolean): number | null {
  if (players <= 0 || seat <= 0) return null;
  // At most one full lap (two in snake order) separates a seat from its next pick.
  for (let n = picksMade + 1; n <= total && n <= picksMade + 2 * players; n++) {
    if (seatFor(players, n, snake) === seat) return n - picksMade - 1;
  }
  return null;
}

/** Seconds per pick in a round from the schedule (the last range starting at or before it); null = no clock. */
export function clockSeconds(clock: RotoClockRange[] | null | undefined, round: number): number | null {
  let best: RotoClockRange | null = null;
  for (const r of clock ?? []) if (r.fromRound <= round && (!best || r.fromRound > best.fromRound)) best = r;
  return best?.seconds ?? null;
}

/** "4 h", "1 h 30 min", "45 min", "30 s". */
export function durationText(seconds: number): string {
  const h = Math.floor(seconds / 3600), m = Math.floor((seconds % 3600) / 60), s = seconds % 60;
  if (h > 0) return m > 0 ? `${h} h ${m} min` : `${h} h`;
  if (m > 0) return s > 0 ? `${m} min ${s} s` : `${m} min`;
  return `${s} s`;
}

/** "1:42:10", "4:05", "0:09". */
export function countdownText(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60;
  const pad = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(r)}` : `${m}:${pad(r)}`;
}

/** The pairing a roto prefills: round robin for 2–8 players, Swiss for 9 or more. */
export const defaultPairing = (players: number): "swiss" | "round_robin" => (players >= 9 ? "swiss" : "round_robin");

/** Round robin rounds shown before round 1 (at least 1 for an empty event). */
export const roundRobinRoundsFor = (players: number) => (players < 2 ? 1 : players % 2 === 0 ? players - 1 : players);

/** Times the clock editor offers, 30 s to 24 h. */
export const CLOCK_DURATIONS = [30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 14400, 28800, 43200, 86400];

/** Add a range: splits what's left of the last one, at about half its time. */
export function addClockRange(ranges: RotoClockRange[], rounds: number): RotoClockRange[] {
  const last = ranges[ranges.length - 1];
  if (!last) return [{ fromRound: 1, seconds: 14400 }];
  const from = last.fromRound + Math.max(1, Math.floor((rounds - last.fromRound + 1) / 2));
  const seconds = [...CLOCK_DURATIONS].reverse().find((d) => d <= Math.max(30, Math.floor(last.seconds / 2))) ?? 30;
  return [...ranges, { fromRound: Math.min(rounds, from), seconds }];
}

/* ── merging deltas ─────────────────────────────────────────────────── */

/**
 * Folds a `roto_state(p_after_pick = after)` answer into the picks held. Picks above the server's `picksMade` are
 * dropped (an undo); new picks replace any held at the same number. `needsFull` is true when the delta can't be
 * trusted to repair what's held: the server is behind what was held (an undo, possibly followed by new picks at the
 * same numbers), a card shows up at two pick numbers, or numbers are missing. Fetch every pick again then.
 */
export function mergePicks(held: RotoPick[], delta: RotoPick[], picksMade: number): { picks: RotoPick[]; needsFull: boolean } {
  const byNo = new Map<number, RotoPick>();
  for (const p of held) if (p.pickNo <= picksMade) byNo.set(p.pickNo, p);
  for (const p of delta) if (p.pickNo <= picksMade) byNo.set(p.pickNo, p);
  const picks = [...byNo.values()].sort((a, b) => a.pickNo - b.pickNo);
  const heldTop = held.reduce((n, p) => Math.max(n, p.pickNo), 0);
  const duplicateSlot = new Set(picks.map((p) => p.slot)).size !== picks.length;
  const gap = picks.length !== (picks[picks.length - 1]?.pickNo ?? 0);
  return { picks, needsFull: picksMade < heldTop || duplicateSlot || gap };
}

/* ── cards (from the local catalog) ─────────────────────────────────── */

export const COLOR_GROUPS = ["White", "Blue", "Black", "Red", "Green", "Multicolor", "Colorless", "Lands"];

/** What the Draft screens show of a card: from the local catalog only (no network, no images in the grid). */
export interface RotoCard {
  cardId: string;
  name: string;
  typeLine: string;
  manaCost: string;
  /** W U B R G present in the mana cost, in that order. */
  colors: string[];
  manaValue: number;
  /** White … Multicolor, Colorless, Lands (the lists contract "Display" for cubes). */
  group: string;
  isLand: boolean;
  isCreature: boolean;
  /** Printing index in the catalog, for images. */
  p: number | null;
}

/** "{2}{U}{U}" → 4; X counts 0, hybrid and Phyrexian count 1. Split cards use the front face. */
export function manaValue(cost: string): number {
  const front = cost.split(" // ")[0];
  let total = 0;
  for (const m of front.matchAll(/\{([^}]*)\}/g)) {
    const sym = m[1];
    if (/^\d+$/.test(sym)) total += Number(sym);
    else if (sym !== "X" && sym !== "Y" && sym !== "Z") total += 1;
  }
  return total;
}

export function rotoCard(cardId: string, name: string, typeLine: string, manaCost: string, p: number | null): RotoCard {
  const front = typeLine.split(" // ")[0];
  const colors = ["W", "U", "B", "R", "G"].filter((c) => manaCost.includes(`{${c}`) || manaCost.includes(`/${c}`));
  const isLand = front.includes("Land");
  const group = isLand
    ? "Lands"
    : colors.length > 1
      ? "Multicolor"
      : ({ W: "White", U: "Blue", B: "Black", R: "Red", G: "Green" } as Record<string, string>)[colors[0]] ?? "Colorless";
  return { cardId, name, typeLine, manaCost, colors, manaValue: manaValue(manaCost), group, isLand, isCreature: front.includes("Creature"), p };
}

export const unknownCard = (cardId: string): RotoCard => rotoCard(cardId, "Card", "", "", null);

/** Color of a bar segment; "L" lands and "C" colorless. */
export const COLOR_HEX: Record<string, string> = {
  W: "#f5edcc", U: "#408cf2", B: "#8c8094", R: "#eb5445", G: "#40b366", C: "#9e9ea8", L: "#9e9ea8",
};
