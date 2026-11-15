// loadPrices waits for a fetch another screen started instead of skipping its cards: a confirmed trade showed no
// prices when the Collection's fetch of every card failed and the trade screen, which asked meanwhile, was never told.
import { describe, expect, it } from "vitest";
import { loadPrices, setPriceFetcherForTests, usdPrice } from "./prices";

const kaldra = "a5a0ae99-d84a-4f27-bed8-889747c78529";
const row = (id: string): [string, ...(number | null)[]] => [id, 9.58, 12.5, null, 5.3, 7.29, 0];
const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

describe("loadPrices", () => {
  it("asks again for cards whose fetch failed while another screen waited on it", async () => {
    let calls = 0;
    setPriceFetcherForTests(async (ids) => {
      const n = ++calls;
      await wait(20);
      if (n === 1) throw new Error("network");
      return ids.map(row);
    });
    const collection = loadPrices([kaldra, "other"]);
    await loadPrices([kaldra]);
    expect(usdPrice(kaldra, "nonfoil", "LP")).toBe(8.62);
    await collection;
    expect(calls).toBe(2);
  });

  it("asks once for cards already being fetched", async () => {
    let calls = 0;
    setPriceFetcherForTests(async (ids) => {
      calls++;
      await wait(20);
      return ids.map(row);
    });
    await Promise.all([loadPrices([kaldra]), loadPrices([kaldra])]);
    expect(usdPrice(kaldra, "nonfoil")).toBe(9.58);
    expect(calls).toBe(1);
  });

  it("doesn't ask again for answered cards, priced or not", async () => {
    const asked: string[][] = [];
    setPriceFetcherForTests(async (ids) => {
      asked.push([...ids].sort());
      return ids.filter((id) => id === kaldra).map(row);
    });
    await loadPrices([kaldra, "unpriced"]);
    await loadPrices([kaldra, "unpriced"]);
    expect(asked).toEqual([[kaldra, "unpriced"]]);
    expect(usdPrice("unpriced", "nonfoil")).toBeNull();
  });
});
