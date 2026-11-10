import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { popularDetail, subjectNoun, type PopularCube } from "./limitedRank";

// Shared with iOS PopularCubesTests and Android PopularCubesTest.
const cases = JSON.parse(readFileSync(new URL("../../../testdata/popular-cubes/cases.json", import.meta.url), "utf8")) as {
  detail: { cube: PopularCube; want: string }[]; noun: { kind: string | null; want: string }[];
};

describe("popular cubes", () => {
  it.each(cases.detail)("detail $want", ({ cube, want }) => expect(popularDetail(cube)).toBe(want));
  it.each(cases.noun)("noun for $kind", ({ kind, want }) => expect(subjectNoun(kind)).toBe(want));
});
