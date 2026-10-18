/* Deck and cube stats (contract/lists-2026-10-15.md, "Stats"). Pure functions over a list's cards, no UI and no
   catalog access, so the same inputs give the same numbers here, on iOS (DeckStats.swift) and on Android
   (DeckStats.kt). testdata/deck-stats/cases.json holds the shared cases; make_cases.py there is the reference. */

/** A token card a card makes (the pack's O-line tokens field). `key` tells apart token cards with the same name. */
export interface StatToken {
  key: string;
  name: string;
  type: string;
}

/**
 * One list line as the stats read it. `type`, `cost`, `cmc`, `colors`, `produced` and `tokens` come from the catalog
 * pack's O line.
 */
export interface StatCard {
  name: string;
  qty: number;
  board: string;
  type: string;
  cost: string;
  cmc: number;
  colors: string;
  legal?: string;
  rarity?: string;
  /** One copy's USD market price; null when there's none. */
  usd?: number | null;
  /** Mana it makes, letters from WUBRGCF; null/undefined when the pack doesn't say (then lands read by basic type). */
  produced?: string | null;
  tokens?: StatToken[];
  /** The front face's card types as bits in TYPES order, read once by `statCard`. */
  typeBits?: number;
}

export const COLORS = ["W", "U", "B", "R", "G"] as const;
export const TYPES = ["Creature", "Planeswalker", "Instant", "Sorcery", "Artifact", "Enchantment", "Battle", "Land"];
const PERMANENTS = new Set(["Creature", "Planeswalker", "Artifact", "Enchantment", "Battle", "Land"]);
export const COLOR_GROUPS = ["White", "Blue", "Black", "Red", "Green", "Multicolor", "Colorless", "Lands"];
/** Mana value columns: 0 … 6, then 7 and more. */
export const BUCKETS = ["0", "1", "2", "3", "4", "5", "6", "7+"];
const BASIC_TYPES: [string, string][] = [["Plains", "W"], ["Island", "U"], ["Swamp", "B"], ["Mountain", "R"], ["Forest", "G"]];
const FOUR_OF = new Set(["standard", "pioneer", "modern", "legacy", "vintage", "pauper", "premodern"]);
const SINGLETON = new Set(["commander", "canlander"]);
/** Cards whose text lets a deck hold any number of copies, and the few with their own cap. */
const ANY_NUMBER = new Set([
  "Relentless Rats", "Rat Colony", "Shadowborn Apostle", "Persistent Petitioners", "Dragon's Approach",
  "Slime Against Humanity", "Hare Apparent", "Templar Knight", "Cid, Timeless Artificer",
]);
const UP_TO: Record<string, number> = { "Seven Dwarves": 7, "Nazgûl": 9 };
const LEGALITY_FORMATS = ["standard", "pioneer", "modern", "legacy", "vintage", "pauper", "commander", "premodern"];

/* ── one card ─────────────────────────────────────────────────────────── */

export const front = (type: string) => type.split(" // ")[0];
const words = (s: string): string[] => s.match(/[A-Za-z]+/g) ?? [];

/** The card types on the front face ("Artifact Creature" → Artifact, Creature). */
export function cardTypes(type: string): string[] {
  const w = new Set(words(front(type).split(" — ")[0]));
  return TYPES.filter((t) => w.has(t));
}

/** A card with its type bits filled in; build cards through this once, then ask the stats many times. */
export function statCard(c: Omit<StatCard, "typeBits">): StatCard {
  return { ...c, typeBits: cardTypes(c.type).reduce((b, t) => b | (1 << TYPES.indexOf(t)), 0) };
}

const bits = (c: StatCard) => c.typeBits ?? statCard(c).typeBits!;
export const isLand = (c: StatCard) => (bits(c) & (1 << 7)) !== 0;
export const isCreature = (c: StatCard) => (bits(c) & 1) !== 0;
export const bucket = (cmc: number) => Math.min(7, Math.max(0, Math.floor(cmc)));

/**
 * Colored mana symbols in a cost, every face counted, as [W, U, B, R, G]. A hybrid symbol counts once for each of
 * its colors; Phyrexian and {2/W} count for their color.
 */
export function pips(cost: string): number[] {
  const out = [0, 0, 0, 0, 0];
  for (const m of cost.matchAll(/\{([^}]*)\}/g)) {
    const parts = m[1].split("/");
    COLORS.forEach((col, i) => { if (parts.includes(col)) out[i]++; });
  }
  return out;
}

/** Colors of the basic land types on any face (Steam Vents → UR). */
export function basicTypeColors(c: StatCard): string {
  const sub = new Set<string>();
  for (const face of c.type.split(" // ")) {
    const i = face.indexOf(" — ");
    if (i >= 0) for (const w of words(face.slice(i + 3))) sub.add(w);
  }
  return BASIC_TYPES.filter(([t]) => sub.has(t)).map(([, col]) => col).join("");
}

/** Any face is a permanent (a spell // land card counts through its land). */
export const isPermanent = (c: StatCard) =>
  c.type.split(" // ").some((face) => words(face.split(" — ")[0]).some((w) => PERMANENTS.has(w)));

export const isBasic = (c: StatCard) => words(c.type).includes("Basic");

/**
 * Mana a card makes as WUBRGC letters. With the pack's produced field: permanents only (rituals aren't sources), and
 * F (searches for any basic land) makes the colors of the deck's basic lands (`basics`). Without it (an older pack):
 * lands by their basic land types.
 */
export function produces(c: StatCard, basics = ""): string {
  if (c.produced == null) return isLand(c) ? basicTypeColors(c) : "";
  if (!isPermanent(c)) return "";
  const got = new Set([...c.produced.replace("F", ""), ...(c.produced.includes("F") ? basics : "")]);
  return [..."WUBRGC"].filter((x) => got.has(x)).join("");
}

/** The cube's color group: the card's colors (not its mana cost), lands on their own. */
export function colorGroup(c: StatCard): string {
  if (isLand(c)) return "Lands";
  if (c.colors.length === 0) return "Colorless";
  if (c.colors.length > 1) return "Multicolor";
  const i = COLORS.indexOf(c.colors as (typeof COLORS)[number]);
  return COLOR_GROUPS[i < 0 ? 6 : i];
}

/* ── decks ────────────────────────────────────────────────────────────── */

const sumQty = (cards: StatCard[]) => cards.reduce((n, c) => n + c.qty, 0);

/** The deck the stats describe: main deck and commander (sideboard and Considering left out). */
export const deckOf = (cards: StatCard[]) => cards.filter((c) => c.board === "main" || c.board === "commander");

/** Spells by mana value, split into creatures and everything else; lands left out. */
export function curve(cards: StatCard[]): { creatures: number[]; other: number[] } {
  const creatures = new Array(8).fill(0), other = new Array(8).fill(0);
  for (const c of deckOf(cards)) {
    if (isLand(c)) continue;
    (isCreature(c) ? creatures : other)[bucket(c.cmc)] += c.qty;
  }
  return { creatures, other };
}

/** Copies of each card type, in TYPES order. A card counts once for every type it has. */
export function typeCounts(cards: StatCard[]): number[] {
  const out = new Array(TYPES.length).fill(0);
  for (const c of cards) {
    const b = bits(c);
    for (let i = 0; i < TYPES.length; i++) if (b & (1 << i)) out[i] += c.qty;
  }
  return out;
}

export function averageMV(cards: StatCard[], withLands: boolean): number {
  let n = 0, sum = 0;
  for (const c of deckOf(cards)) {
    if (!withLands && isLand(c)) continue;
    n += c.qty;
    sum += c.cmc * c.qty;
  }
  return n === 0 ? 0 : sum / n;
}

export function pipTotals(cards: StatCard[]): number[] {
  const out = [0, 0, 0, 0, 0];
  for (const c of deckOf(cards)) pips(c.cost).forEach((p, i) => { out[i] += p * c.qty; });
  return out;
}

export interface Sources {
  /** Copies that make each of W U B R G. */
  colors: number[];
  colorless: number;
  /** Copies that make any mana, and the non-land ones among them (dorks, rocks, a spell // land card). */
  sources: number;
  nonLand: number;
  /** Lands (not basics) that make no mana the stats can read. */
  unread: number;
}

/** Mana sources in the deck: lands and permanents that make mana. */
export function sources(cards: StatCard[]): Sources {
  const deck = deckOf(cards);
  const basicSet = new Set<string>();
  for (const c of deck) if (isBasic(c) && isLand(c)) for (const x of basicTypeColors(c)) basicSet.add(x);
  const basics = [...basicSet].join("");
  const s: Sources = { colors: [0, 0, 0, 0, 0], colorless: 0, sources: 0, nonLand: 0, unread: 0 };
  for (const c of deck) {
    const p = produces(c, basics);
    if (p) {
      s.sources += c.qty;
      if (!isLand(c)) s.nonLand += c.qty;
      COLORS.forEach((col, i) => { if (p.includes(col)) s.colors[i] += c.qty; });
      if (p.includes("C")) s.colorless += c.qty;
    } else if (isLand(c) && !isBasic(c)) {
      s.unread += c.qty;
    }
  }
  return s;
}

export interface TokenUse {
  key: string;
  name: string;
  type: string;
  /** Cards that make it, by name, with their copies. */
  makers: { name: string; qty: number }[];
}

const byCode = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

/** Tokens the main deck, commander and sideboard make, by token card in name order. */
export function tokens(cards: StatCard[]): TokenUse[] {
  const found = new Map<string, { token: StatToken; makers: Map<string, number> }>();
  for (const c of cards) {
    if (c.board === "maybe") continue;
    for (const t of c.tokens ?? []) {
      let e = found.get(t.key);
      if (!e) found.set(t.key, (e = { token: t, makers: new Map() }));
      e.makers.set(c.name, (e.makers.get(c.name) ?? 0) + c.qty);
    }
  }
  return [...found.values()]
    .sort((a, b) => byCode(a.token.name, b.token.name) || byCode(a.token.key, b.token.key))
    .map(({ token, makers }) => ({
      ...token,
      makers: [...makers].sort((a, b) => byCode(a[0], b[0])).map(([name, qty]) => ({ name, qty })),
    }));
}

/** Main deck, sideboard and commander at market price; copies without a price are counted. */
export function price(cards: StatCard[]): { total: number; unpriced: number } {
  let total = 0, unpriced = 0;
  for (const c of cards) {
    if (c.board === "maybe") continue;
    if (c.usd == null) unpriced += c.qty;
    else total += c.usd * c.qty;
  }
  return { total: Math.round(total * 100) / 100, unpriced };
}

/** Cards in the main deck (the library a game starts from). */
export const librarySize = (cards: StatCard[]) => sumQty(cards.filter((c) => c.board === "main"));

/** A legality code read for one format, or null when the format isn't checked (same rule as catalog.legalityOf). */
function codeLegality(code: string, format: string): string | null {
  const f = format === "canlander" ? "vintage" : format;
  const i = LEGALITY_FORMATS.indexOf(f);
  const ch = i < 0 ? undefined : code[i];
  if (!ch) return null;
  return ch === "L" ? "legal" : ch === "R" ? (format === "canlander" ? "legal" : "restricted") : ch === "B" ? "banned" : "not_legal";
}

/** Most copies a deck may hold over main deck and sideboard, null for no limit. */
export function copyLimit(name: string, format: string, basic: boolean): number | null {
  if (basic || ANY_NUMBER.has(name)) return null;
  if (name in UP_TO) return UP_TO[name];
  if (SINGLETON.has(format)) return 1;
  if (FOUR_OF.has(format)) return 4;
  return null;
}

/**
 * Why each card can't be played in a format, by name: Banned, Not legal, Restricted to 1, Singleton, or More than N
 * copies. Main deck, sideboard and commander count; Considering doesn't. Sorted by name (code points).
 */
export function legality(cards: StatCard[], format: string): { name: string; reason: string }[] {
  const copies = new Map<string, number>(), first = new Map<string, StatCard>();
  for (const c of cards) {
    if (c.board === "maybe") continue;
    copies.set(c.name, (copies.get(c.name) ?? 0) + c.qty);
    if (!first.has(c.name)) first.set(c.name, c);
  }
  const out: { name: string; reason: string }[] = [];
  for (const name of [...copies.keys()].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))) {
    const c = first.get(name)!, n = copies.get(name)!;
    const basic = words(c.type).includes("Basic");
    const code = codeLegality(c.legal ?? "", format);
    let reason: string | null = null;
    if (code === "banned") reason = "Banned";
    else if (code === "not_legal") reason = "Not legal";
    else if (code === "restricted" && n > 1) reason = "Restricted to 1";
    else {
      const limit = copyLimit(name, format, basic);
      if (limit != null && n > limit) reason = limit === 1 ? "Singleton" : `More than ${limit} copies`;
    }
    if (reason) out.push({ name, reason });
  }
  return out;
}

/* ── odds ─────────────────────────────────────────────────────────────── */

function lnChoose(n: number, k: number): number {
  if (k <= 0 || k >= n) return 0;
  k = Math.min(k, n - k);
  let s = 0;
  for (let i = 1; i <= k; i++) s += Math.log(n - k + i) - Math.log(i);
  return s;
}

/** P(at least `k` of the `K` cards in a group are among `n` cards drawn from `N`). */
export function hypergeometric(N: number, K: number, n: number, k: number): number {
  n = Math.min(n, N);
  if (k <= 0) return 1;
  if (k > Math.min(K, n)) return 0;
  const total = lnChoose(N, n);
  let p = 0;
  for (let i = k; i <= Math.min(K, n); i++) {
    if (n - i > N - K) continue;
    p += Math.exp(lnChoose(K, i) + lnChoose(N - K, n - i) - total);
  }
  return Math.min(1, p);
}

/** Cards seen by your turn `turn`: the opening seven plus a draw each turn, except the first turn on the play. */
export const drawsByTurn = (turn: number, onPlay: boolean) => 7 + turn - (onPlay ? 1 : 0);

/* ── cubes ────────────────────────────────────────────────────────────── */

export function colorBalance(cards: StatCard[]): number[] {
  const out = new Array(COLOR_GROUPS.length).fill(0);
  for (const c of cards) out[COLOR_GROUPS.indexOf(colorGroup(c))] += c.qty;
  return out;
}

/** Mana value columns for each color group but Lands. */
export function curveByColor(cards: StatCard[]): number[][] {
  const out = Array.from({ length: COLOR_GROUPS.length - 1 }, () => new Array(8).fill(0));
  for (const c of cards) {
    const g = COLOR_GROUPS.indexOf(colorGroup(c));
    if (g < out.length) out[g][bucket(c.cmc)] += c.qty;
  }
  return out;
}

export type AsfanBy = "color" | "type" | "mv";

/** Labels for `asfan`'s values. */
export function asfanLabels(by: AsfanBy): string[] {
  return by === "color" ? COLOR_GROUPS : by === "type" ? TYPES : [...BUCKETS, "Lands"];
}

/** Expected copies of each characteristic in a pack of `pack` cards drawn from the cube. */
export function asfan(cards: StatCard[], pack: number, by: AsfanBy): number[] {
  const total = sumQty(cards);
  let counts: number[];
  if (by === "color") counts = colorBalance(cards);
  else if (by === "type") counts = typeCounts(cards);
  else {
    counts = new Array(9).fill(0);
    for (const c of cards) counts[isLand(c) ? 8 : bucket(c.cmc)] += c.qty;
  }
  return counts.map((n) => (total === 0 ? 0 : (pack * n) / total));
}

/** One copy per element: the order sample hands and packs shuffle. */
export function expand(cards: StatCard[]): number[] {
  const out: number[] = [];
  cards.forEach((c, i) => { for (let k = 0; k < c.qty; k++) out.push(i); });
  return out;
}

/* ── random numbers (same sequence on every platform) ─────────────────── */

/** mulberry32: a small 32-bit generator, seeded, so tests can replay a hand. */
export class StatsRng {
  private a: number;
  constructor(seed: number) { this.a = seed | 0; }

  next(): number {
    this.a = (this.a + 0x6d2b79f5) | 0;
    let t = this.a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return (t ^ (t >>> 14)) >>> 0;
  }

  /** 0 ..< bound (multiply-shift; exact while next() * bound stays under 2^53). */
  int(bound: number): number { return Math.floor((this.next() * bound) / 4294967296); }

  /** A Fisher-Yates permutation of 0 ..< n. */
  shuffle(n: number): number[] {
    const a = Array.from({ length: n }, (_, i) => i);
    for (let i = n - 1; i > 0; i--) {
      const j = this.int(i + 1);
      [a[i], a[j]] = [a[j], a[i]];
    }
    return a;
  }

  static randomSeed(): number {
    return crypto.getRandomValues(new Uint32Array(1))[0];
  }
}

/**
 * A sample opening hand with the London mulligan: every mulligan shuffles and draws seven again, then puts one card
 * on the bottom for each mulligan taken. Values are positions in the expanded library (`expand`). Immutable: each
 * action returns the next hand.
 */
export class SampleHand {
  readonly hand: number[] = [];
  readonly library: number[] = [];
  readonly mulligans: number = 0;
  /** Cards still to put on the bottom before the hand is kept. */
  readonly toBottom: number = 0;
  /** Cards drawn after keeping. */
  readonly drawn: number = 0;

  private constructor(readonly size: number, private readonly rng: StatsRng, init?: Partial<SampleHand>) {
    Object.assign(this, init);
  }

  static deal(size: number, seed: number): SampleHand {
    return new SampleHand(size, new StatsRng(seed)).dealt(0);
  }

  private dealt(mulligans: number): SampleHand {
    const order = this.rng.shuffle(this.size);
    return new SampleHand(this.size, this.rng, {
      hand: order.slice(0, 7), library: order.slice(7), mulligans, toBottom: Math.min(mulligans, Math.min(7, this.size)), drawn: 0,
    });
  }

  /** Down to one card at most. */
  get canMulligan(): boolean { return 7 - this.mulligans > 1 && this.size > 0; }
  get canDraw(): boolean { return this.toBottom === 0 && this.library.length > 0; }

  mulligan(): SampleHand { return this.canMulligan ? this.dealt(this.mulligans + 1) : this; }

  bottom(index: number): SampleHand {
    if (this.toBottom === 0 || index < 0 || index >= this.hand.length) return this;
    const hand = this.hand.filter((_, i) => i !== index);
    return new SampleHand(this.size, this.rng, { ...this.state(), hand, library: [...this.library, this.hand[index]], toBottom: this.toBottom - 1 });
  }

  draw(): SampleHand {
    if (!this.canDraw) return this;
    return new SampleHand(this.size, this.rng, {
      ...this.state(), hand: [...this.hand, this.library[0]], library: this.library.slice(1), drawn: this.drawn + 1,
    });
  }

  private state() {
    return { hand: this.hand, library: this.library, mulligans: this.mulligans, toBottom: this.toBottom, drawn: this.drawn };
  }
}
