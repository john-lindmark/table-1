import { describe, expect, it, vi } from "vitest";

vi.mock("./supabaseClient", () => ({ supabase: {} }));
const { parsePack, coverPrinting } = await import("./catalog");
const { resolveCards } = await import("./rankings");

// Lightning Bolt in three printings (pack format 1), as in catalog.test.ts.
const PACK = [
  "#t1catalog\t1\tv1-test\t1\t3",
  "O\t0\t4457ed35-7c10-48c8-9776-456485fdf070\tLightning Bolt\tlightning bolt\tInstant\t{R}\t1\tR\t",
  "P\t04cb4e4e-8275-4132-8f1a-84b486725400\t0\tf06\t12a\ten\tr\tf\t2006-01-01\t1783943569\t1\t",
  "P\tf29ba16f-c8fb-42fe-aabf-87089cb214a7\t0\t2x2\t117\ten\tu\tfn\t2022-07-08\t1783930000\t1\t",
  "P\t310de1ef-f1b6-4b61-9d6c-6b70382a7f95\t0\t4bb\t208\tes\tc\tn\t1995-04-01\t\t1\tRelámpago",
  "",
].join("\n");
const BOLT = "4457ed35-7c10-48c8-9776-456485fdf070";

describe("the ranker shows cards as the cube has them", () => {
  const c = parsePack("v1-test", PACK);
  it("draws the printing the cube holds", () => {
    const { cards } = resolveCards(c, [BOLT], { [BOLT]: "310de1ef-f1b6-4b61-9d6c-6b70382a7f95" });
    expect(c.pId[cards.get(BOLT)!.p!]).toBe("310de1ef-f1b6-4b61-9d6c-6b70382a7f95");
  });
  it("keeps the usual art without one, or when the card data lacks it", () => {
    const usual = coverPrinting(c, 0);
    expect(resolveCards(c, [BOLT]).cards.get(BOLT)!.p).toBe(usual);
    expect(resolveCards(c, [BOLT], { [BOLT]: "00000000-0000-0000-0000-000000000000" }).cards.get(BOLT)!.p).toBe(usual);
  });
});
