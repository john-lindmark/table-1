import type { CollectionOp, Condition } from "./collection";
import { langForNew } from "./languages";
import { finishOf, ownKey, type Entry, type ListFinish, type ListKind } from "./lists";

/* Adding a deck or cube to the collection (contract/list-to-collection-2026-10-22.md): each line goes in as the
   printing and finish the list names, either what the collection lacks or every copy. Cases in
   testdata/list-to-collection/cases.json, shared with iOS and Android. */

export type AddMode = "missing" | "all";
export interface AddOp { card_id: string; finish: ListFinish; delta: number }

/** Main and Commander always count, a deck's sideboard unless `sideboard` is false, Considering never. `owned` is
    keyed "card_id|finish" over every condition and language; `only` limits it to some printings (card detail). */
export function listAddOps(entries: Entry[], kind: ListKind, owned: Map<string, number>, mode: AddMode,
                           sideboard = true, only?: Set<string>): AddOp[] {
  const need = new Map<string, number>();
  for (const e of entries) {
    if (!(e.board === "main" || e.board === "commander" || (e.board === "side" && kind === "deck" && sideboard))) continue;
    if (only && !only.has(e.cardId)) continue;
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

/** Collection ops in the picked condition; an English printing goes in as the picked language, any other in its own. */
export function toCollectionOps(ops: AddOp[], printingLang: (cardId: string) => string | undefined, condition: Condition, lang: string): CollectionOp[] {
  return ops.map((o) => ({ card_id: o.card_id, finish: o.finish, condition, lang: langForNew(printingLang(o.card_id) ?? "en", lang), delta: o.delta }));
}
