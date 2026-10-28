import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";

vi.mock("./supabaseClient", () => ({ supabase: {} }));
const { markConverted, rowConverted } = await import("./prices");

/* Converted prices (contract/converted-prices-2026-10-28.md) against testdata/converted-prices/cases.json
   (also iOS ConvertedPriceTests, Android ConvertedPriceTest and the database). */

interface Cases {
  rows: { row: (number | null)[]; finish: "nonfoil" | "foil" | "etched"; usd: number | null; converted: boolean }[];
}
const cases: Cases = JSON.parse(readFileSync(new URL("../../../testdata/converted-prices/cases.json", import.meta.url), "utf8"));

describe("converted prices", () => {
  it("reads the converted bit per finish", () => {
    expect(cases.rows.length).toBeGreaterThan(0);
    for (const r of cases.rows) {
      expect(rowConverted(r.row, r.finish), JSON.stringify(r)).toBe(r.converted);
      const i = r.finish === "foil" ? 1 : r.finish === "etched" ? 2 : 0;
      expect(r.row[i] ?? null, JSON.stringify(r)).toBe(r.usd);
    }
  });

  it("marks a converted price", () => {
    expect(markConverted("$7,992.55", true)).toBe("≈ $7,992.55");
    expect(markConverted("$7,992.55", true, true)).toBe("≈ $7,992.55 · from Cardmarket");
    expect(markConverted("$647.32", false, true)).toBe("$647.32");
    expect(markConverted(null, true)).toBeNull();
  });
});
