/* Printings, collapsed (contract/library-polish-2026-10-19.md § Printings, collapsed): a card with several printings
   (or finishes) is one row that opens into one row per printing and finish. Same rules as iOS `PrintingsDisclosure`,
   `CatalogPrinting.oldestFirst` and `LineGroup`. */
import type { Catalog } from "./catalog";

/** Card detail lists printings by release, earliest first (the pack's order is newest first, so on the same day the
 *  later pack position is the older printing). */
export function oldestFirst(c: Catalog, a: number, b: number): number {
  const ra = c.pReleased[a] ?? "", rb = c.pReleased[b] ?? "";
  if (ra !== rb) return ra < rb ? -1 : 1;
  return b - a;
}

/** Which cards show each printing on its own row. Collapsed by default; Expand all opens every card, and a card's own
 *  chevron flips just that card. */
export interface Disclosure { all: boolean; flipped: ReadonlySet<string> }

export const COLLAPSED: Disclosure = { all: false, flipped: new Set() };
export const isOpen = (d: Disclosure, id: string) => d.all !== d.flipped.has(id);
export function toggleOne(d: Disclosure, id: string): Disclosure {
  const flipped = new Set(d.flipped);
  if (flipped.has(id)) flipped.delete(id);
  else flipped.add(id);
  return { all: d.all, flipped };
}
export const setAll = (on: boolean): Disclosure => ({ all: on, flipped: new Set() });

/** One card's lines in one section (its printings and finishes), shown as one row until opened. First-seen order is
 *  kept; inside, the line with the most copies leads. */
export interface LineGroup<T> { id: string; lines: T[]; qty: number }

export function lineGroups<T extends { board: string; oracleId: string | null; cardId: string; qty: number; finish: string }>(lines: T[]): LineGroup<T>[] {
  const order: string[] = [];
  const by = new Map<string, T[]>();
  for (const l of lines) {
    const k = `${l.board}|${l.oracleId ?? l.cardId}`;
    if (!by.has(k)) { order.push(k); by.set(k, []); }
    by.get(k)!.push(l);
  }
  const lineId = (l: T) => `${l.board}|${l.cardId}|${l.finish}`;
  return order.map((k) => {
    const ls = by.get(k)!.sort((a, b) => b.qty - a.qty || (lineId(a) < lineId(b) ? -1 : 1));
    return { id: k, lines: ls, qty: ls.reduce((n, l) => n + l.qty, 0) };
  });
}

/** Copies of one printing in one finish (over conditions and languages): a row a collapsed card opens into. */
export interface Part { cardId: string; finish: "nonfoil" | "foil" | "etched"; qty: number; p: number | null }

const FINISH_ORDER = ["nonfoil", "foil", "etched"];

/** Adds copies to a card's parts. */
export function addPart(parts: Part[], cardId: string, finish: Part["finish"], qty: number, p: number | null) {
  const had = parts.find((x) => x.cardId === cardId && x.finish === finish);
  if (had) had.qty += qty;
  else parts.push({ cardId, finish, qty, p });
}

/** Oldest printing first, then non-foil, foil, etched; printings newer than the card data last. */
export function sortParts(c: Catalog, parts: Part[]): Part[] {
  return parts.sort((a, b) => {
    if (a.p == null || b.p == null) return a.p == null ? (b.p == null ? 0 : 1) : -1;
    if (a.cardId !== b.cardId) return oldestFirst(c, a.p, b.p);
    return FINISH_ORDER.indexOf(a.finish) - FINISH_ORDER.indexOf(b.finish);
  });
}

/** All cards → Price: the most a single copy is worth; no price yet sorts first, as if most valuable. */
export function priceRank(price: number | null): number {
  return price == null ? Infinity : price;
}
