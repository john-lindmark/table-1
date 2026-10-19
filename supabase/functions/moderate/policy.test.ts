import { assert, assertEquals } from "jsr:@std/assert@1";
import { allReview, CATEGORIES, KIND_WORDS, mediaType, parseResults, textPrompt } from "./policy.ts";

const items = [{ id: 11 }, { id: 12 }, { id: 13 }];

Deno.test("parses verdicts by index, in item order", () => {
  const r = parseResults({
    results: [
      { i: 2, verdict: "block", category: "spam", reason: "Advertising" },
      { i: 0, verdict: "allow", category: "none", reason: "" },
      { i: 1, verdict: "review", category: "harassment", reason: "Might target a player" },
    ],
  }, items, "claude-opus-5-5");
  assertEquals(r.map((x) => [x.id, x.verdict, x.category]), [[11, "allow", "none"], [12, "review", "harassment"], [13, "block", "spam"]]);
});

Deno.test("missing or malformed answers go to a person, never allow", () => {
  const r = parseResults({ results: [{ i: 0, verdict: "maybe", category: "none" }] }, items, "m");
  assertEquals(r.map((x) => x.verdict), ["review", "review", "review"]);
  assertEquals(parseResults(null, items, "m").map((x) => x.verdict), ["review", "review", "review"]);
  assertEquals(parseResults("nope", [{ id: 1 }], "m")[0].verdict, "review");
});

Deno.test("child safety always blocks; category agrees with verdict", () => {
  const r = parseResults({
    results: [
      { i: 0, verdict: "review", category: "child_safety", reason: "" },
      { i: 1, verdict: "allow", category: "spam", reason: "" },
      { i: 2, verdict: "block", category: "none", reason: "" },
    ],
  }, items, "m");
  assertEquals(r.map((x) => [x.verdict, x.category]), [["block", "child_safety"], ["allow", "none"], ["block", "other"]]);
});

Deno.test("an unknown category becomes other; the first answer for an index wins", () => {
  const r = parseResults({ results: [{ i: 0, verdict: "block", category: "weird", reason: "x" }, { i: 0, verdict: "allow", category: "none", reason: "" }] },
    [{ id: 1 }], "m");
  assertEquals([r[0].verdict, r[0].category], ["block", "other"]);
});

Deno.test("the prompt carries no ids and names each kind", () => {
  const p = textPrompt([{ id: 987654, kind: "list_name", text: "Burn" }, { id: 5, kind: "display_name", text: "Mara" }]);
  assert(!p.includes("987654"));
  assert(p.includes('"i":0') && p.includes('"i":1'));
  assert(p.includes(KIND_WORDS.list_name));
});

Deno.test("allReview sends everything to a person", () => {
  assertEquals(allReview([{ id: 1 }, { id: 2 }], "x", "m").map((r) => r.verdict), ["review", "review"]);
});

Deno.test("image types from the first bytes", () => {
  assertEquals(mediaType(new Uint8Array([0xff, 0xd8, 0xff, 0xe0])), "image/jpeg");
  assertEquals(mediaType(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 0])), "image/png");
  assertEquals(mediaType(new Uint8Array([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])), "image/webp");
  assertEquals(mediaType(new Uint8Array([1, 2, 3, 4])), null);
});

Deno.test("classifier cases are well formed and lean on Magic false positives", async () => {
  const file = JSON.parse(await Deno.readTextFile(new URL("../../../testdata/moderation/cases.json", import.meta.url)));
  const cases = file.cases as { kind: string; text: string; expect: string }[];
  for (const c of cases) {
    assert(KIND_WORDS[c.kind], `unknown kind ${c.kind}`);
    assert(["allow", "flag", "block"].includes(c.expect), c.text);
    assert(c.text.trim().length > 0);
  }
  // Most cases guard against false positives: card names and archetypes must stay allowed.
  assert(cases.filter((c) => c.expect === "allow").length >= 20);
  assert(CATEGORIES.includes("child_safety"));
});
