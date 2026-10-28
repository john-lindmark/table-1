// Current market prices for printings (card_prices_get), fetched on demand and kept for the page's life.
// USD is TCGplayer's market price as Scryfall publishes it; EUR is Cardmarket's. Prices are near mint; usdPrice
// prices a copy in its condition (conditionPrice).
import { useEffect, useSyncExternalStore } from "react";
import { supabase } from "./supabaseClient";
import { demoBackend, type Finish } from "./collection";
import { conditionPercent, conditionPrice } from "./conditionPrice";

/** [usd, usd_foil, usd_etched, eur, eur_foil, converted] */
const rows = new Map<string, (number | null)[]>();
const asked = new Set<string>();
let version = 0;
const subs = new Set<() => void>();
const bump = () => {
  version++;
  for (const s of subs) s();
};

export async function loadPrices(ids: Iterable<string>) {
  const missing = [...new Set(ids)].filter((id) => !asked.has(id));
  if (!missing.length) return;
  for (const id of missing) asked.add(id);
  const demo = demoBackend();
  if (demo) {
    for (const id of missing) rows.set(id, demoConverted(demo.prices[id] ?? []));
    bump();
    return;
  }
  for (let i = 0; i < missing.length; i += 5000) {
    const chunk = missing.slice(i, i + 5000);
    const { data, error } = await supabase.rpc("card_prices_get", { p_card_ids: chunk });
    if (error) {
      for (const id of chunk) asked.delete(id);
      continue;
    }
    for (const [id, ...v] of data as [string, ...(number | null)[]][]) rows.set(id, v.map((x) => (x == null ? null : Number(x))));
    for (const id of chunk) if (!rows.has(id)) rows.set(id, []);
    bump();
  }
}

/** The demo's prices converted as the server does (rate of 2026-10-28, no guard), so the mark shows in ?demo. */
export function demoConverted(row: (number | null)[]): (number | null)[] {
  const r = [0, 1, 2, 3, 4].map((i) => row[i] ?? null);
  let mask = 0;
  for (const [u, e, bit] of [[0, 3, 1], [1, 4, 2]] as const) {
    if (r[u] == null && r[e] != null && r[e]! > 0) {
      r[u] = Math.round(r[e]! * 1.1133 * 100) / 100;
      mask |= bit;
    }
  }
  return [...r, mask];
}

/** One copy's USD price in a finish and condition (near mint when none is given); null when there's no market price. */
export function usdPrice(cardId: string, finish: Finish, condition = "NM"): number | null {
  const r = rows.get(cardId);
  if (!r) return null;
  return conditionPrice(r[finish === "foil" ? 1 : finish === "etched" ? 2 : 0], condition);
}

/** Whether the USD price of this finish is Cardmarket's converted (contract/converted-prices-2026-10-28.md). */
export function usdConverted(cardId: string, finish: Finish): boolean {
  return rowConverted(rows.get(cardId) ?? [], finish);
}

/** A card_prices_get row without its id: the seventh element is a bitmask of converted finishes (1 nonfoil, 2 foil);
 *  rows from older servers have six. */
export function rowConverted(row: (number | null)[], finish: Finish): boolean {
  const bit = finish === "foil" ? 2 : finish === "etched" ? 0 : 1;
  return bit > 0 && ((row[5] ?? 0) & bit) !== 0;
}

/** "≈ $7,992.55", plus " · from Cardmarket" where there's room to say so. */
export function markConverted(text: string | null, converted: boolean, source = false): string | null {
  return text == null || !converted ? text : `≈ ${text}${source ? " · from Cardmarket" : ""}`;
}

export const usdText = (n: number | null | undefined) =>
  n == null ? null : new Intl.NumberFormat(undefined, { style: "currency", currency: "USD" }).format(n);

/** A copy's price in its condition, saying what near mint would be when it isn't: "$9.00 · LP (NM $10.00)". */
export function conditionPriceText(nearMint: number | null | undefined, condition: string): string | null {
  const price = usdText(conditionPrice(nearMint, condition));
  if (price == null || conditionPercent(condition) === 100) return price;
  return `${price} · ${condition.toUpperCase()} (NM ${usdText(nearMint)})`;
}

/** Re-renders when prices arrive; loads the given printings. */
export function usePrices(ids: string[] | null): number {
  const v = useSyncExternalStore((cb) => {
    subs.add(cb);
    return () => subs.delete(cb);
  }, () => version);
  const key = ids ? ids.length + ":" + (ids[0] ?? "") + ":" + (ids[ids.length - 1] ?? "") : "";
  useEffect(() => {
    if (ids?.length) void loadPrices(ids);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  return v;
}
