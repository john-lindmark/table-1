// The deck-finder agent's pure parts (agent.ts): the prompt, shaping a report, and taking a Table 1 deck's exact list.
import { test } from "node:test";
import assert from "node:assert/strict";
import { placementOf, prompt, shape, stepOfResult, stepsOf, withTable1Deck } from "./agent.ts";

test("prompt carries the date, the format and every answer", () => {
  const p = prompt("boros energy", "modern", [{ question: "Which?", answer: "Boros" }], new Date("2026-11-01T16:00:00Z"));
  assert.equal(p, "Today is 2026-11-01.\n\nRequest: boros energy\n\nDeck format chosen in the app: modern.\n\nYou asked: Which?\nPlayer answered: Boros");
  assert.equal(prompt("x", null, []), `Today is ${new Date().toISOString().slice(0, 10)}.\n\nRequest: x`);
});

test("placement from rank, top 8 or record", () => {
  assert.equal(placementOf({ rank: 1 }), "1st");
  assert.equal(placementOf({ rank: 2 }), "2nd");
  assert.equal(placementOf({ rank: 3 }), "3rd");
  assert.equal(placementOf({ rank: 5, top8: true }), "5th");
  assert.equal(placementOf({ rank: null, top8: true }), "Top 8");
  assert.equal(placementOf({ rank: 12, top8: false, wins: 5, losses: 2, draws: 0 }), "12th");
  assert.equal(placementOf({ rank: 21 }), "21st");
  assert.equal(placementOf({ rank: 111 }), "111th");
  assert.equal(placementOf({ wins: 5, losses: 0, draws: 1 }), "5-0-1");
  assert.equal(placementOf({}), "");
});

const report = {
  status: "deck", question: "", options: [], message: "",
  deck: { name: "Boros Energy", archetype: "Boros Energy", format: "Modern", event: "typed wrong", date: "", placement: "", player: "",
          source_url: "", notes: "Won yesterday", table1_deck_id: 99001, main: [{ qty: 4, name: "Guide of Souls" }], side: [] },
};
const db = {
  deck_id: 99001, format: "modern", date: "2026-10-30", archetype: "Boros Energy", rank: 1, top8: true, wins: 8, losses: 1, draws: 0,
  event: "Modern Challenge 32", url: "https://www.mtgo.com/decklist/modern-challenge-32", source: "mtgo", players: 58,
  main: [{ qty: 4, name: "Guide of Souls" }, { qty: 3, name: "Ajani, Nacatl Pariah" }], side: [{ qty: 2, name: "Wear // Tear" }],
};

test("a Table 1 deck replaces the transcription with the exact list and event", () => {
  const r = shape(withTable1Deck(report, db));
  assert.equal(r.status, "deck");
  assert.deepEqual(r.deck, {
    name: "Boros Energy", archetype: "Boros Energy", format: "modern", event: "Modern Challenge 32", date: "2026-10-30", placement: "1st",
    player: "", source_url: "https://www.mtgo.com/decklist/modern-challenge-32", notes: "Won yesterday", from: "table1",
    main: [{ qty: 4, name: "Guide of Souls" }, { qty: 3, name: "Ajani, Nacatl Pariah" }], side: [{ qty: 2, name: "Wear // Tear" }],
  });
});

test("no Table 1 deck: the report as the model wrote it, from the web", () => {
  const r = shape(withTable1Deck({ ...report, deck: { ...report.deck, table1_deck_id: 0, source_url: "https://mtgdecks.net/x" } }, null));
  assert.equal(r.deck?.from, "web");
  assert.equal(r.deck?.event, "typed wrong");
  assert.equal(r.deck?.source_url, "https://mtgdecks.net/x");
  // An empty answer from the database leaves the report alone too.
  assert.equal(shape(withTable1Deck(report, { deck_id: 99001, main: [] })).deck?.event, "typed wrong");
});

test("shape: questions, not found, bad lines, unknown formats", () => {
  assert.deepEqual(shape({ status: "question", question: " Which Energy? ", options: ["Boros", "", "Jeskai", 4, "a", "b", "c", "d"] }),
    { status: "question", question: "Which Energy?", options: ["Boros", "Jeskai", "a", "b", "c"] });
  assert.deepEqual(shape({ status: "not_found", message: "" }), { status: "not_found", message: "No suitable list turned up." });
  assert.deepEqual(shape({ status: "deck", deck: { main: [] } }), { status: "not_found", message: "No suitable list turned up." });
  const r = shape({ status: "deck", deck: { name: "", archetype: "Affinity", format: "Timeless", source_url: "mtgo.com", main: [{ qty: 4.4, name: " Frogmite " }, { qty: 0, name: "x" }, { qty: 2 }] } });
  assert.deepEqual(r.deck, { name: "Affinity", archetype: "Affinity", format: "other", event: "", date: "", placement: "", player: "", source_url: "", notes: "",
    from: "web", main: [{ qty: 4, name: "Frogmite" }], side: [] });
});

test("the work, in words: remarks, web searches, pages and Table 1 lookups", () => {
  const steps = stepsOf([
    { type: "text", text: "  Let me check Table 1's results\n first. " },
    { type: "tool_use", name: "table1_events", input: { format: "modern", days: 7, archetype: "Energy" } },
    { type: "tool_use", name: "table1_events", input: { format: "canlander" } },
    { type: "tool_use", name: "table1_decklist", input: { deck_id: 169410 } },
    { type: "server_tool_use", name: "web_search", input: { query: "boros energy modern challenge october 2026" } },
    { type: "server_tool_use", name: "web_fetch", input: { url: "https://www.mtgo.com/decklist/modern-challenge-32-2026-10-3012857384#deck_1" } },
    { type: "server_tool_use", name: "web_fetch", input: { url: "not a url" } },
    { type: "web_search_tool_result", content: [] },
    { type: "tool_use", name: "report_result", input: {} },
  ]);
  assert.deepEqual(steps, [
    "Let me check Table 1's results first.",
    "Checking Table 1's results: Modern, last 7 days, \"Energy\"",
    "Checking Table 1's results: Canadian Highlander, last 30 days",
    "Reading deck 169410 from Table 1's results",
    "Searching the web: boros energy modern challenge october 2026",
    "Reading www.mtgo.com/decklist/modern-challenge-32-2026-10-3012857384",
    "Reading not a url",
  ]);
  assert.equal(stepsOf([{ type: "text", text: "x".repeat(300) }])[0].length, 160);
  assert.deepEqual(stepsOf([{ type: "text", text: "   " }]), []);
});

test("what a lookup found", () => {
  assert.equal(stepOfResult("table1_events", []), "Nothing in Table 1's results for that");
  assert.equal(stepOfResult("table1_events", [{ name: "Modern Challenge 32", date: "2026-10-31", decks: [{}, {}] }, { name: "x", decks: [{}] }]),
    "2 events with 3 decks, newest Modern Challenge 32 · 2026-10-31");
  assert.equal(stepOfResult("table1_events", [{ name: "RC", decks: [{}] }]), "1 event with 1 deck, newest RC");
  assert.equal(stepOfResult("table1_decklist", { archetype: "Boros Energy", rank: 1, event: "Modern Challenge 32", main: [{ qty: 4, name: "x" }] }),
    "Read Boros Energy · 1st at Modern Challenge 32");
  assert.equal(stepOfResult("table1_decklist", { error: "No deck" }), "No such deck in Table 1's results");
  assert.equal(stepOfResult("table1_decklist", { main: [{ qty: 1, name: "x" }] }), "Read A deck");
  assert.equal(stepOfResult("other", {}), null);
});
