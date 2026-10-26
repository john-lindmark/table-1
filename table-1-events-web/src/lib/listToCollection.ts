import type { CollectionOp, Condition } from "./collection";
import { finishOf, ownKey, type Entry, type ListFinish, type ListKind } from "./lists";

/* Adding a deck or cube to the collection (contract/list-to-collection-2026-10-22.md): each line goes in as the
   printing and finish the list names, either what the collection lacks or every copy. Cases in
   testdata/list-to-collection/cases.json, shared with iOS and Android. */

export type AddMode = "missing" | "all";
export interface AddOp { card_id: string; finish: ListFinish; delta: number }

/** Main and Commander always count, a deck's sideboard unless `sideboard` is false, Considering never. `owned` is
    keyed "card_id|finish" over every condition and language; `only` limits it to some printings (card detail). Basic
    lands (`basics`) are never missing, so only "all" adds them (contract/basics-2026-10-24.md). */
export function listAddOps(entries: Entry[], kind: ListKind, owned: Map<string, number>, mode: AddMode,
                           sideboard = true, only?: Set<string>, basics?: Set<string>): AddOp[] {
  const need = new Map<string, number>();
  for (const e of entries) {
    if (!(e.board === "main" || e.board === "commander" || (e.board === "side" && kind === "deck" && sideboard))) continue;
    if (only && !only.has(e.cardId)) continue;
    if (mode === "missing" && basics?.has(e.cardId)) continue;
    const k = ownKey(e.cardId, finishOf(e));
    need.set(k, (need.get(k) ?? 0) + e.qty);
  }
  const out: AddOp[] = [];
  for (const [k, n] of need) {
    const delta = mode === "all" ? n : n - (owned.get(k) ?? 0);
    if (delta <= 0) continue;
    const [card_id, finish] = k.split("|") as [string, ListFinish];
    out.push({ card_id, finish, delta });
  }
  return out.sort((a, b) => (a.card_id !== b.card_id ? (a.card_id < b.card_id ? -1 : 1) : a.finish < b.finish ? -1 : a.finish > b.finish ? 1 : 0));
}

export const copiesOf = (ops: AddOp[]) => ops.reduce((n, o) => n + o.delta, 0);

/** Card detail's Add to collection row for one card in a list: a basic land is never missing, so it doesn't claim you
    own every copy either (contract/basics-2026-10-24.md). */
export const cardAddDetail = (missing: number, basic: boolean) =>
  missing > 0 ? `Missing ${missing} · the printing listed here` : basic ? "Basic land · add the copies listed here" : "You own every copy listed here";

/** Collection ops in the picked condition, each copy in the language of the printing the list names (a list line's
 *  language is its printing's; the language picked for other adds never applies here). */
export function toCollectionOps(ops: AddOp[], printingLang: (cardId: string) => string | undefined, condition: Condition): CollectionOp[] {
  return ops.map((o) => ({ card_id: o.card_id, finish: o.finish, condition, lang: printingLang(o.card_id) ?? "en", delta: o.delta }));
}
