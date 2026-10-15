// Life tracker rules, kept pure so web, tests and the sync layer share them.
//
//   op       one tap: {client_op_id, game_no, side, counter, delta, tapped_at}. Hold-repeat taps are
//            individual ops. Ops are the only thing stored; totals and history are derived.
//   totals   for a game = starting value + sum of that game's deltas (life starts at starting_life,
//            every other counter at 0).
//   group    consecutive taps on the same side + counter, each < 2.0 s after the previous one. A tap on
//            another side/counter, or 2 s of quiet, closes it. Groups are display-only, never stored.
//   undo     removes the newest group by adding its inverse op, stamped at the group's last tap so it
//            folds into that group (net 0) on every device; net-zero groups are hidden from history.
//   game     current game = recorded games + 1.

export type Counter = "life" | "poison" | "energy" | "experience" | "rad" | "speed";
export type Side = 0 | 1;

export interface TrackerOp {
  client_op_id: string;
  game_no: number;
  side: Side;
  counter: Counter;
  delta: number;
  tapped_at: string;
  /** Synced sessions: true when this account made the change. */
  mine?: boolean;
}

export interface TrackerGame {
  game_no: number;
  winner_side: Side | null;
  is_draw: boolean;
  recorded_at: string;
}

export interface ChangeGroup {
  /** client_op_id of the group's first op. */
  id: string;
  game_no: number;
  side: Side;
  counter: Counter;
  delta: number;
  startedAt: number;
  endedAt: number;
  /** Total of this counter right after the group. */
  after: number;
  opIds: string[];
  mine?: boolean;
}

export const GROUP_WINDOW_MS = 2000;
export const COUNTERS: Counter[] = ["life", "poison", "energy", "experience", "rad", "speed"];
export const COUNTER_LABEL: Record<Counter, string> = {
  life: "Life",
  poison: "Poison",
  energy: "Energy",
  experience: "Experience",
  rad: "Rad",
  speed: "Speed",
};
/** Bounds a counter can't be pushed past (life is unbounded). */
export const COUNTER_RANGE: Partial<Record<Counter, [number, number]>> = {
  poison: [0, 99],
  energy: [0, 999],
  experience: [0, 999],
  rad: [0, 999],
  speed: [0, 4],
};
export const POISON_LOSS = 10;

export type Totals = Record<Side, Record<Counter, number>>;

const time = (iso: string) => {
  const t = Date.parse(iso);
  return Number.isNaN(t) ? 0 : t;
};

/** Ops in tap order; ties keep arrival order (an undo op shares its group's last timestamp). */
export function sortOps(ops: TrackerOp[]): TrackerOp[] {
  return ops
    .map((op, i) => ({ op, i, t: time(op.tapped_at) }))
    .sort((a, b) => a.t - b.t || a.i - b.i)
    .map((x) => x.op);
}

export function opsForGame(ops: TrackerOp[], gameNo: number): TrackerOp[] {
  return ops.filter((o) => o.game_no === gameNo);
}

export function startValue(counter: Counter, startingLife: number): number {
  return counter === "life" ? startingLife : 0;
}

export function totals(ops: TrackerOp[], gameNo: number, startingLife: number): Totals {
  const make = (): Record<Counter, number> => ({
    life: startingLife, poison: 0, energy: 0, experience: 0, rad: 0, speed: 0,
  });
  const out: Totals = { 0: make(), 1: make() };
  for (const op of ops) {
    if (op.game_no !== gameNo) continue;
    out[op.side][op.counter] += op.delta;
  }
  return out;
}

/** All groups for one game, oldest first (including net-zero ones). */
export function groupOps(ops: TrackerOp[], gameNo: number, startingLife: number): ChangeGroup[] {
  const sorted = sortOps(opsForGame(ops, gameNo));
  const running: Record<string, number> = {};
  const groups: ChangeGroup[] = [];
  let last: ChangeGroup | null = null;
  for (const op of sorted) {
    const key = `${op.side}:${op.counter}`;
    running[key] = (running[key] ?? startValue(op.counter, startingLife)) + op.delta;
    const t = time(op.tapped_at);
    if (last && last.side === op.side && last.counter === op.counter && t - last.endedAt < GROUP_WINDOW_MS) {
      last.delta += op.delta;
      last.endedAt = Math.max(last.endedAt, t);
      last.after = running[key];
      last.opIds.push(op.client_op_id);
      continue;
    }
    last = {
      id: op.client_op_id,
      game_no: op.game_no,
      side: op.side,
      counter: op.counter,
      delta: op.delta,
      startedAt: t,
      endedAt: t,
      after: running[key],
      opIds: [op.client_op_id],
      mine: op.mine,
    };
    groups.push(last);
  }
  return groups;
}

/** What History shows: groups that changed something, newest first. */
export function historyGroups(ops: TrackerOp[], gameNo: number, startingLife: number): ChangeGroup[] {
  return groupOps(ops, gameNo, startingLife).filter((g) => g.delta !== 0).reverse();
}

/** The group a fresh tap would still join, if it's open at `now`. */
export function openGroup(ops: TrackerOp[], gameNo: number, startingLife: number, now: number): ChangeGroup | null {
  const groups = groupOps(ops, gameNo, startingLife);
  const last = groups[groups.length - 1];
  if (!last || last.delta === 0 || now - last.endedAt >= GROUP_WINDOW_MS) return null;
  return last;
}

export function newOpId(): string {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) return crypto.randomUUID();
  // RFC 4122 v4 fallback for old browsers.
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    return (c === "x" ? r : (r & 0x3) | 0x8).toString(16);
  });
}

export function makeOp(
  gameNo: number,
  side: Side,
  counter: Counter,
  delta: number,
  at: number = Date.now(),
  id: string = newOpId(),
): TrackerOp {
  return { client_op_id: id, game_no: gameNo, side, counter, delta, tapped_at: new Date(at).toISOString(), mine: true };
}

/**
 * The op(s) that undo a group. Stamped at the group's last tap so, sorted after it, the inverse joins the
 * same group and the whole thing nets to zero (hidden from history) on every device.
 */
export function inverseOps(group: ChangeGroup, idGen: () => string = newOpId): TrackerOp[] {
  if (group.delta === 0) return [];
  return [makeOp(group.game_no, group.side, group.counter, -group.delta, group.endedAt, idGen())];
}

/** Undo for the newest visible group of a game, or [] when there's nothing to undo. */
export function undoLast(ops: TrackerOp[], gameNo: number, startingLife: number, idGen: () => string = newOpId): TrackerOp[] {
  const newest = historyGroups(ops, gameNo, startingLife)[0];
  return newest ? inverseOps(newest, idGen) : [];
}

/** Ops that put every counter of a game back to its start value. */
export function resetOps(ops: TrackerOp[], gameNo: number, startingLife: number, at: number = Date.now()): TrackerOp[] {
  const t = totals(ops, gameNo, startingLife);
  const out: TrackerOp[] = [];
  for (const side of [0, 1] as Side[]) {
    for (const c of COUNTERS) {
      const diff = t[side][c] - startValue(c, startingLife);
      if (diff !== 0) out.push(makeOp(gameNo, side, c, -diff, at));
    }
  }
  return out;
}

/** Clamp a tap so bounded counters stay in range; 0 means "ignore this tap". */
export function clampDelta(current: number, delta: number, counter: Counter): number {
  const range = COUNTER_RANGE[counter];
  if (!range) return delta;
  const next = Math.min(range[1], Math.max(range[0], current + delta));
  return next - current;
}

export function currentGameNo(games: TrackerGame[]): number {
  return games.length + 1;
}

export interface MatchScore {
  wins: Record<Side, number>;
  draws: number;
  played: number;
}

export function matchScore(games: TrackerGame[]): MatchScore {
  const wins: Record<Side, number> = { 0: 0, 1: 0 };
  let draws = 0;
  for (const g of games) {
    if (g.is_draw || g.winner_side == null) draws += 1;
    else wins[g.winner_side] += 1;
  }
  return { wins, draws, played: games.length };
}

/** Best of three: someone has two wins, or three games have been played. */
export function matchDecided(games: TrackerGame[]): boolean {
  const s = matchScore(games);
  return s.wins[0] >= 2 || s.wins[1] >= 2 || s.played >= 3;
}

/** The side that has lost the current game on the board (life ≤ 0 or poison ≥ 10), if any. */
export function losingSide(t: Totals): Side | null {
  for (const side of [0, 1] as Side[]) {
    if (t[side].life <= 0 || t[side].poison >= POISON_LOSS) return side;
  }
  return null;
}

/** Union by client_op_id, keeping the first copy's position. */
export function mergeOps(existing: TrackerOp[], incoming: TrackerOp[]): TrackerOp[] {
  const seen = new Set(existing.map((o) => o.client_op_id));
  const out = [...existing];
  for (const op of incoming) {
    if (seen.has(op.client_op_id)) continue;
    seen.add(op.client_op_id);
    out.push(op);
  }
  return out;
}

export function formatDelta(n: number): string {
  if (n > 0) return `+${n}`;
  if (n < 0) return `−${Math.abs(n)}`;
  return "±0";
}

/** "2–1" (or "1–1–1" with draws), my wins first. */
export function scoreLabel(my: number, their: number, draws = 0): string {
  return draws > 0 ? `${my}–${their}–${draws}` : `${my}–${their}`;
}

/* ── round clock ───────────────────────────────────────────────────────────
   The match's round timer as tracker_state returns it (and as a rounds UPDATE carries it).
   Running: remaining = remaining_at_change − (now − last_started_at), negative in overtime.
   Paused: remaining_at_change (null = the full duration). */

export interface TrackerClock {
  round_id: string;
  timer_status: "paused" | "running";
  timer_last_started_at: string | null;
  timer_remaining_at_change: number | null;
  timer_duration_seconds: number;
}

export type ClockTone = "normal" | "warning" | "overtime";
/** The tracker turns the clock amber for the last 10 minutes (the organizer screen keeps its own 5). */
export const TRACKER_WARN_SECONDS = 600;

export function clockRemaining(c: TrackerClock, now: number): number {
  const base = c.timer_remaining_at_change ?? c.timer_duration_seconds;
  if (c.timer_status === "running" && c.timer_last_started_at) {
    return base - Math.floor((now - time(c.timer_last_started_at)) / 1000);
  }
  return base;
}

export function clockTone(remaining: number, warnAt = TRACKER_WARN_SECONDS): ClockTone {
  return remaining < 0 ? "overtime" : remaining <= warnAt ? "warning" : "normal";
}

/** "42:52", "6:12", "+0:42" in overtime. Minutes aren't padded. */
export function formatTrackerClock(remaining: number): string {
  const abs = Math.abs(remaining);
  const text = `${Math.floor(abs / 60)}:${String(abs % 60).padStart(2, "0")}`;
  return remaining < 0 ? `+${text}` : text;
}

/** Share of the bar to fill: time left over the round length; full in overtime. */
export function clockProgress(remaining: number, duration: number): number {
  if (remaining < 0) return 1;
  return duration > 0 ? Math.min(1, remaining / duration) : 0;
}

/* ── counter columns ───────────────────────────────────────────────────────
   Each side shows up to three counters as columns next to life. A counter shows when the player
   turned it on, or by itself once it isn't zero (so poison you dealt shows on the other phone),
   unless the player turned it off. This is display only; it's kept per device. */

export const MAX_COUNTERS = 3;
export const COUNTER_SHORT: Record<Counter, string> = { ...COUNTER_LABEL, experience: "Exp" };

export interface CounterPrefs {
  on: Counter[];
  off: Counter[];
}

export const EXTRA_COUNTERS: Counter[] = COUNTERS.filter((c) => c !== "life");

export function shownCounters(values: Record<Counter, number>, prefs: CounterPrefs): Counter[] {
  return EXTRA_COUNTERS.filter(
    (c) => prefs.on.includes(c) || (values[c] !== 0 && !prefs.off.includes(c)),
  ).slice(0, MAX_COUNTERS);
}

/** Turns one counter on or off for a side, given what's showing now. */
export function toggleCounter(prefs: CounterPrefs, shown: Counter[], c: Counter): CounterPrefs {
  if (shown.includes(c)) {
    return { on: prefs.on.filter((x) => x !== c), off: [...prefs.off.filter((x) => x !== c), c] };
  }
  if (shown.length >= MAX_COUNTERS) return prefs;
  return { on: [...prefs.on.filter((x) => x !== c), c], off: prefs.off.filter((x) => x !== c) };
}
