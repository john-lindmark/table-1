import { describe, expect, it } from "vitest";
import { parseLayout, runStacks } from "./cardLayout";

describe("parseLayout", () => {
  it("keeps a saved layout", () => {
    expect(parseLayout("stacks", "1")).toBe("stacks");
    expect(parseLayout("list", "1")).toBe("list");
  });
  it("carries the old grid flag over, otherwise list", () => {
    expect(parseLayout(null, "1")).toBe("grid");
    expect(parseLayout(null, "0")).toBe("list");
    expect(parseLayout("bogus", null)).toBe("list");
  });
});

describe("runStacks", () => {
  const cards = Array.from({ length: 23 }, (_, i) => ({ n: i, set: i < 3 ? "mh3" : i < 5 ? "" : "lea" }));
  it("makes runs of ten in order when not sorted by set", () => {
    const s = runStacks(cards, false, (c) => c.set, "recent|");
    expect(s.map((x) => x.items.length)).toEqual([10, 10, 3]);
    expect(s[1].items[0].n).toBe(10);
    expect(s.every((x) => x.title === undefined)).toBe(true);
    expect(new Set(s.map((x) => x.key)).size).toBe(3);
  });
  it("makes one titled stack per consecutive set when sorted by set", () => {
    const s = runStacks(cards, true, (c) => c.set);
    expect(s.map((x) => [x.title, x.items.length])).toEqual([["MH3", 3], ["Unknown set", 2], ["LEA", 18]]);
  });
  it("keeps a set that comes back later as its own stack with its own key", () => {
    const s = runStacks([{ set: "sld" }, { set: "sld" }, { set: "mh3" }, { set: "sld" }], true, (c) => c.set);
    expect(s.map((x) => [x.title, x.items.length])).toEqual([["SLD", 2], ["MH3", 1], ["SLD", 1]]);
    expect(new Set(s.map((x) => x.key)).size).toBe(3);
  });
  it("handles nothing", () => {
    expect(runStacks([], true, () => "")).toEqual([]);
    expect(runStacks([], false, () => "")).toEqual([]);
  });
});
