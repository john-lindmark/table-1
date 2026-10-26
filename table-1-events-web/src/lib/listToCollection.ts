import type { CollectionOp, Condition } from "./collection";
import { langForNew } from "./languages";
import { finishOf, langOf, ownKey, type Entry, type ListFinish, type ListKind } from "./lists";

/* Adding a deck or cube to the collection (contract/list-to-collection-2026-10-22.md): each line goes in as the
   printing and finish the list names, either what the collection lacks or every copy. Cases in
   testdata/list-to-collection/cases.json, shared with iOS and Android. */

export type AddMode = "missing" | "all";
/** `lang` absent = en. */
export interface AddOp { card_id: string; finish: ListFinish; delta: number; lang?: string }

/** English first, then by language code. */
const langOrder = (a: string, b: string) => (a === b ? 0 : a === "en" ? -1 : b === "en" ? 1 : a < b ? -1 : 1);

/** Main and Commander always count, a deck's sideboard unless `sideboard` is false, Considering never. Each line keeps
    its language. `owned` is keyed "card_id|finish" (English copies) or "card_id|finish|lang"; Missing goes by printing +
    finish over every condition and language: owned copies cover lines in their own language first, then the rest,
    English lines first, then by language code. `only` limits it to some printings (card detail). Basic lands
    (`basics`) are never missing, so only "all" adds them (contract/basics-2026-10-24.md). */
export function listAddOps(entries: Entry[], kind: ListKind, owned: Map<string, number>, mode: AddMode,
                           sideboard = true, only?: Set<string>, basics?: Set<string>): AddOp[] {
  const need = new Map<string, Map<string, number>>(); // "card|finish" → lang → copies
  for (const e of entries) {
    if (!(e.board === "main" || e.board === "commander" || (e.board === "side" && kind === "deck" && sideboard))) continue;
    if (only && !only.has(e.cardId)) continue;
    if (mode === "missing" && basics?.has(e.cardId)) continue;
    const k = ownKey(e.cardId, finishOf(e));
    const m = need.get(k) ?? new Map<string, number>();
    m.set(langOf(e), (m.get(langOf(e)) ?? 0) + e.qty);
    need.set(k, m);
  }
  const have = new Map<string, Map<string, number>>();
  if (mode === "missing") {
    for (const [k, n] of owned) {
      const [card, finish, lang = "en"] = k.split("|");
      const m = have.get(`${card}|${finish}`) ?? new Map<string, number>();
      m.set(lang, (m.get(lang) ?? 0) + n);
      have.set(`${card}|${finish}`, m);
    }
  }
  const out: AddOp[] = [];
  for (const [k, langs] of need) {
    const [card_id, finish] = k.split("|") as [string, ListFinish];
    const left = new Map(langs);
    if (mode === "missing") {
      const mine = have.get(k) ?? new Map<string, number>();
      let spare = [...mine.values()].reduce((a, b) => a + b, 0);
      for (const [l, n] of left) { const c = Math.min(n, mine.get(l) ?? 0); left.set(l, n - c); spare -= c; }
      for (const l of [...left.keys()].sort(langOrder)) {
        if (spare <= 0) break;
        const c = Math.min(left.get(l)!, spare);
        left.set(l, left.get(l)! - c);
        spare -= c;
      }
    }
    for (const [l, n] of left) if (n > 0) out.push({ card_id, finish, delta: n, ...(l !== "en" ? { lang: l } : {}) });
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
