import type { CartAnswer, CartItem } from "./wantPrices";
import type { Holdings } from "./ownedByCard";

/* The Buy screen's rules (contract/buy-2026-11-06.md): which copies of a deck, cube, Wants or Missing go into a
   TCGplayer cart, what they cost, and the tcgplayer_cart calls that build it. Cases in testdata/buy/cases.json
   (buyList.test.ts), shared with iOS and Android. */

/** One line offered for buying. `unit` is one copy's price in cents; `any` marks a want for any printing (sent by
 *  `oracleId`, priced and drawn by `cardId`). */
export interface BuyLine {
  cardId: string; oracleId?: string | null; any?: boolean; board: string; finish: string; qty: number; unit?: number | null; basic?: boolean;
}
export interface BuyOptions { skipOwned: boolean; anyPrinting: boolean; exact: boolean; boards: Set<string> }
export interface BuyRow { line: BuyLine; owned: number; buy: number }
export interface BuyTotals { cards: number; owned: number; buy: number; price: number; ownedValue: number; total: number; unpriced: number }
export interface BuyCall { products: boolean; items: CartItem[] }

export const BOARD_ORDER = ["commander", "main", "side", "maybe", "tokens"];

/** One row per line in a picked board with copies, in line order. Skip owned leaves basic lands out, then a line's own
 *  printing and finish cover it first and, with Any printing, the card's other copies, lines in order, each copy once.
 *  Without Skip owned nothing is owned. */
export function buyRows(lines: BuyLine[], h: Holdings, o: BuyOptions): BuyRow[] {
  const inc = lines.filter((l) => o.boards.has(l.board) && l.qty > 0 && !(o.skipOwned && l.basic));
  if (!o.skipOwned) return inc.map((l) => ({ line: l, owned: 0, buy: l.qty }));
  const exact = new Map(h.byPrinting), spare = new Map(h.byCard);
  const cov = inc.map(() => 0);
  inc.forEach((l, i) => {
    const k = `${l.cardId}|${l.finish}`, card = h.cardOf(l.cardId);
    const c = Math.min(l.qty, exact.get(k) ?? 0);
    exact.set(k, (exact.get(k) ?? 0) - c);
    spare.set(card, (spare.get(card) ?? 0) - c);
    cov[i] = c;
  });
  if (o.anyPrinting) {
    inc.forEach((l, i) => {
      const card = h.cardOf(l.cardId);
      const c = Math.min(l.qty - cov[i], Math.max(0, spare.get(card) ?? 0));
      spare.set(card, (spare.get(card) ?? 0) - c);
      cov[i] += c;
    });
  }
  return inc.map((l, i) => ({ line: l, owned: cov[i], buy: l.qty - cov[i] }));
}

/** Money in cents: price over every row's copies, the owned copies at their line's price, the total bought. */
export function buyTotals(rows: BuyRow[]): BuyTotals {
  const t: BuyTotals = { cards: 0, owned: 0, buy: 0, price: 0, ownedValue: 0, total: 0, unpriced: 0 };
  for (const r of rows) {
    t.cards += r.line.qty;
    t.owned += r.owned;
    t.buy += r.buy;
    const u = r.line.unit;
    if (u == null) t.unpriced += r.buy;
    else { t.price += r.line.qty * u; t.ownedValue += r.owned * u; t.total += r.buy * u; }
  }
  return t;
}

/** The tcgplayer_cart calls: tokens always to their product pages, everything else by Exact printings; copies summed
 *  per key in row order; one call when both agree, none when nothing's bought. */
export function buyCalls(rows: BuyRow[], exact: boolean): BuyCall[] {
  const groups = new Map<boolean, Map<string, CartItem>>();
  for (const r of rows) {
    if (r.buy <= 0) continue;
    const products = r.line.board === "tokens" ? true : exact;
    const any = !!r.line.any && !!r.line.oracleId;
    const key = any ? `o:${r.line.oracleId}` : `c:${r.line.cardId}`;
    const g = groups.get(products) ?? new Map<string, CartItem>();
    const had = g.get(key);
    if (had) had.qty += r.buy;
    else g.set(key, any ? { oracle_id: r.line.oracleId!, qty: r.buy } : { card_id: r.line.cardId, qty: r.buy });
    groups.set(products, g);
  }
  return [exact, !exact].flatMap((p) => (groups.has(p) ? [{ products: p, items: [...groups.get(p)!.values()] }] : []));
}

/** Two calls' answers as one: Mass Entry parts in order, then every product page by name, set and number. */
export function mergeAnswers(answers: CartAnswer[]): CartAnswer {
  const out: CartAnswer = { enabled: answers.every((a) => a.enabled), lines: 0, unknown: 0, urls: [], products: [] };
  for (const a of answers) {
    out.lines += a.lines;
    out.unknown += a.unknown;
    out.urls.push(...a.urls);
    out.products!.push(...(a.products ?? []));
  }
  const cmp = (x: string, y: string) => (x < y ? -1 : x > y ? 1 : 0);
  out.products!.sort((a, b) => cmp(a.name, b.name) || cmp(a.set, b.set) || cmp(a.number, b.number));
  return out;
}

export const cents = (usd: number | null | undefined): number | null => (usd == null ? null : Math.round(usd * 100));

/** "$1,441.95". */
export const buyMoney = (c: number) => (c / 100).toLocaleString("en-US", { style: "currency", currency: "USD" });

/* Options remembered per device and family (deck, cube, wants, missing). */
const KEY = (family: string, o: string) => `buy.${family}.${o}`;
export function storedBuy(family: string, o: string): boolean | null {
  try {
    const v = localStorage.getItem(KEY(family, o));
    return v == null ? null : v === "1";
  } catch { return null; }
}
export function storeBuy(family: string, o: string, v: string) {
  try { localStorage.setItem(KEY(family, o), v); } catch { /* private window */ }
}

/** The options remembered for a family (deck, cube, wants, missing). */
export function storedBuyOptions(family: string): BuyOptions {
  let boards: Set<string> = new Set(["commander", "main", "side"]);
  try {
    const b = localStorage.getItem(KEY(family, "boards"));
    if (b != null) boards = new Set(b ? b.split(",") : []);
  } catch { /* private window */ }
  return {
    skipOwned: storedBuy(family, "skip") ?? true,
    anyPrinting: storedBuy(family, "any") ?? true,
    exact: storedBuy(family, "exact") ?? family === "wants",
    boards,
  };
}

