// The deck image's plan and geometry (contract/deck-image-2026-10-20.md), the same rules and numbers as the web's
// deckImage.ts, iOS DeckImage.swift and Android DeckImage.kt: the cards layout, grouped by type, checked against
// testdata/deck-image/cases.json. Pure.

export interface Line {
  card_id: string;
  oracle_id: string | null;
  name: string;
  board: string;
  qty: number;
  finish: string;
  type_line: string | null;
  cmc: number | null;
  set: string;
  image_ts: number | null;
}

/** One card on the image: every copy of an Oracle card in a section, shown as its most-held printing. */
export interface Card {
  key: string;
  cardId: string;
  name: string;
  qty: number;
  set: string;
  finish: string;
  imageTs: number | null;
}
export interface Pile { title: string; cards: Card[] }
export interface Plan { main: Pile[]; side: Card[] }

export const TYPE_ORDER = ["Creatures", "Planeswalkers", "Instants", "Sorceries", "Artifacts", "Enchantments", "Battles", "Lands", "Other"];

export function typeGroup(t: string): string {
  if (t.includes("Creature")) return "Creatures";
  if (t.includes("Planeswalker")) return "Planeswalkers";
  if (t.includes("Land")) return "Lands";
  if (t.includes("Instant")) return "Instants";
  if (t.includes("Sorcery")) return "Sorceries";
  if (t.includes("Artifact")) return "Artifacts";
  if (t.includes("Enchantment")) return "Enchantments";
  if (t.includes("Battle")) return "Battles";
  return "Other";
}

const front = (l: Line) => (l.type_line ?? "").split(" // ")[0];
const isLand = (l: Line) => front(l).includes("Land") && !front(l).includes("Creature");
const mvOf = (l: Line) => (isLand(l) ? 99 : Math.max(0, Math.floor(l.cmc ?? 0)));

export const count = (cards: Card[]) => cards.reduce((n, c) => n + c.qty, 0);
export const mainCount = (plan: Plan) => plan.main.reduce((n, p) => n + count(p.cards), 0);
export const ordered = (plan: Plan) => plan.main.flatMap((p) => p.cards);

function cards(ls: Line[]): Card[] {
  const same = new Map<string, Line[]>();
  for (const l of ls) {
    const k = l.oracle_id ?? l.card_id;
    same.set(k, [...(same.get(k) ?? []), l]);
  }
  return [...same.entries()].map(([key, group]) => {
    const lead = group.reduce((a, b) => (b.qty > a.qty || (b.qty === a.qty && b.card_id < a.card_id) ? b : a));
    return {
      key, cardId: lead.card_id, name: lead.name, qty: group.reduce((n, l) => n + l.qty, 0), set: lead.set,
      finish: lead.finish, imageTs: lead.image_ts, mv: mvOf(lead),
    };
  })
    .sort((a, b) => a.mv - b.mv || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
    .map(({ mv: _mv, ...c }) => c);
}

/** Lines → the plan: Commander first, then the type groups in order, the sideboard apart; Considering left off. */
export function plan(lines: Line[]): Plan {
  const main: Pile[] = [];
  const commander = lines.filter((l) => l.board === "commander");
  if (commander.length) main.push({ title: "Commander", cards: cards(commander) });
  const deck = lines.filter((l) => l.board === "main");
  const present = new Set(deck.map((l) => typeGroup(front(l))));
  for (const g of TYPE_ORDER) {
    if (present.has(g)) main.push({ title: g, cards: cards(deck.filter((l) => typeGroup(front(l)) === g)) });
  }
  return { main, side: cards(lines.filter((l) => l.board === "side")) };
}

// The cards layout's geometry (points; the picture is drawn at a scale).
export const WIDTH = 1200;
export const PAD = 40;
export const HEADER = 132;
export const GAP = 14;
export const ROW_GAP = 22;
export const SIDE_GUTTER = 56;
export const ASPECT = 1.396;
export const MIN_WIDTH = 72;

export interface Fit { cols: number; cw: number; step: number; height: number }

/** Cards grow as large as the 16:9 canvas allows (columns 2–16 tried; the sideboard column keeps cards at least 10%
 *  of a card apart); below MIN_WIDTH the canvas grows taller instead. */
export function fit(main: number, side: number): Fit {
  const height = (WIDTH * 9) / 16;
  const room = height - HEADER - PAD;
  const flag = side > 0 ? 1 : 0;
  const sideMax = side > 1 ? room / ((1 + 0.1 * (side - 1)) * ASPECT) : Infinity;
  let best = { cols: 1, cw: 0 };
  for (let cols = 2; cols <= 16; cols++) {
    const r = Math.ceil(Math.max(main, 1) / cols);
    const byWidth = (WIDTH - 2 * PAD - flag * SIDE_GUTTER - (cols - 1) * GAP) / (cols + flag);
    const byHeight = (room - (r - 1) * ROW_GAP) / (r * ASPECT);
    const cw = Math.floor(Math.min(byWidth, byHeight, sideMax));
    if (cw > best.cw) best = { cols, cw };
  }
  let { cw, cols } = best;
  let total = height;
  if (cw < MIN_WIDTH) {
    cw = MIN_WIDTH;
    cols = Math.max(1, Math.floor((WIDTH - 2 * PAD - flag * (SIDE_GUTTER + cw) + GAP) / (cw + GAP)));
    const r = Math.ceil(Math.max(main, 1) / cols);
    total = Math.max(height, HEADER + PAD + r * cw * ASPECT + (r - 1) * ROW_GAP);
  }
  const ch = cw * ASPECT;
  const step = side > 1 ? Math.min(ch * 0.19, (total - HEADER - PAD - ch) / (side - 1)) : 0;
  return { cols, cw, step: Math.max(step, 0), height: Math.ceil(total) };
}

/** Rounded corners by set, as a share of the card's width (Alpha rounder, Collectors' Edition square). */
export function cornerRatio(set: string): number {
  if (set === "lea") return 0.0699;
  if (set === "ced" || set === "cei") return 0;
  return 0.0432;
}

/** Scryfall's image for a printing. */
export function imageUrl(cardId: string, imageTs: number | null, size: "small" | "normal"): string {
  return `https://cards.scryfall.io/${size}/front/${cardId[0]}/${cardId[1]}/${cardId}.jpg${imageTs ? `?${imageTs}` : ""}`;
}
