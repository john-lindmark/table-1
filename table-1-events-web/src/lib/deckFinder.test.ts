import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { finished, headline, resume, resumeJob, resultOf, type Job } from "./deckFinder";

/* Deck finder jobs (contract/deck-finder-2026-10-15.md § Jobs) against testdata/deck-finder/cases.json, which iOS
   and Android read too. */
const cases = JSON.parse(readFileSync(new URL("../../../testdata/deck-finder/cases.json", import.meta.url), "utf8"));

describe("deck finder jobs", () => {
  it("resumes the newest job while it runs or for an hour after", () => {
    for (const c of cases.resume) expect(resume(c.status, c.finished_seconds_ago), `${c.status} ${c.finished_seconds_ago}`).toBe(c.show);
  });
  it("headline", () => {
    for (const c of cases.headline) expect(headline(c.placement, c.event, c.date)).toBe(c.text);
  });
  it("a job's state", () => {
    const j: Job = { job_id: "j1", status: "done", query: "x", format: "modern", answers: [], result: null, steps: ["Searching the web: x"],
      created_at: "2026-11-01T16:11:02Z", finished_at: "2026-11-01T16:12:10Z" };
    expect(finished(j)).toBe(true);
    expect(finished({ ...j, status: "running" })).toBe(false);
    expect(resumeJob(j, Date.parse("2026-11-01T16:30:00Z"))).toBe(true);
    expect(resumeJob(j, Date.parse("2026-11-01T18:30:00Z"))).toBe(false);
    expect(resumeJob({ ...j, status: "queued", finished_at: null }, Date.parse("2026-11-02T18:30:00Z"))).toBe(true);
    expect(resultOf(j)).toEqual({ status: "error", message: "The deck finder couldn't finish that search. Try again." });
    expect(resultOf({ ...j, result: { status: "not_found", message: "No." } })).toEqual({ status: "not_found", message: "No." });
  });
});
