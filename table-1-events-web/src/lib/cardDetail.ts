import { FINISH_LETTER, type Catalog } from "./catalog";
import { itemKey, type CollectionOp, type Condition, type Finish, type Item } from "./collection";
import { langForNew } from "./languages";
import type { Board } from "./lists";

/* Card detail's rules (contract/card-detail-2026-10-23.md): the screen is opened in a scope (the collection, a deck or
   cube, a binder, or search), shows that scope's versions of the card, and a pick in the attribute row changes the
   copies in view. Same rules as iOS CardDetail.swift and Android CardDetail.kt, against testdata/card-detail/cases.json. */

/** One thing the scope counts: owned copies are printing × finish × condition × language; a deck or cube line is
 *  printing × section × finish (its condition and language are unused). */
export interface CardVersion {
  cardId: string;
  finish: Finish;
  condition: Condition;
  lang: string;
  /** List scope: the line's section. */
  board?: Board;
  qty: number;
}

export type CardAttribute = "set" | "language" | "condition" | "finish" | "section";

/** What the rules need of a printing. `ord` is its pack position: within a card, higher is older. */
export interface PrintingFacts { cardId: string; lang: string; finishes: string; released: string; ord: number; original: boolean }

export const FINISH_ORDER: Finish[] = ["nonfoil", "foil", "etched"];
const BOARDS: Board[] = ["commander", "main", "side", "maybe"];
const CONDITION_ORDER: Condition[] = ["NM", "LP", "MP", "HP", "DMG"];
const UNSORTED = "unsorted";

export const versionKey = (v: Pick<CardVersion, "cardId" | "finish" | "condition" | "lang">) => itemKey(v.cardId, v.finish, v.condition, v.lang);
export const versionId = (v: CardVersion) => (v.board ? `${v.cardId}|${v.board}|${v.finish}|${v.lang}` : versionKey(v));

export const finishesOf = (p: Pick<PrintingFacts, "finishes">): Finish[] =>
  FINISH_ORDER.filter((f) => [...p.finishes].some((l) => FINISH_LETTER[l] === f));

export function factsOf(c: Catalog, p: number): PrintingFacts {
  return { cardId: c.pId[p], lang: c.pLang[p], finishes: c.pFinishes[p], released: c.pReleased[p] ?? "", ord: p,
           original: c.oOriginal[c.pOracle[p]] === p };
}

/** Printings by release, earliest first. */
export const oldestFirstFacts = (a: PrintingFacts, b: PrintingFacts) =>
  a.released !== b.released ? (a.released < b.released ? -1 : 1) : b.ord - a.ord;

/** The value every version shares, null when they differ (shown as MIX). Empty → null. */
export function shared<T>(versions: CardVersion[], value: (v: CardVersion) => T): T | null {
  if (!versions.length) return null;
  const first = value(versions[0]);
  return versions.every((v) => value(v) === first) ? first : null;
}

/** The version the stepper and the bar's price act on when none is selected: the one held most of, the first on a tie. */
export function mainVersion(versions: CardVersion[]): CardVersion | null {
  return versions.reduce<CardVersion | null>((best, v) => (!best || v.qty > best.qty ? v : best), null);
}

/** Versions in grid order: printings earliest first, then finish, section, condition, language. */
export function orderedVersions(versions: CardVersion[], printings: PrintingFacts[]): CardVersion[] {
  const rank = new Map([...printings].sort(oldestFirstFacts).map((p, i) => [p.cardId, i]));
  const key = (v: CardVersion) => [rank.get(v.cardId) ?? Number.MAX_SAFE_INTEGER, FINISH_ORDER.indexOf(v.finish),
    v.board ? BOARDS.indexOf(v.board) : 0, CONDITION_ORDER.indexOf(v.condition)];
  return versions.filter((v) => v.qty > 0).sort((a, b) => {
    const ka = key(a), kb = key(b);
    for (let i = 0; i < ka.length; i++) if (ka[i] !== kb[i]) return ka[i] - kb[i];
    return a.lang < b.lang ? -1 : a.lang > b.lang ? 1 : 0;
  });
}

/** The version a pick turns `v` into. Set: the new printing, in the same finish if it has it (else its first), in its
 *  own language when it isn't English (else the copy keeps its language). The others change just that field. */
export function repoint(v: CardVersion, attribute: CardAttribute, value: string, printing?: PrintingFacts): CardVersion {
  switch (attribute) {
    case "set": {
      if (!printing) return v;
      const finishes = finishesOf(printing);
      return { ...v, cardId: printing.cardId, finish: finishes.includes(v.finish) ? v.finish : finishes[0] ?? v.finish,
               lang: printing.lang !== "en" ? printing.lang : v.lang };
    }
    case "language": return { ...v, lang: value };
    case "condition": return { ...v, condition: value as Condition };
    case "finish": return { ...v, finish: value as Finish };
    case "section": return { ...v, board: value as Board };
  }
}

/** The version a new copy starts as: the card's original printing (else the earliest), its first finish, and the
 *  condition and language picked for adds. */
export function freshVersion(printings: PrintingFacts[], condition: Condition, lang: string, board?: Board): CardVersion | null {
  const p = printings.find((x) => x.original) ?? [...printings].sort(oldestFirstFacts)[0];
  if (!p) return null;
  return { cardId: p.cardId, finish: finishesOf(p)[0] ?? "nonfoil", condition, lang: langForNew(p.lang, lang), qty: 0, ...(board ? { board } : {}) };
}

/** Moves `qty` of an item's copies to another version, each copy staying where it is: from `from` only when given (a
 *  binder id or Unsorted), else Unsorted first, then the binders in the order given. Null when nothing would change or
 *  there aren't that many copies in those places. */
export function editOps(item: Pick<Item, "cardId" | "finish" | "condition" | "lang" | "qty">, places: { place: string; qty: number }[],
                        to: Pick<CardVersion, "cardId" | "finish" | "condition" | "lang">, qty: number, from?: string | null): CollectionOp[] | null {
  if (qty <= 0 || qty > item.qty || versionKey(to) === versionKey(item)) return null;
  const order = from != null ? places.filter((p) => p.place === from)
    : [...places.filter((p) => p.place === UNSORTED), ...places.filter((p) => p.place !== UNSORTED)];
  let left = qty;
  const ops: CollectionOp[] = [];
  for (const p of order) {
    if (left <= 0) break;
    const n = Math.min(left, p.qty);
    if (n <= 0) continue;
    const where = p.place === UNSORTED ? {} : { binder_id: p.place };
    ops.push({ card_id: item.cardId, finish: item.finish, condition: item.condition, lang: item.lang, delta: -n, ...where });
    ops.push({ card_id: to.cardId, finish: to.finish, condition: to.condition, lang: to.lang, delta: n, ...where });
    left -= n;
  }
  return left === 0 ? ops : null;
}

/** One copy more or less of a version, into or out of a binder (none: the collection's own rule, Unsorted first). */
export function stepOp(v: CardVersion, delta: number, binderId?: string | null): CollectionOp {
  const where = binderId && binderId !== UNSORTED ? { binder_id: binderId } : {};
  return { card_id: v.cardId, finish: v.finish, condition: v.condition, lang: v.lang, delta, ...where };
}

/** A new edition (long press on +): a copy of the version it was made from, one copy, not yet written. It stays dimmed
 *  until a pick makes it a version the scope doesn't hold. */
export const newEdition = (v: CardVersion): CardVersion => ({ ...v, qty: 1 });

/** Whether a new edition is different from every version in view, so it can be written. */
export const isNewEdition = (edition: CardVersion, versions: CardVersion[]) =>
  !versions.some((v) => v.qty > 0 && versionId(v) === versionId(edition));

/** What Add to (the bar's +) adds: one copy of the version on screen, or every copy in view (just the selected version's
 *  when one is selected), each version with its count. */
export function addLines(inView: CardVersion[], current: CardVersion, all: boolean): CardVersion[] {
  const held = inView.filter((v) => v.qty > 0);
  return all && held.length ? held : [{ ...current, qty: 1 }];
}

/** Whether the Finish cell shows: some printing in view comes in more than one finish, or the versions differ. */
export function showsFinish(versions: CardVersion[], printings: Map<string, PrintingFacts>): boolean {
  if (shared(versions, (v) => v.finish) == null) return true;
  return versions.some((v) => { const p = printings.get(v.cardId); return p ? finishesOf(p).length > 1 : false; });
}
