import type { CollectionOp, Condition } from "./collection";
import { langForNew } from "./languages";
import { finishOf, langOf, ownKey, type Entry, type ListFinish, type ListKind } from "./lists";

/* Adding a deck or cube to the collection (contract/list-to-collection-2026-10-22.md): each line goes in as the exact
   printing, finish and language the list names, either what the collection lacks of it or every copy. Cases in
   testdata/list-to-collection/cases.json, shared with iOS and Android. */

export type AddMode = "missing" | "all";
/** `lang` absent = en. */
export interface AddOp { card_id: string; finish: ListFinish; delta: number; lang?: string }

/** Main and Commander always count, a deck's sideboard unless `sideboard` is false, Considering never. Each line goes in
    as the exact printing, finish and language it names, so Missing counts only owned copies of that printing, finish
    and language, over every condition (`owned` is keyed "card_id|finish" for English copies or "card_id|finish|lang");
    another printing, finish or language of the card never covers a line here (John, 2026-11-01), unlike the deck's own
    Missing (contract/owned-by-card-2026-10-31.md). `only` limits it to some printings (card detail). Basic lands
    (`basics`) are never missing, so only "all" adds them (contract/basics-2026-10-24.md). */
export function listAddOps(entries: Entry[], kind: ListKind, owned: Map<string, number>, mode: AddMode,
                           sideboard = true, only?: Set<string>, basics?: Set<string>): AddOp[] {
  const need = new Map<string, number>(); // "card|finish|lang" → copies
  for (const e of entries) {
    if (!(e.board === "main" || e.board === "commander" || (e.board === "side" && kind === "deck" && sideboard))) continue;
    if (only && !only.has(e.cardId)) continue;
    if (mode === "missing" && basics?.has(e.cardId)) continue;
    const k = `${ownKey(e.cardId, finishOf(e))}|${langOf(e)}`;
    need.set(k, (need.get(k) ?? 0) + e.qty);
  }
  if (mode === "missing") {
    for (const [k, n] of owned) {
      const [card, finish, lang = "en"] = k.split("|");
      const key = `${card}|${finish}|${lang}`;
      if (need.has(key)) need.set(key, need.get(key)! - n);
    }
  }
  const out: AddOp[] = [];
  for (const [k, n] of need) {
    if (n <= 0) continue;
    const [card_id, finish, l] = k.split("|") as [string, ListFinish, string];
    out.push({ card_id, finish, delta: n, ...(l !== "en" ? { lang: l } : {}) });
  }
  const cmp = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);
  return out.sort((a, b) => cmp(a.card_id, b.card_id) || cmp(a.finish, b.finish) || cmp(a.lang ?? "en", b.lang ?? "en"));
}

export const copiesOf = (ops: AddOp[]) => ops.reduce((n, o) => n + o.delta, 0);

/** Card detail's Add to collection row for one card in a list: a basic land is never missing, so it doesn't claim you
    own every copy either (contract/basics-2026-10-24.md). */
export const cardAddDetail = (missing: number, basic: boolean) =>
  missing > 0 ? `Missing ${missing} · the printing listed here` : basic ? "Basic land · add the copies listed here" : "You own every copy listed here";

/** Collection ops in the picked condition, each copy in the language its line names (a non-English printing is always
 *  its own); the language picked for other adds never applies here. */
export function toCollectionOps(ops: AddOp[], printingLang: (cardId: string) => string | undefined, condition: Condition): CollectionOp[] {
  return ops.map((o) => ({ card_id: o.card_id, finish: o.finish, condition, lang: langForNew(printingLang(o.card_id) ?? "en", o.lang ?? "en"), delta: o.delta }));
}
