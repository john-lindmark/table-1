// Cube rankings engine (contract/cube-rankings-2026-10-21.md). Pure: everything comes from a ranking's screen log, so
// undo, redo and watching never need repair. Same rules as the reference testdata/cube-ranking/make_cases.py and iOS
// CubeRanking.swift, checked against its cases.json by cubeRanking.test.ts:
// - A screen is 2-4 cards put in order, best first; every pair on it is known. Knowledge is the transitive closure,
//   applied final screens newest first, then the colors' screens, then picks (applyOrder); a pair that contradicts what's
//   known is skipped. It covers the cube's cards and every card in
//   the log, so a card that left the cube still carries what it settled; jobs and lists only hold the cube's cards.
// - Cards added since the ranking last caught up with its cube ("new") wait outside the lists until they're placed
//   (in a list with nothing placed yet they're simply part of what's left to sort).
// - A job (a color, or the final over every card) places from the top: the next place goes to the card known to beat
//   every other card still in; a card with `target` or more known above it is out.
// - The next screen: the cards nothing still in is known to beat (fewest known below, then a seeded hash), filled to
//   four with cards unordered against the screen, nearest the top first; in the final, new colors first. When only two
//   qualify it's a placement screen: one free card against up to three locked cards in known order.
// - The final places a card only once its order against the rest is checked (Support); until then the next screen is
//   that check, and its answer wins over what the colors or a detour through another color had settled.

/** A ranking job: a color of the cube (Group by color) or the final. "P" isn't a job: its screens are P1P1 picks (the
 *  first card picked over the rest of its pack). */
export type RankJob = "W" | "U" | "B" | "R" | "G" | "M" | "C" | "L" | "F" | "P";
export const COLOR_JOBS: RankJob[] = ["W", "U", "B", "R", "G", "M", "C", "L"];
export const JOB_TITLE: Record<RankJob, string> = {
  W: "White", U: "Blue", B: "Black", R: "Red", G: "Green", M: "Multicolor", C: "Colorless", L: "Lands", F: "Final", P: "P1P1",
};
/** From the cube's Group by color ("White" … "Lands"). */
export function jobOfColor(group: string): RankJob | null {
  return COLOR_JOBS.find((j) => JOB_TITLE[j] === group) ?? null;
}

/** One screen of the log: the cards as locked in (best first), its job, and when (epoch ms). */
export interface RankScreen { s: RankJob; o: string[]; t?: number }

/* ── bit sets over card indexes ─────────────────────────────────────── */

export type Bits = Uint32Array;
const words = (n: number) => (n + 31) >>> 5;
const has = (b: Bits, i: number) => (b[i >>> 5] & (1 << (i & 31))) !== 0;
const put = (b: Bits, i: number) => { b[i >>> 5] |= 1 << (i & 31); };
const drop = (b: Bits, i: number) => { b[i >>> 5] &= ~(1 << (i & 31)); };
function popcount(x: number): number {
  x -= (x >>> 1) & 0x55555555;
  x = (x & 0x33333333) + ((x >>> 2) & 0x33333333);
  return (((x + (x >>> 4)) & 0x0f0f0f0f) * 0x01010101) >>> 24;
}
export function count(b: Bits): number { let n = 0; for (let k = 0; k < b.length; k++) n += popcount(b[k]); return n; }
function andCount(a: Bits, b: Bits): number { let n = 0; for (let k = 0; k < a.length; k++) n += popcount(a[k] & b[k]); return n; }
function intersects(a: Bits, b: Bits): boolean { for (let k = 0; k < a.length; k++) if (a[k] & b[k]) return true; return false; }
export function members(b: Bits): number[] {
  const out: number[] = [];
  for (let k = 0; k < b.length; k++) {
    let v = b[k];
    while (v) {
      const t = v & -v;
      out.push(k * 32 + (31 - Math.clz32(t)));
      v ^= t;
    }
  }
  return out;
}
export const contains = has;

export function fnv1a(s: string): number {
  let h = 0x811c9dc5;
  for (const b of new TextEncoder().encode(s)) {
    h ^= b;
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

/* ── knowledge ────────────────────────────────────────────────────────── */

/** The order screens are applied in (2026-11-07): final screens newest first, then the colors' screens, then picks, each
 *  in log order. Without a contradiction the order changes nothing (the closure is the same). With one, a newer final
 *  screen wins over an older one and over a color's sort, so the final's checks can correct an order the colors or a
 *  detour through another color settled. Picks stay last, so "Keep my ranking" still skips a pick's disagreeing pairs. */
export function applyOrder(log: RankScreen[]): number[] {
  const out: number[] = [];
  for (let k = log.length - 1; k >= 0; k--) if (log[k].s === "F") out.push(k);
  log.forEach((s, k) => { if (s.s !== "F" && s.s !== "P") out.push(k); });
  log.forEach((s, k) => { if (s.s === "P") out.push(k); });
  return out;
}

/** The log as a transitive "beats" relation over the cube's cards, indexed by sorted Oracle id. */
export class Knowledge {
  readonly ids: string[];
  readonly index = new Map<string, number>();
  readonly beats: Bits[];
  readonly below: Bits[];
  screens = 0;
  readonly perJob: Partial<Record<RankJob, number>> = {};
  /** Screen index → pairs it said that were skipped because the opposite was already known. */
  readonly contradicted = new Map<number, [number, number][]>();
  /** The screens this knowledge was built from. */
  readonly log: RankScreen[] = [];
  /** The final's Support, kept up to date one screen at a time (built again when a check overturns an order). */
  private support: Support | null = null;

  constructor(cards: string[], log: RankScreen[] = []) {
    this.ids = [...new Set([...cards, ...log.flatMap((s) => s.o)].map((c) => c.toLowerCase()))].sort();
    this.ids.forEach((id, i) => this.index.set(id, i));
    const w = words(this.ids.length);
    this.beats = this.ids.map(() => new Uint32Array(w));
    this.below = this.ids.map(() => new Uint32Array(w));
    this.log.push(...log);
    this.build();
  }

  private build() {
    for (const b of this.beats) b.fill(0);
    for (const b of this.below) b.fill(0);
    this.contradicted.clear();
    this.support = null;
    for (const k of Object.keys(this.perJob) as RankJob[]) delete this.perJob[k];
    for (const s of this.log) this.perJob[s.s] = (this.perJob[s.s] ?? 0) + 1;
    for (const k of applyOrder(this.log)) {
      const skipped = this.pairs(this.log[k]).filter(([w, l]) => !this.add(w, l));
      if (skipped.length) this.contradicted.set(k, skipped);
    }
    this.screens = this.log.length;
  }

  get size() { return this.ids.length; }

  clone(): Knowledge {
    const k = Object.create(Knowledge.prototype) as Knowledge;
    Object.assign(k, { ids: this.ids, index: this.index, screens: this.screens, perJob: { ...this.perJob }, contradicted: new Map(this.contradicted),
                       beats: this.beats.map((b) => b.slice()), below: this.below.map((b) => b.slice()), log: this.log.slice(),
                       support: this.support?.clone() ?? null });
    return k;
  }

  /** The screen's cards that are in the cube, in order, once each. */
  indexes(cards: string[]): number[] {
    const xs: number[] = [];
    for (const c of cards) {
      const i = this.index.get(c.toLowerCase());
      if (i != null && !xs.includes(i)) xs.push(i);
    }
    return xs;
  }

  /** One more screen. A final screen that contradicts what's known wins (final screens apply newest first), so the
   *  whole log is applied again; anything else gives the same answer added on its own. */
  apply(screen: RankScreen) {
    this.log.push(screen);
    const prs = this.pairs(screen);
    if (screen.s === "F" && prs.some(([w, l]) => this.known(l, w))) { this.build(); return; }
    this.perJob[screen.s] = (this.perJob[screen.s] ?? 0) + 1;
    const skipped = prs.filter(([w, l]) => !this.add(w, l));
    if (skipped.length) this.contradicted.set(this.screens, skipped);
    this.screens++;
    this.support?.addScreen(this, screen);
  }

  /** The final's Support for these colors (built once, then kept up to date by apply). */
  supportFor(groups: number[]): Support {
    const s = this.support;
    if (s && s.groups.length === groups.length && s.groups.every((g, i) => g === groups[i])) return s;
    return (this.support = new Support(this, groups));
  }

  /** What a screen says, as [winner, loser] pairs: every pair in order, or for a pick the picked card over each other
   *  card of its pack. */
  pairs(screen: RankScreen): [number, number][] {
    const xs = this.indexes(screen.o);
    if (screen.s === "P") return xs.slice(1).map((y) => [xs[0], y]);
    const out: [number, number][] = [];
    for (let i = 0; i < xs.length; i++) for (let j = i + 1; j < xs.length; j++) out.push([xs[i], xs[j]]);
    return out;
  }

  /** Learns a beats b; false when the opposite was already known (the pair is skipped). */
  add(a: number, b: number): boolean {
    if (has(this.beats[b], a)) return false;
    if (has(this.beats[a], b)) return true;
    const ups = this.below[a].slice(); put(ups, a);
    const downs = this.beats[b].slice(); put(downs, b);
    for (const x of members(ups)) { const t = this.beats[x]; for (let k = 0; k < t.length; k++) t[k] |= downs[k]; }
    for (const y of members(downs)) { const t = this.below[y]; for (let k = 0; k < t.length; k++) t[k] |= ups[k]; }
    return true;
  }

  known(a: number, b: number) { return has(this.beats[a], b); }

  /** Same relation (redo: "Removing it changes nothing"). */
  same(o: Knowledge): boolean {
    if (o.ids.length !== this.ids.length || o.ids.some((id, i) => id !== this.ids[i])) return false;
    for (let x = 0; x < this.beats.length; x++) {
      const a = this.beats[x], b = o.beats[x];
      for (let k = 0; k < a.length; k++) if (a[k] !== b[k]) return false;
    }
    return true;
  }
}

/* ── one job ────────────────────────────────────────────────────────────── */

export interface RankSession {
  top: number[];
  done: boolean;
  target: number;
  size: number;
  /** The next screen's cards in shown order; null when done. */
  question: number[] | null;
  /** Placement screens: the locked cards, in known order. */
  pinned: number[];
  /** Cards still in and not yet placed. */
  open: Bits;
  /** New cards that can still make the list and aren't placed yet: `top` leaves them out. */
  waiting: number[];
  /** The final's check: the next card to place against cards its order with hasn't been asked about directly. */
  check: boolean;
  /** Places checked from the top (the final; a color's list counts every place). `done` once it reaches the target;
   *  `top` shows every place the log settles, checked or not. */
  checked: number;
}

/** Places from the top: the next place goes to the card in U known to beat every other card in U (U loses them). */
function ranked(K: Knowledge, U: Bits, T: number): number[] {
  const top: number[] = [];
  while (top.length < T) {
    let found = -1;
    for (const x of members(U)) {
      const bx = K.beats[x];
      let ok = true;
      for (let k = 0; k < U.length && ok; k++) {
        let rest = U[k] & ~bx[k];
        if (k === x >>> 5) rest &= ~(1 << (x & 31));
        if (rest) ok = false;
      }
      if (ok) { found = x; break; }
    }
    if (found < 0) break;
    top.push(found);
    drop(U, found);
  }
  return top;
}

const bitsOf = (n: number) => new Uint32Array(words(n));

/** What the final needs before it places a card (2026-11-07): which orders a screen asked about directly. `met[x]` the
 *  cards x was ordered against on any screen (a pick: the picked card and the rest), `metFinal[x]` on a final screen,
 *  `won[x]` the cards x beat on a screen (and still beats); `color` the same-color order screens set directly (no detour
 *  through another color), `sorted` the order the color's own screens set. */
class Support {
  readonly met!: Bits[];
  readonly metFinal!: Bits[];
  readonly won!: Bits[];
  readonly color!: Knowledge;
  readonly sorted!: Knowledge;

  constructor(K: Knowledge | null, readonly groups: number[]) {
    if (!K) return; // clone() fills it in
    const n = K.size;
    this.met = K.ids.map(() => bitsOf(n));
    this.metFinal = K.ids.map(() => bitsOf(n));
    this.won = K.ids.map(() => bitsOf(n));
    const blank = () => {
      const k = Object.create(Knowledge.prototype) as Knowledge;
      Object.assign(k, { ids: K.ids, index: K.index, beats: K.ids.map(() => bitsOf(n)), below: K.ids.map(() => bitsOf(n)) });
      return k;
    };
    this.color = blank();
    this.sorted = blank();
    for (const sc of K.log) this.addScreen(K, sc);
  }

  /** One more screen of K's log (K already knows it). */
  addScreen(K: Knowledge, sc: RankScreen) {
    for (const [w, l] of K.pairs(sc)) {
      put(this.met[w], l); put(this.met[l], w);
      if (sc.s === "F") { put(this.metFinal[w], l); put(this.metFinal[l], w); }
      if (K.known(w, l)) {
        put(this.won[w], l);
        if (this.groups[w] === this.groups[l]) {
          this.color.add(w, l);
          if (sc.s !== "F" && sc.s !== "P") this.sorted.add(w, l);
        }
      }
    }
  }

  clone(): Support {
    const s = new Support(null, this.groups);
    const copy = (k: Knowledge) => {
      const c = Object.create(Knowledge.prototype) as Knowledge;
      Object.assign(c, { ids: k.ids, index: k.index, beats: k.beats.map((b) => b.slice()), below: k.below.map((b) => b.slice()) });
      return c;
    };
    Object.assign(s, { met: this.met.map((b) => b.slice()), metFinal: this.metFinal.map((b) => b.slice()), won: this.won.map((b) => b.slice()),
                       color: copy(this.color), sorted: copy(this.sorted) });
    return s;
  }

  /** How many colors other than x's and y's have cards known between them. */
  private thirdColors(K: Knowledge, x: number, y: number): number {
    const between = K.beats[x].slice();
    for (let k = 0; k < between.length; k++) between[k] &= K.below[y][k];
    const gs = new Set<number>();
    for (const m of members(between)) if (this.groups[m] !== this.groups[x] && this.groups[m] !== this.groups[y]) gs.add(this.groups[m]);
    return gs.size;
  }

  /** x is known to beat every other card in U. The cards it still needs a screen with, one per color at most: each
   *  other color's best card still in (fewest known above it in U, then index) when its order against x went through a
   *  third color (Novice Inspector over Colossal Dreadmask over Counterspell put 13 white cards above Counterspell in a
   *  Pauper top 50 that never showed them together), and x's own color's best card when only the color's own screens
   *  put x above it (a color sorted wrong holds its better cards back, then lets them out in a run). Checked: x met the
   *  card on a screen; or, for another color, x (or a card of its color x is above, by that color's screens) beat a
   *  card of the other color that is above it or is it, by that color's screens; or cards of two or more other colors
   *  sit between them (Black Lotus over Minsc & Boo through blue and black cards needs no screen of its own). */
  unchecked(K: Knowledge, x: number, U: Bits): Bits {
    const best = new Map<number, [number, number]>();
    for (const y of members(U)) {
      if (y === x) continue;
      const g = this.groups[y], k = andCount(K.below[y], U);
      const cur = best.get(g);
      if (!cur || k < cur[0] || (k === cur[0] && y < cur[1])) best.set(g, [k, y]);
    }
    let reach: Bits | null = null; // worked out only when a card x never met needs it
    const reached = (y: number) => {
      if (!reach) {
        const C = this.color, r = C.beats[x].slice();
        for (const a of [x, ...members(C.beats[x])]) {
          for (const b of members(this.won[a])) {
            put(r, b);
            const cb = C.beats[b];
            for (let k = 0; k < r.length; k++) r[k] |= cb[k];
          }
        }
        reach = r;
      }
      return has(reach, y);
    };
    const miss = bitsOf(K.size);
    for (const [g, [, y]] of best) {
      if (g === this.groups[x]) { if (this.sorted.known(x, y) && !has(this.metFinal[x], y)) put(miss, y); }
      else if (!has(this.met[x], y) && !reached(y) && this.thirdColors(K, x, y) < 2) put(miss, y);
    }
    return miss;
  }
}

/** ranked() for the final: a card known to beat every other card still in is placed only once its order against them
 *  is checked (Support.unchecked). Returns the places and, when it stops at one, the card and its unchecked cards. */
function checked(K: Knowledge, U: Bits, T: number, sup: Support): [number[], [number, Bits] | null] {
  const top: number[] = [];
  while (top.length < T) {
    const one = ranked(K, U.slice(), 1);
    if (!one.length) break;
    const x = one[0];
    const miss = sup.unchecked(K, x, U);
    if (members(miss).length) return [top, [x, miss]];
    top.push(x); drop(U, x);
  }
  return [top, null];
}

/** The check: x with up to three of the cards it hasn't been checked against: its own color's next card first, then
 *  other colors' cards nearest the top, one per color first. Nothing is locked: the answer is new and wins. */
function checkScreen(K: Knowledge, U: Bits, x: number, miss: Bits, groups: number[], h: (x: number) => number): number[] {
  const key = new Map(members(miss).map((y) => [y, [andCount(K.below[y], U), h(y)]]));
  const ys = [...key.keys()].sort((a, b) => { const ka = key.get(a)!, kb = key.get(b)!; return ka[0] - kb[0] || ka[1] - kb[1] || a - b; });
  const picked = [x, ...ys.filter((y) => groups[y] === groups[x]).slice(0, 1)];
  for (const y of ys) if (picked.length < 4 && !picked.includes(y) && !picked.some((p) => groups[p] === groups[y])) picked.push(y);
  for (const y of ys) if (picked.length < 4 && !picked.includes(y)) picked.push(y);
  return picked;
}

/** One job: `scope` is the cards in it; `groups` maps a card index to its color (final only); `fresh` is the cube's new
 *  cards. The list (`top`) leaves out new cards still waiting to be placed (`waiting`); screens and `done` count all. */
export function session(K: Knowledge, scope: Bits, target: number, seed: string, groups: number[] | null = null,
                        fresh: Bits | null = null): RankSession {
  const inScope = members(scope);
  const n = inScope.length;
  const T = Math.min(target, n);
  const live = new Uint32Array(scope.length);
  for (const x of inScope) if (andCount(K.below[x], scope) < T) put(live, x);
  const U = live.slice();
  const full = ranked(K, U, T);
  let sure = full.length, stuck: [number, Bits] | null = null, left = U;
  if (groups) {
    left = live.slice();
    const [good, why] = checked(K, left, T, K.supportFor(groups));
    sure = good.length; stuck = why;
  }
  const done = sure >= T;
  const placed = new Set(full);
  const waiting = fresh ? members(live).filter((x) => has(fresh, x) && !placed.has(x)) : [];
  let top = full;
  if (waiting.length) {
    const shown = live.slice();
    for (const x of waiting) drop(shown, x);
    top = ranked(K, shown, T);
    // A list with nothing placed yet: new cards are simply part of what's left to sort.
    if (!top.length) { top = full; waiting.length = 0; }
  }
  if (done) return { top, done, target: T, size: n, question: null, pinned: [], open: U, waiting, check: false, checked: sure };

  const hashes = new Map<number, number>();
  const h = (x: number) => {
    let v = hashes.get(x);
    if (v == null) { v = fnv1a(`${seed}:${K.ids[x]}`); hashes.set(x, v); }
    return v;
  };
  if (stuck) return { top, done: false, target: T, size: n, question: checkScreen(K, left, stuck[0], stuck[1], groups!, h), pinned: [], open: U, waiting, check: true, checked: sure };
  const open = members(U);
  const cands = open.filter((x) => !intersects(K.below[x], U));
  const ck = new Map(cands.map((x) => [x, [andCount(K.beats[x], U), h(x)]]));
  cands.sort((a, b) => { const ka = ck.get(a)!, kb = ck.get(b)!; return ka[0] - kb[0] || ka[1] - kb[1] || a - b; });
  let picked = choose(K, cands, groups, []);
  if (picked.length < 4) {
    const candSet = new Set(cands);
    const others = open.filter((x) => !candSet.has(x));
    const ok = new Map(others.map((x) => [x, [andCount(K.below[x], U), andCount(K.beats[x], U), h(x)]]));
    others.sort((a, b) => { const ka = ok.get(a)!, kb = ok.get(b)!; return ka[0] - kb[0] || ka[1] - kb[1] || ka[2] - kb[2] || a - b; });
    picked = choose(K, others, groups, picked);
  }
  let pinned: number[] = [];
  if (picked.length === 2) [picked, pinned] = placement(K, U, picked[0], picked[1], h);
  return { top, done: false, target: T, size: n, question: picked, pinned, open: U, waiting, check: false, checked: sure };
}

function choose(K: Knowledge, order: number[], groups: number[] | null, start: number[]): number[] {
  const picked = start.slice();
  const ok = (x: number) => !picked.includes(x) && picked.every((y) => !K.known(x, y) && !K.known(y, x));
  if (groups) {
    for (const x of order) {
      if (picked.length === 4) break;
      if (ok(x) && !picked.some((y) => groups[y] === groups[x])) picked.push(x);
    }
  }
  for (const x of order) {
    if (picked.length === 4) break;
    if (ok(x)) picked.push(x);
  }
  return picked;
}

/** Only two cards qualify: the free card against the leader and up to two cards of the run below it (its middle and
 *  its end), locked in known order. Returns [cards in shown order, pinned cards]. */
function placement(K: Knowledge, U: Bits, a: number, b: number, h: (x: number) => number): [number[], number[]] {
  let best: { chain: number[]; free: number } | null = null;
  for (const [lead, free] of [[a, b], [b, a]]) {
    const run = members(U).filter((c) => K.known(lead, c) && !K.known(free, c) && !K.known(c, free));
    const keys = new Map(run.map((c) => [c, [andCount(K.below[c], U), h(c)]]));
    run.sort((x, y) => { const kx = keys.get(x)!, ky = keys.get(y)!; return kx[0] - ky[0] || kx[1] - ky[1] || x - y; });
    const chain = [lead];
    for (const c of run) if (K.known(chain[chain.length - 1], c)) chain.push(c);
    if (!best || chain.length > best.chain.length) best = { chain, free };
  }
  let { chain } = best!;
  const { free } = best!;
  if (chain.length === 1) return [[a, b], []];
  if (chain.length > 3) {
    const rest = chain.slice(1);
    chain = [chain[0], rest[Math.floor((rest.length - 1) / 2)], rest[rest.length - 1]];
  }
  return [[...chain, free], chain];
}

/** A redone screen's cards come back first while each is still open and their order is unknown. */
export function reaskOpen(K: Knowledge, st: RankSession, cards: string[]): boolean {
  const xs: number[] = [];
  for (const c of cards) {
    const i = K.index.get(c.toLowerCase());
    if (i == null) return false;
    xs.push(i);
  }
  if (xs.length < 2 || !xs.every((x) => has(st.open, x))) return false;
  for (let i = 0; i < xs.length; i++) for (let j = i + 1; j < xs.length; j++) if (K.known(xs[i], xs[j]) || K.known(xs[j], xs[i])) return false;
  return true;
}

/* ── estimates ────────────────────────────────────────────────────────── */

/** About how many screens a job takes: ordering the top k of n cards. */
export function expectedSort(n: number, k: number): number {
  k = Math.min(k, n);
  if (n <= 1 || k <= 0) return 0;
  let bits = 0;
  for (let i = n - k + 1; i <= n; i++) bits += Math.log2(i);
  const f = k >= n - 1 ? 1.55 : 1.66;
  return Math.ceil((f * bits) / Math.log2(24));
}

/** About how many screens the final takes once every color is sorted: placing the top `top` across colors. */
export function expectedMerge(sizes: number[], top: number): number {
  const T = Math.min(top, sizes.reduce((a, b) => a + b, 0));
  if (T <= 0 || sizes.filter((s) => s > 0).length <= 1) return 0;
  const C: number[][] = [[1]];
  for (let t = 1; t <= T; t++) {
    const row = new Array(t + 1).fill(1);
    for (let k = 1; k < t; k++) row[k] = C[t - 1][k - 1] + C[t - 1][k];
    C.push(row);
  }
  let f = [1, ...new Array(T).fill(0)];
  for (const s of sizes) {
    const g = new Array(T + 1).fill(0);
    for (let t = 0; t <= T; t++) for (let k = 0; k <= Math.min(s, t); k++) g[t] += f[t - k] * C[t][k];
    f = g;
  }
  return Math.ceil((4.9 * Math.log2(f[T])) / Math.log2(24));
}

/* ── why ──────────────────────────────────────────────────────────────── */

export interface Link { winner: string; loser: string; screen: number }

/** The shortest chain of screens that puts `hi` above `lo`, or null when nothing has settled it. */
export function why(K: Knowledge, log: RankScreen[], hi: string, lo: string): Link[] | null {
  const a = K.index.get(hi.toLowerCase()), b = K.index.get(lo.toLowerCase());
  if (a == null || b == null || a === b || !K.known(a, b)) return null;
  const n = K.size;
  const first = new Map<number, number>();
  log.forEach((sc, k) => {
    for (const [w, l] of K.pairs(sc)) {
      if (!K.known(w, l)) continue;
      const key = w * n + l;
      if (!first.has(key)) first.set(key, k);
    }
  });
  const adj = new Map<number, [number, number][]>();
  for (const [key, k] of first) {
    const w = Math.floor(key / n);
    if (!adj.has(w)) adj.set(w, []);
    adj.get(w)!.push([k, key % n]);
  }
  for (const l of adj.values()) l.sort((x, y) => x[0] - y[0] || x[1] - y[1]);
  const prev = new Map<number, [number, number] | null>([[a, null]]);
  let queue = [a];
  while (queue.length) {
    const next: number[] = [];
    for (const x of queue) for (const [k, y] of adj.get(x) ?? []) {
      if (!prev.has(y)) { prev.set(y, [x, k]); next.push(y); }
    }
    if (prev.has(b)) break;
    queue = next;
  }
  if (!prev.has(b)) return null;
  const chain: Link[] = [];
  let y = b;
  for (let p = prev.get(y); p; p = prev.get(y)) {
    chain.push({ winner: K.ids[p[0]], loser: K.ids[y], screen: p[1] + 1 });
    y = p[0];
  }
  return chain.reverse();
}

/* ── P1P1 picks ───────────────────────────────────────────────────────── */

export const PACK_SIZE = 15;

/** The next pack: up to 15 of the cube's cards, by a hash of the ranking, the picks so far and the card. */
export function pack(rankingId: string, K: Knowledge): string[] {
  const n = K.perJob.P ?? 0;
  const rid = rankingId.toLowerCase();
  return K.ids.map((id, i) => [fnv1a(`${rid}:P:${n}:${id}`), i] as const)
    .sort((a, b) => a[0] - b[0] || a[1] - b[1]).slice(0, PACK_SIZE).map(([, i]) => K.ids[i]);
}

/** Cards of the pack the ranking already puts above the picked card, in pack order. */
export function disagreements(K: Knowledge, picked: string, packIds: string[]): string[] {
  const p = K.index.get(picked.toLowerCase());
  if (p == null) return [];
  return packIds.filter((c) => {
    if (c.toLowerCase() === picked.toLowerCase()) return false;
    const i = K.index.get(c.toLowerCase());
    return i != null && K.known(i, p);
  });
}

/** "Let the pick win": while the ranking puts a pack card above the picked one, take out the newest screen of the
 *  shortest chain that says so (at most 30). Returns the log indexes to remove, ascending. */
export function pickWins(cards: string[], log: RankScreen[], picked: string, packIds: string[]): number[] {
  const alive = log.map((_, i) => i);
  const removed: number[] = [];
  for (let round = 0; round < 30; round++) {
    const cur = alive.map((i) => log[i]);
    const K = new Knowledge(cards, cur);
    const d = disagreements(K, picked, packIds)[0];
    if (d == null) break;
    const chain = why(K, cur, d, picked);
    if (!chain) break;
    const k = Math.max(...chain.map((l) => l.screen));
    removed.push(alive.splice(k - 1, 1)[0]);
  }
  return removed.sort((a, b) => a - b);
}

/* ── the change log ───────────────────────────────────────────────────── */

/** How much of each color a ranking sorts (2026-10-23: quarter and third added). The final top N comes out exact at any
 *  depth; it just asks about a card itself when a color has more cards in the top N than it sorted. */
export type RankDepth = "quarter" | "third" | "half" | "full";
export const RANK_DEPTHS: RankDepth[] = ["quarter", "third", "half", "full"];
const DIVISOR: Record<string, number> = { half: 2, third: 3, quarter: 4 };
export const depthTarget = (n: number, depth: string) => (depth === "full" ? n : Math.ceil(n / (DIVISOR[depth] ?? 2)));
export const depthPhrase = (depth: string) => ({ half: "top half", third: "top third", quarter: "top quarter" } as Record<string, string>)[depth] ?? "every card";
/** The depth a new ranking starts with: a quarter of each color for a top 50, a third for a top 100. */
export const suggestedDepth = (top: number): RankDepth => (top <= 50 ? "quarter" : "third");

/** One line of the change log: a card's place in a list went from → to (null = not placed). */
export interface RankChange { s: RankJob; c: string; f: number | null; to: number | null; t?: number; by?: string; n?: number }

export type Places = Partial<Record<RankJob, Map<string, number>>>;

/** What moved between two states' places: colors then the final, each by the better place, then card id. */
export function diffPlaces(before: Places, after: Places): RankChange[] {
  const out: RankChange[] = [];
  for (const job of [...COLOR_JOBS, "F" as RankJob]) {
    const a = before[job] ?? new Map<string, number>(), b = after[job] ?? new Map<string, number>();
    const rows = [...new Set([...a.keys(), ...b.keys()])].filter((c) => a.get(c) !== b.get(c))
      .map((c) => ({ c, f: a.get(c) ?? null, to: b.get(c) ?? null }));
    const best = (r: { f: number | null; to: number | null }) => Math.min(...[r.f, r.to].filter((x): x is number => x != null));
    rows.sort((x, y) => best(x) - best(y) || (x.c < y.c ? -1 : x.c > y.c ? 1 : 0));
    out.push(...rows.map((r) => ({ s: job, c: r.c, f: r.f, to: r.to })));
  }
  return out;
}

/* ── compare ──────────────────────────────────────────────────────────── */

export interface Gap { card: string; a: number; aOut: boolean; b: number; bOut: boolean; gap: number; atLeast: boolean }
export interface Comparison { compared: number; avgTenths: number; atLeast: boolean; biggest: Gap[]; oneSide: Gap[] }

/** Two rankings' orders of one list, both in K's card indexes. */
export function compare(K: Knowledge, a: Pick<RankSession, "top" | "done" | "size">, b: Pick<RankSession, "top" | "done" | "size">,
                        scope: Bits): Comparison {
  const place = (st: Pick<RankSession, "top" | "done" | "size">, x: number): [number, boolean] | null => {
    const i = st.top.indexOf(x);
    if (i >= 0) return [i + 1, false];
    if (st.done && st.top.length < st.size) return [st.top.length + 1, true];
    return null;
  };
  const rows: { gap: Gap; best: number; x: number }[] = [];
  for (const x of members(scope)) {
    const pa = place(a, x), pb = place(b, x);
    if (!pa || !pb || (pa[1] && pb[1])) continue;
    const best = Math.min(...[pa, pb].filter((p) => !p[1]).map((p) => p[0]));
    rows.push({ gap: { card: K.ids[x], a: pa[0], aOut: pa[1], b: pb[0], bOut: pb[1], gap: Math.abs(pa[0] - pb[0]), atLeast: pa[1] || pb[1] }, best, x });
  }
  const n = rows.length;
  const total = rows.reduce((s, r) => s + r.gap.gap, 0);
  const biggest = rows.slice().sort((p, q) => q.gap.gap - p.gap.gap || p.best - q.best || p.x - q.x).slice(0, 10).map((r) => r.gap);
  const oneSide = rows.filter((r) => r.gap.aOut !== r.gap.bOut).sort((p, q) => p.best - q.best || p.x - q.x).map((r) => r.gap);
  return { compared: n, avgTenths: n ? Math.floor((20 * total + n) / (2 * n)) : 0, atLeast: rows.some((r) => r.gap.atLeast), biggest, oneSide };
}

/* ── the whole ranking ────────────────────────────────────────────────── */

/** A whole ranking worked out from its log: the cube's cards and colors, depth and final size. */
export class RankingState {
  readonly rankingId: string;
  readonly knowledge: Knowledge;
  readonly category: Map<string, RankJob>;
  readonly depth: RankDepth;
  readonly top: number;
  /** The cube's cards added since the ranking last caught up: they wait outside the lists until they're placed. */
  readonly fresh: Set<string>;
  private cache = new Map<RankJob, RankSession>();

  /** `cards` are the cube's cards now (a card in the log but not here has left the cube); `fresh` its new cards. */
  constructor(rankingId: string, cards: Map<string, RankJob>, log: RankScreen[], depth: RankDepth, top: number, knowledge?: Knowledge,
              fresh: Iterable<string> = []) {
    this.rankingId = rankingId.toLowerCase();
    this.category = new Map([...cards].map(([k, v]) => [k.toLowerCase(), v]));
    this.knowledge = knowledge ?? new Knowledge([...this.category.keys()], log);
    this.depth = depth;
    this.top = top;
    this.fresh = new Set([...fresh].map((c) => c.toLowerCase()).filter((c) => this.category.has(c)));
  }

  /** The same ranking with one more screen. */
  appending(screen: RankScreen): RankingState {
    const k = this.knowledge.clone();
    k.apply(screen);
    return new RankingState(this.rankingId, this.category, [], this.depth, this.top, k, this.fresh);
  }

  /** New cards not placed yet in any list: a re-rank is due. */
  get waiting(): string[] {
    const out = new Set<string>();
    for (const job of [...this.jobs, "F" as RankJob]) for (const x of this.session(job).waiting) out.add(this.id(x));
    return [...out].sort();
  }

  id(x: number) { return this.knowledge.ids[x]; }

  scope(job: RankJob): Bits {
    const m = new Uint32Array(words(this.knowledge.size));
    this.knowledge.ids.forEach((id, i) => {
      const c = this.category.get(id);
      if (c && (job === "F" || c === job)) put(m, i);
    });
    return m;
  }

  size(job: RankJob) { return job === "F" ? this.category.size : [...this.category.values()].filter((c) => c === job).length; }

  target(job: RankJob) {
    if (job === "F") return this.top;
    const n = this.size(job);
    return depthTarget(n, this.depth);
  }

  /** Colors with at least one card, in order. */
  get jobs(): RankJob[] { return COLOR_JOBS.filter((j) => this.size(j) > 0); }

  session(job: RankJob): RankSession {
    const hit = this.cache.get(job);
    if (hit) return hit;
    const groups = job === "F" ? this.knowledge.ids.map((id) => Math.max(0, COLOR_JOBS.indexOf(this.category.get(id) ?? "C"))) : null;
    let fresh: Bits | null = null;
    if (this.fresh.size) {
      fresh = new Uint32Array(words(this.knowledge.size));
      for (const c of this.fresh) { const i = this.knowledge.index.get(c); if (i != null) put(fresh, i); }
    }
    const s = session(this.knowledge, this.scope(job), this.target(job), `${this.rankingId}:${job}:${this.knowledge.screens}`, groups, fresh);
    this.cache.set(job, s);
    return s;
  }

  expected(job: RankJob) {
    return job === "F" ? expectedMerge(this.jobs.map((j) => this.size(j)), this.top) : expectedSort(this.size(job), this.target(job));
  }

  /** The places of some lists (all by default; a color's screen can only move that color and the final). */
  places(only?: RankJob[]): Places {
    const out: Places = {};
    for (const job of only ?? [...this.jobs, "F" as RankJob]) {
      out[job] = new Map(this.session(job).top.map((x, i) => [this.id(x), i + 1]));
    }
    return out;
  }

  /** Colors sorted, colors with cards, places ranked in the final: what list rows show. */
  get progress() {
    const js = this.jobs;
    return { sorted: js.filter((j) => this.session(j).done).length, categories: js.length, ranked: this.session("F").top.length };
  }
}
