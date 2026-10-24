import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";
import { betterCondition, conditionPercent, conditionPrice } from "./conditionPrice";
import { addPart, type Part } from "./printings";

vi.mock("./supabaseClient", () => ({ supabase: {} }));
const { conditionPriceText, usdText } = await import("./prices");

/* A copy's price follows its condition (contract/condition-prices-2026-10-24.md) against
   testdata/condition-prices/cases.json (also iOS ConditionPriceTests, Android ConditionPriceTest and the database). */

interface Cases {
  percent: Record<string, number>;
  unit: { nm: number | null; condition: string; price: number | null }[];
  copies: { nm: number | null; condition: string; qty: number }[];
  total: number;
}
const cases: Cases = JSON.parse(readFileSync(new URL("../../../testdata/condition-prices/cases.json", import.meta.url), "utf8"));

describe("condition prices", () => {
  it("shares", () => {
    for (const [k, v] of Object.entries(cases.percent)) expect(conditionPercent(k)).toBe(v);
  });
  it("unit cases", () => {
    for (const u of cases.unit) expect(conditionPrice(u.nm, u.condition), `${u.nm} ${u.condition}`).toBe(u.price);
  });
  it("total", () => {
    const t = cases.copies.reduce((n, c) => n + c.qty * (conditionPrice(c.nm, c.condition) ?? 0), 0);
    expect(t).toBeCloseTo(cases.total, 6);
  });
  it("a printing row is priced by its best copy", () => {
    const parts: Part[] = [];
    addPart(parts, "bolt", "nonfoil", 2, 0, "HP");
    addPart(parts, "bolt", "nonfoil", 1, 0, "LP");
    addPart(parts, "bolt", "nonfoil", 1, 0, "DMG");
    expect(parts).toEqual([{ cardId: "bolt", finish: "nonfoil", qty: 4, p: 0, condition: "LP" }]);
    expect(betterCondition("NM", "DMG")).toBe(true);
  });
  it("details label says what near mint would be", () => {
    expect(conditionPriceText(10, "NM")).toBe(usdText(10));
    expect(conditionPriceText(10, "LP")).toBe(`${usdText(8.5)} · LP (NM ${usdText(10)})`);
    expect(conditionPriceText(null, "LP")).toBeNull();
  });
});
