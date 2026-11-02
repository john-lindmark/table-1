import type { Catalog } from "./catalog";

/* Owning a card in any printing (contract/owned-by-card-2026-10-31.md): a deck or cube line is covered by copies of the
   same card in any printing, finish or language, the printing and finish it names first. Also card detail's Match
   collection. Cases in testdata/owned-by-card/cases.json (ownedByCard.test.ts), shared with iOS and Android. */

/** A printing's card key; a printing the catalog doesn't know is its own card (as before the catalog loads). */
export type CardOf = (cardId: string) => string;

export const cardOfCatalog = (c: Catalog | null | undefined): CardOf => (id) => {
  const p = c?.printingIndex.get(id);
  return p == null ? id : `o${c!.pOracle[p]}`;
};
export const cardOfMap = (m: Record<string, string>): CardOf => (id) => m[id] ?? id;

/** What the collection holds, per printing + finish and per card. */
export interface Holdings { byPrinting: Map<string, number>; byCard: Map<string, number>; cardOf: CardOf }

/** `owned` keyed "card_id|finish", "card_id|finish|lang" or "card_id|finish|lang|cond". */
export function holdings(owned: Map<string, number>, cardOf: CardOf): Holdings {
  const byPrinting = new Map<string, number>(), byCard = new Map<string, number>();
  for (const [k, n] of owned) {
    const [id, finish = "nonfoil"] = k.split("|");
    byPrinting.set(`${id}|${finish}`, (byPrinting.get(`${id}|${finish}`) ?? 0) + n);
    byCard.set(cardOf(id), (byCard.get(cardOf(id)) ?? 0) + n);
  }
  return { byPrinting, byCard, cardOf };
}

export const ownedOfCard = (h: Holdings, cardId: string) => h.byCard.get(h.cardOf(cardId)) ?? 0;
export const ownedOfPrinting = (h: Holdings, cardId: string, finish: string) => h.byPrinting.get(`${cardId}|${finish}`) ?? 0;

/** One deck or cube line, in list order. */
export interface Need { cardId: string; board: string; finish: string; qty: number; lang?: string; cond?: string }

/** Copies each line still needs. The printing and finish a line names cover it first, then the card's other copies
 *  cover what's left, lines in order; a copy covers one line. Considering and basics never need any or use copies. */
export function shorts(lines: Need[], h: Holdings, basics: Set<string>): number[] {
  const counted = lines.map((l) => l.board !== "maybe" && !basics.has(l.cardId));
  const exact = new Map(h.byPrinting), spare = new Map(h.byCard);
  const covered = lines.map(() => 0);
  lines.forEach((l, i) => {
    if (!counted[i]) return;
    const k = `${l.cardId}|${l.finish}`, o = h.cardOf(l.cardId);
    const c = Math.min(l.qty, exact.get(k) ?? 0);
    exact.set(k, (exact.get(k) ?? 0) - c);
    spare.set(o, (spare.get(o) ?? 0) - c);
    covered[i] = c;
  });
  lines.forEach((l, i) => {
    if (!counted[i]) return;
    const o = h.cardOf(l.cardId);
    const c = Math.min(l.qty - covered[i], spare.get(o) ?? 0);
    spare.set(o, (spare.get(o) ?? 0) - c);
    covered[i] += c;
  });
  return lines.map((l, i) => (counted[i] ? l.qty - covered[i] : 0));
}

export interface MissingLine { cardId: string; finish: string; card: string; short: number; lists: string[] }

/** Wants → Missing: one line per card, the largest shortfall across lists (lists don't reserve copies), shown as the
 *  first short line of the list that needs most (the earliest list on a tie). Roto event decks never count. */
export function missingByCard(lists: { name: string; event?: boolean; lines: Need[] }[], h: Holdings, basics: Set<string>): MissingLine[] {
  const need = new Map<string, { short: number; lists: string[]; line: Need | null }>();
  for (const l of lists) {
    if (l.event) continue;
    const per = new Map<string, number>(), first = new Map<string, Need>();
    const s = shorts(l.lines, h, basics);
    l.lines.forEach((e, i) => {
      if (e.board === "maybe" || basics.has(e.cardId)) return;
      const o = h.cardOf(e.cardId);
      per.set(o, (per.get(o) ?? 0) + e.qty);
      if (s[i] > 0 && !first.has(o)) first.set(o, e);
    });
    for (const [o, n] of per) {
      const short = n - (h.byCard.get(o) ?? 0);
      if (short <= 0) continue;
      const v = need.get(o) ?? { short: 0, lists: [], line: null };
      if (short > v.short) { v.short = short; v.line = first.get(o)!; }
      v.lists.push(l.name);
      need.set(o, v);
    }
  }
  return [...need].map(([card, v]) => ({ cardId: v.line!.cardId, finish: v.line!.finish, card, short: v.short, lists: v.lists.sort() }))
    .sort((a, b) => b.short - a.short || (`${a.cardId}|${a.finish}` < `${b.cardId}|${b.finish}` ? -1 : 1));
}

/* ── Match collection (card detail) ─────────────────────────────────── */

/** A version you own: printing × finish, every condition and language together. */
export interface Version { cardId: string; finish: string; owned: number }
export interface Pick { cardId: string; finish: string; qty: number }
/** A list_edit move op: `qty` copies of a line to another printing and/or finish, keeping its language and condition. */
export interface Move { cardId: string; finish: string; lang?: string; cond?: string; toCardId: string; toFinish: string; qty: number }

const cmp = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

/** Versions the section already lists first, then the ones you hold most of, then by card id and finish. */
export function autoMatch(lines: Need[], versions: Version[]): Pick[] {
  let left = lines.reduce((n, l) => n + l.qty, 0);
  const listed = new Set(lines.map((l) => `${l.cardId}|${l.finish}`));
  const order = [...versions].sort((a, b) => {
    const la = listed.has(`${a.cardId}|${a.finish}`), lb = listed.has(`${b.cardId}|${b.finish}`);
    return la !== lb ? (la ? -1 : 1) : b.owned - a.owned || cmp(a.cardId, b.cardId) || cmp(a.finish, b.finish);
  });
  const picks: Pick[] = [];
  for (const v of order) {
    const n = Math.min(v.owned, left);
    if (n > 0) { picks.push({ cardId: v.cardId, finish: v.finish, qty: n }); left -= n; }
  }
  return picks;
}

/** A tap on a version's tile: one more of it while you own more and copies are left to pick; otherwise back to none. */
export function tapPick(picks: Pick[], versions: Version[], total: number, cardId: string, finish: string): Pick[] {
  const have = versions.find((v) => v.cardId === cardId && v.finish === finish)?.owned ?? 0;
  const used = picks.reduce((n, p) => n + p.qty, 0);
  const i = picks.findIndex((p) => p.cardId === cardId && p.finish === finish);
  if (i < 0) return used < total && have > 0 ? [...picks, { cardId, finish, qty: 1 }] : picks;
  if (picks[i].qty < have && used < total) return picks.map((p, j) => (j === i ? { ...p, qty: p.qty + 1 } : p));
  return picks.filter((_, j) => j !== i);
}

/** Move ops that give the section the picked printings; copies not picked stay as they are. Lines that already are a
 *  picked version keep those copies; the rest move in list order to the picks in pick order. */
export function matchOps(lines: Need[], picks: Pick[]): Move[] {
  const want = new Map<string, number>();
  for (const p of picks) want.set(`${p.cardId}|${p.finish}`, (want.get(`${p.cardId}|${p.finish}`) ?? 0) + p.qty);
  const keep = lines.map((l) => {
    const k = `${l.cardId}|${l.finish}`;
    const c = Math.min(l.qty, want.get(k) ?? 0);
    want.set(k, (want.get(k) ?? 0) - c);
    return c;
  });
  const targets = picks.map((p) => ({ p, left: want.get(`${p.cardId}|${p.finish}`) ?? 0 }));
  const ops: Move[] = [];
  lines.forEach((l, i) => {
    let movable = l.qty - keep[i];
    for (const t of targets) {
      if (movable <= 0) break;
      const n = Math.min(movable, t.left);
      if (n <= 0) continue;
      ops.push({ cardId: l.cardId, finish: l.finish, ...(l.lang && l.lang !== "en" ? { lang: l.lang } : {}),
                   ...(l.cond && l.cond !== "NM" ? { cond: l.cond } : {}), toCardId: t.p.cardId, toFinish: t.p.finish, qty: n });
      t.left -= n;
      movable -= n;
    }
  });
  return ops;
}

/** The versions you own of these printings (printing × finish, every condition and language), in `printings` order. */
export function ownedVersions(printingIds: string[], items: Iterable<{ cardId: string; finish: string; qty: number }>): Version[] {
  const n = new Map<string, number>();
  const ids = new Set(printingIds);
  for (const it of items) if (ids.has(it.cardId)) n.set(`${it.cardId}|${it.finish}`, (n.get(`${it.cardId}|${it.finish}`) ?? 0) + it.qty);
  return printingIds.flatMap((id) => ["nonfoil", "foil", "etched"].flatMap((f) => {
    const q = n.get(`${id}|${f}`) ?? 0;
    return q > 0 ? [{ cardId: id, finish: f, owned: q }] : [];
  }));
}

/** Sections holding the card (not Considering) whose printings Auto would change; `lines` are the list's lines of it. */
export function matchSections(lines: Need[], versions: Version[]): string[] {
  if (!versions.length) return [];
  return ["commander", "main", "side"].filter((b) => {
    const ls = lines.filter((l) => l.board === b);
    return ls.length > 0 && matchOps(ls, autoMatch(ls, versions)).length > 0;
  });
}

/** "You own 3 in other printings": copies of the card in versions the list doesn't name. */
export function matchDetail(lines: Need[], versions: Version[]): string {
  const listed = new Set(lines.map((l) => `${l.cardId}|${l.finish}`));
  const other = versions.filter((v) => !listed.has(`${v.cardId}|${v.finish}`)).reduce((n, v) => n + v.owned, 0);
  return other > 0 ? `You own ${other} in other printings` : "Use the printings you own";
}
