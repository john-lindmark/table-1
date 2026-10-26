/* Sort (the View menu on every card list, after Group by; contract/card-sort-2026-10-25.md). One rule everywhere,
   tested against testdata/card-sort/cases.json (iOS CardSort.swift, Android CardSort.kt):
   - Name: A–Z, ignoring case.
   - Mana value: spells low to high, then lands (Group by's Lands), then by name.
   - Set: newest set first, then set code, then collector number (digits as a number, then the text), then name; a
     card newer than the local card data goes last.
   Screens that had their own order keep it first: All cards' Recent and Price, binders' Most copies. Group by makes
   the sections; Sort orders the cards inside each. */
import { useState } from "react";
import type { Catalog } from "./catalog";

export type CardSort = "recent" | "price" | "count" | "name" | "manaValue" | "set";
export type SortScreen = "list" | "shared" | "binder" | "allCards";

export const SORT_TITLE: Record<CardSort, string> = {
  recent: "Most recent first", price: "Highest price first", count: "Most copies first",
  name: "Sort by name", manaValue: "Sort by mana value", set: "Sort by set",
};

/** The screen family's choices, its own order first (that's also where it starts). */
export function sortOptions(s: SortScreen): CardSort[] {
  if (s === "binder") return ["count", "name", "manaValue", "set"];
  if (s === "allCards") return ["recent", "price", "name", "manaValue", "set"];
  return ["name", "manaValue", "set"];
}

/** The saved sort, or the screen's first option when it's missing or not one of its own. */
export function sortOf(raw: string | null | undefined, s: SortScreen): CardSort {
  const o = sortOptions(s);
  return o.includes(raw as CardSort) ? (raw as CardSort) : o[0];
}

/** Whether this rule orders the cards (name, mana value, set); the others are the screen's own. */
export const isSharedSort = (s: CardSort) => s === "name" || s === "manaValue" || s === "set";

/** What a card sorts on: its name, its mana value (and whether it's a land) and the printing shown. */
export interface SortKey { name: string; cmc: number; land: boolean; released: string; set: string; cn: string }

export const sortKey = (name: string, cmc = 0, land = false, released = "", set = "", cn = ""): SortKey =>
  ({ name: name.toLowerCase(), cmc, land, released, set, cn });

/** A card's key from the catalog: Oracle index `oi` (-1: not in the card data yet) and printing `p` (the one shown). */
export function sortKeyOf(c: Catalog, name: string, oi: number, p: number | null): SortKey {
  const front = oi < 0 ? "" : c.oType[oi].split(" // ")[0];
  const land = front.includes("Land") && !front.includes("Creature");
  return sortKey(name, oi < 0 ? 0 : c.oCmc[oi], land, p == null ? "" : c.pReleased[p] ?? "", p == null ? "" : c.pSet[p], p == null ? "" : c.pCn[p]);
}

const cmp = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);
const number = (cn: string) => {
  const d = cn.replace(/\D/g, "");
  return d ? parseInt(d, 10) : Number.MAX_SAFE_INTEGER;
};

/** Negative when `a` goes before `b` under `by` (name, mana value or set; any other sort reads as name). */
export function compareKeys(a: SortKey, b: SortKey, by: CardSort): number {
  if (by === "manaValue") {
    if (a.land !== b.land) return a.land ? 1 : -1;
    if (a.cmc !== b.cmc) return a.cmc - b.cmc;
  } else if (by === "set") {
    if (!a.set !== !b.set) return a.set ? -1 : 1;
    if (a.released !== b.released) return cmp(b.released, a.released);
    if (a.set !== b.set) return cmp(a.set, b.set);
    const na = number(a.cn), nb = number(b.cn);
    if (na !== nb) return na - nb;
    if (a.cn !== b.cn) return cmp(a.cn, b.cn);
  }
  return cmp(a.name, b.name);
}

/** `items` in this sort, each item's key worked out once. Recent, price and count leave the order as it is. */
export function applySort<T>(items: T[], by: CardSort, key: (t: T) => SortKey): T[] {
  if (!isSharedSort(by)) return items;
  return items.map((t) => [key(t), t] as const).sort((x, y) => compareKeys(x[0], y[0], by)).map((x) => x[1]);
}

/** The saved Sort for a screen family (decks and cubes share theirs between your own and shared ones). */
export function useStoredSort(key: string, s: SortScreen): [CardSort, (v: CardSort) => void] {
  const [v, setV] = useState<CardSort>(() => {
    try {
      return sortOf(localStorage.getItem(key), s);
    } catch {
      return sortOptions(s)[0];
    }
  });
  const set = (x: CardSort) => {
    setV(x);
    try {
      localStorage.setItem(key, x);
    } catch {
      /* storage blocked: keep it for this visit */
    }
  };
  return [v, set];
}

/** Storage keys: decks and cubes share one per kind; All cards (its existing sort), binders and shared sections each
 *  keep their own. */
export const SORT_KEY = {
  deck: "table1.library.deck.sort",
  cube: "table1.library.cube.sort",
  allCards: "table1.library.allCards.sort",
  binder: "table1.library.binder.sort",
  shared: "table1.library.shared.sort",
} as const;
