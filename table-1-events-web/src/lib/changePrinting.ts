import { itemKey, type CollectionOp, type Finish, type Item } from "./collection";
import { placement } from "./binders";
import { lineKey, type TradeLine } from "./trades";

/* Change printing (contract/change-printing-2026-10-18.md): owned copies moving to another printing or finish in the
   same place, and a trade get pointed at another printing. Same rules as iOS PrintingChange / TradeLine.repoint and
   Android ChangePrinting; deck and cube lines use list_edit's swap op. */

/** Unsorted as a place (a binder route id, as in Binders). */
export const UNSORTED_PLACE = "unsorted";

/**
 * Owned copies changing printing: take `qty` out of `place` (a binder id, or Unsorted / null for none) and put as many
 * of the other printing back in the same place, keeping condition, and language unless the new printing is itself
 * non-English. One batch, so Undo puts them back. Null when there's nothing to change.
 */
export function printingChangeOps(item: Item, place: string | null | undefined, toCardId: string, toFinish: Finish,
                                  toLang: string | null | undefined, qty: number): CollectionOp[] | null {
  const lang = toLang && toLang !== "en" ? toLang : item.lang;
  const to = itemKey(toCardId, toFinish, item.condition, lang);
  if (qty < 1 || qty > item.qty || to === item.k) return null;
  const binderId = place == null || place === UNSORTED_PLACE ? undefined : place;
  const withBinder = binderId ? { binder_id: binderId } : {};
  return [
    { card_id: item.cardId, finish: item.finish, condition: item.condition, lang: item.lang, delta: -qty, ...withBinder },
    { card_id: toCardId, finish: toFinish, condition: item.condition, lang, delta: qty, ...withBinder },
  ];
}

/** Every place an item's copies sit: the binders by name, then Unsorted. */
export function printingPlaces(item: Item): { place: string; name: string; qty: number }[] {
  const p = placement(item);
  return [...p.binders.map((h) => ({ place: h.binder.id, name: h.binder.name, qty: h.qty })),
          ...(p.unsorted > 0 ? [{ place: UNSORTED_PLACE, name: "Unsorted", qty: p.unsorted }] : [])];
}

/** The place to change from: the chosen one, else the one opened from, else the one holding the most. */
export function pickPlace(places: { place: string; qty: number }[], chosen: string | null, from: string | null | undefined): string | null {
  if (chosen && places.some((p) => p.place === chosen)) return chosen;
  if (from && places.some((p) => p.place === from)) return from;
  return places.reduce<{ place: string; qty: number } | null>((m, p) => (!m || p.qty > m.qty ? p : m), null)?.place ?? null;
}

/** Points the line keyed `k` at another printing and/or finish, merging it into a line that already holds that copy. */
export function repointTradeLine(lines: TradeLine[], k: string, cardId: string, finish: Finish): TradeLine[] {
  const i = lines.findIndex((l) => lineKey(l) === k);
  if (i < 0) return lines;
  const moved = { ...lines[i], card_id: cardId, finish };
  const to = lineKey(moved);
  if (to === k) return lines;
  const j = lines.findIndex((l) => lineKey(l) === to);
  if (j >= 0) return lines.flatMap((l, n) => (n === i ? [] : n === j ? [{ ...l, qty: l.qty + moved.qty }] : [l]));
  return lines.map((l, n) => (n === i ? moved : l));
}
