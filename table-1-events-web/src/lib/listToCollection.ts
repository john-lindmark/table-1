import type { CollectionOp, Condition } from "./collection";
import { langForNew } from "./languages";
import { LIST_CONDITIONS, condOf, finishOf, langOf, ownKey, type Entry, type ListFinish, type ListKind } from "./lists";

/* Adding a deck or cube to the collection (contract/list-to-collection-2026-10-22.md): each line goes in as the exact
   printing, finish, language and condition the list records, either what the collection lacks of it or every copy. Cases in
   testdata/list-to-collection/cases.json, shared with iOS and Android. */

export type AddMode = "missing" | "all";
/** `lang` absent = en, `cond` absent = NM. */
export interface AddOp { card_id: string; finish: ListFinish; delta: number; lang?: string; cond?: Condition }

/** Main and Commander always count, a deck's sideboard unless `sideboard` is false, Considering never. Each line goes in
    as the exact printing, finish, language and condition it records, so Missing counts only owned copies of that
    printing, finish and language (`owned` is keyed "card_id|finish" for English NM copies, "card_id|finish|lang" or
    "card_id|finish|lang|cond"); another printing, finish or language of the card never covers a line here (John,
    2026-11-01), unlike the deck's own Missing (contract/owned-by-card-2026-10-31.md). Owned copies of any condition
    count: they cover lines in their own condition first, then the rest from NM down. `only` limits it to some
    printings (card detail). Basic lands (`basics`) are never missing, so only "all" adds them
    (contract/basics-2026-10-24.md). */
export function listAddOps(entries: Entry[], kind: ListKind, owned: Map<string, number>, mode: AddMode,
                           sideboard = true, only?: Set<string>, basics?: Set<string>): AddOp[] {
  const need = new Map<string, Map<Condition, number>>(); // "card|finish|lang" → cond → copies
  for (const e of entries) {
    if (!(e.board === "main" || e.board === "commander" || (e.board === "side" && kind === "deck" && sideboard))) continue;
    if (only && !only.has(e.cardId)) continue;
    if (mode === "missing" && basics?.has(e.cardId)) continue;
    const k = `${ownKey(e.cardId, finishOf(e))}|${langOf(e)}`;
    const m = need.get(k) ?? new Map<Condition, number>();
    m.set(condOf(e), (m.get(condOf(e)) ?? 0) + e.qty);
    need.set(k, m);
  }
  if (mode === "missing") {
    const have = new Map<string, Map<string, number>>();
    for (const [k, n] of owned) {
      const [card, finish, lang = "en", cond = "NM"] = k.split("|");
      const m = have.get(`${card}|${finish}|${lang}`) ?? new Map<string, number>();
      m.set(cond, (m.get(cond) ?? 0) + n);
      have.set(`${card}|${finish}|${lang}`, m);
    }
    for (const [k, conds] of need) {
      const mine = have.get(k) ?? new Map<string, number>();
      let spare = [...mine.values()].reduce((a, b) => a + b, 0);
      for (const [c, n] of conds) { const x = Math.min(n, mine.get(c) ?? 0); conds.set(c, n - x); spare -= x; }
      for (const c of LIST_CONDITIONS) {
        if (spare <= 0) break;
        const x = Math.min(conds.get(c) ?? 0, spare);
        if (x > 0) { conds.set(c, conds.get(c)! - x); spare -= x; }
      }
    }
  }
  const out: AddOp[] = [];
  for (const [k, conds] of need) {
    const [card_id, finish, l] = k.split("|") as [string, ListFinish, string];
    for (const [c, n] of conds) if (n > 0) out.push({ card_id, finish, delta: n, ...(l !== "en" ? { lang: l } : {}), ...(c !== "NM" ? { cond: c } : {}) });
  }
  const cmp = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);
  const rank = (o: AddOp) => LIST_CONDITIONS.indexOf(o.cond ?? "NM");
  return out.sort((a, b) => cmp(a.card_id, b.card_id) || cmp(a.finish, b.finish) || cmp(a.lang ?? "en", b.lang ?? "en") || rank(a) - rank(b));
}

export const copiesOf = (ops: AddOp[]) => ops.reduce((n, o) => n + o.delta, 0);

/** Card detail's Add to collection row for one card in a list: a basic land is never missing, so it doesn't claim you
    own every copy either (contract/basics-2026-10-24.md). */
export const cardAddDetail = (missing: number, basic: boolean) =>
  missing > 0 ? `Missing ${missing} · the printing listed here` : basic ? "Basic land · add the copies listed here" : "You own every copy listed here";

/** Collection ops, each copy in the language and condition its line records (a non-English printing is always its own);
 *  the language and condition picked for other adds never apply here. */
export function toCollectionOps(ops: AddOp[], printingLang: (cardId: string) => string | undefined): CollectionOp[] {
  return ops.map((o) => ({ card_id: o.card_id, finish: o.finish, condition: o.cond ?? "NM", lang: langForNew(printingLang(o.card_id) ?? "en", o.lang ?? "en"), delta: o.delta }));
}
