import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { decideNext, type TrackerNext, type TrackerNextAnswer } from "./trackerNext";

/* The life tracker follows its player into the next round (contract/life-tracker-options-2026-10-20.md § Next round),
   against testdata/tracker-next/cases.json (also iOS TrackerNextTests, Android TrackerNextTest). */
type Case = { name: string; current: string | null; answer: TrackerNextAnswer | null; want: TrackerNext };
const file: { cases: Case[] } = JSON.parse(readFileSync(new URL("../../../testdata/tracker-next/cases.json", import.meta.url), "utf8"));

describe("decideNext", () => {
  it("has cases", () => expect(file.cases.length).toBeGreaterThan(0));
  for (const c of file.cases) {
    it(c.name, () => expect(decideNext(c.current, c.answer)).toEqual(c.want));
  }
});
