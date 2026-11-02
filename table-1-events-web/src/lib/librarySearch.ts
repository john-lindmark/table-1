import { normName } from "./catalog";
import type { Item } from "./collection";
import type { Binder, Want, WantOp } from "./binders";

/* Searching inside a screen (a cube, a binder, all binders, wants) and among one card's printings, plus the small
   rules behind want printings, binder Move in and cube Replace (contract/library-search-2026-10-18.md). Same rules
   as iOS and Android; search cases in testdata/library-search/cases.json. */

/**
 * Every word of the query is in the card's name or its type line (normalized like card names, so "jace" finds
 * "Jace, the Mind Sculptor" and "legendary creature" finds legends). An empty query matches everything.
 */
export function cardMatches(query: string, name: string, type: string): boolean {
  const words = normName(query).split(" ").filter(Boolean);
  if (!words.length) return true;
  const hay = `${normName(name)} | ${normName(type)}`;
  return words.every((w) => hay.includes(w));
}

/** One printing by set code, collector number or year: every word starts one of them ("mh2", "mh2 130", "2021"). */
export function printingMatches(query: string, set: string, cn: string, releasedAt: string): boolean {
  const words = query.toLowerCase().split(/[ #]+/).filter(Boolean);
  const hay = [set.toLowerCase(), cn.toLowerCase(), releasedAt.slice(0, 4)];
  return words.every((w) => hay.some((h) => h.startsWith(w)));
}

/**
 * Collection Search, your own decks, cubes and binders: every word of the query is in the name or the format code
 * (normalized like card names). An empty query matches nothing.
 */
export function listMatches(query: string, name: string, format: string): boolean {
  const words = normName(query).split(" ").filter(Boolean);
  if (!words.length) return false;
  const hay = `${normName(name)} | ${normName(format)}`;
  return words.every((w) => hay.includes(w));
}

/** Names starting with the query's first word first, then by normalized name, then name. */
export function listOrder<T>(query: string, items: T[], name: (t: T) => string): T[] {
  const first = normName(query).split(" ")[0] ?? "";
  const keyed = items.map((t) => ({ t, n: normName(name(t)), raw: name(t) }));
  keyed.sort((a, b) => Number(!a.n.startsWith(first)) - Number(!b.n.startsWith(first))
    || (a.n < b.n ? -1 : a.n > b.n ? 1 : 0) || (a.raw < b.raw ? -1 : a.raw > b.raw ? 1 : 0));
  return keyed.map((k) => k.t);
}

/**
 * Ops that point a want at another printing (`cardId` null = any printing; `finish` only with a printing): the old
 * want comes off and its copies are added to the new one (merging into a want already there), keeping its max
 * price. Null when it already points there.
 */
export function repointWant(w: Want, cardId: string | null, finish: Want["finish"]): WantOp[] | null {
  const f = cardId == null ? null : finish;
  if (w.cardId === cardId && w.finish === f) return null;
  return [{ oracle_id: w.oracleId, card_id: w.cardId, finish: w.finish, qty: 0 },
          { oracle_id: w.oracleId, card_id: cardId, finish: f, delta: w.qty, max_usd: w.maxUsd }];
}

export interface Place { item: Item; from: Binder | null; qty: number }

/**
 * Where Move in (adding a card you own to a binder, `target` null = Unsorted) takes one copy from: Unsorted first,
 * then binders not for trade, then for-trade binders, each by name; in one place, the item with the most copies
 * there. Never the target itself. Null when every copy is already there.
 */
export function moveInSource(places: Place[], target: string | null): { item: Item; from: string | null } | null {
  const rank = (p: Place) => (p.from == null ? 0 : p.from.for_trade ? 2 : 1);
  const cands = places.filter((p) => p.qty > 0 && (p.from?.id ?? null) !== target);
  cands.sort((a, b) => rank(a) - rank(b)
    || (a.from?.name.toLowerCase() ?? "").localeCompare(b.from?.name.toLowerCase() ?? "")
    || b.qty - a.qty || (a.item.k < b.item.k ? -1 : a.item.k > b.item.k ? 1 : 0));
  return cands.length ? { item: cands[0].item, from: cands[0].from?.id ?? null } : null;
}

/** The list's own lines whose card matches a search, by name: what Remove or replace offers. Empty query: none. */
export function matchingLines<T extends { name: string; type: string; board: string; finish: string }>(lines: T[], query: string): T[] {
  if (!normName(query)) return [];
  const order = ["commander", "main", "side", "maybe"];
  return lines.filter((l) => cardMatches(query, l.name, l.type))
    .sort((a, b) => a.name.localeCompare(b.name) || order.indexOf(a.board) - order.indexOf(b.board) || a.finish.localeCompare(b.finish));
}
