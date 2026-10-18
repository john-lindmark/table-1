import { describe, expect, it, vi } from "vitest";

vi.mock("./supabaseClient", () => ({ supabase: {} }));
const { normName, parsePack, searchCatalog, cardImageUrl, coverPrinting, legalityOf, printingsByName, tokenIndexes } = await import("./catalog");

// Header, three cards (sorted by name_norm) and four printings, in pack format 1.
const PACK = [
  "#t1catalog\t1\tv1-test\t3\t4",
  "O\t0\tae92942b-919c-4ea9-b693-85fcef765d5a\tFire // Ice\tfire ice\tInstant // Instant\t{1}{R} // {1}{U}\t4\tRU\tFire // Ice",
  "O\t1\t4457ed35-7c10-48c8-9776-456485fdf070\tLightning Bolt\tlightning bolt\tInstant\t{R}\t1\tR\t",
  "O\t2\t11111111-1111-1111-1111-111111111111\tLightning Bolt Token\tlightning bolt token\tToken Creature — Elemental\t\t0\tR\t",
  "P\t04cb4e4e-8275-4132-8f1a-84b486725400\t0\tf06\t12a\ten\tr\tf\t2006-01-01\t1783943569\t1\t",
  "P\tf29ba16f-c8fb-42fe-aabf-87089cb214a7\t1\t2x2\t117\ten\tu\tfn\t2022-07-08\t1783930000\t1\t",
  "P\t310de1ef-f1b6-4b61-9d6c-6b70382a7f95\t1\t4bb\t208\tes\tc\tn\t1995-04-01\t\t1\tRelámpago",
  "P\t22222222-2222-2222-2222-222222222222\t2\ttfoo\t1\ten\tc\tn\t2020-01-01\t\t0\t",
  "X\tfuture line type is ignored",
  "",
].join("\n");

describe("normName matches public.card_name_norm", () => {
  it.each([
    ["Æther Vial", "aether vial"],
    ["Lim-Dûl the Necromancer", "lim dul the necromancer"],
    ["Urza's Saga", "urzas saga"],
    ["Fire // Ice", "fire ice"],
    ["  Jötun   Grunt ", "jotun grunt"],
  ])("%s → %s", (input, out) => expect(normName(input)).toBe(out));
});

describe("parsePack", () => {
  const c = parsePack("v1-test", PACK);
  it("reads cards and printings into columns", () => {
    expect(c.oracles).toBe(3);
    expect(c.printings).toBe(4);
    expect(c.oName[1]).toBe("Lightning Bolt");
    expect(c.oFaces[0]).toBe("Fire // Ice");
    expect(c.pFirst[1]).toBe(1);
    expect(c.pCount[1]).toBe(2);
    expect(c.pPrintedName[2]).toBe("Relámpago");
    expect(c.printingIndex.get("f29ba16f-c8fb-42fe-aabf-87089cb214a7")).toBe(1);
  });
  it("rejects an unknown format", () => {
    expect(() => parsePack("x", "#t1catalog\t2\tv\t0\t0")).toThrow();
  });
  it("builds Scryfall CDN image urls", () => {
    expect(cardImageUrl(c, 1)).toBe(
      "https://cards.scryfall.io/normal/front/f/2/f29ba16f-c8fb-42fe-aabf-87089cb214a7.jpg?1783930000",
    );
  });
});

describe("produced mana and tokens", () => {
  const pack = [
    "#t1catalog\t1\tv1-test\t3\t0",
    "O\t0\t11111111-1111-1111-1111-111111111111\tElemental\telemental\tToken Creature — Elemental\t\t0\tR\t\t--------\t\t\t",
    "O\t1\t22222222-2222-2222-2222-222222222222\tPolluted Delta\tpolluted delta\tLand\t\t0\t\t\t--LLL-LL\t\tUB\t",
    "O\t2\t33333333-3333-3333-3333-333333333333\tYoung Pyromancer\tyoung pyromancer\tCreature — Human Shaman\t{1}{R}\t2\tR\t\t-LLLLLL-\t\t\t0",
  ].join("\n");
  const c = parsePack("v1-test", pack);
  it("reads the trailing fields", () => {
    expect(c.oProduced).toEqual(["", "UB", ""]);
    expect(tokenIndexes(c, 2)).toEqual([0]);
    expect(tokenIndexes(c, 1)).toEqual([]);
  });
  it("leaves produced unknown in older packs", () => {
    expect(parsePack("v1-test", PACK).oProduced[1]).toBeNull();
  });
});

describe("legality and original printing", () => {
  const pack = [
    "#t1catalog\t1\tv1-test\t2\t3",
    "O\t0\t5089ec1a-f881-4d55-af14-5d996171203b\tBlack Lotus\tblack lotus\tArtifact\t{0}\t0\t\t\t---BR-B-\t7",
    "O\t1\t4457ed35-7c10-48c8-9776-456485fdf070\tLightning Bolt\tlightning bolt\tInstant\t{R}\t1\tR\t",
    "P\tbd8fa327-dd41-4737-8f19-2cf5eb1f7cdd\t0\tlea\t232\ten\tr\tn\t1993-08-05\t1\t1\t\t1",
    "P\tf29ba16f-c8fb-42fe-aabf-87089cb214a7\t1\t2x2\t117\ten\tu\tfn\t2022-07-08\t1\t1\t",
    "P\t11111111-2222-3333-4444-555555555555\t1\tlea\t161\ten\tc\tn\t1993-08-05\t1\t1\t\t1",
  ].join("\n");
  const c = parsePack("v1-test", pack);
  it("reads legality codes per format", () => {
    expect(legalityOf(c, 0, "vintage")).toBe("restricted");
    expect(legalityOf(c, 0, "legacy")).toBe("banned");
    expect(legalityOf(c, 0, "modern")).toBe("not_legal");
    expect(legalityOf(c, 0, "other")).toBeNull();
    expect(legalityOf(c, 1, "modern")).toBeNull(); // no code in the pack
    expect(legalityOf(c, 0, "canlander")).toBe("legal"); // restricted in Vintage is fine in a singleton format
  });
  it("reads Canadian Highlander points", () => {
    expect(c.oPoints[0]).toBe(7);
    expect(c.oPoints[1]).toBe(0);
  });
  it("defaults to the original printing, not the newest", () => {
    expect(coverPrinting(c, 1)).toBe(2);
    expect(coverPrinting(c, 0)).toBe(0);
  });
});

describe("printingsByName", () => {
  const c = parsePack("v1-test", PACK);
  it("finds exact names, front faces and skips unknown names", () => {
    const m = printingsByName(c, ["Lightning Bolt", "Fire", "Not A Card"]);
    expect(m.get("Lightning Bolt")).toBe(coverPrinting(c, 1));
    expect(m.get("Fire")).toBe(coverPrinting(c, 0));
    expect(m.has("Not A Card")).toBe(false);
  });
});

describe("searchCatalog", () => {
  const c = parsePack("v1-test", PACK);
  const names = (q: string) => searchCatalog(c, q).map((i) => c.oName[i]);
  it("puts an exact name first", () => {
    expect(names("lightning bolt")).toEqual(["Lightning Bolt", "Lightning Bolt Token"]);
  });
  it("puts prefix matches first and tokens last", () => {
    expect(names("light")).toEqual(["Lightning Bolt", "Lightning Bolt Token"]);
  });
  it("finds a word inside the name and ignores accents and punctuation", () => {
    expect(names("bolt")).toEqual(["Lightning Bolt", "Lightning Bolt Token"]);
    expect(names("ice")).toEqual(["Fire // Ice"]);
  });
  it("needs two characters", () => {
    expect(names("l")).toEqual([]);
  });
});
