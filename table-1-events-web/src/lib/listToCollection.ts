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
    its language. `owned` is keyed "card_id|finish" (English copies) or "card_id|finish|lang"; Missing goes by card
    (contract/owned-by-card-2026-10-31.md): copies of the printing + finish a line names over every condition and
    language cover it first, their own language first, then the rest, English lines first, then by language code; then
    the card's other copies (`cardOf` maps a printing to its card) cover what's left, lines by card_id, finish, then
    language. `only` limits it to some printings (card detail). Basic lands (`basics`) are never missing, so only "all"
    adds them (contract/basics-2026-10-24.md). */
export function listAddOps(entries: Entry[], kind: ListKind, owned: Map<string, number>, mode: AddMode,
                           sideboard = true, only?: Set<string>, basics?: Set<string>, cardOf: (cardId: string) => string = (id) => id): AddOp[] {
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
  const left = new Map([...need].map(([k, m]) => [k, new Map(m)]));
  if (mode === "missing") {
    const have = new Map<string, Map<string, number>>();
    for (const [k, n] of owned) {
      const [card, finish, lang = "en"] = k.split("|");
      const m = have.get(`${card}|${finish}`) ?? new Map<string, number>();
      m.set(lang, (m.get(lang) ?? 0) + n);
      have.set(`${card}|${finish}`, m);
    }
    const sum = (m?: Map<string, number>) => [...(m?.values() ?? [])].reduce((a, b) => a + b, 0);
    for (const [k, langs] of left) {
      const mine = have.get(k) ?? new Map<string, number>();
      let spare = sum(mine);
      for (const [l, n] of langs) { const c = Math.min(n, mine.get(l) ?? 0); langs.set(l, n - c); spare -= c; }
      for (const l of [...langs.keys()].sort(langOrder)) {
        if (spare <= 0) break;
        const c = Math.min(langs.get(l)!, spare);
        langs.set(l, langs.get(l)! - c);
        spare -= c;
      }
    }
    // What the card's copies hold beyond the lines that name their printing and finish.
    const cardOfKey = (k: string) => cardOf(k.split("|")[0]);
    const pool = new Map<string, number>();
    for (const [k, mine] of have) {
      const total = sum(mine);
      pool.set(cardOfKey(k), (pool.get(cardOfKey(k)) ?? 0) + total - Math.min(total, sum(need.get(k))));
    }
    for (const k of [...left.keys()].sort()) {
      const o = cardOfKey(k), langs = left.get(k)!;
      for (const l of [...langs.keys()].sort(langOrder)) {
        if ((pool.get(o) ?? 0) <= 0) break;
        const c = Math.min(langs.get(l)!, pool.get(o)!);
        langs.set(l, langs.get(l)! - c);
        pool.set(o, pool.get(o)! - c);
      }
    }
  }
  const out: AddOp[] = [];
  for (const [k, langs] of left) {
    const [card_id, finish] = k.split("|") as [string, ListFinish];
    for (const [l, n] of langs) if (n > 0) out.push({ card_id, finish, delta: n, ...(l !== "en" ? { lang: l } : {}) });
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
