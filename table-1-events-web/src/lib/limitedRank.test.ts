// Ranking a Limited set and New in Insights pushes against testdata/limited-rankings/cases.json (iOS
// LimitedRankingsTests, Android LimitedRankingsTest read the same cases).
import { describe, expect, it } from "vitest";
import cases from "../../../testdata/limited-rankings/cases.json";
import { insightsPush, limitedLabel, limitedPicker, rankableDetail, type RankableSet, setKeyOf, setSubjectId, sharingLabel, soonText, subjectRow } from "./limitedRank";

describe("limited rankings", () => {
  it("names a set's subject", () => {
    for (const c of cases.subjects) expect(setSubjectId(c.set_key)).toBe(c.id);
    for (const c of cases.keys) expect(setKeyOf(c.id)).toBe(c.key);
  });

  it("reads rows of cubes and of sets as one subject id", () => {
    for (const c of cases.rows) {
      const r = subjectRow(c.json as { list_id: string | null; set_key?: string | null });
      expect(r.list_id).toBe(c.subject);
      expect(!!setKeyOf(r.list_id)).toBe(c.is_set);
    }
  });

  it("labels sharing by subject", () => {
    for (const c of cases.sharing) expect(sharingLabel(c.sharing as "cube" | "private", c.set)).toBe(c.label);
  });

  it("routes New in Insights pushes", () => {
    for (const c of cases.pushes) expect(insightsPush(c.info)).toEqual(c.route);
  });

  it("sums up a set to rank", () => {
    const today = new Date("2026-10-30T12:00:00Z");
    expect(rankableDetail({ key: "PWR-2510", name: "Arena Powered Cube · Oct 2025", released: "2025-10-30", kind: "cube", cards: 540, pack: true, mine: 1, rankings: 3 }, today))
      .toBe("Arena cube · 540 cards · 3 rankings (1 yours)");
    expect(rankableDetail({ key: "NHZ", name: "New Horizons", released: "2026-11-14", kind: "set", cards: 264, pack: false, mine: 0, rankings: 0 }, today))
      .toBe("Out Nov 14 · 264 cards");
    expect(rankableDetail({ key: "FRA", name: "Foundations Remastered", released: "2026-09-23", kind: "set", cards: 281, pack: true, mine: 0, rankings: 1 }, today))
      .toBe("281 cards · 1 ranking");
  });

  it("labels the set picker and puts sets with no data yet first", () => {
    for (const c of cases.labels) expect(limitedLabel(c.key, c.name)).toBe(c.label);
    for (const c of cases.picker) expect(limitedPicker(c.packs, c.rankable as RankableSet[], c.today)).toEqual(c.chips);
    for (const c of cases.soon) expect(soonText(c.set as RankableSet, c.today)).toBe(c.text);
  });
});
