import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { cartDirect, cartMenu, money, partTitle, trend, wantDetail } from "./wantPrices";

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

describe("buy on TCGplayer", () => {
  it("labels the parts", () => {
    expect(partTitle(0, 3)).toBe("Part 1 of 3");
    expect(partTitle(2, 3)).toBe("Part 3 of 3");
  });

  it("opens the only link, or shows the menu (testdata/tcgplayer-cart/cases.json)", () => {
    const cart = JSON.parse(readFileSync(new URL("../../../testdata/tcgplayer-cart/cases.json", import.meta.url), "utf8"));
    for (const c of cart.cases) {
      expect(cartDirect(c), c.name).toBe(c.open);
      expect(cartMenu(c), c.name).toEqual(c.menu);
    }
  });

  it("reads an answer from before product links", () => {
    expect(cartMenu({ urls: ["a", "b"] }).map((e) => e.title)).toEqual(["Part 1 of 2", "Part 2 of 2"]);
  });
});
