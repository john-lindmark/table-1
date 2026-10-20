import { describe, expect, it } from "vitest";
import type { CollectionOp, Item } from "./collection";
import { LANGUAGES, langForNew, languageChangeOps, languageName } from "./languages";

/* Changing a card's language (contract/card-language-2026-10-19.md): copies move to the new language in the places they're
   in, Unsorted first unless a place is chosen. Same cases as iOS Table1Tests/LanguageTests.swift. */

const item: Item = { k: "c1|foil|LP|en", cardId: "c1", finish: "foil", condition: "LP", lang: "en", qty: 5, seq: 1 };
const places = [{ place: "b-trade", qty: 2 }, { place: "b-box", qty: 1 }, { place: "unsorted", qty: 2 }];
const summary = (ops: CollectionOp[] | null) =>
  (ops ?? []).map((o) => `${o.lang} ${o.delta} ${o.binder_id ?? "unsorted"} ${o.finish} ${o.condition}`);

describe("language change", () => {
  it("takes Unsorted first, then binders in order", () => {
    expect(summary(languageChangeOps(item, places, "ja", 3))).toEqual([
      "en -2 unsorted foil LP", "ja 2 unsorted foil LP",
      "en -1 b-trade foil LP", "ja 1 b-trade foil LP",
    ]);
  });

  it("keeps every copy in its place", () => {
    const ops = languageChangeOps(item, places, "de", 5) ?? [];
    expect(ops.reduce((n, o) => n + (o.delta ?? 0), 0)).toBe(0);
    expect(new Set(ops.filter((o) => o.lang === "de").map((o) => `${o.binder_id ?? "unsorted"} ${o.delta}`)))
      .toEqual(new Set(["b-trade 2", "b-box 1", "unsorted 2"]));
  });

  it("changes copies from one place", () => {
    expect(summary(languageChangeOps(item, places, "fr", 1, "b-box"))).toEqual(["en -1 b-box foil LP", "fr 1 b-box foil LP"]);
    expect(languageChangeOps(item, places, "fr", 2, "b-box")).toBeNull(); // the place holds only 1
  });

  it("does nothing when nothing would change", () => {
    expect(languageChangeOps(item, places, "en", 1)).toBeNull();
    expect(languageChangeOps(item, places, "ja", 0)).toBeNull();
    expect(languageChangeOps(item, places, "ja", 6)).toBeNull();
  });

  it("adds new copies in their printing's language", () => {
    expect(langForNew("ja", "de")).toBe("ja");
    expect(langForNew("en", "de")).toBe("de");
  });

  it("uses codes the server takes", () => {
    for (const l of LANGUAGES) expect(l.code).toMatch(/^[a-z]{2,3}$/); // collection_items.lang
    expect(languageName("zhs")).toBe("Chinese Simplified");
  });
});
