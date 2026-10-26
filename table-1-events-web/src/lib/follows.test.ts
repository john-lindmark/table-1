import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { redactPath, screenName } from "./analytics";
import { ago, change, followDetail, followHome, followHref, followSections, type Follow } from "./follows";

/* Following (contract/follows-2026-10-25.md) against testdata/follows/cases.json, which iOS and Android read too. */

const cases = JSON.parse(readFileSync(new URL("../../../testdata/follows/cases.json", import.meta.url), "utf8"));

describe("follows", () => {
  it("says how long ago and what changed", () => {
    for (const a of cases.ago) expect(ago(a.seconds)).toBe(a.text);
    for (const c of cases.change) expect(change(c.added, c.removed)).toBe(c.text);
  });

  it("writes the Following and Library home lines", () => {
    const now = new Date(cases.now);
    for (const d of cases.detail) expect(followDetail(d.follow, now)).toBe(d.text);
    for (const h of cases.home) expect(followHome(h.items)).toBe(h.text);
  });

  it("splits an update into Added and Taken out", () => {
    for (const s of cases.sections) {
      const got = followSections(s.cards);
      expect(got.added).toEqual(s.added);
      expect(got.removed).toEqual(s.removed);
    }
  });

  it("reads server timestamps with microseconds", () => {
    const f = { ...cases.detail[2].follow, last_update: { ...cases.detail[2].follow.last_update, at: "2026-10-25T15:59:59.500000+00:00" } } as Follow;
    expect(followDetail(f, new Date(cases.now))).toBe(cases.detail[2].text);
  });

  it("opens through the profile or the link it was followed with, never when unavailable", () => {
    const base = cases.detail[0].follow as Follow;
    expect(followHref({ ...base, user_id: "u1" })).toBe(`/u/u1/deck/${base.id}`);
    expect(followHref({ ...base, user_id: "u1", token: "tok" })).toBe("/l/tok");
    expect(followHref({ ...base, available: false, user_id: "u1" })).toBeNull();
  });

  it("names the screens", () => {
    expect(screenName("/library/following")).toBe("following");
    expect(screenName("/library/following/deck/d1")).toBe("follow_changes");
    expect(redactPath("/library/following/deck/2b1d")).toBe("/library/following/deck/:id");
  });
});
