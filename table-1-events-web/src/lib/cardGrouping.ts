/* Group by (the View menu on every card list: your decks, cubes, binders and All cards, and anything shared with you
   on a profile; contract/shared-lists-grouping-2026-10-20.md §4). One rule everywhere, tested against
   testdata/card-grouping/cases.json (iOS CardGrouping.swift, Android CardGrouping.kt):
   - Type: Creatures, Planeswalkers, Instants, Sorceries, Artifacts, Enchantments, Battles, Lands, Other (the front
     face's type line; a land creature is a creature).
   - Color: White, Blue, Black, Red, Green, Multicolor, Colorless, then Lands (from the card's colors; packs without
     colors fall back to the mana cost's symbols).
   - Mana value: 0 … 6, 7+, then Lands (lands have mana value 0 but read as their own pile).
   Decks start on Type, cubes on Color, collections and binders on None. */
import { useState } from "react";
import type { Catalog } from "./catalog";

export type Grouping = "none" | "type" | "color" | "manaValue";
export const GROUPINGS: Grouping[] = ["none", "type", "color", "manaValue"];

export const GROUPING_TITLE: Record<Grouping, string> = {
  none: "No groups", type: "Group by type", color: "Group by color", manaValue: "Group by mana value",
};

export const TYPE_ORDER = ["Creatures", "Planeswalkers", "Instants", "Sorceries", "Artifacts", "Enchantments", "Battles", "Lands", "Other"];
export const COLOR_ORDER = ["White", "Blue", "Black", "Red", "Green", "Multicolor", "Colorless", "Lands"];
export const MV_ORDER = ["0", "1", "2", "3", "4", "5", "6", "7+", "Lands"];

export const groupingOrder = (g: Grouping): string[] =>
  g === "type" ? TYPE_ORDER : g === "color" ? COLOR_ORDER : g === "manaValue" ? MV_ORDER : [];

/** The group's heading: mana values read "Mana value 3". */
export const groupLabel = (g: Grouping, key: string) => (g === "manaValue" && key !== "Lands" ? `Mana value ${key}` : key);

/** Keys in this grouping's order (unknown ones last, by name). */
export function sortGroups(g: Grouping, keys: Iterable<string>): string[] {
  const order = groupingOrder(g);
  const rank = (k: string) => (order.includes(k) ? order.indexOf(k) : 99);
  return [...new Set(keys)].sort((a, b) => rank(a) - rank(b) || (a < b ? -1 : a > b ? 1 : 0));
}

/** A deck's or cube's choices (they always group); collections and binders add None. */
export const groupingOptions = (list: boolean): Grouping[] => (list ? ["type", "color", "manaValue"] : GROUPINGS);

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

export function colorGroup(letters: string): string {
  const colors = (["W", "U", "B", "R", "G"] as const).filter((c) => letters.includes(c));
  if (colors.length > 1) return "Multicolor";
  return ({ W: "White", U: "Blue", B: "Black", R: "Red", G: "Green" } as const)[colors[0]] ?? "Colorless";
}

/** One card's group under each grouping. */
export interface GroupKeys { type: string; color: string; manaValue: string }

export const NO_KEYS: GroupKeys = { type: "Other", color: "Colorless", manaValue: "0" };

export function groupKeys(typeLine: string, manaCost: string, colors: string, cmc: number): GroupKeys {
  const front = typeLine.split(" // ")[0];
  const type = typeGroup(front);
  if (front.includes("Land") && !front.includes("Creature")) return { type, color: "Lands", manaValue: "Lands" };
  const mv = Math.floor(cmc);
  return { type, color: colorGroup(colors || manaCost), manaValue: mv >= 7 ? "7+" : String(Math.max(0, mv)) };
}

/** An Oracle card's keys from the catalog (index -1: not in the card data yet). */
export const keysOf = (c: Catalog, oi: number): GroupKeys =>
  oi < 0 ? NO_KEYS : groupKeys(c.oType[oi], c.oCost[oi], c.oColors[oi] ?? "", c.oCmc[oi]);

export const keyFor = (k: GroupKeys, g: Grouping): string => (g === "none" ? "" : k[g]);

/** Items in sections under `g`, the items' own order kept inside each: one untitled section for None. */
export function groupSections<T>(items: T[], g: Grouping, keys: (t: T) => GroupKeys): { key: string; items: T[] }[] {
  if (g === "none") return [{ key: "", items }];
  const by = new Map<string, T[]>();
  for (const it of items) {
    const k = keyFor(keys(it), g);
    const arr = by.get(k);
    if (arr) arr.push(it);
    else by.set(k, [it]);
  }
  return sortGroups(g, by.keys()).map((key) => ({ key, items: by.get(key)! }));
}

/** The saved Group by for a screen family (decks and cubes share theirs between your own and shared ones). */
export function useStoredGrouping(key: string, fallback: Grouping, list: boolean): [Grouping, (g: Grouping) => void] {
  const allowed = groupingOptions(list);
  const [v, setV] = useState<Grouping>(() => {
    try {
      const s = localStorage.getItem(key) as Grouping | null;
      return s && allowed.includes(s) ? s : fallback;
    } catch {
      return fallback;
    }
  });
  const set = (g: Grouping) => {
    setV(g);
    try {
      localStorage.setItem(key, g);
    } catch {
      /* storage blocked: keep it for this visit */
    }
  };
  return [v, set];
}

/** Storage keys: decks and cubes share one per kind; All cards, binders and shared sections each keep their own. */
export const GROUPING_KEY = {
  deck: "table1.library.deck.grouping",
  cube: "table1.library.cube.grouping",
  allCards: "table1.library.allCards.grouping",
  binder: "table1.library.binder.grouping",
  shared: "table1.library.shared.grouping",
} as const;
