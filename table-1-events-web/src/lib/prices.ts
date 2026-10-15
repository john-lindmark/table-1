// Current market prices for printings (card_prices_get), fetched on demand and kept for the page's life.
// USD is TCGplayer's market price as Scryfall publishes it; EUR is Cardmarket's. Prices are near mint.
import { useEffect, useSyncExternalStore } from "react";
import { supabase } from "./supabaseClient";
import { demoBackend, type Finish } from "./collection";

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

export function usdPrice(cardId: string, finish: Finish): number | null {
  const r = rows.get(cardId);
  if (!r) return null;
  return r[finish === "foil" ? 1 : finish === "etched" ? 2 : 0] ?? null;
}

export const usdText = (n: number | null | undefined) =>
  n == null ? null : new Intl.NumberFormat(undefined, { style: "currency", currency: "USD" }).format(n);

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
