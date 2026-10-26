// Alert text for `want.price` (contract/want-prices-2026-10-26.md): one push a day when wants got meaningfully
// cheaper or fell to their max. `data` comes from t1_private.want_price_digest: n, names (up to 3, biggest first)
// and the first want's name, price, pct (under its 30-day average), reason (drop / under_max) and max.
import { nameList } from "./follow.ts";

const usd = (v: unknown) => `$${Number(v ?? 0).toFixed(2)}`;

export function wantPriceCopy(d: Record<string, unknown>): { title: string; body: string } {
  const names = Array.isArray(d.names) ? d.names.map(String) : [];
  const n = Number(d.n ?? names.length) || 1;
  const name = String(d.name ?? names[0] ?? "A card you want");
  const first = d.reason === "under_max" && d.max != null
    ? `${name} is ${usd(d.price)}, under your max of ${usd(d.max)}.`
    : `${name} is ${usd(d.price)}, ${d.pct}% under its 30-day average.`;
  const rest = nameList(names.slice(1), n - 1);
  return { title: n === 1 ? "Price alert" : "Price alerts", body: rest ? `${first} Also cheaper: ${rest}.` : first };
}
