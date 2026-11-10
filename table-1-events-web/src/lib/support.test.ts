import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { FAQ, GUIDE, LIMIT, queryWords, STOP, supportSearch, words } from "./support";

/* Support (contract/support-2026-11-10.md): the search rule against testdata/support-search/cases.json from its
   Python reference, and the bundled files kept user-facing (tools/support/scrub.json's forbidden patterns). */

const read = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");
const cases = JSON.parse(read("../../../testdata/support-search/cases.json"));
const scrub = JSON.parse(read("../../../tools/support/scrub.json"));

describe("support search", () => {
  it("shares the stop words and limit", () => {
    expect([...STOP].sort()).toEqual(cases.stop);
    expect(LIMIT).toBe(cases.limit);
  });

  type Norm = { text: string; words: string[] };
  type Case = { query: string; words: string[]; partial: boolean; count: number; top: string[] };
  it.each((cases.normalize as Norm[]).map((c) => [c.text, c] as [string, Norm]))("normalizes %s", (_, c) => {
    expect(words(c.text)).toEqual(c.words);
  });

  it.each((cases.cases as Case[]).map((c) => [c.query, c] as [string, Case]))("finds %s", (_, c) => {
    const { hits, partial } = supportSearch(c.query);
    expect(queryWords(c.query)).toEqual(c.words);
    expect(partial).toBe(c.partial);
    expect(hits.length).toBe(c.count);
    expect(hits.slice(0, 8).map((h) => `${h.doc.kind}:${h.doc.id}:${h.score}`)).toEqual(c.top);
  });
});

describe("support content", () => {
  const forbidden = new RegExp(scrub.forbidden.join("|"));
  const sections = new Set(GUIDE.sections.map((s) => s.id));

  it("says nothing that isn't for players", () => {
    for (const f of FAQ.faqs) for (const t of [f.q, f.a]) expect(t, f.id).not.toMatch(forbidden);
    for (const e of GUIDE.entries) for (const t of [e.h, e.t, e.x]) if (t) expect(t, e.id).not.toMatch(forbidden);
  });

  it("links every answer to a topic and a guide section that exist", () => {
    const topics = new Set(FAQ.topics.map((t) => t.key));
    for (const f of FAQ.faqs) {
      expect(topics.has(f.topic), f.id).toBe(true);
      if (f.guide) expect(sections.has(f.guide), `${f.id} → ${f.guide}`).toBe(true);
    }
    for (const t of FAQ.topics) expect(FAQ.faqs.some((f) => f.topic === t.key), t.key).toBe(true);
  });

  it("keeps ids unique and every entry in a section", () => {
    const ids = [...FAQ.faqs.map((f) => f.id), ...GUIDE.entries.map((e) => e.id)];
    expect(new Set(ids).size).toBe(ids.length);
    for (const e of GUIDE.entries) expect(sections.has(e.s), e.id).toBe(true);
  });
});
