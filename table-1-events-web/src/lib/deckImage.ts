import { exportFileName } from "./listExport";
import { groupLabel, keyFor, sortGroups, type GroupKeys, type Grouping } from "./cardGrouping";

/* Deck image (contract/deck-image-2026-10-20.md): which cards go on the picture, in what order, and how big they
   draw. The same rules and numbers as iOS DeckImage.swift and Android DeckImage.kt; screens/DeckImage.tsx draws it. */

export type DeckImageLayout = "grid" | "stacks";

/** One card on the image: every copy of an Oracle card in a section, shown as its most-held printing. */
export interface DeckImageCard { key: string; name: string; qty: number; p: number | null; set: string; finish: string }
export interface Pile { title: string; cards: DeckImageCard[] }
export interface Plan { main: Pile[]; side: DeckImageCard[] }

/** What plan() reads from a deck's resolved lines. */
export interface PlanLine { cardId: string; oracleId: string | null; name: string; board: string; qty: number; p: number | null; set: string; finish: string; keys: GroupKeys }

export const count = (cards: DeckImageCard[]) => cards.reduce((n, c) => n + c.qty, 0);
export const mainCount = (plan: Plan) => plan.main.reduce((n, p) => n + count(p.cards), 0);
export const ordered = (plan: Plan) => plan.main.flatMap((p) => p.cards);

const mvOf = (k: GroupKeys) => (k.manaValue === "Lands" ? 99 : Number.parseInt(k.manaValue, 10) || 0);

/** Lines → the plan: a deck's Commander first, then the Group by groups in order (type when None), the sideboard
 *  apart; Considering left off. Cards sort by mana value then name inside a group. */
export function plan(lines: PlanLine[], grouping: Grouping): Plan {
  const by: Grouping = grouping === "none" ? "type" : grouping;
  const cards = (ls: PlanLine[]): DeckImageCard[] => {
    const same = new Map<string, PlanLine[]>();
    for (const l of ls) {
      const k = l.oracleId ?? l.cardId;
      same.set(k, [...(same.get(k) ?? []), l]);
    }
    return [...same.entries()].map(([key, group]) => {
      const lead = group.reduce((a, b) => (b.qty > a.qty || (b.qty === a.qty && b.cardId < a.cardId) ? b : a));
      return { key, name: lead.name, qty: group.reduce((n, l) => n + l.qty, 0), p: lead.p, set: lead.set, finish: lead.finish, mv: mvOf(lead.keys) };
    })
      .sort((a, b) => a.mv - b.mv || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
      .map(({ mv: _mv, ...c }) => c);
  };
  const main: Pile[] = [];
  const commander = lines.filter((l) => l.board === "commander");
  if (commander.length) main.push({ title: "Commander", cards: cards(commander) });
  const deck = lines.filter((l) => l.board === "main");
  for (const g of sortGroups(by, deck.map((l) => keyFor(l.keys, by)))) {
    main.push({ title: groupLabel(by, g), cards: cards(deck.filter((l) => keyFor(l.keys, by) === g)) });
  }
  return { main, side: cards(lines.filter((l) => l.board === "side")) };
}

/** Stacks: a group taller than `max` cards continues in the next column (untitled). */
export function columns(piles: Pile[], max: number): { title: string | null; cards: DeckImageCard[] }[] {
  return piles.flatMap((p) => {
    const out: { title: string | null; cards: DeckImageCard[] }[] = [];
    for (let i = 0; i < p.cards.length; i += max) out.push({ title: i === 0 ? `${p.title} · ${count(p.cards)}` : null, cards: p.cards.slice(i, i + max) });
    return out;
  });
}

export function rows<T>(items: T[], n: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += n) out.push(items.slice(i, i + n));
  return out;
}

// The cards layout's geometry (points; the image is drawn at 2×).
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

/** "Izzet Tempo.jpg", from the deck's name. */
export const fileName = (deck: string) => exportFileName(deck, "deck", "text").replace(/\.txt$/, ".jpg");
