/* A copy's price follows its condition (contract/condition-prices-2026-10-24.md, cases
   testdata/condition-prices/cases.json). Market prices are near mint; other conditions are a fixed share of them.
   Same rule as iOS `Conditions.price`, Android `Conditions.price` and the server's `t1_private.condition_price`. */

const ORDER = ["NM", "LP", "MP", "HP", "DMG"];

/** The share of the near-mint price a copy in this condition is worth. */
export function conditionPercent(condition: string | null | undefined): number {
  switch ((condition ?? "").toUpperCase()) {
    case "LP": return 85;
    case "MP": return 70;
    case "HP": return 50;
    case "DMG": return 35;
    default: return 100;
  }
}

/** One copy's price in its condition from the near-mint price: whole cents, half up, never below a cent. */
export function conditionPrice(nearMint: number | null | undefined, condition: string | null | undefined): number | null {
  if (nearMint == null) return null;
  const cents = Math.round(nearMint * 100);
  if (cents <= 0) return nearMint;
  return Math.max(1, Math.floor((cents * conditionPercent(condition) + 50) / 100)) / 100;
}

/** True when a is a better condition than b (NM before LP … DMG). */
export function betterCondition(a: string, b: string): boolean {
  const ia = ORDER.indexOf(a), ib = ORDER.indexOf(b);
  return (ia < 0 ? ORDER.length : ia) < (ib < 0 ? ORDER.length : ib);
}
