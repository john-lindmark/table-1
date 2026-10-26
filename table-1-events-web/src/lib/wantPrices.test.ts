import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { money, trend, wantDetail } from "./wantPrices";

/* Want prices (contract/want-prices-2026-10-26.md) against testdata/want-prices/cases.json, which iOS and Android read too. */

const cases = JSON.parse(readFileSync(new URL("../../../testdata/want-prices/cases.json", import.meta.url), "utf8"));

describe("want prices", () => {
  it("writes money in whole cents", () => {
    for (const c of cases.money) expect(money(c.v)).toBe(c.want);
  });

  it("says which way the price went", () => {
    for (const c of cases.trend) expect(trend(c.now, c.then, c.days)).toEqual(c.want);
  });

  it("writes a Wanted row's detail", () => {
    for (const c of cases.detail) expect(wantDetail(c.which, c.max, c.now, c.any)).toBe(c.want);
  });
});
