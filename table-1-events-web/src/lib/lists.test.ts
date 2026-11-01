import { describe, expect, it, vi } from "vitest";

vi.mock("./supabaseClient", () => ({ supabase: {} }));
const { boardsOf, countOf, current, diff, entryWire, fromWire, listName, missingIn } = await import("./lists");

const BOLT = "f29ba16f-c8fb-42fe-aabf-87089cb214a7";
const DELVER = "11bf83bb-c95b-4b4f-9a56-ce7a1816307a";

// The shape list_edit / lists_changes return (from the 2026-10-15 dry run on the live database).
const wire = {
  id: "d1", kind: "deck" as const, name: "Burn", format: "modern", seq: 4, current_version: 2, deleted: false,
  versions: [
    { version: 1, note: "Imported", at: 1760000000, entries: [[BOLT, "main", 4]] as [string, "main", number][] },
    { version: 2, note: "Edited", at: 1760086400, entries: [[BOLT, "main", 3], [DELVER, "maybe", 2]] as [string, "main" | "maybe", number][] },
  ],
};

describe("lists wire format", () => {
  it("reads a list with its versions", () => {
    const l = fromWire(wire)!;
    expect(l.versions).toHaveLength(2);
    expect(current(l).number).toBe(2);
    expect(countOf(l, "main")).toBe(3);
    expect(countOf(l, "maybe")).toBe(2);
    expect(boardsOf(l)).toEqual(["main", "maybe"]);
  });
  it("treats a deleted list as gone", () => {
    expect(fromWire({ id: "d1", deleted: true })).toBeNull();
  });
});

describe("diff and missing", () => {
  const l = fromWire(wire)!;
  it("lists removals before additions, per section", () => {
    expect(diff(l.versions[0], l.versions[1])).toEqual([
      { cardId: BOLT, board: "main", delta: -1, finish: "nonfoil", lang: "en" },
      { cardId: DELVER, board: "maybe", delta: 2, finish: "nonfoil", lang: "en" },
    ]);
  });
  it("never counts Considering as missing", () => {
    expect(missingIn(l, new Map([[`${BOLT}|nonfoil`, 1]]), new Set())).toBe(2);
    expect(missingIn(l, new Map([[`${BOLT}|nonfoil`, 3]]), new Set())).toBe(0);
  });
  it("splits finishes into their own lines; any finish of the card covers them (contract/owned-by-card-2026-10-31.md)", () => {
    const split = fromWire({ id: "x", kind: "deck", name: "x", format: "modern",
      versions: [{ version: 1, note: "Created", at: 0, entries: [[BOLT, "main", 2], [BOLT, "main", 2, "foil"]] }] })!;
    expect(split.versions[0].entries).toEqual([{ cardId: BOLT, board: "main", qty: 2 }, { cardId: BOLT, board: "main", qty: 2, finish: "foil" }]);
    expect(missingIn(split, new Map([[`${BOLT}|nonfoil`, 4]]), new Set())).toBe(0);
    expect(missingIn(split, new Map([[`${BOLT}|foil`, 3]]), new Set())).toBe(1);
    expect(missingIn(split, new Map([[`${BOLT}|nonfoil`, 2], [`${BOLT}|foil`, 2]]), new Set())).toBe(0);
  });
});

describe("languages (contract/lists-2026-10-15.md, Languages)", () => {
  const l = fromWire({ id: "x", kind: "cube", name: "x", format: "vintage", versions: [
    { version: 1, note: "Created", at: 0, entries: [[BOLT, "main", 2]] },
    { version: 2, note: "Edited", at: 1, entries: [[BOLT, "main", 1], [BOLT, "main", 1, "nonfoil", "ja"], [DELVER, "main", 1, "foil", "de"]] },
  ] })!;
  it("reads the fifth element as the line's language", () => {
    expect(current(l).entries).toEqual([{ cardId: BOLT, board: "main", qty: 1 }, { cardId: BOLT, board: "main", qty: 1, lang: "ja" },
                                        { cardId: DELVER, board: "main", qty: 1, finish: "foil", lang: "de" }]);
  });
  it("writes the language only when it isn't English, with the finish before it", () => {
    expect(current(l).entries.map(entryWire)).toEqual([[BOLT, "main", 1], [BOLT, "main", 1, "nonfoil", "ja"], [DELVER, "main", 1, "foil", "de"]]);
  });
  it("sees a language change in the history", () => {
    expect(diff(l.versions[0], l.versions[1]).filter((c) => c.cardId === BOLT)).toEqual([
      { cardId: BOLT, board: "main", delta: -1, finish: "nonfoil", lang: "en" },
      { cardId: BOLT, board: "main", delta: 1, finish: "nonfoil", lang: "ja" },
    ]);
  });
  it("counts Missing over every language", () => {
    expect(missingIn(l, new Map([[`${BOLT}|nonfoil`, 2]]), new Set())).toBe(1);
  });
});

describe("renaming a deck or cube", () => {
  it("keeps the name the way the server stores it", () => {
    expect(listName("  Izzet Murktide \n")).toBe("Izzet Murktide");
    expect(listName("a".repeat(70))).toHaveLength(60);
    expect(listName("   ")).toBe(""); // blank keeps the old name
  });
});
