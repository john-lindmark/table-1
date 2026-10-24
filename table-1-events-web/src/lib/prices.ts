// Current market prices for printings (card_prices_get), fetched on demand and kept for the page's life.
// USD is TCGplayer's market price as Scryfall publishes it; EUR is Cardmarket's. Prices are near mint; usdPrice
// prices a copy in its condition (conditionPrice).
import { useEffect, useSyncExternalStore } from "react";
import { supabase } from "./supabaseClient";
import { demoBackend, type Finish } from "./collection";
import { conditionPercent, conditionPrice } from "./conditionPrice";

/** [usd, usd_foil, usd_etched, eur, eur_foil] */
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
    for (const id of missing) rows.set(id, demo.prices[id] ?? []);
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

/** One copy's USD price in a finish and condition (near mint when none is given); null when there's no market price. */
export function usdPrice(cardId: string, finish: Finish, condition = "NM"): number | null {
  const r = rows.get(cardId);
  if (!r) return null;
  return conditionPrice(r[finish === "foil" ? 1 : finish === "etched" ? 2 : 0], condition);
}

export const usdText = (n: number | null | undefined) =>
  n == null ? null : new Intl.NumberFormat(undefined, { style: "currency", currency: "USD" }).format(n);

/** A copy's price in its condition, saying what near mint would be when it isn't: "$8.50 · LP (NM $10.00)". */
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
